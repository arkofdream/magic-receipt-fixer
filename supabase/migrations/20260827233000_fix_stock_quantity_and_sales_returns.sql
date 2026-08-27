-- ============================================================================
-- FAZ 4.2: DÖNEM KAPATMA, FATURA NUMARASI VE SATIŞ İADESİ GÜVENCESİ
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-27
-- ============================================================================

-- 1. get_product_stock_quantity Fonksiyonu Güvencesi
-- PostgREST PGRST203 overload çakışmasını önlemek için tek parametreli tanım kaldırılır;
-- default parametreli kanonik imza (p_product_id UUID, p_warehouse_id UUID DEFAULT NULL) kullanılır.
DROP FUNCTION IF EXISTS public.get_product_stock_quantity(UUID);
DROP FUNCTION IF EXISTS public.get_product_stock_quantity(UUID, UUID);

CREATE OR REPLACE FUNCTION public.get_product_stock_quantity(
  p_product_id   UUID,
  p_warehouse_id UUID DEFAULT NULL
)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
  v_qty     NUMERIC := 0;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    SELECT user_id INTO v_user_id FROM public.products WHERE id = p_product_id;
  END IF;

  IF v_user_id IS NULL THEN
    RETURN 0;
  END IF;

  SELECT COALESCE(SUM(
    CASE
      WHEN movement_type IN ('GIRIS', 'TRANSFER_IN') THEN quantity
      WHEN movement_type IN ('CIKIS', 'TRANSFER_OUT') THEN -quantity
      ELSE 0
    END
  ), 0)
  INTO v_qty
  FROM public.stock_movements
  WHERE product_id = p_product_id
    AND user_id = v_user_id
    AND deleted_at IS NULL
    AND (p_warehouse_id IS NULL OR warehouse_id = p_warehouse_id);

  RETURN v_qty;
END;
$$;

REVOKE ALL ON FUNCTION public.get_product_stock_quantity(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_product_stock_quantity(UUID, UUID) TO authenticated, service_role;


-- 2. BENZERSİZ VE DAYANIKLI FATURA NUMARASI ÜRETİMİ (next_entry_number_with_prefix)
-- Mevcut tablodaki en büyük numarayı dinamik denetler; sayaç uyumsuzluğunu self-heal eder ve duplicate constraint ihlalini kesin olarak önler.
CREATE OR REPLACE FUNCTION public.next_entry_number_with_prefix(
  p_user_id    UUID,
  p_year       INTEGER,
  p_prefix     TEXT DEFAULT 'EAR'
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_next         BIGINT;
  v_max_existing BIGINT := 0;
  v_clean_prefix TEXT;
  v_pattern      TEXT;
  v_candidate    TEXT;
BEGIN
  v_clean_prefix := UPPER(COALESCE(NULLIF(trim(p_prefix), ''), 'EAR'));
  IF LENGTH(v_clean_prefix) > 3 THEN
    v_clean_prefix := SUBSTRING(v_clean_prefix FROM 1 FOR 3);
  ELSIF LENGTH(v_clean_prefix) < 3 THEN
    v_clean_prefix := RPAD(v_clean_prefix, 3, 'X');
  END IF;

  v_pattern := v_clean_prefix || p_year::TEXT || '%';

  -- 1. Invoices tablosunda mevcut en yüksek sıra numarasını bul
  SELECT COALESCE(MAX(
    CASE
      WHEN invoice_number ~ ('^' || v_clean_prefix || p_year::TEXT || '[0-9]{9}$')
      THEN SUBSTRING(invoice_number FROM 8 FOR 9)::BIGINT
      ELSE 0
    END
  ), 0)
  INTO v_max_existing
  FROM public.invoices
  WHERE user_id = p_user_id
    AND invoice_number LIKE v_pattern;

  -- 2. Sayacı en yüksek mevcut numara ile senkronize et
  INSERT INTO public.entry_counters (user_id, year, counter_type, last_number, updated_at)
  VALUES (p_user_id, p_year, 'INVOICE_' || v_clean_prefix, GREATEST(v_max_existing, 0) + 1, now())
  ON CONFLICT (user_id, year, counter_type)
  DO UPDATE SET
    last_number = GREATEST(entry_counters.last_number, v_max_existing) + 1,
    updated_at  = now()
  RETURNING last_number INTO v_next;

  -- 3. Çakışma denetimi (Güvenlik Döngüsü)
  LOOP
    v_candidate := v_clean_prefix || p_year::TEXT || LPAD(v_next::TEXT, 9, '0');
    EXIT WHEN NOT EXISTS (
      SELECT 1 FROM public.invoices
      WHERE user_id = p_user_id AND invoice_number = v_candidate
    );
    v_next := v_next + 1;
    UPDATE public.entry_counters
    SET last_number = v_next, updated_at = now()
    WHERE user_id = p_user_id AND year = p_year AND counter_type = ('INVOICE_' || v_clean_prefix);
  END LOOP;

  RETURN v_candidate;
END;
$$;

GRANT EXECUTE ON FUNCTION public.next_entry_number_with_prefix TO authenticated, service_role;


-- 3. ATOMİK SATIŞ İADESİ RPC'Sİ (create_sales_return)
CREATE OR REPLACE FUNCTION public.create_sales_return(
  p_original_invoice_id UUID,
  p_return_date         DATE,
  p_items               JSONB,
  p_description         TEXT DEFAULT NULL,
  p_warehouse_id        UUID DEFAULT NULL,
  p_return_doc_no       TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
  v_item_prod_id        UUID;
  v_item_name           TEXT;
  v_item_unit           TEXT;
  v_item_qty            NUMERIC;
  v_item_price          NUMERIC;
  v_item_vat_rate       NUMERIC;
  v_item_disc_rate      NUMERIC;
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
  v_calc_debit          NUMERIC;
  v_calc_credit         NUMERIC;
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

  PERFORM public.assert_accounting_period_open(v_user_id, p_return_date);

  v_year  := EXTRACT(YEAR FROM p_return_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM p_return_date)::INTEGER;

  IF p_original_invoice_id IS NOT NULL THEN
    SELECT * INTO v_orig_invoice
    FROM public.invoices
    WHERE id = p_original_invoice_id
      AND user_id = v_user_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Orijinal satış faturası bulunamadı (ID: %)', p_original_invoice_id;
    END IF;
  END IF;

  v_warehouse_id := p_warehouse_id;
  IF v_warehouse_id IS NULL THEN
    SELECT id INTO v_warehouse_id
    FROM public.warehouses
    WHERE user_id = v_user_id
    ORDER BY is_default DESC, created_at ASC
    LIMIT 1;
  END IF;

  IF p_return_doc_no IS NOT NULL AND trim(p_return_doc_no) != '' THEN
    v_return_inv_number := trim(p_return_doc_no);
  ELSE
    v_return_inv_number := public.next_entry_number_with_prefix(v_user_id, v_year, 'IAD');
  END IF;

  INSERT INTO public.invoices (
    user_id,
    customer_id,
    warehouse_id,
    invoice_number,
    invoice_date,
    type,
    status,
    currency,
    exchange_rate,
    ettn,
    notes,
    created_at,
    updated_at
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

    v_item_taxable    := round(v_item_qty * v_item_price * (1 - v_item_disc_rate / 100.0), 2);
    v_item_vat_amount := round(v_item_taxable * (v_item_vat_rate / 100.0), 2);
    v_item_line_total := v_item_taxable + v_item_vat_amount;

    v_calc_taxable    := v_calc_taxable + v_item_taxable;
    v_calc_vat        := v_calc_vat + v_item_vat_amount;
    v_calc_grand_total:= v_calc_grand_total + v_item_line_total;

    INSERT INTO public.invoice_items (
      user_id,
      invoice_id,
      product_id,
      name,
      unit,
      quantity,
      unit_price,
      discount_rate,
      vat_rate,
      subtotal,
      total_price,
      created_at
    ) VALUES (
      v_user_id,
      v_return_invoice_id,
      v_item_prod_id,
      v_item_name,
      v_item_unit,
      v_item_qty,
      v_item_price,
      v_item_disc_rate,
      v_item_vat_rate,
      v_item_taxable,
      v_item_line_total,
      now()
    );

    IF v_item_prod_id IS NOT NULL THEN
      SELECT COALESCE(purchase_price, 0) INTO v_item_cost_unit
      FROM public.products
      WHERE id = v_item_prod_id AND user_id = v_user_id;

      v_item_cost_total := round(v_item_qty * v_item_cost_unit, 2);
      v_calc_cost_total := v_calc_cost_total + v_item_cost_total;

      INSERT INTO public.stock_movements (
        user_id,
        product_id,
        warehouse_id,
        movement_type,
        quantity,
        unit_price,
        unit_cost,
        total_cost,
        movement_date,
        document_no,
        description,
        source,
        source_id,
        created_at
      ) VALUES (
        v_user_id,
        v_item_prod_id,
        v_warehouse_id,
        'GIRIS',
        v_item_qty,
        v_item_price,
        v_item_cost_unit,
        v_item_cost_total,
        p_return_date,
        v_return_inv_number,
        'Satış İadesi: ' || v_return_inv_number,
        'SATIS_IADE',
        v_return_invoice_id,
        now()
      );
    END IF;
  END LOOP;

  UPDATE public.invoices
  SET
    subtotal       = v_calc_taxable,
    taxable_amount = v_calc_taxable,
    total_vat      = v_calc_vat,
    grand_total    = v_calc_grand_total,
    updated_at     = now()
  WHERE id = v_return_invoice_id;

  IF v_orig_invoice.customer_id IS NOT NULL AND v_calc_grand_total > 0 THEN
    INSERT INTO public.account_transactions (
      user_id,
      customer_id,
      source_id,
      txn_date,
      txn_type,
      amount,
      document_no,
      description,
      source,
      period_year,
      period_month,
      created_at
    ) VALUES (
      v_user_id,
      v_orig_invoice.customer_id,
      v_return_invoice_id,
      p_return_date,
      'ALACAK',
      v_calc_grand_total,
      v_return_inv_number,
      'Satış İadesi Alacak Kaydı: ' || v_return_inv_number,
      'FATURA',
      v_year,
      v_month,
      now()
    )
    RETURNING id INTO v_txn_id;
  END IF;

  SELECT id INTO v_acc_120_id
  FROM public.chart_of_accounts
  WHERE (code = '120' OR system_tag = 'ALICILAR')
    AND (user_id = v_user_id OR user_id IS NULL)
    AND is_active = true
  ORDER BY user_id NULLS LAST
  LIMIT 1;

  SELECT id INTO v_acc_610_id
  FROM public.chart_of_accounts
  WHERE (code = '610' OR code = '600' OR system_tag = 'SATIS_IADE' OR system_tag = 'YURTICI_SATIS')
    AND (user_id = v_user_id OR user_id IS NULL)
    AND is_active = true
  ORDER BY (code = '610') DESC, user_id NULLS LAST
  LIMIT 1;

  SELECT id INTO v_acc_191_id
  FROM public.chart_of_accounts
  WHERE (code = '191' OR system_tag = 'INDIRILECEK_KDV')
    AND (user_id = v_user_id OR user_id IS NULL)
    AND is_active = true
  ORDER BY user_id NULLS LAST
  LIMIT 1;

  SELECT id INTO v_acc_153_id
  FROM public.chart_of_accounts
  WHERE (code = '153' OR system_tag = 'STOK')
    AND (user_id = v_user_id OR user_id IS NULL)
    AND is_active = true
  ORDER BY user_id NULLS LAST
  LIMIT 1;

  SELECT id INTO v_acc_621_id
  FROM public.chart_of_accounts
  WHERE (code = '621' OR system_tag = 'STMM')
    AND (user_id = v_user_id OR user_id IS NULL)
    AND is_active = true
  ORDER BY user_id NULLS LAST
  LIMIT 1;

  v_journal_number := public.next_entry_number(v_user_id, v_year, 'JOURNAL');

  INSERT INTO public.journal_entries (
    user_id,
    entry_number,
    entry_date,
    description,
    entry_type,
    source_type,
    source_id,
    status,
    period_year,
    period_month,
    created_at,
    updated_at
  ) VALUES (
    v_user_id,
    v_journal_number,
    p_return_date,
    'Satış İadesi Muhasebe Kaydı: ' || v_return_inv_number,
    'MAHSUP',
    'SALES_RETURN',
    v_return_invoice_id,
    'POSTED',
    v_year,
    v_month,
    now(),
    now()
  )
  RETURNING id INTO v_journal_entry_id;

  IF v_calc_taxable > 0 AND v_acc_610_id IS NOT NULL THEN
    INSERT INTO public.journal_lines (
      journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
    ) VALUES (
      v_journal_entry_id, v_user_id, v_acc_610_id,
      'Satış İadesi Matrahı: ' || v_return_inv_number,
      v_calc_taxable, 0, COALESCE(v_orig_invoice.currency, 'TRY'), 1
    );
  END IF;

  IF v_calc_vat > 0 AND v_acc_191_id IS NOT NULL THEN
    INSERT INTO public.journal_lines (
      journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
    ) VALUES (
      v_journal_entry_id, v_user_id, v_acc_191_id,
      'Satış İadesi KDV: ' || v_return_inv_number,
      v_calc_vat, 0, COALESCE(v_orig_invoice.currency, 'TRY'), 1
    );
  END IF;

  IF v_calc_grand_total > 0 AND v_acc_120_id IS NOT NULL THEN
    INSERT INTO public.journal_lines (
      journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
    ) VALUES (
      v_journal_entry_id, v_user_id, v_acc_120_id,
      'Satış İadesi Müşteri Alacağı: ' || v_return_inv_number,
      0, v_calc_grand_total, COALESCE(v_orig_invoice.currency, 'TRY'), 1
    );
  END IF;

  IF v_calc_cost_total > 0 AND v_acc_153_id IS NOT NULL AND v_acc_621_id IS NOT NULL THEN
    INSERT INTO public.journal_lines (
      journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
    ) VALUES (
      v_journal_entry_id, v_user_id, v_acc_153_id,
      'Satış İadesi Stok Maliyet Girişi: ' || v_return_inv_number,
      v_calc_cost_total, 0, COALESCE(v_orig_invoice.currency, 'TRY'), 1
    );

    INSERT INTO public.journal_lines (
      journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
    ) VALUES (
      v_journal_entry_id, v_user_id, v_acc_621_id,
      'Satış İadesi STMM Azalışı: ' || v_return_inv_number,
      0, v_calc_cost_total, COALESCE(v_orig_invoice.currency, 'TRY'), 1
    );
  END IF;

  RETURN jsonb_build_object(
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
$$;

REVOKE ALL ON FUNCTION public.create_sales_return FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_sales_return TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
