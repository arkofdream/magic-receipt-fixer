-- =============================================================
-- FAZ 2.2.5 — IMPLEMENTATION 1/4: SATIN ALMA FATURASI ATOMİK MUHASEBE MOTORU
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-23
-- =============================================================
-- BU MİGRATION:
--   ✅ create_purchase_invoice RPC fonksiyonunu oluşturur (TEK ATOMİK TRANSACTION):
--      - Tedarikçi (partner_type = 'TEDARIKCI') doğrulaması
--      - Açık muhasebe dönemi kontrolü (assert_accounting_period_open)
--      - Mükerrer alış faturası engelleme (Idempotency)
--      - Fatura (type='ALIS') ve invoice_items kayıtları
--      - invoice_tax_lines alış KDV (direction='ALIS') satırları
--      - Tedarikçi cari hareketi: 320 Satıcılar ALACAK = Genel Toplam (KDV Dahil)
--      - Stok girişi: stock_movements GIRIS (unit_cost = Net Alış Fiyatı, KDV hariç)
--      - Ağırlıklı ortalama maliyet entegrasyonu
--      - Çift taraflı tam dengeli Yevmiye Fişi:
--          153 Ticari Mallar    BORÇ   = Net Mal Bedeli (Matrah)
--          191 İndirilecek KDV  BORÇ   = Toplam KDV
--          320 Satıcılar       ALACAK  = Genel Toplam
--   ✅ cancel_purchase_invoice RPC fonksiyonunu oluşturur (TEK ATOMİK TRANSACTION):
--      - Fatura IPTAL statüsü
--      - Tedarikçi cari ters kaydı (BORC = Genel Toplam)
--      - Stok ters çıkışı (CIKIS)
--      - KDV satırları iptali
--      - Muhasebe Reversal Fişi (320 BORÇ / 153 ALACAK / 191 ALACAK)
--   ✅ Idempotency ve performans indekslerini ekler
--   ✅ Multi-tenant (user_id = auth.uid()) ve SECURITY DEFINER güvenliği
-- =============================================================

-- 1. Idempotency ve Performans İndeksleri
CREATE INDEX IF NOT EXISTS idx_invoices_user_type_date
  ON public.invoices(user_id, type, invoice_date);

CREATE UNIQUE INDEX IF NOT EXISTS idx_purchase_invoices_unique_supplier_doc
  ON public.invoices(user_id, customer_id, invoice_number)
  WHERE type IN ('ALIS', 'GELEN_FATURA', 'GELEN_E_ARSIV') AND status != 'IPTAL';

-- 2. create_purchase_invoice RPC Fonksiyonu
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
  
  -- Deterministik Ürün Kilit Dizisi
  v_product_ids       UUID[];
  v_locked_product    RECORD;
  
  -- Muhasebe Hesap ID'leri
  v_acc_153_id        UUID;
  v_acc_191_id        UUID;
  v_acc_320_id        UUID;
  
  -- KDV Toplamları Döngüsü
  v_tax_rec           RECORD;
  v_calc_total_debit  NUMERIC := 0;
  v_calc_total_credit NUMERIC := 0;
BEGIN
  -- 1. Yetkilendirme Kontrolü
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Temel Doğrulamalar
  IF p_invoice_date IS NULL THEN
    RAISE EXCEPTION 'Fatura tarihi zorunludur.';
  END IF;

  IF p_invoice_number IS NULL OR trim(p_invoice_number) = '' THEN
    RAISE EXCEPTION 'Tedarikçi fatura numarası zorunludur.';
  END IF;
  v_invoice_number := trim(p_invoice_number);

  IF p_supplier_id IS NULL THEN
    RAISE EXCEPTION 'Tedarikçi seçimi zorunludur.';
  END IF;

  -- 3. Kapalı Dönem Kontrolü
  PERFORM public.assert_accounting_period_open(v_user_id, p_invoice_date);

  -- 4. Tedarikçi Aidiyet ve partner_type Doğrulaması
  IF NOT EXISTS (
    SELECT 1 FROM public.customers
    WHERE id = p_supplier_id
      AND user_id = v_user_id
      AND deleted_at IS NULL
      AND partner_type = 'TEDARIKCI'
  ) THEN
    RAISE EXCEPTION 'Seçilen cari kart tedarikçi (TEDARIKCI) türünde değil veya silinmiş. Tedarikçi ID: %', p_supplier_id;
  END IF;

  -- 5. Mükerrer Alış Faturası Engelleme (Idempotency)
  IF EXISTS (
    SELECT 1 FROM public.invoices
    WHERE user_id = v_user_id
      AND customer_id = p_supplier_id
      AND invoice_number = v_invoice_number
      AND type IN ('ALIS', 'GELEN_FATURA', 'GELEN_E_ARSIV')
      AND status != 'IPTAL'
  ) THEN
    RAISE EXCEPTION 'Bu tedarikçiye ait bu fatura numarası (%) ile kayıtlı bir alış faturası zaten mevcuttur.', v_invoice_number;
  END IF;

  -- 6. Depo Aidiyet ve Varlık Kontrolü
  IF p_warehouse_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.warehouses
      WHERE id = p_warehouse_id AND user_id = v_user_id AND deleted_at IS NULL
    ) THEN
      RAISE EXCEPTION 'Geçersiz veya silinmiş depo seçimi. Depo ID: %', p_warehouse_id;
    END IF;
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) != 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'En az bir geçerli fatura kalemi girilmelidir.';
  END IF;

  IF p_grand_total < 0 THEN
    RAISE EXCEPTION 'Fatura genel toplamı negatif olamaz.';
  END IF;

  v_year        := EXTRACT(YEAR FROM p_invoice_date)::INTEGER;
  v_month       := EXTRACT(MONTH FROM p_invoice_date)::INTEGER;
  v_should_post := (p_status = 'ONAYLANDI');
  v_ettn        := COALESCE(NULLIF(trim(p_ettn), ''), UPPER(gen_random_uuid()::TEXT));

  -- 7. Deterministik Ürün Satır Kilitlemesi (Deadlock Koruması)
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
      NULL; -- Ürün satır kilidi alındı
    END LOOP;

    IF (SELECT count(*) FROM public.products WHERE id = ANY(v_product_ids) AND user_id = v_user_id AND deleted_at IS NULL) < array_length(v_product_ids, 1) THEN
      RAISE EXCEPTION 'Alış faturasındaki ürünlerden biri veya birkaçı sistemde bulunamadı ya da silinmiş.';
    END IF;
  END IF;

  -- 8. Fatura Başlığını Oluşturma (invoices INSERT with type='ALIS')
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
    p_supplier_id,
    p_warehouse_id,
    v_should_post,
    v_ettn,
    v_invoice_number,
    'ALIS',
    p_status,
    CASE WHEN v_should_post THEN v_now ELSE NULL END,
    p_invoice_date,
    p_currency,
    COALESCE(p_exchange_rate, 1),
    p_supplier_info,
    p_items,
    p_subtotal,
    p_total_discount,
    p_taxable_amount,
    p_total_vat,
    COALESCE(p_total_tevkifat, 0),
    p_grand_total,
    COALESCE(p_notes, ''),
    COALESCE(p_payment_info, '')
  )
  RETURNING id INTO v_invoice_id;

  -- 9. Fatura Kalemlerini Normalize Olarak Kaydetme (invoice_items INSERT)
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
      v_invoice_id,
      v_user_id,
      v_line_number,
      v_product_id,
      COALESCE(trim(v_item->>'name'), 'Kalem ' || v_line_number),
      COALESCE(NULLIF(trim(v_item->>'unit'), ''), 'Adet'),
      v_quantity,
      v_unit_price,
      v_discount_rate,
      v_item_taxable,
      v_vat_rate,
      v_item_vat,
      v_item_total,
      p_currency,
      COALESCE(p_exchange_rate, 1)
    );
  END LOOP;

  -- 10. Alış KDV Satırlarını Oran Bazında Kaydetme (invoice_tax_lines direction='ALIS')
  INSERT INTO public.invoice_tax_lines (
    invoice_id,
    user_id,
    direction,
    vat_rate,
    taxable_amount,
    tax_amount,
    withholding_rate,
    withholding_amount,
    currency,
    exchange_rate,
    taxable_amount_try,
    tax_amount_try,
    period_year,
    period_month
  )
  SELECT
    v_invoice_id,
    v_user_id,
    'ALIS',
    vat_rate,
    SUM(taxable_amount) AS taxable_amount,
    SUM(vat_amount)     AS tax_amount,
    0,
    0,
    p_currency,
    COALESCE(p_exchange_rate, 1),
    ROUND(SUM(taxable_amount) * COALESCE(p_exchange_rate, 1), 2),
    ROUND(SUM(vat_amount) * COALESCE(p_exchange_rate, 1), 2),
    v_year,
    v_month
  FROM public.invoice_items
  WHERE invoice_id = v_invoice_id
  GROUP BY vat_rate;

  -- 11. ONAYLI Alış Faturası İse: Tedarikçi Cari (320), Stok Girişi (GIRIS) ve Yevmiye Fişi
  IF v_should_post THEN

    -- A) Tedarikçi Cari Hesap Hareketi (account_transactions INSERT)
    -- Tedarikçiye borçlandığımız için ALACAK kaydı atılır (amount = KDV dahil grand_total)
    IF p_grand_total > 0 THEN
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
        p_invoice_date,
        'ALACAK',
        p_grand_total,
        v_invoice_number,
        'Alış faturası tedarikçi alacak kaydı (' || v_invoice_number || ')',
        'ALIS_FATURASI',
        v_invoice_id
      )
      RETURNING id INTO v_txn_id;
    END IF;

    -- B) Stok Giriş Hareketleri (stock_movements INSERT)
    -- KRİTİK: unit_cost = Net Alış Fiyatı (KDV kesinlikle maliyete dahil edilmez)
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
      IF (v_item->>'productId') IS NOT NULL AND trim(v_item->>'productId') != '' THEN
        v_product_id := (v_item->>'productId')::UUID;
        v_quantity   := GREATEST(0, COALESCE((v_item->>'quantity')::NUMERIC, 0));
        -- Net birim alış maliyeti (indirim sonrası net birim matrah)
        v_discount_rate := GREATEST(0, LEAST(100, COALESCE((v_item->>'discountRate')::NUMERIC, 0)));
        v_unit_price    := ROUND(COALESCE((v_item->>'unitPrice')::NUMERIC, 0) * (1 - (v_discount_rate / 100.0)), 4);

        IF v_quantity > 0 THEN
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
            p_warehouse_id,
            p_supplier_id,
            p_invoice_date,
            'GIRIS',
            v_quantity,
            v_unit_price,
            v_unit_price,
            ROUND(v_quantity * v_unit_price, 2),
            v_invoice_number,
            'Alış faturası stok girişi (' || v_invoice_number || ')',
            'ALIS_FATURASI',
            v_invoice_id
          );
        END IF;
      END IF;
    END LOOP;

    -- C) Muhasebe Hesaplarının Tespiti
    -- 153 Ticari Mallar
    SELECT id INTO v_acc_153_id
    FROM public.chart_of_accounts
    WHERE (code = '153' OR system_tag = 'STOK')
      AND (user_id = v_user_id OR user_id IS NULL)
      AND is_active = true
    ORDER BY user_id NULLS LAST
    LIMIT 1;

    IF v_acc_153_id IS NULL THEN
      RAISE EXCEPTION 'Muhasebe hesap planında 153 (Ticari Mallar) hesabı bulunamadı.';
    END IF;

    -- 191 İndirilecek KDV
    IF p_total_vat > 0 THEN
      SELECT id INTO v_acc_191_id
      FROM public.chart_of_accounts
      WHERE (code = '191' OR system_tag = 'INDIRILECEK_KDV')
        AND (user_id = v_user_id OR user_id IS NULL)
        AND is_active = true
      ORDER BY user_id NULLS LAST
      LIMIT 1;

      IF v_acc_191_id IS NULL THEN
        RAISE EXCEPTION 'Muhasebe hesap planında 191 (İndirilecek KDV) hesabı bulunamadı.';
      END IF;
    END IF;

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

    -- D) Otomatik Yevmiye Fişi Başlığı (journal_entries INSERT)
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
      p_invoice_date,
      'Alış Faturası Muhasebe Kaydı - ' || v_invoice_number,
      'MAHSUP',
      'PURCHASE_INVOICE',
      v_invoice_id,
      'DRAFT',
      v_year,
      v_month
    )
    RETURNING id INTO v_journal_entry_id;

    -- E) Yevmiye Fişi Satırları (journal_lines INSERT)
    -- 1. Satır: 153 TİCARİ MALLAR ➔ BORÇ = Net Mal Bedeli (Matrah)
    IF p_taxable_amount > 0 THEN
      INSERT INTO public.journal_lines (
        journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
      ) VALUES (
        v_journal_entry_id, v_user_id, v_acc_153_id,
        'Ticari Mal Alışı: ' || v_invoice_number,
        p_taxable_amount, 0, p_currency, COALESCE(p_exchange_rate, 1)
      );
    END IF;

    -- 2. Satırlar: 191 İNDİRİLECEK KDV ➔ BORÇ = KDV Tutarları (Oran Bazında)
    FOR v_tax_rec IN
      SELECT vat_rate, tax_amount
      FROM public.invoice_tax_lines
      WHERE invoice_id = v_invoice_id AND tax_amount > 0
    LOOP
      INSERT INTO public.journal_lines (
        journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
      ) VALUES (
        v_journal_entry_id, v_user_id, v_acc_191_id,
        'İndirilecek KDV (%' || v_tax_rec.vat_rate || '): ' || v_invoice_number,
        v_tax_rec.tax_amount, 0, p_currency, COALESCE(p_exchange_rate, 1)
      );
    END LOOP;

    -- 3. Satır: 320 SATICILAR ➔ ALACAK = Genel Toplam (Tedarikçiye Borç)
    IF p_grand_total > 0 THEN
      INSERT INTO public.journal_lines (
        journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
      ) VALUES (
        v_journal_entry_id, v_user_id, v_acc_320_id,
        'Tedarikçi Borç Kaydı: ' || v_invoice_number,
        0, p_grand_total, p_currency, COALESCE(p_exchange_rate, 1)
      );
    END IF;

    -- F) Yevmiye Fişi Denklik Doğrulaması ve POSTED Yapılması
    SELECT SUM(debit), SUM(credit)
    INTO v_calc_total_debit, v_calc_total_credit
    FROM public.journal_lines
    WHERE journal_entry_id = v_journal_entry_id;

    IF v_calc_total_debit IS NULL OR v_calc_total_credit IS NULL OR v_calc_total_debit != v_calc_total_credit THEN
      RAISE EXCEPTION 'Alış faturası muhasebe fişi borç ve alacak toplamları denk değil! Borç: %, Alacak: %',
        v_calc_total_debit, v_calc_total_credit;
    END IF;

    -- Fişi Onaylı (POSTED) Yap
    UPDATE public.journal_entries
    SET status = 'POSTED'
    WHERE id = v_journal_entry_id;

    -- G) Cari Hareketi Yevmiye Fişine Bağlama
    IF v_txn_id IS NOT NULL THEN
      UPDATE public.account_transactions
      SET journal_entry_id = v_journal_entry_id
      WHERE id = v_txn_id;
    END IF;

  END IF;

  -- 12. Sonuç Dönüşü
  RETURN jsonb_build_object(
    'id', v_invoice_id,
    'invoice_number', v_invoice_number,
    'type', 'ALIS',
    'status', p_status,
    'ettn', v_ettn,
    'posted', v_should_post,
    'journal_entry_id', v_journal_entry_id,
    'journal_entry_number', v_journal_number
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_purchase_invoice FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_purchase_invoice TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_purchase_invoice TO service_role;

-- 3. cancel_purchase_invoice RPC Fonksiyonu
CREATE OR REPLACE FUNCTION public.cancel_purchase_invoice(
  p_invoice_id    UUID,
  p_cancel_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id             UUID;
  v_invoice             RECORD;
  v_orig_journal        RECORD;
  v_reversal_journal_id UUID;
  v_reversal_entry_no   TEXT;
  v_orig_line           RECORD;
  v_orig_stock          RECORD;
  v_orig_tax            RECORD;
  v_reversal_tax_id     UUID;
  v_rev_count_txn       INTEGER := 0;
  v_rev_count_stock     INTEGER := 0;
  v_now                 TIMESTAMPTZ := now();
BEGIN
  -- 1. Yetkilendirme Kontrolü
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Fatura Varlık, Tür ve Aidiyet Kontrolü
  SELECT *
  INTO v_invoice
  FROM public.invoices
  WHERE id = p_invoice_id
    AND user_id = v_user_id
    AND type IN ('ALIS', 'GELEN_FATURA', 'GELEN_E_ARSIV')
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'İptal edilecek alış faturası bulunamadı veya bu faturaya erişim yetkiniz yok. Fatura ID: %', p_invoice_id;
  END IF;

  -- 3. Kapalı Dönem Kontrolü
  PERFORM public.assert_accounting_period_open(v_user_id, v_invoice.invoice_date);
  PERFORM public.assert_accounting_period_open(v_user_id, CURRENT_DATE);

  -- 4. Zaten İptal Edilmiş mi?
  IF v_invoice.status = 'IPTAL' THEN
    RAISE EXCEPTION 'Bu alış faturası (%) zaten iptal edilmiştir. Mükerrer iptal işlemi yapılamaz.',
      v_invoice.invoice_number;
  END IF;

  -- 5. Fatura Durumunu IPTAL Olarak Güncelleme
  UPDATE public.invoices
  SET
    status = 'IPTAL',
    cancel_date = v_now,
    notes = CASE
      WHEN trim(p_cancel_reason) != '' THEN
        COALESCE(notes, '') || E'\n[İPTAL SEBEBİ]: ' || trim(p_cancel_reason)
      ELSE notes
    END
  WHERE id = p_invoice_id;

  -- 6. Eğer Fatura Onaylı (POSTED) İdiyse Ters Kayıtlar Üret
  IF v_invoice.posted THEN

    -- A) Tedarikçi Cari Hesap Ters Kaydı (account_transactions INSERT)
    -- Orijinal ALACAK terslenerek BORC kaydı atılır
    IF v_invoice.customer_id IS NOT NULL AND v_invoice.grand_total > 0 THEN
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
        v_invoice.customer_id,
        CURRENT_DATE,
        'BORC',
        v_invoice.grand_total,
        v_invoice.invoice_number,
        'Alış Faturası İptali Ters Kaydı (' || v_invoice.invoice_number || ')' ||
          CASE WHEN trim(p_cancel_reason) != '' THEN ' - Sebep: ' || trim(p_cancel_reason) ELSE '' END,
        'ALIS_FATURASI_IPTAL',
        p_invoice_id
      );
      v_rev_count_txn := 1;
    END IF;

    -- B) Stok Ters Çıkış Hareketleri (stock_movements CIKIS)
    FOR v_orig_stock IN
      SELECT *
      FROM public.stock_movements
      WHERE source_id = p_invoice_id
        AND user_id = v_user_id
        AND deleted_at IS NULL
        AND source = 'ALIS_FATURASI'
    LOOP
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
        v_orig_stock.product_id,
        v_orig_stock.warehouse_id,
        v_orig_stock.customer_id,
        CURRENT_DATE,
        'CIKIS',
        v_orig_stock.quantity,
        v_orig_stock.unit_price,
        v_orig_stock.unit_cost,
        v_orig_stock.total_cost,
        v_invoice.invoice_number,
        'Alış Faturası İptali Stok Çıkışı (' || v_invoice.invoice_number || ')',
        'ALIS_FATURASI_IPTAL',
        p_invoice_id
      );
      v_rev_count_stock := v_rev_count_stock + 1;
    END LOOP;

    -- C) KDV Satırları İptali (invoice_tax_lines)
    FOR v_orig_tax IN
      SELECT *
      FROM public.invoice_tax_lines
      WHERE invoice_id = p_invoice_id
        AND user_id = v_user_id
        AND is_reversal = false
    LOOP
      INSERT INTO public.invoice_tax_lines (
        invoice_id,
        user_id,
        direction,
        vat_rate,
        taxable_amount,
        tax_amount,
        withholding_rate,
        withholding_amount,
        is_exempt,
        exemption_code,
        is_cancelled,
        is_reversal,
        reversal_of,
        currency,
        exchange_rate,
        taxable_amount_try,
        tax_amount_try,
        period_year,
        period_month
      ) VALUES (
        p_invoice_id,
        v_user_id,
        v_orig_tax.direction,
        v_orig_tax.vat_rate,
        v_orig_tax.taxable_amount,
        v_orig_tax.tax_amount,
        v_orig_tax.withholding_rate,
        v_orig_tax.withholding_amount,
        v_orig_tax.is_exempt,
        v_orig_tax.exemption_code,
        true,
        true,
        v_orig_tax.id,
        v_orig_tax.currency,
        v_orig_tax.exchange_rate,
        v_orig_tax.taxable_amount_try,
        v_orig_tax.tax_amount_try,
        EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER,
        EXTRACT(MONTH FROM CURRENT_DATE)::INTEGER
      )
      RETURNING id INTO v_reversal_tax_id;

      UPDATE public.invoice_tax_lines
      SET is_cancelled = true
      WHERE id = v_orig_tax.id;
    END LOOP;

    -- D) Yevmiye Fişi Reversal (journal_entries & journal_lines)
    -- Orijinal 153 Borç / 191 Borç / 320 Alacak tersine çevrilir:
    -- Reversal: 320 BORÇ / 153 ALACAK / 191 ALACAK
    SELECT *
    INTO v_orig_journal
    FROM public.journal_entries
    WHERE source_type = 'PURCHASE_INVOICE'
      AND source_id = p_invoice_id
      AND user_id = v_user_id
      AND status = 'POSTED'
    LIMIT 1;

    IF FOUND THEN
      v_reversal_entry_no := public.next_entry_number(v_user_id, EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER, 'JOURNAL');

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
        v_reversal_entry_no,
        CURRENT_DATE,
        'Alış Faturası İptal Ters Kaydı - ' || v_invoice.invoice_number ||
          CASE WHEN trim(p_cancel_reason) != '' THEN ' (' || trim(p_cancel_reason) || ')' ELSE '' END,
        'MAHSUP',
        'PURCHASE_INVOICE_CANCEL',
        p_invoice_id,
        'DRAFT',
        EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER,
        EXTRACT(MONTH FROM CURRENT_DATE)::INTEGER
      )
      RETURNING id INTO v_reversal_journal_id;

      FOR v_orig_line IN
        SELECT *
        FROM public.journal_lines
        WHERE journal_entry_id = v_orig_journal.id
          AND user_id = v_user_id
      LOOP
        INSERT INTO public.journal_lines (
          journal_entry_id,
          user_id,
          account_id,
          description,
          debit,
          credit,
          currency,
          exchange_rate
        ) VALUES (
          v_reversal_journal_id,
          v_user_id,
          v_orig_line.account_id,
          'İptal Ters Kaydı: ' || COALESCE(v_orig_line.description, v_invoice.invoice_number),
          v_orig_line.credit, -- Alacak ➔ Borç
          v_orig_line.debit,  -- Borç ➔ Alacak
          v_orig_line.currency,
          v_orig_line.exchange_rate
        );
      END LOOP;

      UPDATE public.journal_entries
      SET status = 'POSTED'
      WHERE id = v_reversal_journal_id;

      UPDATE public.journal_entries
      SET status = 'CANCELLED'
      WHERE id = v_orig_journal.id;
    END IF;

  END IF;

  -- 7. JSONB Sonuç Dönüşü
  RETURN jsonb_build_object(
    'invoice_id', p_invoice_id,
    'invoice_number', v_invoice.invoice_number,
    'type', 'ALIS',
    'status', 'IPTAL',
    'posted', v_invoice.posted,
    'reversal_journal_id', v_reversal_journal_id,
    'reversal_journal_number', v_reversal_entry_no,
    'reversal_transactions_count', v_rev_count_txn,
    'reversal_stock_movements_count', v_rev_count_stock
  );
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_purchase_invoice FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_purchase_invoice TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_purchase_invoice TO service_role;
