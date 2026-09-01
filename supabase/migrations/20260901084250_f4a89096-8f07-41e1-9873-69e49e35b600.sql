CREATE OR REPLACE FUNCTION public.create_sales_return(p_original_invoice_id uuid, p_return_date date, p_items jsonb, p_description text DEFAULT NULL::text, p_warehouse_id uuid DEFAULT NULL::uuid, p_return_doc_no text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id             UUID;
  v_year                INTEGER;
  v_month               INTEGER;
  v_orig_invoice        RECORD;
  v_return_invoice_id   UUID;
  v_return_inv_number   TEXT;
  v_journal_entry_id    UUID;
  v_journal_number      TEXT;
  v_txn_id              UUID;
  v_warehouse_id        UUID;

  v_item_elem           JSONB;
  v_line_number         INTEGER := 0;
  v_item_prod_id        UUID;
  v_item_name           TEXT;
  v_item_unit           TEXT;
  v_item_qty            NUMERIC;
  v_item_price          NUMERIC;
  v_item_vat_rate       NUMERIC;
  v_item_disc_rate      NUMERIC;
  v_item_subtotal       NUMERIC;
  v_item_discount       NUMERIC;
  v_item_line_total     NUMERIC;
  v_item_taxable        NUMERIC;
  v_item_vat_amount     NUMERIC;
  v_item_cost_unit      NUMERIC;
  v_item_cost_total     NUMERIC;

  v_calc_taxable        NUMERIC := 0;
  v_calc_vat            NUMERIC := 0;
  v_calc_grand_total    NUMERIC := 0;
  v_calc_cost_total     NUMERIC := 0;

  v_acc_120_id          UUID;
  v_acc_610_id          UUID;
  v_acc_191_id          UUID;
  v_acc_153_id          UUID;
  v_acc_621_id          UUID;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.' USING ERRCODE = '42501';
  END IF;

  IF p_return_date IS NULL THEN
    RAISE EXCEPTION 'İade tarihi zorunludur.';
  END IF;

  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'İade edilecek en az bir ürün/hizmet kalemi seçilmelidir.';
  END IF;

  IF p_original_invoice_id IS NULL THEN
    RAISE EXCEPTION 'Satış iadesi için orijinal fatura seçilmelidir.';
  END IF;

  PERFORM public.assert_accounting_period_open(v_user_id, p_return_date);

  v_year  := EXTRACT(YEAR FROM p_return_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM p_return_date)::INTEGER;

  SELECT * INTO v_orig_invoice
  FROM public.invoices
  WHERE id = p_original_invoice_id
    AND user_id = v_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Orijinal satış faturası bulunamadı (ID: %)', p_original_invoice_id;
  END IF;

  v_warehouse_id := COALESCE(p_warehouse_id, v_orig_invoice.warehouse_id);
  IF v_warehouse_id IS NULL THEN
    SELECT id INTO v_warehouse_id
    FROM public.warehouses
    WHERE user_id = v_user_id AND deleted_at IS NULL
    ORDER BY is_default DESC, created_at ASC
    LIMIT 1;
  END IF;

  IF p_return_doc_no IS NOT NULL AND trim(p_return_doc_no) != '' THEN
    v_return_inv_number := trim(p_return_doc_no);
  ELSE
    v_return_inv_number := public.next_entry_number_with_prefix(v_user_id, v_year, 'IAD');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.invoices
    WHERE user_id = v_user_id
      AND invoice_number = v_return_inv_number
      AND status <> 'IPTAL'
  ) THEN
    RAISE EXCEPTION 'Bu iade belge numarası ile kayıtlı bir fatura zaten mevcut: %', v_return_inv_number;
  END IF;

  INSERT INTO public.invoices (
    user_id, customer_id, warehouse_id, invoice_number, invoice_date,
    type, status, currency, exchange_rate, ettn, notes, created_at, updated_at
  ) VALUES (
    v_user_id,
    v_orig_invoice.customer_id,
    v_warehouse_id,
    v_return_inv_number,
    p_return_date,
    'SATIS_IADE',
    'ONAYLANDI',
    COALESCE(v_orig_invoice.currency, 'TRY'),
    COALESCE(v_orig_invoice.exchange_rate, 1),
    LOWER(gen_random_uuid()::TEXT),
    COALESCE(p_description, 'Satış İadesi: ' || COALESCE(v_orig_invoice.invoice_number, '')),
    now(),
    now()
  )
  RETURNING id INTO v_return_invoice_id;

  FOR v_item_elem IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_line_number     := v_line_number + 1;
    v_item_prod_id    := NULLIF(v_item_elem->>'productId', '')::UUID;
    v_item_name       := COALESCE(v_item_elem->>'name', 'İade Kalemi');
    v_item_unit       := COALESCE(v_item_elem->>'unit', 'Adet');
    v_item_qty        := COALESCE((v_item_elem->>'quantity')::NUMERIC, 1);
    v_item_price      := COALESCE((v_item_elem->>'unitPrice')::NUMERIC, 0);
    v_item_vat_rate   := COALESCE((v_item_elem->>'vatRate')::NUMERIC, 20);
    v_item_disc_rate  := COALESCE((v_item_elem->>'discountRate')::NUMERIC, 0);

    IF v_item_qty <= 0 THEN
      RAISE EXCEPTION 'İade miktarı 0 dan büyük olmalıdır: %', v_item_name;
    END IF;

    v_item_subtotal   := round(v_item_qty * v_item_price, 2);
    v_item_discount   := round(v_item_subtotal * (v_item_disc_rate / 100.0), 2);
    v_item_taxable    := v_item_subtotal - v_item_discount;
    v_item_vat_amount := round(v_item_taxable * (v_item_vat_rate / 100.0), 2);
    v_item_line_total := v_item_taxable + v_item_vat_amount;

    v_calc_taxable     := v_calc_taxable + v_item_taxable;
    v_calc_vat         := v_calc_vat + v_item_vat_amount;
    v_calc_grand_total := v_calc_grand_total + v_item_line_total;

    v_item_cost_unit := 0;
    v_item_cost_total := 0;
    IF v_item_prod_id IS NOT NULL THEN
      SELECT COALESCE(NULLIF(unit_cost, 0), purchase_price, 0) INTO v_item_cost_unit
      FROM public.products
      WHERE id = v_item_prod_id AND user_id = v_user_id;

      v_item_cost_unit  := COALESCE(v_item_cost_unit, 0);
      v_item_cost_total := round(v_item_qty * v_item_cost_unit, 2);
      v_calc_cost_total := v_calc_cost_total + v_item_cost_total;
    END IF;

    INSERT INTO public.invoice_items (
      user_id, invoice_id, product_id, line_number, name, description, unit,
      quantity, unit_price, discount_rate, subtotal, discount_amount,
      taxable_amount, vat_rate, vat_amount, line_total, unit_cost, total_cost,
      currency, exchange_rate, created_at
    ) VALUES (
      v_user_id, v_return_invoice_id, v_item_prod_id, v_line_number, v_item_name,
      COALESCE(v_item_elem->>'description', ''), v_item_unit,
      v_item_qty, v_item_price, v_item_disc_rate, v_item_subtotal, v_item_discount,
      v_item_taxable, v_item_vat_rate, v_item_vat_amount, v_item_line_total,
      v_item_cost_unit, v_item_cost_total,
      COALESCE(v_orig_invoice.currency, 'TRY'), COALESCE(v_orig_invoice.exchange_rate, 1), now()
    );

    IF v_item_prod_id IS NOT NULL THEN
      INSERT INTO public.stock_movements (
        user_id, product_id, warehouse_id, movement_type, quantity, unit_price,
        unit_cost, total_cost, movement_date, document_no, description,
        source, source_id, created_at
      ) VALUES (
        v_user_id, v_item_prod_id, v_warehouse_id, 'GIRIS', v_item_qty, v_item_price,
        v_item_cost_unit, v_item_cost_total, p_return_date, v_return_inv_number,
        'Satış İadesi: ' || v_return_inv_number, 'SATIS_IADE', v_return_invoice_id, now()
      );
    END IF;
  END LOOP;

  UPDATE public.invoices
  SET subtotal       = v_calc_taxable,
      taxable_amount = v_calc_taxable,
      total_vat      = v_calc_vat,
      grand_total    = v_calc_grand_total,
      updated_at     = now()
  WHERE id = v_return_invoice_id;

  IF v_orig_invoice.customer_id IS NOT NULL AND v_calc_grand_total > 0 THEN
    INSERT INTO public.account_transactions (
      user_id, customer_id, source_id, txn_date, txn_type, amount,
      document_no, description, source, created_at, updated_at
    ) VALUES (
      v_user_id, v_orig_invoice.customer_id, v_return_invoice_id, p_return_date,
      'ALACAK', v_calc_grand_total, v_return_inv_number,
      'Satış İadesi Alacak Kaydı: ' || v_return_inv_number, 'FATURA', now(), now()
    )
    RETURNING id INTO v_txn_id;
  END IF;

  SELECT id INTO v_acc_120_id
  FROM public.chart_of_accounts
  WHERE (code = '120' OR system_tag = 'ALICILAR')
    AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true
  ORDER BY user_id NULLS LAST LIMIT 1;

  SELECT id INTO v_acc_610_id
  FROM public.chart_of_accounts
  WHERE (code = '610' OR code = '600' OR system_tag = 'SATIS_IADE' OR system_tag = 'YURTICI_SATIS')
    AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true
  ORDER BY (code = '610') DESC, user_id NULLS LAST LIMIT 1;

  SELECT id INTO v_acc_191_id
  FROM public.chart_of_accounts
  WHERE (code = '191' OR system_tag = 'INDIRILECEK_KDV')
    AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true
  ORDER BY user_id NULLS LAST LIMIT 1;

  SELECT id INTO v_acc_153_id
  FROM public.chart_of_accounts
  WHERE (code = '153' OR system_tag = 'STOK')
    AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true
  ORDER BY user_id NULLS LAST LIMIT 1;

  SELECT id INTO v_acc_621_id
  FROM public.chart_of_accounts
  WHERE (code = '621' OR system_tag = 'STMM')
    AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true
  ORDER BY user_id NULLS LAST LIMIT 1;

  v_journal_number := public.next_entry_number(v_user_id, v_year, 'JOURNAL');

  INSERT INTO public.journal_entries (
    user_id, entry_number, entry_date, description, entry_type, source_type,
    source_id, status, period_year, period_month, created_at, updated_at
  ) VALUES (
    v_user_id, v_journal_number, p_return_date,
    'Satış İadesi Muhasebe Kaydı: ' || v_return_inv_number,
    'MAHSUP', 'SALES_RETURN', v_return_invoice_id, 'POSTED',
    v_year, v_month, now(), now()
  )
  RETURNING id INTO v_journal_entry_id;

  IF v_calc_taxable > 0 AND v_acc_610_id IS NOT NULL THEN
    INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
    VALUES (v_journal_entry_id, v_user_id, v_acc_610_id, 'Satış İadesi Matrahı: ' || v_return_inv_number, v_calc_taxable, 0, COALESCE(v_orig_invoice.currency, 'TRY'), 1);
  END IF;

  IF v_calc_vat > 0 AND v_acc_191_id IS NOT NULL THEN
    INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
    VALUES (v_journal_entry_id, v_user_id, v_acc_191_id, 'Satış İadesi KDV: ' || v_return_inv_number, v_calc_vat, 0, COALESCE(v_orig_invoice.currency, 'TRY'), 1);
  END IF;

  IF v_calc_grand_total > 0 AND v_acc_120_id IS NOT NULL THEN
    INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
    VALUES (v_journal_entry_id, v_user_id, v_acc_120_id, 'Satış İadesi Müşteri Alacağı: ' || v_return_inv_number, 0, v_calc_grand_total, COALESCE(v_orig_invoice.currency, 'TRY'), 1);
  END IF;

  IF v_calc_cost_total > 0 AND v_acc_153_id IS NOT NULL AND v_acc_621_id IS NOT NULL THEN
    INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
    VALUES (v_journal_entry_id, v_user_id, v_acc_153_id, 'Satış İadesi Stok Maliyet Girişi: ' || v_return_inv_number, v_calc_cost_total, 0, COALESCE(v_orig_invoice.currency, 'TRY'), 1);

    INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
    VALUES (v_journal_entry_id, v_user_id, v_acc_621_id, 'Satış İadesi STMM Azalışı: ' || v_return_inv_number, 0, v_calc_cost_total, COALESCE(v_orig_invoice.currency, 'TRY'), 1);
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'return_invoice_id', v_return_invoice_id,
    'invoice_number', v_return_inv_number,
    'type', 'SATIS_IADE',
    'status', 'ONAYLANDI',
    'grand_total', v_calc_grand_total,
    'taxable_amount', v_calc_taxable,
    'vat_amount', v_calc_vat,
    'cost_total', v_calc_cost_total,
    'journal_entry_id', v_journal_entry_id,
    'journal_entry_number', v_journal_number
  );
END;
$function$;