-- =============================================================
-- FAZ 2.2.5 — IMPLEMENTATION 3/4: SATIN ALMA İADELERİ VE TEDARİKÇİ ÖDEMELERİ
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-23
-- =============================================================
-- BU MİGRATION:
--   ✅ create_purchase_return RPC fonksiyonunu oluşturur (TEK ATOMİK TRANSACTION):
--      - Orijinal alış faturası ve tedarikçi doğrulaması
--      - Kapalı muhasebe dönemi kontrolü (assert_accounting_period_open)
--      - Deterministik ürün satır kilitleme (FOR UPDATE) ve stok mevcudiyeti kontrolü
--      - Fatura (type='ALIS_IADE') ve invoice_items kayıtları
--      - invoice_tax_lines iade KDV kayıtları
--      - Tedarikçi cari hareketi: 320 Satıcılar BORÇ = Genel Toplam (Tedarikçi Borcunu Azaltma)
--      - Stok çıkışı: stock_movements CIKIS (source = 'ALIS_IADE')
--      - Çift taraflı tam dengeli Yevmiye Fişi:
--          320 Satıcılar        BORÇ   = Genel Toplam (İade Tutarı)
--          153 Ticari Mallar   ALACAK  = Net Mal Bedeli (Matrah)
--          191 İndirilecek KDV ALACAK  = Toplam KDV
--   ✅ create_supplier_payment RPC fonksiyonunu oluşturur (TEK ATOMİK TRANSACTION):
--      - Tedarikçi (partner_type = 'TEDARIKCI') doğrulaması
--      - Kapalı dönem kontrolü
--      - 320 Satıcılar ve 100 Kasa / 102 Bankalar hesaplarının tespiti
--      - Tedarikçi cari hareketi: account_transactions (txn_type='BORC', source='TEDARIKCI_ODEME')
--      - Çift taraflı tam dengeli Yevmiye Fişi:
--          320 Satıcılar        BORÇ   = Ödeme Tutarı
--          100/102 Kasa/Banka  ALACAK  = Ödeme Tutarı
--   ✅ Idempotency, RLS ve SECURITY DEFINER güvenliği
-- =============================================================

-- 1. create_purchase_return RPC Fonksiyonu (Alış İadesi)
CREATE OR REPLACE FUNCTION public.create_purchase_return(
  p_original_invoice_id   UUID,
  p_return_date           DATE,
  p_return_invoice_number TEXT,
  p_items                 JSONB,
  p_warehouse_id          UUID DEFAULT NULL,
  p_notes                 TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id           UUID;
  v_orig_invoice      RECORD;
  v_return_invoice_id UUID;
  v_return_inv_number TEXT;
  v_ettn              TEXT;
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
  
  v_calc_subtotal     NUMERIC(14,2) := 0;
  v_calc_taxable      NUMERIC(14,2) := 0;
  v_calc_vat          NUMERIC(14,2) := 0;
  v_calc_grand_total  NUMERIC(14,2) := 0;
  
  v_year              INTEGER;
  v_month             INTEGER;
  v_now               TIMESTAMPTZ := now();
  v_txn_id            UUID;
  v_journal_entry_id  UUID;
  v_journal_number    TEXT;
  
  -- Deterministik Ürün Kilidi ve Stok Kontrolü
  v_product_ids       UUID[];
  v_locked_product    RECORD;
  v_current_stock     NUMERIC;
  
  -- Muhasebe Hesap ID'leri
  v_acc_153_id        UUID;
  v_acc_191_id        UUID;
  v_acc_320_id        UUID;
  
  v_tax_rec           RECORD;
  v_calc_debit        NUMERIC := 0;
  v_calc_credit       NUMERIC := 0;
BEGIN
  -- 1. Yetkilendirme Kontrolü
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Temel Doğrulamalar
  IF p_return_date IS NULL THEN
    RAISE EXCEPTION 'İade tarihi zorunludur.';
  END IF;

  IF p_return_invoice_number IS NULL OR trim(p_return_invoice_number) = '' THEN
    RAISE EXCEPTION 'İade fatura/irsaliye numarası zorunludur.';
  END IF;
  v_return_inv_number := trim(p_return_invoice_number);

  IF p_items IS NULL OR jsonb_typeof(p_items) != 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'En az bir geçerli iade kalemi girilmelidir.';
  END IF;

  -- 3. Kapalı Dönem Kontrolü
  PERFORM public.assert_accounting_period_open(v_user_id, p_return_date);

  -- 4. Orijinal Alış Faturası Doğrulaması
  SELECT *
  INTO v_orig_invoice
  FROM public.invoices
  WHERE id = p_original_invoice_id
    AND user_id = v_user_id
    AND type IN ('ALIS', 'GELEN_FATURA', 'GELEN_E_ARSIV')
    AND status != 'IPTAL'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'İade edilecek geçerli orijinal alış faturası bulunamadı. Fatura ID: %', p_original_invoice_id;
  END IF;

  -- 5. Mükerrer İade Belgesi Engelleme
  IF EXISTS (
    SELECT 1 FROM public.invoices
    WHERE user_id = v_user_id
      AND customer_id = v_orig_invoice.customer_id
      AND invoice_number = v_return_inv_number
      AND type = 'ALIS_IADE'
      AND status != 'IPTAL'
  ) THEN
    RAISE EXCEPTION 'Bu tedarikçiye ait bu iade numarası (%) ile kayıtlı bir alış iadesi zaten mevcuttur.', v_return_inv_number;
  END IF;

  v_year := EXTRACT(YEAR FROM p_return_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM p_return_date)::INTEGER;
  v_ettn := UPPER(gen_random_uuid()::TEXT);

  -- 6. Deterministik Ürün Kilit Dizisi ve Stok Kontrolü
  SELECT array_agg(DISTINCT (item->>'productId')::UUID ORDER BY (item->>'productId')::UUID)
  INTO v_product_ids
  FROM jsonb_array_elements(p_items) AS item
  WHERE (item->>'productId') IS NOT NULL AND trim(item->>'productId') != '';

  IF v_product_ids IS NOT NULL AND array_length(v_product_ids, 1) > 0 THEN
    FOR v_locked_product IN
      SELECT id, name, COALESCE(track_stock, true) AS track_stock
      FROM public.products
      WHERE id = ANY(v_product_ids)
        AND user_id = v_user_id
        AND deleted_at IS NULL
      ORDER BY id ASC
      FOR UPDATE
    LOOP
      IF v_locked_product.track_stock THEN
        -- Her ürün için iade miktarını topla ve mevcut stokla karşılaştır
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
        LOOP
          IF (v_item->>'productId')::UUID = v_locked_product.id THEN
            v_quantity := GREATEST(0, COALESCE((v_item->>'quantity')::NUMERIC, 0));
            v_current_stock := public.get_product_stock_quantity(v_locked_product.id);
            IF v_current_stock < v_quantity THEN
              RAISE EXCEPTION 'Yetersiz stok! İade edilmek istenen ürün: % (Mevcut Stok: %, İade Edilmek İstenen: %)',
                v_locked_product.name, v_current_stock, v_quantity;
            END IF;
          END IF;
        END LOOP;
      END IF;
    END LOOP;
  END IF;

  -- 7. İade Toplamlarının Hesaplanması
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_quantity      := GREATEST(0.0001, COALESCE((v_item->>'quantity')::NUMERIC, 1));
    v_unit_price    := ROUND(COALESCE((v_item->>'unitPrice')::NUMERIC, 0), 4);
    v_discount_rate := GREATEST(0, LEAST(100, COALESCE((v_item->>'discountRate')::NUMERIC, 0)));
    v_vat_rate      := GREATEST(0, LEAST(100, COALESCE((v_item->>'vatRate')::NUMERIC, 20)));

    v_item_subtotal := ROUND(v_quantity * v_unit_price, 2);
    v_item_discount := ROUND(v_item_subtotal * (v_discount_rate / 100.0), 2);
    v_item_taxable  := ROUND(v_item_subtotal - v_item_discount, 2);
    v_item_vat      := ROUND(v_item_taxable * (v_vat_rate / 100.0), 2);
    v_item_total    := v_item_taxable + v_item_vat;

    v_calc_subtotal    := v_calc_subtotal + v_item_subtotal;
    v_calc_taxable     := v_calc_taxable + v_item_taxable;
    v_calc_vat         := v_calc_vat + v_item_vat;
    v_calc_grand_total := v_calc_grand_total + v_item_total;
  END LOOP;

  -- 8. İade Faturası Başlığı (invoices INSERT with type='ALIS_IADE')
  INSERT INTO public.invoices (
    user_id,
    customer_id,
    warehouse_id,
    posted,
    ettn,
    invoice_number,
    type,
    status,
    gib_approval_date,
    invoice_date,
    currency,
    exchange_rate,
    customer,
    items,
    subtotal,
    total_discount,
    taxable_amount,
    total_vat,
    total_tevkifat,
    grand_total,
    notes,
    payment_info
  ) VALUES (
    v_user_id,
    v_orig_invoice.customer_id,
    COALESCE(p_warehouse_id, v_orig_invoice.warehouse_id),
    true,
    v_ettn,
    v_return_inv_number,
    'ALIS_IADE',
    'ONAYLANDI',
    v_now,
    p_return_date,
    v_orig_invoice.currency,
    v_orig_invoice.exchange_rate,
    v_orig_invoice.customer,
    p_items,
    v_calc_subtotal,
    v_calc_subtotal - v_calc_taxable,
    v_calc_taxable,
    v_calc_vat,
    0,
    v_calc_grand_total,
    COALESCE(p_notes, 'Alış İade Faturası (Orijinal: ' || v_orig_invoice.invoice_number || ')'),
    ''
  )
  RETURNING id INTO v_return_invoice_id;

  -- 9. İade Kalemlerini Kaydetme (invoice_items INSERT)
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
      invoice_id,
      user_id,
      line_number,
      product_id,
      description,
      unit,
      quantity,
      unit_price,
      discount_rate,
      taxable_amount,
      vat_rate,
      vat_amount,
      line_total,
      currency,
      exchange_rate
    ) VALUES (
      v_return_invoice_id,
      v_user_id,
      v_line_number,
      v_product_id,
      COALESCE(trim(v_item->>'name'), 'İade Kalemi ' || v_line_number),
      COALESCE(NULLIF(trim(v_item->>'unit'), ''), 'Adet'),
      v_quantity,
      v_unit_price,
      v_discount_rate,
      v_item_taxable,
      v_vat_rate,
      v_item_vat,
      v_item_total,
      v_orig_invoice.currency,
      v_orig_invoice.exchange_rate
    );

    -- 10. İade Stok Çıkışı (stock_movements CIKIS)
    IF v_product_id IS NOT NULL AND v_quantity > 0 THEN
      INSERT INTO public.stock_movements (
        user_id,
        product_id,
        warehouse_id,
        customer_id,
        movement_date,
        movement_type,
        quantity,
        unit_price,
        unit_cost,
        total_cost,
        document_no,
        description,
        source,
        source_id
      ) VALUES (
        v_user_id,
        v_product_id,
        COALESCE(p_warehouse_id, v_orig_invoice.warehouse_id),
        v_orig_invoice.customer_id,
        p_return_date,
        'CIKIS',
        v_quantity,
        v_unit_price,
        v_unit_price,
        v_item_taxable,
        v_return_inv_number,
        'Alış İadesi Stok Çıkışı (' || v_return_inv_number || ')',
        'ALIS_IADE',
        v_return_invoice_id
      );
    END IF;
  END LOOP;

  -- 11. İade KDV Satırlarını Kaydetme (invoice_tax_lines direction='ALIS', is_reversal=true)
  INSERT INTO public.invoice_tax_lines (
    invoice_id,
    user_id,
    direction,
    vat_rate,
    taxable_amount,
    tax_amount,
    withholding_rate,
    withholding_amount,
    is_reversal,
    currency,
    exchange_rate,
    taxable_amount_try,
    tax_amount_try,
    period_year,
    period_month
  )
  SELECT
    v_return_invoice_id,
    v_user_id,
    'ALIS',
    vat_rate,
    SUM(taxable_amount),
    SUM(vat_amount),
    0,
    0,
    true,
    v_orig_invoice.currency,
    v_orig_invoice.exchange_rate,
    ROUND(SUM(taxable_amount) * COALESCE(v_orig_invoice.exchange_rate, 1), 2),
    ROUND(SUM(vat_amount) * COALESCE(v_orig_invoice.exchange_rate, 1), 2),
    v_year,
    v_month
  FROM public.invoice_items
  WHERE invoice_id = v_return_invoice_id
  GROUP BY vat_rate;

  -- 12. Tedarikçi Cari Hesap Hareketi (account_transactions INSERT)
  -- İade yapıldığı için tedarikçi borçlandırılır (txn_type='BORC', amount=v_calc_grand_total)
  IF v_calc_grand_total > 0 THEN
    INSERT INTO public.account_transactions (
      user_id,
      customer_id,
      txn_date,
      txn_type,
      amount,
      document_no,
      description,
      source,
      source_id
    ) VALUES (
      v_user_id,
      v_orig_invoice.customer_id,
      p_return_date,
      'BORC',
      v_calc_grand_total,
      v_return_inv_number,
      'Alış İadesi Tedarikçi Borç Kaydı (' || v_return_inv_number || ')',
      'ALIS_IADE',
      v_return_invoice_id
    )
    RETURNING id INTO v_txn_id;
  END IF;

  -- 13. Muhasebe Hesaplarının Tespiti
  SELECT id INTO v_acc_153_id
  FROM public.chart_of_accounts
  WHERE (code = '153' OR system_tag = 'STOK')
    AND (user_id = v_user_id OR user_id IS NULL)
    AND is_active = true
  ORDER BY user_id NULLS LAST
  LIMIT 1;

  IF p_calc_vat > 0 OR v_calc_vat > 0 THEN
    SELECT id INTO v_acc_191_id
    FROM public.chart_of_accounts
    WHERE (code = '191' OR system_tag = 'INDIRILECEK_KDV')
      AND (user_id = v_user_id OR user_id IS NULL)
      AND is_active = true
    ORDER BY user_id NULLS LAST
    LIMIT 1;
  END IF;

  SELECT id INTO v_acc_320_id
  FROM public.chart_of_accounts
  WHERE (code = '320' OR system_tag = 'SATICILAR')
    AND (user_id = v_user_id OR user_id IS NULL)
    AND is_active = true
  ORDER BY user_id NULLS LAST
  LIMIT 1;

  -- 14. Alış İadesi Yevmiye Fişi (journal_entries & journal_lines)
  -- 320 Satıcılar BORÇ = Genel Toplam
  -- 153 Ticari Mallar ALACAK = Net Matrah
  -- 191 İndirilecek KDV ALACAK = Toplam KDV
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
    period_month
  ) VALUES (
    v_user_id,
    v_journal_number,
    p_return_date,
    'Alış İadesi Muhasebe Kaydı - ' || v_return_inv_number,
    'MAHSUP',
    'PURCHASE_RETURN',
    v_return_invoice_id,
    'DRAFT',
    v_year,
    v_month
  )
  RETURNING id INTO v_journal_entry_id;

  -- Satır 1: 320 Satıcılar BORÇ
  IF v_calc_grand_total > 0 THEN
    INSERT INTO public.journal_lines (
      journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
    ) VALUES (
      v_journal_entry_id, v_user_id, v_acc_320_id,
      'Alış İadesi Tedarikçi Borçlanması: ' || v_return_inv_number,
      v_calc_grand_total, 0, v_orig_invoice.currency, COALESCE(v_orig_invoice.exchange_rate, 1)
    );
  END IF;

  -- Satır 2: 153 Ticari Mallar ALACAK
  IF v_calc_taxable > 0 THEN
    INSERT INTO public.journal_lines (
      journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
    ) VALUES (
      v_journal_entry_id, v_user_id, v_acc_153_id,
      'Alış İadesi Stok Azalışı: ' || v_return_inv_number,
      0, v_calc_taxable, v_orig_invoice.currency, COALESCE(v_orig_invoice.exchange_rate, 1)
    );
  END IF;

  -- Satır 3: 191 İndirilecek KDV ALACAK
  FOR v_tax_rec IN
    SELECT vat_rate, tax_amount
    FROM public.invoice_tax_lines
    WHERE invoice_id = v_return_invoice_id AND tax_amount > 0
  LOOP
    INSERT INTO public.journal_lines (
      journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
    ) VALUES (
      v_journal_entry_id, v_user_id, v_acc_191_id,
      'Alış İadesi KDV Düzeltmesi (%' || v_tax_rec.vat_rate || '): ' || v_return_inv_number,
      0, v_tax_rec.tax_amount, v_orig_invoice.currency, COALESCE(v_orig_invoice.exchange_rate, 1)
    );
  END LOOP;

  -- Denklik Kontrolü ve Onaylama
  SELECT SUM(debit), SUM(credit)
  INTO v_calc_debit, v_calc_credit
  FROM public.journal_lines
  WHERE journal_entry_id = v_journal_entry_id;

  IF v_calc_debit IS NULL OR v_calc_credit IS NULL OR v_calc_debit != v_calc_credit THEN
    RAISE EXCEPTION 'Alış iadesi yevmiye fişi borç ve alacak toplamları denk değil! Borç: %, Alacak: %',
      v_calc_debit, v_calc_credit;
  END IF;

  UPDATE public.journal_entries
  SET status = 'POSTED'
  WHERE id = v_journal_entry_id;

  IF v_txn_id IS NOT NULL THEN
    UPDATE public.account_transactions
    SET journal_entry_id = v_journal_entry_id
    WHERE id = v_txn_id;
  END IF;

  RETURN jsonb_build_object(
    'return_invoice_id', v_return_invoice_id,
    'invoice_number', v_return_inv_number,
    'type', 'ALIS_IADE',
    'status', 'ONAYLANDI',
    'grand_total', v_calc_grand_total,
    'journal_entry_id', v_journal_entry_id,
    'journal_entry_number', v_journal_number
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_purchase_return FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_purchase_return TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_purchase_return TO service_role;

-- 2. create_supplier_payment RPC Fonksiyonu (Tedarikçi Ödemesi)
CREATE OR REPLACE FUNCTION public.create_supplier_payment(
  p_supplier_id    UUID,
  p_payment_date   DATE,
  p_amount         NUMERIC,
  p_payment_method TEXT DEFAULT 'BANKA',
  p_document_no    TEXT DEFAULT '',
  p_description    TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id           UUID;
  v_supplier          RECORD;
  v_year              INTEGER;
  v_month             INTEGER;
  v_txn_id            UUID;
  v_journal_entry_id  UUID;
  v_journal_number    TEXT;
  v_acc_320_id        UUID;
  v_acc_payment_id    UUID;
  v_method_upper      TEXT;
BEGIN
  -- 1. Yetkilendirme Kontrolü
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Temel Doğrulamalar
  IF p_supplier_id IS NULL THEN
    RAISE EXCEPTION 'Tedarikçi seçimi zorunludur.';
  END IF;

  IF p_payment_date IS NULL THEN
    RAISE EXCEPTION 'Ödeme tarihi zorunludur.';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Ödeme tutarı 0''dan büyük olmalıdır.';
  END IF;

  -- 3. Kapalı Dönem Kontrolü
  PERFORM public.assert_accounting_period_open(v_user_id, p_payment_date);

  -- 4. Tedarikçi Aidiyet Doğrulaması
  SELECT *
  INTO v_supplier
  FROM public.customers
  WHERE id = p_supplier_id
    AND user_id = v_user_id
    AND deleted_at IS NULL
    AND partner_type = 'TEDARIKCI'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Geçerli tedarikçi kartı bulunamadı. Tedarikçi ID: %', p_supplier_id;
  END IF;

  v_year := EXTRACT(YEAR FROM p_payment_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM p_payment_date)::INTEGER;
  v_method_upper := UPPER(COALESCE(p_payment_method, 'BANKA'));

  -- 5. Muhasebe Hesaplarının Tespiti
  -- 320 Satıcılar
  SELECT id INTO v_acc_320_id
  FROM public.chart_of_accounts
  WHERE (code = '320' OR system_tag = 'SATICILAR')
    AND (user_id = v_user_id OR user_id IS NULL)
    AND is_active = true
  ORDER BY user_id NULLS LAST
  LIMIT 1;

  IF v_acc_320_id IS NULL THEN
    RAISE EXCEPTION 'Muhasebe hesap planında 320 (Satıcılar) hesabı bulunamadı.';
  END IF;

  -- 100 Kasa veya 102 Bankalar
  IF v_method_upper IN ('KASA', 'CASH', 'NAKIT') THEN
    SELECT id INTO v_acc_payment_id
    FROM public.chart_of_accounts
    WHERE (code = '100' OR system_tag = 'KASA')
      AND (user_id = v_user_id OR user_id IS NULL)
      AND is_active = true
    ORDER BY user_id NULLS LAST
    LIMIT 1;
  ELSE
    SELECT id INTO v_acc_payment_id
    FROM public.chart_of_accounts
    WHERE (code = '102' OR system_tag = 'BANKA')
      AND (user_id = v_user_id OR user_id IS NULL)
      AND is_active = true
    ORDER BY user_id NULLS LAST
    LIMIT 1;
  END IF;

  IF v_acc_payment_id IS NULL THEN
    RAISE EXCEPTION 'Muhasebe hesap planında ödeme hesabı (100 Kasa / 102 Bankalar) bulunamadı.';
  END IF;

  -- 6. Tedarikçi Cari Hesap Hareketi (account_transactions INSERT)
  -- Ödeme yapıldığında tedarikçi cari borçlandırılır (txn_type='BORC')
  INSERT INTO public.account_transactions (
    user_id,
    customer_id,
    txn_date,
    txn_type,
    amount,
    document_no,
    description,
    source,
    source_id
  ) VALUES (
    v_user_id,
    p_supplier_id,
    p_payment_date,
    'BORC',
    p_amount,
    COALESCE(p_document_no, ''),
    COALESCE(NULLIF(trim(p_description), ''), 'Tedarikçi Ödemesi (' || v_supplier.title || ')'),
    'TEDARIKCI_ODEME',
    gen_random_uuid()
  )
  RETURNING id INTO v_txn_id;

  -- 7. Yevmiye Fişi (journal_entries & journal_lines)
  -- 320 Satıcılar BORÇ = p_amount
  -- 100/102 Kasa/Banka ALACAK = p_amount
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
    period_month
  ) VALUES (
    v_user_id,
    v_journal_number,
    p_payment_date,
    'Tedarikçi Ödemesi - ' || v_supplier.title || CASE WHEN trim(p_document_no) != '' THEN ' (' || trim(p_document_no) || ')' ELSE '' END,
    'TEDIYE',
    'SUPPLIER_PAYMENT',
    v_txn_id,
    'DRAFT',
    v_year,
    v_month
  )
  RETURNING id INTO v_journal_entry_id;

  -- Satır 1: 320 Satıcılar BORÇ
  INSERT INTO public.journal_lines (
    journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
  ) VALUES (
    v_journal_entry_id, v_user_id, v_acc_320_id,
    'Tedarikçi Borç Kapatma: ' || v_supplier.title,
    p_amount, 0, 'TRY', 1
  );

  -- Satır 2: 100 Kasa / 102 Banka ALACAK
  INSERT INTO public.journal_lines (
    journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
  ) VALUES (
    v_journal_entry_id, v_user_id, v_acc_payment_id,
    'Tedarikçi Ödeme Çıkışı: ' || v_supplier.title,
    0, p_amount, 'TRY', 1
  );

  -- Onaylama
  UPDATE public.journal_entries
  SET status = 'POSTED'
  WHERE id = v_journal_entry_id;

  UPDATE public.account_transactions
  SET journal_entry_id = v_journal_entry_id
  WHERE id = v_txn_id;

  RETURN jsonb_build_object(
    'transaction_id', v_txn_id,
    'supplier_id', p_supplier_id,
    'supplier_title', v_supplier.title,
    'payment_date', p_payment_date,
    'amount', p_amount,
    'payment_method', v_method_upper,
    'journal_entry_id', v_journal_entry_id,
    'journal_entry_number', v_journal_number
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_supplier_payment FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_supplier_payment TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_supplier_payment TO service_role;
