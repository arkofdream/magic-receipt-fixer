-- 1) SATIŞ FATURASI ONAYI: hizmet kalemleri stok/STMM üretmesin
CREATE OR REPLACE FUNCTION public.approve_sales_invoice(p_invoice_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id           UUID;
  v_inv               RECORD;
  v_item              JSONB;
  v_item_name         TEXT;
  v_product_id        UUID;
  v_quantity          NUMERIC;
  v_unit_price        NUMERIC;
  v_discount_rate     NUMERIC;
  v_vat_rate          NUMERIC;
  v_unit              TEXT;
  v_item_subtotal     NUMERIC;
  v_item_discount     NUMERIC;
  v_item_taxable      NUMERIC;
  v_unit_cost         NUMERIC;
  v_total_cost        NUMERIC;
  v_total_stmm        NUMERIC := 0;
  v_is_return         BOOLEAN;
  v_is_stock          BOOLEAN;
  v_year              INTEGER;
  v_month             INTEGER;
  v_now               TIMESTAMPTZ := now();
  v_line_number       INTEGER := 0;
  v_journal_entry_id  UUID;
  v_journal_number    TEXT;
  v_acc_120_id        UUID;
  v_acc_600_id        UUID;
  v_acc_391_id        UUID;
  v_acc_153_id        UUID;
  v_acc_621_id        UUID;
  v_product_ids       UUID[];
  v_locked_product    RECORD;
  v_due_date          DATE;
  v_payment_term_days INTEGER;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id AND user_id = v_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fatura bulunamadı.'; END IF;

  IF v_inv.status IN ('ONAYLANDI', 'SENT') THEN
    RETURN jsonb_build_object('success', true, 'message', 'Fatura zaten onaylı.');
  END IF;
  IF v_inv.status = 'IPTAL' THEN RAISE EXCEPTION 'İptal edilmiş fatura onaylanamaz.'; END IF;

  IF v_inv.items IS NULL OR jsonb_array_length(v_inv.items) = 0 THEN
    RAISE EXCEPTION 'Fatura en az bir kalem içermelidir.';
  END IF;

  PERFORM public.assert_accounting_period_open(v_user_id, v_inv.invoice_date);

  v_year := EXTRACT(YEAR FROM v_inv.invoice_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM v_inv.invoice_date)::INTEGER;
  v_is_return := (v_inv.type IN ('SATIS_IADE', 'IADE'));

  v_payment_term_days := 30;
  IF v_inv.customer_id IS NOT NULL THEN
    SELECT COALESCE(c.payment_term_days, 30) INTO v_payment_term_days
    FROM public.customers c WHERE c.id = v_inv.customer_id;
  END IF;
  v_due_date := v_inv.invoice_date + v_payment_term_days;

  SELECT array_agg(DISTINCT pid ORDER BY pid)
  INTO v_product_ids
  FROM (
    SELECT COALESCE(
      NULLIF(trim(item->>'productId'), ''),
      NULLIF(trim(item->>'product_id'), '')
    )::UUID AS pid
    FROM jsonb_array_elements(v_inv.items) AS item
    WHERE COALESCE(NULLIF(trim(item->>'productId'), ''), NULLIF(trim(item->>'product_id'), '')) IS NOT NULL
  ) sub;

  IF v_product_ids IS NOT NULL AND array_length(v_product_ids, 1) > 0 THEN
    FOR v_locked_product IN
      SELECT id FROM public.products WHERE id = ANY(v_product_ids) AND user_id = v_user_id AND deleted_at IS NULL ORDER BY id ASC FOR UPDATE
    LOOP NULL; END LOOP;
  END IF;

  -- Taslak aşamasında yazılmış kalemler varsa temizle (mükerrer kayıt önlenir)
  DELETE FROM public.invoice_items WHERE invoice_id = p_invoice_id AND user_id = v_user_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_inv.items)
  LOOP
    v_line_number := v_line_number + 1;
    v_item_name   := COALESCE(NULLIF(trim(v_item->>'name'), ''), 'Genel Kalem');
    v_product_id  := COALESCE(NULLIF(v_item->>'productId', ''), NULLIF(v_item->>'product_id', ''))::UUID;
    v_quantity    := COALESCE((v_item->>'quantity')::NUMERIC, 1);
    v_unit_price  := COALESCE((v_item->>'unitPrice')::NUMERIC, (v_item->>'unit_price')::NUMERIC, 0);
    v_discount_rate := COALESCE((v_item->>'discountRate')::NUMERIC, (v_item->>'discount_rate')::NUMERIC, 0);
    v_vat_rate    := COALESCE((v_item->>'vatRate')::NUMERIC, (v_item->>'vat_rate')::NUMERIC, 20);
    v_unit        := COALESCE(v_item->>'unit', 'Adet');

    v_item_subtotal := ROUND(v_quantity * v_unit_price, 2);
    v_item_discount := ROUND(v_item_subtotal * (v_discount_rate / 100.0), 2);
    v_item_taxable  := v_item_subtotal - v_item_discount;

    IF v_product_id IS NULL THEN
      SELECT id INTO v_product_id FROM public.products
      WHERE user_id = v_user_id AND LOWER(trim(name)) = LOWER(trim(v_item_name)) AND deleted_at IS NULL LIMIT 1;

      IF v_product_id IS NULL THEN
        -- Serbest metin kalemi: katalog kartı açılır ancak stok takibi yapılmaz
        INSERT INTO public.products (
          user_id, name, unit, unit_price, vat_rate, track_stock, created_at, updated_at
        ) VALUES (
          v_user_id, v_item_name, v_unit, v_unit_price, v_vat_rate, false, v_now, v_now
        ) RETURNING id INTO v_product_id;
      END IF;
    END IF;

    -- Hizmet / stok takipsiz kalemler stok ve maliyet üretmez
    v_is_stock := true;
    IF v_product_id IS NOT NULL THEN
      SELECT COALESCE(track_stock, true) INTO v_is_stock FROM public.products WHERE id = v_product_id;
      v_is_stock := COALESCE(v_is_stock, true);
    END IF;

    v_unit_cost := 0;
    IF v_is_stock AND v_product_id IS NOT NULL THEN
      SELECT COALESCE(NULLIF(unit_cost, 0), NULLIF(purchase_price, 0), 0)
      INTO v_unit_cost FROM public.products WHERE id = v_product_id;
    END IF;
    v_unit_cost := COALESCE(v_unit_cost, 0);
    v_total_cost := ROUND(v_unit_cost * v_quantity, 2);
    v_total_stmm := v_total_stmm + v_total_cost;

    INSERT INTO public.invoice_items (
      user_id, invoice_id, product_id, line_number, name, description, unit,
      quantity, unit_price, discount_rate, vat_rate, subtotal, discount_amount,
      taxable_amount, vat_amount, line_total, unit_cost, total_cost
    ) VALUES (
      v_user_id, p_invoice_id, v_product_id, v_line_number,
      v_item_name, COALESCE(v_item->>'description', ''), v_unit,
      v_quantity, v_unit_price, v_discount_rate, v_vat_rate,
      v_item_subtotal, v_item_discount, v_item_taxable,
      ROUND(v_item_taxable * (v_vat_rate / 100.0), 2),
      v_item_taxable + ROUND(v_item_taxable * (v_vat_rate / 100.0), 2),
      v_unit_cost, v_total_cost
    ) ON CONFLICT DO NOTHING;

    IF v_product_id IS NOT NULL AND v_is_stock AND v_quantity > 0 THEN
      INSERT INTO public.stock_movements (
        user_id, product_id, warehouse_id, movement_type, quantity, unit_price,
        unit_cost, total_cost, document_no, description, movement_date, source, source_id, created_at
      ) VALUES (
        v_user_id, v_product_id, v_inv.warehouse_id,
        CASE WHEN v_is_return THEN 'GIRIS' ELSE 'CIKIS' END,
        v_quantity, v_unit_price, v_unit_cost, v_total_cost,
        v_inv.invoice_number,
        CASE WHEN v_is_return THEN 'Satış İade Faturası Kalemi' ELSE 'Satış Faturası Kalemi' END,
        v_inv.invoice_date, 'FATURA', p_invoice_id, v_now
      );

      UPDATE public.products SET updated_at = v_now WHERE id = v_product_id;
    END IF;
  END LOOP;

  UPDATE public.invoices
  SET status = 'ONAYLANDI', posted = true, gib_approval_date = v_now, updated_at = v_now
  WHERE id = p_invoice_id;

  IF v_inv.customer_id IS NOT NULL AND v_inv.grand_total > 0 THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.account_transactions
      WHERE source = 'FATURA' AND source_id = p_invoice_id AND user_id = v_user_id
    ) THEN
      INSERT INTO public.account_transactions (
        user_id, customer_id, source_id, txn_date, due_date, txn_type, amount, document_no, description, source, created_at
      ) VALUES (
        v_user_id, v_inv.customer_id, p_invoice_id, v_inv.invoice_date, v_due_date,
        CASE WHEN v_is_return THEN 'ALACAK' ELSE 'BORC' END,
        v_inv.grand_total, v_inv.invoice_number,
        CASE WHEN v_is_return THEN 'Satış İade Faturası Alacak Kaydı' ELSE 'Satış Faturası Borç Kaydı' END,
        'FATURA', v_now
      );
    END IF;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.journal_entries WHERE source_type = 'INVOICE' AND source_id = p_invoice_id AND status = 'POSTED') THEN
    DELETE FROM public.journal_entries WHERE source_type = 'INVOICE' AND source_id = p_invoice_id AND status = 'DRAFT';

    SELECT id INTO v_acc_120_id FROM public.chart_of_accounts WHERE (code = '120' OR system_tag IN ('ALICILAR', 'AR')) AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
    SELECT id INTO v_acc_600_id FROM public.chart_of_accounts WHERE (code = '600' OR system_tag IN ('YURTICI_SATIS', 'SATIS_GELIRI')) AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
    SELECT id INTO v_acc_391_id FROM public.chart_of_accounts WHERE (code = '391' OR system_tag IN ('HESAPLANAN_KDV', 'TAX_OUTPUT')) AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
    SELECT id INTO v_acc_153_id FROM public.chart_of_accounts WHERE (code = '153' OR system_tag IN ('STOK', 'INVENTORY')) AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
    SELECT id INTO v_acc_621_id FROM public.chart_of_accounts WHERE (code = '621' OR system_tag IN ('STMM', 'COGS')) AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;

    v_journal_number := public.next_entry_number(v_user_id, v_year, 'JOURNAL');

    INSERT INTO public.journal_entries (
      user_id, entry_number, entry_date, description, entry_type, source_type, source_id, status, period_year, period_month, created_at, updated_at
    ) VALUES (
      v_user_id, v_journal_number, v_inv.invoice_date, 'Satış Faturası Tahakkuku: ' || v_inv.invoice_number, 'MAHSUP', 'INVOICE', p_invoice_id, 'DRAFT', v_year, v_month, v_now, v_now
    ) RETURNING id INTO v_journal_entry_id;

    IF COALESCE(v_inv.taxable_amount, 0) > 0 AND v_acc_600_id IS NOT NULL THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_600_id, 'Yurtiçi Satışlar', 0, v_inv.taxable_amount, 'TRY', 1);
    END IF;

    IF COALESCE(v_inv.total_vat, 0) > 0 AND v_acc_391_id IS NOT NULL THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_391_id, 'Hesaplanan KDV', 0, v_inv.total_vat, 'TRY', 1);
    END IF;

    IF COALESCE(v_inv.grand_total, 0) > 0 AND v_acc_120_id IS NOT NULL THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_120_id, 'Müşteri Borcu', v_inv.grand_total, 0, 'TRY', 1);
    END IF;

    IF v_total_stmm > 0 AND v_acc_153_id IS NOT NULL AND v_acc_621_id IS NOT NULL THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_621_id, 'Satılan Ticari Mallar Maliyeti', v_total_stmm, 0, 'TRY', 1);

      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_153_id, 'Stok Çıkışı', 0, v_total_stmm, 'TRY', 1);
    END IF;

    UPDATE public.journal_entries SET status = 'POSTED', updated_at = v_now WHERE id = v_journal_entry_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'invoice_id', p_invoice_id, 'message', 'Satış faturası başarıyla onaylandı ve muhasebeleşti.');
END;
$function$;

-- 2) FATURA İPTALİ: ters stok kaydı gerçekte oluşan hareketlerden üretilsin
CREATE OR REPLACE FUNCTION public.cancel_sales_invoice(p_invoice_id uuid, p_cancel_reason text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id         UUID;
  v_invoice         RECORD;
  v_is_return       BOOLEAN;
  v_sm              RECORD;
  v_now             TIMESTAMPTZ := now();
  v_journal         RECORD;
  v_reversal_je_id  UUID;
  v_line            RECORD;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.' USING ERRCODE = '42501';
  END IF;

  IF p_invoice_id IS NULL THEN
    RAISE EXCEPTION 'Fatura ID zorunludur.';
  END IF;

  SELECT * INTO v_invoice
  FROM public.invoices
  WHERE id = p_invoice_id AND user_id = v_user_id AND deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fatura bulunamadı veya bu işlem için yetkiniz yok. Fatura ID: %', p_invoice_id;
  END IF;

  IF v_invoice.status = 'IPTAL' THEN
    RAISE EXCEPTION 'Bu fatura zaten iptal edilmiştir. Fatura No: %', v_invoice.invoice_number;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.invoices r
    WHERE r.original_invoice_id = p_invoice_id
      AND r.user_id = v_user_id
      AND r.status <> 'IPTAL'
      AND r.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Bu faturaya iade işlemi yapılmış. Önce iade faturasını iptal edin.';
  END IF;

  v_is_return := (v_invoice.type IN ('IADE', 'SATIS_IADE'));

  UPDATE public.invoices
  SET
    status = 'IPTAL',
    cancel_date = v_now,
    notes = CASE
      WHEN p_cancel_reason IS NOT NULL AND trim(p_cancel_reason) != '' THEN
        CASE
          WHEN notes IS NULL OR trim(notes) = '' THEN 'İptal Nedeni: ' || trim(p_cancel_reason)
          ELSE notes || ' | İptal Nedeni: ' || trim(p_cancel_reason)
        END
      ELSE notes
    END,
    updated_at = v_now
  WHERE id = p_invoice_id;

  IF v_invoice.posted = true THEN

    IF v_invoice.customer_id IS NOT NULL AND v_invoice.grand_total > 0 THEN
      INSERT INTO public.account_transactions (
        user_id, customer_id, txn_date, txn_type, amount, document_no, description, source, source_id
      ) VALUES (
        v_user_id, v_invoice.customer_id, v_now::date,
        CASE WHEN v_is_return THEN 'BORC' ELSE 'ALACAK' END,
        v_invoice.grand_total, v_invoice.invoice_number,
        CASE
          WHEN v_is_return THEN 'İade Faturası İptali (Borç Düzeltme) - ' || v_invoice.invoice_number
          ELSE 'Satış Faturası İptali (Alacak Düzeltme) - ' || v_invoice.invoice_number
        END,
        'FATURA_IPTAL', p_invoice_id
      );
    END IF;

    -- Stok ters kaydı: faturanın gerçekte oluşturduğu hareketlerden türetilir
    FOR v_sm IN
      SELECT * FROM public.stock_movements
      WHERE user_id = v_user_id
        AND source_id = p_invoice_id
        AND source IN ('FATURA', 'SATIS_IADE')
        AND deleted_at IS NULL
    LOOP
      IF COALESCE(v_sm.quantity, 0) > 0 THEN
        INSERT INTO public.stock_movements (
          user_id, product_id, warehouse_id, customer_id, movement_date, movement_type,
          quantity, unit_price, unit_cost, total_cost, document_no, description, source, source_id
        ) VALUES (
          v_user_id, v_sm.product_id, v_sm.warehouse_id, v_invoice.customer_id, v_now::date,
          CASE WHEN v_sm.movement_type = 'CIKIS' THEN 'GIRIS' ELSE 'CIKIS' END,
          v_sm.quantity, v_sm.unit_price, v_sm.unit_cost, v_sm.total_cost,
          v_invoice.invoice_number,
          'Fatura İptali Ters Stok Kaydı - ' || v_invoice.invoice_number,
          'FATURA_IPTAL', p_invoice_id
        );
      END IF;
    END LOOP;

    IF EXISTS (
      SELECT 1 FROM public.invoice_tax_lines
      WHERE invoice_id = p_invoice_id AND is_reversal = false
    ) THEN
      INSERT INTO public.invoice_tax_lines (
        invoice_id, user_id, direction, vat_rate, taxable_amount, tax_amount,
        withholding_rate, withholding_amount, is_exempt, exemption_code,
        is_cancelled, is_reversal, reversal_of, currency, exchange_rate,
        taxable_amount_try, tax_amount_try, period_year, period_month
      )
      SELECT
        invoice_id, user_id, direction, vat_rate, taxable_amount, tax_amount,
        withholding_rate, withholding_amount, is_exempt, exemption_code,
        true, true, id, currency, exchange_rate,
        taxable_amount_try, tax_amount_try,
        EXTRACT(YEAR FROM v_now)::INTEGER, EXTRACT(MONTH FROM v_now)::INTEGER
      FROM public.invoice_tax_lines
      WHERE invoice_id = p_invoice_id AND is_reversal = false;
    END IF;

    SELECT * INTO v_journal
    FROM public.journal_entries
    WHERE source_type = 'INVOICE' AND source_id = p_invoice_id AND status = 'POSTED'
    LIMIT 1;

    IF FOUND THEN
      INSERT INTO public.journal_entries (
        user_id, entry_number, entry_date, description, entry_type, source_type,
        source_id, status, period_year, period_month
      ) VALUES (
        v_user_id,
        public.next_entry_number(v_user_id, EXTRACT(YEAR FROM v_now)::INTEGER, 'JOURNAL'),
        v_now::date,
        'Fatura İptal Yevmiye Fişi - ' || v_invoice.invoice_number,
        'MAHSUP', 'INVOICE_CANCEL', p_invoice_id, 'DRAFT',
        EXTRACT(YEAR FROM v_now)::INTEGER, EXTRACT(MONTH FROM v_now)::INTEGER
      )
      RETURNING id INTO v_reversal_je_id;

      FOR v_line IN
        SELECT * FROM public.journal_lines WHERE journal_entry_id = v_journal.id
      LOOP
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit,
          currency, foreign_amount, exchange_rate
        ) VALUES (
          v_reversal_je_id, v_user_id, v_line.account_id,
          'İptal Ters Kaydı: ' || COALESCE(v_line.description, ''),
          v_line.credit, v_line.debit,
          v_line.currency, v_line.foreign_amount, v_line.exchange_rate
        );
      END LOOP;

      UPDATE public.journal_entries SET status = 'POSTED' WHERE id = v_reversal_je_id;
    END IF;

  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'id', p_invoice_id,
    'invoice_number', v_invoice.invoice_number,
    'status', 'IPTAL',
    'cancel_date', v_now
  );
END;
$function$;