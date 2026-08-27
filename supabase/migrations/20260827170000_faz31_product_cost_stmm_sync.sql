-- ============================================================================
-- FAZ 3.1: ÜRÜN MALİYETİ VE STMM YEVMİYE SENKRONİZASYONU MIGRATION
-- ============================================================================
-- AMAÇ: Satış faturası kesildiğinde ürün maliyetinin 0 kalması nedeniyle 621/153
--       STMM yevmiye kaydının oluşmaması riskini ortadan kaldırır.
--       3 Aşamalı Maliyet Fallback Zinciri:
--       1) products.unit_cost
--       2) products.purchase_price (katalog alış fiyatı)
--       3) public.get_product_moving_average_cost (geçmiş alış hareketlerinden)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. CREATE_SALES_INVOICE RPC GÜNCELLEMESİ (3 AŞAMALI MALİYET FALLBACK İLE)
-- ----------------------------------------------------------------------------
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
  v_journal_entry_id  UUID;
  v_journal_number    TEXT;
  v_acc_120_id        UUID;
  v_acc_600_id        UUID;
  v_acc_610_id        UUID;
  v_acc_391_id        UUID;
  v_acc_621_id        UUID;
  v_acc_153_id        UUID;
  v_acc_136_id        UUID;
  v_tax_rec           RECORD;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.' USING ERRCODE = '42501';
  END IF;

  IF p_invoice_date IS NULL THEN
    RAISE EXCEPTION 'Fatura tarihi zorunludur.';
  END IF;

  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Fatura en az bir kalem içermelidir.';
  END IF;

  v_year  := EXTRACT(YEAR FROM p_invoice_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM p_invoice_date)::INTEGER;

  -- Kapalı Dönem Kontrolü
  PERFORM public.assert_accounting_period_open(v_user_id, p_invoice_date);

  v_should_post := (p_status = 'ONAYLANDI' OR p_status = 'SENT');
  v_is_return   := (p_type = 'SATIS_IADE' OR p_type = 'IADE');

  -- Kilitlemeler
  IF p_customer_id IS NOT NULL THEN
    PERFORM id FROM public.customers
    WHERE id = p_customer_id AND user_id = v_user_id
    FOR UPDATE;
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    IF (v_item->>'productId') IS NOT NULL AND trim(v_item->>'productId') != '' THEN
      PERFORM id FROM public.products
      WHERE id = (v_item->>'productId')::UUID AND user_id = v_user_id
      FOR UPDATE;
    END IF;
  END LOOP;

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
    v_product_id      := NULLIF(trim(v_item->>'productId'), '')::UUID;
    v_quantity        := COALESCE((v_item->>'quantity')::NUMERIC, 1);
    v_unit_price      := COALESCE((v_item->>'unitPrice')::NUMERIC, 0);
    v_discount_rate   := COALESCE((v_item->>'discountRate')::NUMERIC, 0);
    v_vat_rate        := COALESCE((v_item->>'vatRate')::NUMERIC, 0);
    v_item_subtotal   := ROUND(v_quantity * v_unit_price, 2);
    v_item_discount   := ROUND(v_item_subtotal * (v_discount_rate / 100.0), 2);
    v_item_taxable    := v_item_subtotal - v_item_discount;
    v_item_vat        := ROUND(v_item_taxable * (v_vat_rate / 100.0), 2);
    v_item_total      := v_item_taxable + v_item_vat;

    -- FAZ 3.1: 3 AŞAMALI MALİYET FALLBACK ZİNCİRİ
    v_unit_cost := 0;
    IF v_product_id IS NOT NULL THEN
      -- 1) Ve 2) Aşama: products tablosundaki unit_cost veya purchase_price
      SELECT COALESCE(NULLIF(unit_cost, 0), NULLIF(purchase_price, 0), 0)
      INTO v_unit_cost
      FROM public.products
      WHERE id = v_product_id AND user_id = v_user_id AND deleted_at IS NULL;

      -- 3) Aşama: Eğer hala 0 ise hareketli ortalama maliyet motorunu çalıştır
      IF COALESCE(v_unit_cost, 0) <= 0 THEN
        v_unit_cost := public.get_product_moving_average_cost(v_product_id, p_warehouse_id);
      END IF;
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
      IF v_should_post THEN
        IF v_is_return THEN
          UPDATE public.products
          SET stock_quantity = stock_quantity + v_quantity, updated_at = v_now
          WHERE id = v_product_id AND user_id = v_user_id;
        ELSE
          UPDATE public.products
          SET stock_quantity = stock_quantity - v_quantity, updated_at = v_now
          WHERE id = v_product_id AND user_id = v_user_id;
        END IF;
      END IF;

      INSERT INTO public.stock_movements (
        user_id, product_id, warehouse_id, movement_type, quantity, unit_price,
        unit_cost, total_cost, total_price, reference_type, reference_id, description, movement_date
      ) VALUES (
        v_user_id, v_product_id, p_warehouse_id,
        CASE WHEN v_is_return THEN 'IN' ELSE 'OUT' END,
        v_quantity, v_unit_price,
        v_unit_cost, v_total_cost, v_item_total, 'INVOICE', v_invoice_id,
        CASE WHEN v_is_return THEN 'Satış İade Faturası Kalemi' ELSE 'Satış Faturası Kalemi' END,
        p_invoice_date
      );
    END IF;
  END LOOP;

  -- KDV Satırları
  INSERT INTO public.invoice_tax_lines (
    invoice_id, user_id, direction, vat_rate, taxable_amount, tax_amount,
    withholding_rate, withholding_amount, currency, exchange_rate,
    taxable_amount_try, tax_amount_try, period_year, period_month
  )
  SELECT
    v_invoice_id, v_user_id, 'SATIS', vat_rate,
    SUM(taxable_amount), SUM(vat_amount), 0, 0,
    p_currency, COALESCE(p_exchange_rate, 1),
    ROUND(SUM(taxable_amount) * COALESCE(p_exchange_rate, 1), 2),
    ROUND(SUM(vat_amount) * COALESCE(p_exchange_rate, 1), 2),
    v_year, v_month
  FROM public.invoice_items
  WHERE invoice_id = v_invoice_id
  GROUP BY vat_rate;

  -- ONAYLI ise Cari ve Yevmiye Fişi Oluşturma
  IF v_should_post THEN
    IF p_customer_id IS NOT NULL THEN
      INSERT INTO public.account_transactions (
        user_id, customer_id, txn_date, txn_type, amount, document_no,
        description, source, source_id
      ) VALUES (
        v_user_id, p_customer_id, p_invoice_date,
        CASE WHEN v_is_return THEN 'ALACAK' ELSE 'BORC' END,
        p_grand_total, v_invoice_number,
        CASE WHEN v_is_return THEN 'Satış İadeleri Kaydı: ' ELSE 'Satış Faturası Borç Kaydı: ' END || v_invoice_number,
        'INVOICE', v_invoice_id
      );
    END IF;

    -- Accounting Accounts Resolution
    SELECT id INTO v_acc_120_id FROM public.chart_of_accounts
    WHERE (code = '120' OR system_tag = 'ALICILAR') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true
    ORDER BY user_id NULLS LAST LIMIT 1;
    IF v_acc_120_id IS NULL THEN RAISE EXCEPTION 'Muhasebe hesap planında 120 (Alıcılar) hesabı bulunamadı.'; END IF;

    SELECT id INTO v_acc_600_id FROM public.chart_of_accounts
    WHERE (code = '600' OR system_tag = 'SATIS_GELIRI') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true
    ORDER BY user_id NULLS LAST LIMIT 1;
    IF v_acc_600_id IS NULL THEN RAISE EXCEPTION 'Muhasebe hesap planında 600 (Yurtiçi Satışlar) hesabı bulunamadı.'; END IF;

    SELECT id INTO v_acc_610_id FROM public.chart_of_accounts
    WHERE (code = '610' OR system_tag = 'SATIS_IADE') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true
    ORDER BY user_id NULLS LAST LIMIT 1;
    IF v_is_return AND v_acc_610_id IS NULL THEN v_acc_610_id := v_acc_600_id; END IF;

    SELECT id INTO v_acc_391_id FROM public.chart_of_accounts
    WHERE (code = '391' OR system_tag = 'HESAPLANAN_KDV') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true
    ORDER BY user_id NULLS LAST LIMIT 1;
    IF v_acc_391_id IS NULL AND ROUND(COALESCE(p_total_vat, 0), 2) > 0 THEN
      RAISE EXCEPTION 'Muhasebe hesap planında 391 (Hesaplanan KDV) hesabı bulunamadı.';
    END IF;

    IF ROUND(COALESCE(p_total_tevkifat, 0), 2) > 0 THEN
      SELECT id INTO v_acc_136_id FROM public.chart_of_accounts
      WHERE (code = '136' OR system_tag = 'TEVKIFAT_ALACAGI') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true
      ORDER BY user_id NULLS LAST LIMIT 1;
    END IF;

    IF ROUND(COALESCE(v_total_stmm, 0), 2) > 0 THEN
      SELECT id INTO v_acc_621_id FROM public.chart_of_accounts
      WHERE (code = '621' OR system_tag = 'COGS') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true
      ORDER BY user_id NULLS LAST LIMIT 1;

      SELECT id INTO v_acc_153_id FROM public.chart_of_accounts
      WHERE (code = '153' OR system_tag = 'STOK') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true
      ORDER BY user_id NULLS LAST LIMIT 1;
    END IF;

    -- Journal Entry Header
    v_journal_number := public.next_entry_number(v_user_id, v_year, 'JOURNAL');
    INSERT INTO public.journal_entries (
      user_id, entry_number, entry_date, description, entry_type, source_type, source_id, status, period_year, period_month
    ) VALUES (
      v_user_id, v_journal_number, p_invoice_date,
      CASE WHEN v_is_return THEN 'İade Faturası Muhasebe Kaydı - ' || v_invoice_number ELSE 'Satış Faturası Muhasebe Kaydı - ' || v_invoice_number END,
      'MAHSUP', 'INVOICE', v_invoice_id, 'DRAFT', v_year, v_month
    ) RETURNING id INTO v_journal_entry_id;

    -- Journal Lines
    IF NOT v_is_return THEN
      -- 1. 120 ALICILAR
      IF ROUND(COALESCE(p_grand_total, 0), 2) > 0 THEN
        INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
        VALUES (v_journal_entry_id, v_user_id, v_acc_120_id, 'Fatura Borç Kaydı: ' || v_invoice_number, ROUND(p_grand_total, 2), 0, p_currency, COALESCE(p_exchange_rate, 1));
      END IF;

      -- 2. 136 TEVKİFAT ALACAĞI
      IF ROUND(COALESCE(p_total_tevkifat, 0), 2) > 0 AND v_acc_136_id IS NOT NULL THEN
        INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
        VALUES (v_journal_entry_id, v_user_id, v_acc_136_id, 'Tevkifat KDV Alacağı: ' || v_invoice_number, ROUND(p_total_tevkifat, 2), 0, p_currency, COALESCE(p_exchange_rate, 1));
      END IF;

      -- 3. 621 STMM (BORÇ)
      IF ROUND(COALESCE(v_total_stmm, 0), 2) > 0 AND v_acc_621_id IS NOT NULL THEN
        INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
        VALUES (v_journal_entry_id, v_user_id, v_acc_621_id, 'Satılan Ticari Mallar Maliyeti (STMM): ' || v_invoice_number, ROUND(v_total_stmm, 2), 0, 'TRY', 1);
      END IF;

      -- 4. 600 YURTİÇİ SATIŞLAR
      IF ROUND(COALESCE(p_taxable_amount, 0), 2) > 0 THEN
        INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
        VALUES (v_journal_entry_id, v_user_id, v_acc_600_id, 'Satış Geliri: ' || v_invoice_number, 0, ROUND(p_taxable_amount, 2), p_currency, COALESCE(p_exchange_rate, 1));
      END IF;

      -- 5. 391 HESAPLANAN KDV
      IF v_acc_391_id IS NOT NULL THEN
        FOR v_tax_rec IN SELECT vat_rate, ROUND(tax_amount, 2) AS rounded_tax_amount FROM public.invoice_tax_lines WHERE invoice_id = v_invoice_id AND ROUND(tax_amount, 2) > 0 LOOP
          INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
          VALUES (v_journal_entry_id, v_user_id, v_acc_391_id, 'Hesaplanan KDV (%' || v_tax_rec.vat_rate || '): ' || v_invoice_number, 0, v_tax_rec.rounded_tax_amount, p_currency, COALESCE(p_exchange_rate, 1));
        END LOOP;
      END IF;

      -- 6. 153 TİCARİ MALLAR (ALACAK)
      IF ROUND(COALESCE(v_total_stmm, 0), 2) > 0 AND v_acc_153_id IS NOT NULL THEN
        INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
        VALUES (v_journal_entry_id, v_user_id, v_acc_153_id, 'Stoktan Çıkış Maliyeti (STMM): ' || v_invoice_number, 0, ROUND(v_total_stmm, 2), 'TRY', 1);
      END IF;

    ELSE
      -- Satış İadesi Kayıtları
      IF ROUND(COALESCE(p_taxable_amount, 0), 2) > 0 THEN
        INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
        VALUES (v_journal_entry_id, v_user_id, COALESCE(v_acc_610_id, v_acc_600_id), 'Satıştan İade: ' || v_invoice_number, ROUND(p_taxable_amount, 2), 0, p_currency, COALESCE(p_exchange_rate, 1));
      END IF;

      IF v_acc_391_id IS NOT NULL THEN
        FOR v_tax_rec IN SELECT vat_rate, ROUND(tax_amount, 2) AS rounded_tax_amount FROM public.invoice_tax_lines WHERE invoice_id = v_invoice_id AND ROUND(tax_amount, 2) > 0 LOOP
          INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
          VALUES (v_journal_entry_id, v_user_id, v_acc_391_id, 'İade KDV (%' || v_tax_rec.vat_rate || '): ' || v_invoice_number, v_tax_rec.rounded_tax_amount, 0, p_currency, COALESCE(p_exchange_rate, 1));
        END LOOP;
      END IF;

      IF ROUND(COALESCE(v_total_stmm, 0), 2) > 0 AND v_acc_153_id IS NOT NULL THEN
        INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
        VALUES (v_journal_entry_id, v_user_id, v_acc_153_id, 'İade Alınan Stok Maliyeti (STMM Düzeltmesi): ' || v_invoice_number, ROUND(v_total_stmm, 2), 0, 'TRY', 1);
      END IF;

      IF ROUND(COALESCE(p_grand_total, 0), 2) > 0 THEN
        INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
        VALUES (v_journal_entry_id, v_user_id, v_acc_120_id, 'İade Alacak Kaydı: ' || v_invoice_number, 0, ROUND(p_grand_total, 2), p_currency, COALESCE(p_exchange_rate, 1));
      END IF;

      IF ROUND(COALESCE(v_total_stmm, 0), 2) > 0 AND v_acc_621_id IS NOT NULL THEN
        INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
        VALUES (v_journal_entry_id, v_user_id, v_acc_621_id, 'İade Edilen Satış Maliyeti Düzeltmesi (STMM): ' || v_invoice_number, 0, ROUND(v_total_stmm, 2), 'TRY', 1);
      END IF;
    END IF;

    UPDATE public.journal_entries SET status = 'POSTED', updated_at = v_now WHERE id = v_journal_entry_id;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'invoice_id', v_invoice_id,
    'invoice_number', v_invoice_number,
    'ettn', v_ettn
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_sales_invoice TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_sales_invoice TO service_role;

-- ----------------------------------------------------------------------------
-- 2. CREATE_PURCHASE_INVOICE RPC GÜNCELLEMESİ (ÜRÜN KATALOG ALIŞ FİYATI OTOMATİK DOLDURMA İLE)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_purchase_invoice(
  p_invoice_date      DATE,
  p_supplier_id       UUID,
  p_invoice_number    TEXT,
  p_warehouse_id      UUID DEFAULT NULL,
  p_supplier_info     JSONB DEFAULT '{}'::jsonb,
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
  p_status            TEXT DEFAULT 'ONAYLANDI'
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
  v_should_post       BOOLEAN;
  v_item              JSONB;
  v_product_id        UUID;
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
  v_txn_id            UUID;
  v_journal_entry_id  UUID;
  v_journal_number    TEXT;
  v_product_ids       UUID[];
  v_locked_product    RECORD;
  v_acc_153_id        UUID;
  v_acc_191_id        UUID;
  v_acc_320_id        UUID;
  v_tax_rec           RECORD;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.' USING ERRCODE = '42501';
  END IF;

  IF p_invoice_date IS NULL THEN RAISE EXCEPTION 'Fatura tarihi zorunludur.'; END IF;
  IF p_invoice_number IS NULL OR trim(p_invoice_number) = '' THEN RAISE EXCEPTION 'Tedarikçi fatura numarası zorunludur.'; END IF;
  v_invoice_number := trim(p_invoice_number);
  IF p_supplier_id IS NULL THEN RAISE EXCEPTION 'Tedarikçi seçimi zorunludur.'; END IF;

  PERFORM public.assert_accounting_period_open(v_user_id, p_invoice_date);

  IF NOT EXISTS (
    SELECT 1 FROM public.customers
    WHERE id = p_supplier_id AND user_id = v_user_id AND deleted_at IS NULL AND partner_type = 'TEDARIKCI'
  ) THEN
    RAISE EXCEPTION 'Seçilen cari kart tedarikçi (TEDARIKCI) türünde değil veya silinmiş.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.invoices
    WHERE user_id = v_user_id AND customer_id = p_supplier_id AND invoice_number = v_invoice_number AND type IN ('ALIS', 'GELEN_FATURA', 'GELEN_E_ARSIV') AND status != 'IPTAL'
  ) THEN
    RAISE EXCEPTION 'Bu tedarikçiye ait bu fatura numarası (%) ile kayıtlı bir alış faturası zaten mevcuttur.', v_invoice_number;
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) != 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'En az bir geçerli fatura kalemi girilmelidir.';
  END IF;

  v_year        := EXTRACT(YEAR FROM p_invoice_date)::INTEGER;
  v_month       := EXTRACT(MONTH FROM p_invoice_date)::INTEGER;
  v_should_post := (p_status = 'ONAYLANDI');
  v_ettn        := COALESCE(NULLIF(trim(p_ettn), ''), UPPER(gen_random_uuid()::TEXT));

  -- Deterministik Ürün Satır Kilitlemesi
  SELECT array_agg(DISTINCT (item->>'productId')::UUID ORDER BY (item->>'productId')::UUID)
  INTO v_product_ids
  FROM jsonb_array_elements(p_items) AS item
  WHERE (item->>'productId') IS NOT NULL AND trim(item->>'productId') != '';

  IF v_product_ids IS NOT NULL AND array_length(v_product_ids, 1) > 0 THEN
    FOR v_locked_product IN
      SELECT id FROM public.products WHERE id = ANY(v_product_ids) AND user_id = v_user_id AND deleted_at IS NULL ORDER BY id ASC FOR UPDATE
    LOOP NULL; END LOOP;
  END IF;

  -- Fatura Başlığı
  INSERT INTO public.invoices (
    user_id, customer_id, warehouse_id, posted, ettn, invoice_number, type, status,
    gib_approval_date, invoice_date, currency, exchange_rate, customer, items,
    subtotal, total_discount, taxable_amount, total_vat, total_tevkifat, grand_total,
    notes, payment_info
  ) VALUES (
    v_user_id, p_supplier_id, p_warehouse_id, v_should_post, v_ettn, v_invoice_number,
    'ALIS', p_status, CASE WHEN v_should_post THEN v_now ELSE NULL END,
    p_invoice_date, p_currency, COALESCE(p_exchange_rate, 1), p_supplier_info, p_items,
    p_subtotal, p_total_discount, p_taxable_amount, p_total_vat, COALESCE(p_total_tevkifat, 0),
    p_grand_total, COALESCE(p_notes, ''), COALESCE(p_payment_info, '')
  ) RETURNING id INTO v_invoice_id;

  -- Fatura Kalemleri
  v_line_number := 0;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_line_number   := v_line_number + 1;
    v_product_id    := NULLIF(trim(v_item->>'productId'), '')::UUID;
    v_quantity      := GREATEST(0.0001, COALESCE((v_item->>'quantity')::NUMERIC, 1));
    v_unit_price    := ROUND(COALESCE((v_item->>'unitPrice')::NUMERIC, 0), 4);
    v_discount_rate := GREATEST(0, LEAST(100, COALESCE((v_item->>'discountRate')::NUMERIC, 0)));
    v_vat_rate      := GREATEST(0, LEAST(100, COALESCE((v_item->>'vatRate')::NUMERIC, 20)));
    v_item_subtotal := ROUND(v_quantity * v_unit_price, 2);
    v_item_discount := ROUND(v_item_subtotal * (v_discount_rate / 100.0), 2);
    v_item_taxable  := ROUND(v_item_subtotal - v_item_discount, 2);
    v_item_vat      := ROUND(v_item_taxable * (v_vat_rate / 100.0), 2);
    v_item_total    := v_item_taxable + v_item_vat;

    INSERT INTO public.invoice_items (
      invoice_id, user_id, line_number, product_id, description, unit,
      quantity, unit_price, discount_rate, taxable_amount, vat_rate, vat_amount,
      line_total, currency, exchange_rate
    ) VALUES (
      v_invoice_id, v_user_id, v_line_number, v_product_id,
      COALESCE(trim(v_item->>'name'), 'Kalem ' || v_line_number),
      COALESCE(NULLIF(trim(v_item->>'unit'), ''), 'Adet'),
      v_quantity, v_unit_price, v_discount_rate, v_item_taxable, v_vat_rate,
      v_item_vat, v_item_total, p_currency, COALESCE(p_exchange_rate, 1)
    );
  END LOOP;

  -- KDV Satırları
  INSERT INTO public.invoice_tax_lines (
    invoice_id, user_id, direction, vat_rate, taxable_amount, tax_amount,
    withholding_rate, withholding_amount, currency, exchange_rate,
    taxable_amount_try, tax_amount_try, period_year, period_month
  )
  SELECT
    v_invoice_id, v_user_id, 'ALIS', vat_rate,
    SUM(taxable_amount), SUM(vat_amount), 0, 0,
    p_currency, COALESCE(p_exchange_rate, 1),
    ROUND(SUM(taxable_amount) * COALESCE(p_exchange_rate, 1), 2),
    ROUND(SUM(vat_amount) * COALESCE(p_exchange_rate, 1), 2),
    v_year, v_month
  FROM public.invoice_items
  WHERE invoice_id = v_invoice_id
  GROUP BY vat_rate;

  IF v_should_post THEN
    -- Tedarikçi Cari Alacak Kaydı
    IF p_grand_total > 0 THEN
      INSERT INTO public.account_transactions (
        user_id, customer_id, txn_date, txn_type, amount, document_no, description, source, source_id
      ) VALUES (
        v_user_id, p_supplier_id, p_invoice_date, 'ALACAK', p_grand_total, v_invoice_number,
        'Alış faturası tedarikçi alacak kaydı (' || v_invoice_number || ')', 'ALIS_FATURASI', v_invoice_id
      ) RETURNING id INTO v_txn_id;
    END IF;

    -- Stok Giriş Hareketleri ve FAZ 3.1 Ürün Katalog Alış Fiyatı Yedekleme
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
      IF (v_item->>'productId') IS NOT NULL AND trim(v_item->>'productId') != '' THEN
        v_product_id := (v_item->>'productId')::UUID;
        v_quantity   := GREATEST(0, COALESCE((v_item->>'quantity')::NUMERIC, 0));
        v_discount_rate := GREATEST(0, LEAST(100, COALESCE((v_item->>'discountRate')::NUMERIC, 0)));
        v_unit_price    := ROUND(COALESCE((v_item->>'unitPrice')::NUMERIC, 0) * (1 - (v_discount_rate / 100.0)), 4);

        IF v_quantity > 0 THEN
          INSERT INTO public.stock_movements (
            user_id, product_id, warehouse_id, customer_id, movement_date,
            movement_type, quantity, unit_price, unit_cost, total_cost,
            document_no, description, source, source_id
          ) VALUES (
            v_user_id, v_product_id, p_warehouse_id, p_supplier_id, p_invoice_date,
            'GIRIS', v_quantity, v_unit_price, v_unit_price,
            ROUND(v_quantity * v_unit_price, 2), v_invoice_number,
            'Alış faturası stok girişi (' || v_invoice_number || ')', 'ALIS_FATURASI', v_invoice_id
          );

          -- FAZ 3.1: Ürünün katalog alış fiyatı 0 veya NULL ise ilk/son net alış fiyatı ile otomatik güncelle
          UPDATE public.products
          SET purchase_price = v_unit_price,
              updated_at = v_now
          WHERE id = v_product_id
            AND user_id = v_user_id
            AND (purchase_price IS NULL OR purchase_price = 0);
        END IF;
      END IF;
    END LOOP;

    -- Yevmiye Fişi Oluşturma (153 BORÇ, 191 BORÇ, 320 ALACAK)
    SELECT id INTO v_acc_153_id FROM public.chart_of_accounts WHERE (code = '153' OR system_tag = 'STOK') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
    IF v_acc_153_id IS NULL THEN RAISE EXCEPTION 'Muhasebe hesap planında 153 (Ticari Mallar) hesabı bulunamadı.'; END IF;

    IF p_total_vat > 0 THEN
      SELECT id INTO v_acc_191_id FROM public.chart_of_accounts WHERE (code = '191' OR system_tag = 'INDIRILECEK_KDV') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
      IF v_acc_191_id IS NULL THEN RAISE EXCEPTION 'Muhasebe hesap planında 191 (İndirilecek KDV) hesabı bulunamadı.'; END IF;
    END IF;

    SELECT id INTO v_acc_320_id FROM public.chart_of_accounts WHERE (code = '320' OR system_tag = 'SATICILAR') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
    IF v_acc_320_id IS NULL THEN RAISE EXCEPTION 'Muhasebe hesap planında 320 (Satıcılar) hesabı bulunamadı.'; END IF;

    v_journal_number := public.next_entry_number(v_user_id, v_year, 'JOURNAL');
    INSERT INTO public.journal_entries (
      user_id, entry_number, entry_date, description, entry_type, source_type, source_id, status, period_year, period_month
    ) VALUES (
      v_user_id, v_journal_number, p_invoice_date, 'Alış Faturası Muhasebe Kaydı - ' || v_invoice_number, 'MAHSUP', 'INVOICE', v_invoice_id, 'DRAFT', v_year, v_month
    ) RETURNING id INTO v_journal_entry_id;

    -- 1. 153 TİCARİ MALLAR (BORÇ = Matrah)
    IF ROUND(COALESCE(p_taxable_amount, 0), 2) > 0 THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_153_id, 'Stok Girişi: ' || v_invoice_number, ROUND(p_taxable_amount, 2), 0, p_currency, COALESCE(p_exchange_rate, 1));
    END IF;

    -- 2. 191 İNDİRİLECEK KDV (BORÇ = Toplam KDV)
    IF v_acc_191_id IS NOT NULL THEN
      FOR v_tax_rec IN SELECT vat_rate, ROUND(tax_amount, 2) AS rounded_tax_amount FROM public.invoice_tax_lines WHERE invoice_id = v_invoice_id AND ROUND(tax_amount, 2) > 0 LOOP
        INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
        VALUES (v_journal_entry_id, v_user_id, v_acc_191_id, 'İndirilecek KDV (%' || v_tax_rec.vat_rate || '): ' || v_invoice_number, v_tax_rec.rounded_tax_amount, 0, p_currency, COALESCE(p_exchange_rate, 1));
      END LOOP;
    END IF;

    -- 3. 320 SATICILAR (ALACAK = Genel Toplam)
    IF ROUND(COALESCE(p_grand_total, 0), 2) > 0 THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_320_id, 'Tedarikçi Borç Kaydı: ' || v_invoice_number, 0, ROUND(p_grand_total, 2), p_currency, COALESCE(p_exchange_rate, 1));
    END IF;

    UPDATE public.journal_entries SET status = 'POSTED', updated_at = v_now WHERE id = v_journal_entry_id;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'invoice_id', v_invoice_id,
    'invoice_number', v_invoice_number,
    'ettn', v_ettn
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_purchase_invoice TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_purchase_invoice TO service_role;
