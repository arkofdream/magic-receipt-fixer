-- ============================================================================
-- FAZ 4.2: DÖNEM KAPATMA, FATURA NUMARASI, UNIT_COST GÜVENCESİ VE SATIŞ İADESİ
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-28
-- ============================================================================

-- 0. KOLON TAMAMLAMA GÜVENCESİ (products ve invoice_items için unit_cost/total_cost)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='products' AND column_name='unit_cost') THEN
    ALTER TABLE public.products ADD COLUMN unit_cost NUMERIC(14,4) NOT NULL DEFAULT 0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='products' AND column_name='purchase_price') THEN
    ALTER TABLE public.products ADD COLUMN purchase_price NUMERIC(14,2) NOT NULL DEFAULT 0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='invoice_items' AND column_name='unit_cost') THEN
    ALTER TABLE public.invoice_items ADD COLUMN unit_cost NUMERIC(14,4) NOT NULL DEFAULT 0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='invoice_items' AND column_name='total_cost') THEN
    ALTER TABLE public.invoice_items ADD COLUMN total_cost NUMERIC(14,2) NOT NULL DEFAULT 0;
  END IF;
END $$;


-- 1. get_product_stock_quantity Fonksiyonu Güvencesi
-- 'is not unique' (42725) overload çakışmasını önlemek için tek parametreli tanım kaldırılır;
-- default parametreli kanonik imza (p_product_id UUID, p_warehouse_id UUID DEFAULT NULL) tek başına kullanılır.
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


-- 3. CREATE_SALES_INVOICE RPC GÜNCELLEMESİ (purchase_price / unit_cost dayanıklılığı)
CREATE OR REPLACE FUNCTION public.create_sales_invoice(
  p_invoice_date      DATE,
  p_type              TEXT DEFAULT 'SATIS',
  p_status            TEXT DEFAULT 'TASLAK',
  p_customer_id       UUID DEFAULT NULL,
  p_warehouse_id      UUID DEFAULT NULL,
  p_customer_info     JSONB DEFAULT '{}'::jsonb,
  p_items             JSONB DEFAULT '[]'::jsonb,
  p_subtotal          NUMERIC DEFAULT 0,
  p_total_discount    NUMERIC DEFAULT 0,
  p_taxable_amount    NUMERIC DEFAULT 0,
  p_total_vat         NUMERIC DEFAULT 0,
  p_total_tevkifat    NUMERIC DEFAULT 0,
  p_grand_total       NUMERIC DEFAULT 0,
  p_currency          TEXT DEFAULT 'TRY',
  p_exchange_rate     NUMERIC DEFAULT 1,
  p_notes             TEXT DEFAULT '',
  p_payment_info      TEXT DEFAULT '',
  p_ettn              TEXT DEFAULT NULL,
  p_invoice_number    TEXT DEFAULT NULL,
  p_prefix            TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id           UUID;
  v_invoice_id        UUID;
  v_invoice_number    TEXT;
  v_ettn              TEXT;
  v_prefix            TEXT;
  v_should_post       BOOLEAN;
  v_is_return         BOOLEAN;
  v_item              JSONB;
  v_product_id        UUID;
  v_unit_cost         NUMERIC;
  v_total_cost        NUMERIC;
  v_total_stmm        NUMERIC := 0;
  v_quantity          NUMERIC;
  v_unit_price        NUMERIC;
  v_discount_rate     NUMERIC;
  v_vat_rate          NUMERIC;
  v_line_number       INTEGER := 0;
  v_item_subtotal     NUMERIC;
  v_item_discount     NUMERIC;
  v_item_taxable      NUMERIC;
  v_item_vat          NUMERIC;
  v_item_total        NUMERIC;
  v_year              INTEGER;
  v_month             INTEGER;
  v_now               TIMESTAMPTZ := now();
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.' USING ERRCODE = '42501';
  END IF;

  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Fatura en az bir kalem içermelidir.';
  END IF;

  v_year  := EXTRACT(YEAR FROM p_invoice_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM p_invoice_date)::INTEGER;

  PERFORM public.assert_accounting_period_open(v_user_id, p_invoice_date);

  v_should_post := (p_status = 'ONAYLANDI' OR p_status = 'SENT');
  v_is_return   := (p_type = 'SATIS_IADE' OR p_type = 'IADE');

  IF p_invoice_number IS NOT NULL AND trim(p_invoice_number) != '' THEN
    v_invoice_number := trim(p_invoice_number);
  ELSE
    v_prefix := COALESCE(
      NULLIF(trim(p_prefix), ''),
      NULLIF(trim(p_customer_info->>'customPrefix'), ''),
      NULLIF(SUBSTRING(trim(p_customer_info->>'code') FROM 1 FOR 3), ''),
      'EAR'
    );
    v_invoice_number := public.next_entry_number_with_prefix(v_user_id, v_year, v_prefix);
  END IF;

  v_ettn := COALESCE(NULLIF(trim(p_ettn), ''), LOWER(gen_random_uuid()::TEXT));

  INSERT INTO public.invoices (
    user_id, customer_id, warehouse_id, posted, ettn, invoice_number, type, status,
    gib_approval_date, invoice_date, currency, exchange_rate, customer, items,
    subtotal, total_discount, taxable_amount, total_vat, total_tevkifat, grand_total,
    notes, payment_info
  ) VALUES (
    v_user_id, p_customer_id, p_warehouse_id, v_should_post, v_ettn, v_invoice_number,
    p_type, p_status, CASE WHEN v_should_post THEN v_now ELSE NULL END,
    p_invoice_date, p_currency, p_exchange_rate, p_customer_info, p_items,
    p_subtotal, p_total_discount, p_taxable_amount, p_total_vat, p_total_tevkifat, p_grand_total,
    p_notes, p_payment_info
  ) RETURNING id INTO v_invoice_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_line_number     := v_line_number + 1;
    v_product_id      := NULLIF(v_item->>'productId', '')::UUID;
    v_quantity        := COALESCE((v_item->>'quantity')::NUMERIC, 1);
    v_unit_price      := COALESCE((v_item->>'unitPrice')::NUMERIC, 0);
    v_discount_rate   := COALESCE((v_item->>'discountRate')::NUMERIC, 0);
    v_vat_rate        := COALESCE((v_item->>'vatRate')::NUMERIC, 0);
    v_item_subtotal   := ROUND(v_quantity * v_unit_price, 2);
    v_item_discount   := ROUND(v_item_subtotal * (v_discount_rate / 100.0), 2);
    v_item_taxable    := v_item_subtotal - v_item_discount;
    v_item_vat        := ROUND(v_item_taxable * (v_vat_rate / 100.0), 2);
    v_item_total      := v_item_taxable + v_item_vat;

    v_unit_cost := 0;
    IF v_product_id IS NOT NULL THEN
      SELECT COALESCE(purchase_price, unit_cost, 0) INTO v_unit_cost FROM public.products WHERE id = v_product_id;
    END IF;
    v_total_cost := ROUND(v_unit_cost * v_quantity, 2);
    v_total_stmm := v_total_stmm + v_total_cost;

    INSERT INTO public.invoice_items (
      user_id, invoice_id, product_id, line_number, name, description, unit,
      quantity, unit_price, discount_rate, vat_rate, subtotal, discount_amount,
      taxable_amount, vat_amount, line_total, unit_cost, total_cost
    ) VALUES (
      v_user_id, v_invoice_id, v_product_id, v_line_number,
      COALESCE(v_item->>'name', 'Ürün/Hizmet'),
      COALESCE(v_item->>'description', ''),
      COALESCE(v_item->>'unit', 'Adet'),
      v_quantity, v_unit_price, v_discount_rate, v_vat_rate,
      v_item_subtotal, v_item_discount, v_item_taxable, v_item_vat, v_item_total,
      v_unit_cost, v_total_cost
    );

    IF v_product_id IS NOT NULL THEN
      INSERT INTO public.stock_movements (
        user_id, product_id, warehouse_id, movement_type, quantity, unit_price,
        unit_cost, total_cost, document_no, description, movement_date, source, source_id
      ) VALUES (
        v_user_id, v_product_id, p_warehouse_id,
        CASE WHEN v_is_return THEN 'GIRIS' ELSE 'CIKIS' END,
        v_quantity, v_unit_price, v_unit_cost, v_total_cost,
        v_invoice_number,
        CASE WHEN v_is_return THEN 'Satış İade Faturası Kalemi' ELSE 'Satış Faturası Kalemi' END,
        p_invoice_date, 'FATURA', v_invoice_id
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'invoice_id', v_invoice_id,
    'invoice_number', v_invoice_number,
    'ettn', v_ettn
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_sales_invoice TO authenticated, service_role;


-- 4. RUN_ACCOUNTING_AUDIT RPC GÜNCELLEMESİ (İç alt sorgu ile %100 dayanıklı stok kontrolü)
CREATE OR REPLACE FUNCTION public.run_accounting_audit(
  p_year  INTEGER DEFAULT NULL,
  p_month INTEGER DEFAULT NULL
)
RETURNS TABLE (
  check_name     TEXT,
  severity       TEXT,
  status         TEXT,
  expected_value NUMERIC,
  actual_value   NUMERIC,
  difference     NUMERIC,
  detail         TEXT,
  source_id      UUID
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id             UUID;
  v_rec                 RECORD;
  v_stock_cogs_net      NUMERIC(14,2) := 0;
  v_journal_621_net     NUMERIC(14,2) := 0;
  v_inv_taxable_net     NUMERIC(14,2) := 0;
  v_journal_600_net     NUMERIC(14,2) := 0;
  v_inv_tax_net         NUMERIC(14,2) := 0;
  v_journal_391_net     NUMERIC(14,2) := 0;
  v_cust_subledger_net  NUMERIC(14,2) := 0;
  v_journal_120_net     NUMERIC(14,2) := 0;
  v_p_rec               RECORD;
  v_p_qty               NUMERIC;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.' USING ERRCODE = '42501';
  END IF;

  -- KONTROL 1: UNBALANCED_POSTED_JOURNAL
  FOR v_rec IN
    SELECT je.id, je.entry_number, je.entry_date, je.total_debit, je.total_credit
    FROM public.journal_entries je
    WHERE je.user_id = v_user_id
      AND je.status = 'POSTED'
      AND je.total_debit != je.total_credit
      AND (p_year IS NULL OR je.period_year = p_year)
      AND (p_month IS NULL OR je.period_month = p_month)
  LOOP
    check_name     := 'UNBALANCED_POSTED_JOURNAL';
    severity       := 'CRITICAL';
    status         := 'FAIL';
    expected_value := v_rec.total_credit;
    actual_value   := v_rec.total_debit;
    difference     := v_rec.total_debit - v_rec.total_credit;
    detail         := 'Yevmiye fişi borç ve alacak toplamları denk değil! Fiş No: ' || v_rec.entry_number;
    source_id      := v_rec.id;
    RETURN NEXT;
  END LOOP;

  -- KONTROL 2: POSTED_JOURNAL_WITHOUT_LINES
  FOR v_rec IN
    SELECT je.id, je.entry_number
    FROM public.journal_entries je
    LEFT JOIN public.journal_lines jl ON jl.journal_entry_id = je.id
    WHERE je.user_id = v_user_id
      AND je.status = 'POSTED'
      AND (p_year IS NULL OR je.period_year = p_year)
      AND (p_month IS NULL OR je.period_month = p_month)
      AND jl.id IS NULL
  LOOP
    check_name     := 'POSTED_JOURNAL_WITHOUT_LINES';
    severity       := 'CRITICAL';
    status         := 'FAIL';
    expected_value := 1;
    actual_value   := 0;
    difference     := 1;
    detail         := 'Onaylı yevmiye fişinin satırı bulunamadı! Fiş No: ' || v_rec.entry_number;
    source_id      := v_rec.id;
    RETURN NEXT;
  END LOOP;

  -- KONTROL 3: INVOICE_WITHOUT_JOURNAL
  FOR v_rec IN
    SELECT inv.id, inv.invoice_number, inv.grand_total
    FROM public.invoices inv
    LEFT JOIN public.journal_entries je
      ON je.source_type = 'INVOICE'
      AND je.source_id = inv.id
      AND je.status = 'POSTED'
    WHERE inv.user_id = v_user_id
      AND inv.posted = true
      AND inv.status != 'IPTAL'
      AND (p_year IS NULL OR EXTRACT(YEAR FROM inv.invoice_date) = p_year)
      AND (p_month IS NULL OR EXTRACT(MONTH FROM inv.invoice_date) = p_month)
      AND je.id IS NULL
  LOOP
    check_name     := 'INVOICE_WITHOUT_JOURNAL';
    severity       := 'CRITICAL';
    status         := 'FAIL';
    expected_value := v_rec.grand_total;
    actual_value   := 0;
    difference     := v_rec.grand_total;
    detail         := 'Onaylı satış faturasının muhasebe yevmiye fişi bulunamadı! Fatura No: ' || v_rec.invoice_number;
    source_id      := v_rec.id;
    RETURN NEXT;
  END LOOP;

  -- KONTROL 4: NEGATIVE_STOCK (İç alt sorgu ile fonksiyon bağımsız hesaplama)
  FOR v_p_rec IN
    SELECT p.id, p.name
    FROM public.products p
    WHERE p.user_id = v_user_id AND p.deleted_at IS NULL AND COALESCE(p.track_stock, true) = true
  LOOP
    SELECT COALESCE(SUM(
      CASE
        WHEN sm.movement_type IN ('GIRIS', 'TRANSFER_IN') THEN sm.quantity
        WHEN sm.movement_type IN ('CIKIS', 'TRANSFER_OUT') THEN -sm.quantity
        ELSE 0
      END
    ), 0)
    INTO v_p_qty
    FROM public.stock_movements sm
    WHERE sm.product_id = v_p_rec.id
      AND sm.user_id = v_user_id
      AND sm.deleted_at IS NULL;

    IF v_p_qty < 0 THEN
      check_name     := 'NEGATIVE_STOCK';
      severity       := 'CRITICAL';
      status         := 'FAIL';
      expected_value := 0;
      actual_value   := v_p_qty;
      difference     := v_p_qty;
      detail         := 'Üründe negatif stok tespit edildi! Ürün: ' || v_p_rec.name || ' (Miktar: ' || v_p_qty || ')';
      source_id      := v_p_rec.id;
      RETURN NEXT;
    END IF;
  END LOOP;

  -- KONTROL 5: STMM ↔ 621 MUTABAKATI
  SELECT COALESCE(SUM(
    CASE
      WHEN sm.movement_type = 'CIKIS' AND sm.source = 'FATURA' THEN sm.total_cost
      WHEN sm.movement_type = 'GIRIS' AND sm.source = 'FATURA' THEN -sm.total_cost
      ELSE 0
    END
  ), 0)
  INTO v_stock_cogs_net
  FROM public.stock_movements sm
  INNER JOIN public.invoices inv ON inv.id = sm.source_id AND inv.status != 'IPTAL'
  WHERE sm.user_id = v_user_id
    AND sm.deleted_at IS NULL
    AND (p_year IS NULL OR EXTRACT(YEAR FROM sm.movement_date) = p_year)
    AND (p_month IS NULL OR EXTRACT(MONTH FROM sm.movement_date) = p_month);

  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_journal_621_net
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND (coa.code = '621' OR coa.system_tag = 'COGS')
    AND (p_year IS NULL OR je.period_year = p_year)
    AND (p_month IS NULL OR je.period_month = p_month);

  check_name     := 'STMM_621_MISMATCH';
  expected_value := v_stock_cogs_net;
  actual_value   := v_journal_621_net;
  difference     := v_journal_621_net - v_stock_cogs_net;
  source_id      := NULL;

  IF ABS(difference) > 0.05 THEN
    severity := 'CRITICAL';
    status   := 'FAIL';
    detail   := 'STMM stok çıkış maliyeti (' || v_stock_cogs_net || ' TL) ile 621 hesabı (' || v_journal_621_net || ' TL) arasında fark var!';
  ELSE
    severity := 'INFO';
    status   := 'PASS';
    detail   := 'STMM stok maliyeti ile 621 hesabı tam mutabık.';
  END IF;
  RETURN NEXT;

  -- KONTROL 6: SATIŞ ↔ 600 MUTABAKATI
  SELECT COALESCE(SUM(
    CASE
      WHEN inv.type = 'IADE' THEN -inv.taxable_amount
      ELSE inv.taxable_amount
    END
  ), 0)
  INTO v_inv_taxable_net
  FROM public.invoices inv
  WHERE inv.user_id = v_user_id
    AND inv.posted = true
    AND inv.status != 'IPTAL'
    AND (p_year IS NULL OR EXTRACT(YEAR FROM inv.invoice_date) = p_year)
    AND (p_month IS NULL OR EXTRACT(MONTH FROM inv.invoice_date) = p_month);

  SELECT COALESCE(SUM(jl.credit - jl.debit), 0)
  INTO v_journal_600_net
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND (coa.code = '600' OR coa.system_tag = 'SATIS_GELIRI')
    AND (p_year IS NULL OR je.period_year = p_year)
    AND (p_month IS NULL OR je.period_month = p_month);

  check_name     := 'SALES_600_MISMATCH';
  expected_value := v_inv_taxable_net;
  actual_value   := v_journal_600_net;
  difference     := v_journal_600_net - v_inv_taxable_net;
  source_id      := NULL;

  IF ABS(difference) > 0.05 THEN
    severity := 'CRITICAL';
    status   := 'FAIL';
    detail   := 'Fatura satış matrahı toplamı (' || v_inv_taxable_net || ' TL) ile 600 hesabı (' || v_journal_600_net || ' TL) arasında fark var!';
  ELSE
    severity := 'INFO';
    status   := 'PASS';
    detail   := 'Satış faturaları matrahı ile 600 hesabı tam mutabık.';
  END IF;
  RETURN NEXT;

  -- KONTROL 7: KDV ↔ 391 MUTABAKATI
  SELECT COALESCE(SUM(
    CASE
      WHEN inv.type = 'IADE' THEN -itl.tax_amount
      ELSE itl.tax_amount
    END
  ), 0)
  INTO v_inv_tax_net
  FROM public.invoice_tax_lines itl
  INNER JOIN public.invoices inv ON inv.id = itl.invoice_id
  WHERE itl.user_id = v_user_id
    AND inv.posted = true
    AND inv.status != 'IPTAL'
    AND itl.is_cancelled = false
    AND (p_year IS NULL OR itl.period_year = p_year)
    AND (p_month IS NULL OR itl.period_month = p_month);

  SELECT COALESCE(SUM(jl.credit - jl.debit), 0)
  INTO v_journal_391_net
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND (coa.code = '391' OR coa.system_tag = 'HESAPLANAN_KDV')
    AND (p_year IS NULL OR je.period_year = p_year)
    AND (p_month IS NULL OR je.period_month = p_month);

  check_name     := 'TAX_391_MISMATCH';
  expected_value := v_inv_tax_net;
  actual_value   := v_journal_391_net;
  difference     := v_journal_391_net - v_inv_tax_net;
  source_id      := NULL;

  IF ABS(difference) > 0.05 THEN
    severity := 'WARNING';
    status   := 'WARNING';
    detail   := 'Fatura KDV satırları toplamı (' || v_inv_tax_net || ' TL) ile 391 hesabı (' || v_journal_391_net || ' TL) arasında fark var!';
  ELSE
    severity := 'INFO';
    status   := 'PASS';
    detail   := 'Fatura KDV satırları ile 391 hesabı tam mutabık.';
  END IF;
  RETURN NEXT;

  -- KONTROL 8: CARİ ↔ 120 MUTABAKATI
  SELECT COALESCE(SUM(
    CASE
      WHEN txn_type = 'BORC' THEN amount
      WHEN txn_type = 'ALACAK' THEN -amount
      ELSE 0
    END
  ), 0)
  INTO v_cust_subledger_net
  FROM public.account_transactions
  WHERE user_id = v_user_id
    AND deleted_at IS NULL
    AND (p_year IS NULL OR EXTRACT(YEAR FROM txn_date) = p_year)
    AND (p_month IS NULL OR EXTRACT(MONTH FROM txn_date) = p_month);

  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_journal_120_net
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND (coa.code = '120' OR coa.system_tag = 'ALICILAR')
    AND (p_year IS NULL OR je.period_year = p_year)
    AND (p_month IS NULL OR je.period_month = p_month);

  check_name     := 'CUSTOMER_120_MISMATCH';
  expected_value := v_cust_subledger_net;
  actual_value   := v_journal_120_net;
  difference     := v_journal_120_net - v_cust_subledger_net;
  source_id      := NULL;

  IF ABS(difference) > 0.05 THEN
    severity := 'WARNING';
    status   := 'WARNING';
    detail   := 'Cari hareketler toplamı (' || v_cust_subledger_net || ' TL) ile 120 hesabı (' || v_journal_120_net || ' TL) arasında fark var!';
  ELSE
    severity := 'INFO';
    status   := 'PASS';
    detail   := 'Cari hareketler ile 120 hesabı tam mutabık.';
  END IF;
  RETURN NEXT;

END;
$$;

GRANT EXECUTE ON FUNCTION public.run_accounting_audit TO authenticated, service_role;


-- 5. ATOMİK SATIŞ İADESİ RPC'Sİ (create_sales_return)
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
      SELECT COALESCE(purchase_price, unit_cost, 0) INTO v_item_cost_unit
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
