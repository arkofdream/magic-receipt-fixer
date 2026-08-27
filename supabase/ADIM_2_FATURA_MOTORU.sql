-- =============================================================
-- ADIM 2 / 3: SATIŞ, ALIŞ, İADE VE ÖDEME MOTORU FONKSİYONLARI
-- =============================================================
-- =============================================================
-- FAZ 1B.4 — ATOMİK FATURA İPTALİ VE REVERSAL (TERS KAYIT) RPC
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-22
-- =============================================================
-- BU MİGRATION:
--   ✅ cancel_sales_invoice RPC fonksiyonunu oluşturur
--   ✅ Orijinal cari ve stok kayıtlarını silmeden/soft-delete etmeden korur
--   ✅ İptal anında ters yönde dengeleyici (reversal) cari ve stok kayıtları oluşturur
--   ✅ SELECT ... FOR UPDATE ile aynı faturaya eşzamanlı çift iptali engeller
--   ✅ auth.uid() doğrulaması ile tam kullanıcı izolasyonu sağlar
--   ✅ Herhangi bir adım başarısız olursa TÜM işlemi ROLLBACK eder
-- =============================================================

CREATE OR REPLACE FUNCTION public.cancel_sales_invoice(
  p_invoice_id    UUID,
  p_cancel_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id         UUID;
  v_invoice         RECORD;
  v_is_return       BOOLEAN;
  v_item            JSONB;
  v_product_id      UUID;
  v_quantity        NUMERIC;
  v_unit_price      NUMERIC;
  v_now             TIMESTAMPTZ := now();
  v_cancel_date_str TEXT;
  v_journal         RECORD;
  v_reversal_je_id  UUID;
  v_line            RECORD;
BEGIN
  -- 1. Yetkilendirme Kontrolü
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  IF p_invoice_id IS NULL THEN
    RAISE EXCEPTION 'Fatura ID zorunludur.';
  END IF;

  -- 2. Faturayı Satır Kilitlemeli Olarak Oku (Concurrency / Çift İptal Koruması)
  SELECT *
  INTO v_invoice
  FROM public.invoices
  WHERE id = p_invoice_id AND user_id = v_user_id AND deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fatura bulunamadı veya bu işlem için yetkiniz yok. Fatura ID: %', p_invoice_id;
  END IF;

  -- 3. Durum Kontrolü
  IF v_invoice.status = 'IPTAL' THEN
    RAISE EXCEPTION 'Bu fatura zaten iptal edilmiştir. Fatura No: %', v_invoice.invoice_number;
  END IF;

  v_is_return := (v_invoice.type = 'IADE');
  v_cancel_date_str := to_char(v_now, 'YYYY-MM-DD');

  -- 4. Fatura Başlığını İptal Durumuna Güncelle (Orijinal Kayıt Korunur)
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

  -- 5. Onaylı (POSTED) Fatura ise Muhasebesel Ters Kayıtları Oluştur
  IF v_invoice.posted = true THEN

    -- A) Cari Reversal (Ters Cari Kaydı: SATIS ise ALACAK, IADE ise BORC)
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
        v_now::date,
        CASE WHEN v_is_return THEN 'BORC' ELSE 'ALACAK' END,
        v_invoice.grand_total,
        v_invoice.invoice_number,
        CASE
          WHEN v_is_return THEN 'İade Faturası İptali (Borç Düzeltme) - ' || v_invoice.invoice_number
          ELSE 'Satış Faturası İptali (Alacak Düzeltme) - ' || v_invoice.invoice_number
        END,
        'FATURA_IPTAL',
        p_invoice_id
      );
    END IF;

    -- B) Stok Reversal (Ters Stok Kaydı: SATIS ise GIRIS, IADE ise CIKIS)
    IF v_invoice.items IS NOT NULL AND jsonb_typeof(v_invoice.items) = 'array' THEN
      FOR v_item IN SELECT * FROM jsonb_array_elements(v_invoice.items)
      LOOP
        IF (v_item->>'productId') IS NOT NULL AND trim(v_item->>'productId') != '' THEN
          v_product_id := (v_item->>'productId')::UUID;
          v_quantity   := GREATEST(0, COALESCE((v_item->>'quantity')::NUMERIC, 0));
          v_unit_price := ROUND(COALESCE((v_item->>'unitPrice')::NUMERIC, 0), 2);

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
              document_no,
              description,
              source,
              source_id
            ) VALUES (
              v_user_id,
              v_product_id,
              v_invoice.warehouse_id,
              v_invoice.customer_id,
              v_now::date,
              CASE WHEN v_is_return THEN 'CIKIS' ELSE 'GIRIS' END,
              v_quantity,
              v_unit_price,
              v_invoice.invoice_number,
              CASE
                WHEN v_is_return THEN 'İade Faturası İptali (Stok Çıkışı) - ' || v_invoice.invoice_number
                ELSE 'Satış Faturası İptali (Stok Girişi) - ' || v_invoice.invoice_number
              END,
              'FATURA_IPTAL',
              p_invoice_id
            );
          END IF;
        END IF;
      END LOOP;
    END IF;

    -- C) Varsa KDV Reversal (invoice_tax_lines)
    IF EXISTS (
      SELECT 1 FROM public.invoice_tax_lines
      WHERE invoice_id = p_invoice_id AND is_reversal = false
    ) THEN
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
      )
      SELECT
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
        true,
        true,
        id,
        currency,
        exchange_rate,
        taxable_amount_try,
        tax_amount_try,
        EXTRACT(YEAR FROM v_now)::INTEGER,
        EXTRACT(MONTH FROM v_now)::INTEGER
      FROM public.invoice_tax_lines
      WHERE invoice_id = p_invoice_id AND is_reversal = false;
    END IF;

    -- D) Varsa Yevmiye Fişi Reversal (journal_entries)
    SELECT * INTO v_journal
    FROM public.journal_entries
    WHERE source_type = 'INVOICE' AND source_id = p_invoice_id AND status = 'POSTED'
    LIMIT 1;

    IF FOUND THEN
      -- Yeni Ters Yevmiye Fişi Başlığı
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
        public.next_entry_number(v_user_id, EXTRACT(YEAR FROM v_now)::INTEGER, 'JOURNAL'),
        v_now::date,
        'Fatura İptal Yevmiye Fişi - ' || v_invoice.invoice_number,
        'MAHSUP',
        'INVOICE_CANCEL',
        p_invoice_id,
        'DRAFT',
        EXTRACT(YEAR FROM v_now)::INTEGER,
        EXTRACT(MONTH FROM v_now)::INTEGER
      )
      RETURNING id INTO v_reversal_je_id;

      -- Orijinal Fiş Satırlarını Ters Yönle (Borç ➔ Alacak, Alacak ➔ Borç) Ekle
      FOR v_line IN
        SELECT * FROM public.journal_lines WHERE journal_entry_id = v_journal.id
      LOOP
        INSERT INTO public.journal_lines (
          journal_entry_id,
          user_id,
          account_id,
          description,
          debit,
          credit,
          currency,
          foreign_amount,
          exchange_rate
        ) VALUES (
          v_reversal_je_id,
          v_user_id,
          v_line.account_id,
          'İptal Ters Kaydı: ' || COALESCE(v_line.description, ''),
          v_line.credit, -- Orijinal alacak burada borç olur
          v_line.debit,  -- Orijinal borç burada alacak olur
          v_line.currency,
          v_line.foreign_amount,
          v_line.exchange_rate
        );
      END LOOP;

      -- Fişi Onaylı (POSTED) Durumuna Getir (Trigger toplamları otomatik hesaplar)
      UPDATE public.journal_entries
      SET status = 'POSTED'
      WHERE id = v_reversal_je_id;
    END IF;

  END IF;

  -- 6. Yanıt Dönüşü
  RETURN jsonb_build_object(
    'success', true,
    'id', p_invoice_id,
    'invoice_number', v_invoice.invoice_number,
    'status', 'IPTAL',
    'cancel_date', v_now
  );
END;
$$;

-- Yetkilendirme
REVOKE ALL ON FUNCTION public.cancel_sales_invoice FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_sales_invoice TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_sales_invoice TO service_role;


-- =============================================================
-- FAZ 2.1 AUDIT DÜZELTMESİ — TEVKİFATLI FATURA YEVMİYE DESTEĞİ
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-22
-- =============================================================
-- BU MİGRATION:
--   ✅ Tevkifatlı satış faturalarında (p_total_tevkifat > 0) yevmiye fişi
--      borç/alacak denkliğini 136 Tevkifat Alacağı hesabı ile sağlar
--   ✅ 120 Alıcılar (Tahsil Edilecek Net Tutar = Matrah + KDV - Tevkifat)
--   ✅ 136 Diğer Çeşitli Alacaklar (Tevkifat Alacağı = p_total_tevkifat)
--   ✅ 600 Yurtiçi Satışlar (Matrah = p_taxable_amount)
--   ✅ 391 Hesaplanan KDV (Toplam KDV = p_total_vat)
--   ✅ Borç (120 + 136) = Alacak (600 + 391) tam denkliğini garanti eder
-- =============================================================

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
  p_invoice_number    TEXT DEFAULT NULL
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
  v_is_return         BOOLEAN;
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
  
  -- Muhasebe Hesap ID'leri
  v_acc_120_id        UUID;
  v_acc_136_id        UUID;
  v_acc_600_id        UUID;
  v_acc_610_id        UUID;
  v_acc_391_id        UUID;
  
  -- KDV Toplamları Döngüsü
  v_tax_rec           RECORD;
  v_calc_total_debit  NUMERIC := 0;
  v_calc_total_credit NUMERIC := 0;
BEGIN
  -- 1. Yetkilendirme Kontrolü (auth.uid zorunlu)
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Temel Doğrulamalar
  IF p_invoice_date IS NULL THEN
    RAISE EXCEPTION 'Fatura tarihi zorunludur.';
  END IF;

  IF p_status NOT IN ('TASLAK', 'ONAYLANDI') THEN
    RAISE EXCEPTION 'Geçersiz fatura durumu: %. Sadece TASLAK veya ONAYLANDI kabul edilir.', p_status;
  END IF;

  IF p_type NOT IN ('SATIS', 'IADE', 'TEVKIFAT', 'ISTISNA') THEN
    RAISE EXCEPTION 'Geçersiz fatura türü: %.', p_type;
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) != 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'En az bir geçerli fatura kalemi girilmelidir.';
  END IF;

  IF p_grand_total < 0 THEN
    RAISE EXCEPTION 'Fatura genel toplamı negatif olamaz.';
  END IF;

  v_year  := EXTRACT(YEAR FROM p_invoice_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM p_invoice_date)::INTEGER;

  -- 3. Müşteri Aidiyet ve Varlık Kontrolü
  IF p_customer_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.customers
      WHERE id = p_customer_id AND user_id = v_user_id AND deleted_at IS NULL
    ) THEN
      RAISE EXCEPTION 'Geçersiz veya silinmiş müşteri seçimi. Müşteri ID: %', p_customer_id;
    END IF;
  END IF;

  -- 4. Depo Aidiyet ve Varlık Kontrolü
  IF p_warehouse_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.warehouses
      WHERE id = p_warehouse_id AND user_id = v_user_id AND deleted_at IS NULL
    ) THEN
      RAISE EXCEPTION 'Geçersiz veya silinmiş depo seçimi. Depo ID: %', p_warehouse_id;
    END IF;
  END IF;

  -- 5. Kalemlerin Doğrulanması
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    IF (v_item->>'name') IS NULL OR trim(v_item->>'name') = '' THEN
      RAISE EXCEPTION 'Fatura kalemlerinde açıklama/ürün adı boş olamaz.';
    END IF;

    IF (v_item->>'productId') IS NOT NULL AND trim(v_item->>'productId') != '' THEN
      v_product_id := (v_item->>'productId')::UUID;
      IF NOT EXISTS (
        SELECT 1 FROM public.products
        WHERE id = v_product_id AND user_id = v_user_id AND deleted_at IS NULL
      ) THEN
        RAISE EXCEPTION 'Geçersiz veya silinmiş ürün kalemi. Ürün ID: %', v_product_id;
      END IF;
    END IF;
  END LOOP;

  -- 6. Atomik Fatura Numarası Üretimi
  IF p_invoice_number IS NOT NULL AND trim(p_invoice_number) != '' THEN
    v_invoice_number := trim(p_invoice_number);
  ELSE
    v_invoice_number := public.next_entry_number(v_user_id, v_year, 'INVOICE');
  END IF;

  -- 7. Değişkenlerin Hazırlanması
  v_should_post := (p_status = 'ONAYLANDI');
  v_is_return   := (p_type = 'IADE');
  v_ettn        := COALESCE(NULLIF(trim(p_ettn), ''), UPPER(gen_random_uuid()::TEXT));

  -- 8. Fatura Başlığını Oluşturma (invoices INSERT)
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
    p_customer_id,
    p_warehouse_id,
    v_should_post,
    v_ettn,
    v_invoice_number,
    p_type,
    p_status,
    CASE WHEN v_should_post THEN v_now ELSE NULL END,
    p_invoice_date,
    p_currency,
    COALESCE(p_exchange_rate, 1),
    p_customer_info,
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

  -- 10. KDV Satırlarını Oran Bazında Toplulaştırarak Kaydetme (invoice_tax_lines INSERT)
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
    'SATIS',
    vat_rate,
    SUM(taxable_amount) AS taxable_amount,
    SUM(vat_amount)     AS tax_amount,
    CASE WHEN p_total_vat > 0 AND p_total_tevkifat > 0 THEN ROUND((p_total_tevkifat / p_total_vat) * 100, 2) ELSE 0 END,
    CASE WHEN p_total_vat > 0 AND p_total_tevkifat > 0 THEN ROUND(SUM(vat_amount) * (p_total_tevkifat / p_total_vat), 2) ELSE 0 END,
    p_currency,
    COALESCE(p_exchange_rate, 1),
    ROUND(SUM(taxable_amount) * COALESCE(p_exchange_rate, 1), 2),
    ROUND(SUM(vat_amount) * COALESCE(p_exchange_rate, 1), 2),
    v_year,
    v_month
  FROM public.invoice_items
  WHERE invoice_id = v_invoice_id
  GROUP BY vat_rate;

  -- 11. ONAYLI Fatura İse: Cari, Stok ve Yevmiye Fişi Kayıtları
  IF v_should_post THEN

    -- A) Cari Hesap Hareketi (Müşteriden Net Tahsil Edilecek Tutar)
    IF p_customer_id IS NOT NULL AND p_grand_total > 0 THEN
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
        p_customer_id,
        p_invoice_date,
        CASE WHEN v_is_return THEN 'ALACAK' ELSE 'BORC' END,
        p_grand_total,
        v_invoice_number,
        CASE WHEN v_is_return THEN 'İade faturası kaydı' ELSE 'Satış faturası borç kaydı' END,
        'FATURA',
        v_invoice_id
      )
      RETURNING id INTO v_txn_id;
    END IF;

    -- B) Stok Hareketleri
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
      IF (v_item->>'productId') IS NOT NULL AND trim(v_item->>'productId') != '' THEN
        v_product_id := (v_item->>'productId')::UUID;
        v_quantity   := GREATEST(0, COALESCE((v_item->>'quantity')::NUMERIC, 0));
        v_unit_price := ROUND(COALESCE((v_item->>'unitPrice')::NUMERIC, 0), 2);

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
            document_no,
            description,
            source,
            source_id
          ) VALUES (
            v_user_id,
            v_product_id,
            p_warehouse_id,
            p_customer_id,
            p_invoice_date,
            CASE WHEN v_is_return THEN 'GIRIS' ELSE 'CIKIS' END,
            v_quantity,
            v_unit_price,
            v_invoice_number,
            CASE WHEN v_is_return THEN 'Fatura kaynaklı stok iade girişi' ELSE 'Fatura kaynaklı stok çıkışı' END,
            'FATURA',
            v_invoice_id
          );
        END IF;
      END IF;
    END LOOP;

    -- C) Muhasebe Hesaplarının Tespiti
    -- 120 Alıcılar
    SELECT id INTO v_acc_120_id
    FROM public.chart_of_accounts
    WHERE (code = '120' OR system_tag = 'ALICILAR')
      AND (user_id = v_user_id OR user_id IS NULL)
      AND is_active = true
    ORDER BY user_id NULLS LAST
    LIMIT 1;

    IF v_acc_120_id IS NULL THEN
      RAISE EXCEPTION 'Muhasebe hesap planında 120 (Alıcılar) hesabı bulunamadı.';
    END IF;

    -- 136 Diğer Çeşitli Alacaklar (Tevkifat Alacağı)
    IF p_total_tevkifat > 0 THEN
      SELECT id INTO v_acc_136_id
      FROM public.chart_of_accounts
      WHERE (code = '136' OR system_tag = 'TEVKIFAT_ALACAK')
        AND (user_id = v_user_id OR user_id IS NULL)
        AND is_active = true
      ORDER BY user_id NULLS LAST
      LIMIT 1;

      IF v_acc_136_id IS NULL THEN
        RAISE EXCEPTION 'Tevkifatlı fatura için 136 (Diğer Çeşitli Alacaklar) hesabı bulunamadı.';
      END IF;
    END IF;

    -- 600 Yurtiçi Satışlar
    SELECT id INTO v_acc_600_id
    FROM public.chart_of_accounts
    WHERE (code = '600' OR system_tag = 'SATIS_GELIRI')
      AND (user_id = v_user_id OR user_id IS NULL)
      AND is_active = true
    ORDER BY user_id NULLS LAST
    LIMIT 1;

    IF v_acc_600_id IS NULL THEN
      RAISE EXCEPTION 'Muhasebe hesap planında 600 (Yurtiçi Satışlar) hesabı bulunamadı.';
    END IF;

    -- 610 Satıştan İadeler (İade ise kullanılır)
    SELECT id INTO v_acc_610_id
    FROM public.chart_of_accounts
    WHERE (code = '610' OR system_tag = 'SATIS_IADE')
      AND (user_id = v_user_id OR user_id IS NULL)
      AND is_active = true
    ORDER BY user_id NULLS LAST
    LIMIT 1;

    IF v_is_return AND v_acc_610_id IS NULL THEN
      v_acc_610_id := v_acc_600_id;
    END IF;

    -- 391 Hesaplanan KDV
    SELECT id INTO v_acc_391_id
    FROM public.chart_of_accounts
    WHERE (code = '391' OR system_tag = 'HESAPLANAN_KDV')
      AND (user_id = v_user_id OR user_id IS NULL)
      AND is_active = true
    ORDER BY user_id NULLS LAST
    LIMIT 1;

    IF v_acc_391_id IS NULL AND p_total_vat > 0 THEN
      RAISE EXCEPTION 'Muhasebe hesap planında 391 (Hesaplanan KDV) hesabı bulunamadı.';
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
      CASE
        WHEN v_is_return THEN 'İade Faturası Muhasebe Kaydı - ' || v_invoice_number
        ELSE 'Satış Faturası Muhasebe Kaydı - ' || v_invoice_number
      END,
      'MAHSUP',
      'INVOICE',
      v_invoice_id,
      'DRAFT',
      v_year,
      v_month
    )
    RETURNING id INTO v_journal_entry_id;

    -- E) Yevmiye Fişi Satırları (journal_lines INSERT)
    IF NOT v_is_return THEN
      -- === NORMAL SATIŞ FATURASI ===
      -- 1. Satır: 120 ALICILAR ➔ BORÇ = Alıcıdan Tahsil Edilecek Tutar
      IF p_grand_total > 0 THEN
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, v_acc_120_id,
          'Fatura Borç Kaydı: ' || v_invoice_number,
          p_grand_total, 0, p_currency, COALESCE(p_exchange_rate, 1)
        );
      END IF;

      -- 2. Satır (Varsa Tevkifat): 136 TEVKİFAT ALACAĞI ➔ BORÇ = Tevkifat Tutarı
      IF COALESCE(p_total_tevkifat, 0) > 0 THEN
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, v_acc_136_id,
          'Tevkifat KDV Alacağı: ' || v_invoice_number,
          p_total_tevkifat, 0, p_currency, COALESCE(p_exchange_rate, 1)
        );
      END IF;

      -- 3. Satır: 600 YURTİÇİ SATIŞLAR ➔ ALACAK = Matrah
      IF p_taxable_amount > 0 THEN
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, v_acc_600_id,
          'Satış Geliri: ' || v_invoice_number,
          0, p_taxable_amount, p_currency, COALESCE(p_exchange_rate, 1)
        );
      END IF;

      -- 4. Satırlar: 391 HESAPLANAN KDV ➔ ALACAK = KDV Tutarları (Oran Bazında)
      FOR v_tax_rec IN
        SELECT vat_rate, tax_amount
        FROM public.invoice_tax_lines
        WHERE invoice_id = v_invoice_id AND tax_amount > 0
      LOOP
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, v_acc_391_id,
          'Hesaplanan KDV (%' || v_tax_rec.vat_rate || '): ' || v_invoice_number,
          0, v_tax_rec.tax_amount, p_currency, COALESCE(p_exchange_rate, 1)
        );
      END LOOP;

    ELSE
      -- === SATIŞ İADE FATURASI ===
      -- 1. Satır: 610 SATIŞTAN İADELER (veya 600) ➔ BORÇ = Matrah
      IF p_taxable_amount > 0 THEN
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, COALESCE(v_acc_610_id, v_acc_600_id),
          'Satıştan İade: ' || v_invoice_number,
          p_taxable_amount, 0, p_currency, COALESCE(p_exchange_rate, 1)
        );
      END IF;

      -- 2. Satırlar: 391 HESAPLANAN KDV ➔ BORÇ = KDV Tutarları
      FOR v_tax_rec IN
        SELECT vat_rate, tax_amount
        FROM public.invoice_tax_lines
        WHERE invoice_id = v_invoice_id AND tax_amount > 0
      LOOP
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, v_acc_391_id,
          'İade KDV (%' || v_tax_rec.vat_rate || '): ' || v_invoice_number,
          v_tax_rec.tax_amount, 0, p_currency, COALESCE(p_exchange_rate, 1)
        );
      END LOOP;

      -- 3. Satır: 120 ALICILAR ➔ ALACAK = Genel Toplam
      IF p_grand_total > 0 THEN
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, v_acc_120_id,
          'İade Faturası Alacak Kaydı: ' || v_invoice_number,
          0, p_grand_total, p_currency, COALESCE(p_exchange_rate, 1)
        );
      END IF;
    END IF;

    -- F) Yevmiye Fişinin Dengelenme Doğrulaması ve POSTED Yapılması
    SELECT SUM(debit), SUM(credit)
    INTO v_calc_total_debit, v_calc_total_credit
    FROM public.journal_lines
    WHERE journal_entry_id = v_journal_entry_id;

    IF v_calc_total_debit IS NULL OR v_calc_total_credit IS NULL OR v_calc_total_debit != v_calc_total_credit THEN
      RAISE EXCEPTION 'Muhasebe fişi borç ve alacak toplamları denk değil! Borç: %, Alacak: %',
        v_calc_total_debit, v_calc_total_credit;
    END IF;

    -- Fişi Onaylı (POSTED) Yap
    UPDATE public.journal_entries
    SET status = 'POSTED'
    WHERE id = v_journal_entry_id;

    -- G) Cari Hesap Hareketini Yevmiye Fişine Bağlama
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
    'status', p_status,
    'ettn', v_ettn,
    'posted', v_should_post,
    'journal_entry_id', v_journal_entry_id,
    'journal_entry_number', v_journal_number
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_sales_invoice FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_sales_invoice TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_sales_invoice TO service_role;


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


