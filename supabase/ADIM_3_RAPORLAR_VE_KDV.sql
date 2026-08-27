-- =============================================================
-- ADIM 3 / 3: MİZAN, KDV BEYANNAMESİ, KUR DEĞERLEME VE RAPORLAR
-- =============================================================
-- =============================================================
-- FAZ 2.2.3-B — 621 / 153 STMM MUHASEBE YEVMİYE FİŞİ ENTEGRASYONU
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-22
-- =============================================================
-- BU MİGRATION:
--   ✅ create_sales_invoice RPC'sine 621 (STMM) / 153 (Ticari Mallar)
--      maliyet muhasebesi satırlarını entegre eder
--   ✅ Satış faturası onaylandığında:
--      - 120 Alıcılar              BORÇ   = Genel Toplam
--      - 136 Tevkifat Alacağı      BORÇ   = Varsa Tevkifat
--      - 621 STMM                  BORÇ   = Toplam STMM (stock_movements.total_cost toplamı)
--      - 600 Yurtiçi Satışlar      ALACAK = Matrah
--      - 391 Hesaplanan KDV        ALACAK = KDV
--      - 153 Ticari Mallar         ALACAK = Toplam STMM
--   ✅ Satış iadesi onaylandığında:
--      - 610 Satıştan İadeler      BORÇ   = Matrah
--      - 391 Hesaplanan KDV        BORÇ   = KDV
--      - 153 Ticari Mallar         BORÇ   = Toplam STMM (İade Alınan Stok Maliyeti)
--      - 120 Alıcılar              ALACAK = Genel Toplam
--      - 621 STMM                  ALACAK = Toplam STMM
--   ✅ total_stmm = 0 olduğunda sıfır satır oluşturulmaz; normal satış fişi dengeli kalır
--   ✅ Tek atomik yevmiye fişi (journal_entries + journal_lines) oluşturulur
--   ✅ cancel_sales_invoice reversal mekanizması 621/153 satırlarını otomatik dengeler
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
  v_txn_id            UUID;
  v_journal_entry_id  UUID;
  v_journal_number    TEXT;
  
  -- Deterministik Kilit Dizisi
  v_product_ids       UUID[];
  v_locked_product    RECORD;
  v_current_stock     NUMERIC;
  
  -- Muhasebe Hesap ID'leri
  v_acc_120_id        UUID;
  v_acc_136_id        UUID;
  v_acc_600_id        UUID;
  v_acc_610_id        UUID;
  v_acc_391_id        UUID;
  v_acc_621_id        UUID;
  v_acc_153_id        UUID;
  
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
  v_should_post := (p_status = 'ONAYLANDI');
  v_is_return   := (p_type = 'IADE');

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

  -- 5. DETERMINISTIK KİLİTLEME (FOR UPDATE ile Deadlock & Race Condition Koruması)
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
      v_quantity := 0;
      FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
      LOOP
        IF (v_item->>'productId') IS NOT NULL AND (v_item->>'productId')::UUID = v_locked_product.id THEN
          v_quantity := v_quantity + GREATEST(0, COALESCE((v_item->>'quantity')::NUMERIC, 0));
        END IF;
      END LOOP;

      IF v_should_post AND NOT v_is_return AND v_locked_product.track_stock AND v_quantity > 0 THEN
        v_current_stock := public.get_product_stock_quantity(v_locked_product.id, p_warehouse_id);
        IF v_current_stock < v_quantity THEN
          RAISE EXCEPTION 'Yetersiz stok! Ürün: "%", Depodaki Mevcut Stok: %, Talep Edilen Miktar: %',
            v_locked_product.name, v_current_stock, v_quantity;
        END IF;
      END IF;
    END LOOP;

    IF (SELECT count(*) FROM public.products WHERE id = ANY(v_product_ids) AND user_id = v_user_id AND deleted_at IS NULL) < array_length(v_product_ids, 1) THEN
      RAISE EXCEPTION 'Faturadaki ürünlerden biri veya birkaçı sistemde bulunamadı ya da silinmiş.';
    END IF;
  END IF;

  -- Kalem açıklamalarının kontrolü
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    IF (v_item->>'name') IS NULL OR trim(v_item->>'name') = '' THEN
      RAISE EXCEPTION 'Fatura kalemlerinde açıklama/ürün adı boş olamaz.';
    END IF;
  END LOOP;

  -- 6. Atomik Fatura Numarası Üretimi
  IF p_invoice_number IS NOT NULL AND trim(p_invoice_number) != '' THEN
    v_invoice_number := trim(p_invoice_number);
  ELSE
    v_invoice_number := public.next_entry_number(v_user_id, v_year, 'INVOICE');
  END IF;

  v_ettn := COALESCE(NULLIF(trim(p_ettn), ''), UPPER(gen_random_uuid()::TEXT));

  -- 7. Fatura Başlığını Oluşturma (invoices INSERT)
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

  -- 8. Fatura Kalemlerini Normalize Olarak Kaydetme (invoice_items INSERT)
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

  -- 9. KDV Satırlarını Oran Bazında Toplulaştırarak Kaydetme (invoice_tax_lines INSERT)
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

  -- 10. ONAYLI Fatura İse: Cari, Stok (Maliyetli) ve Yevmiye Fişi (STMM Dahil) Kayıtları
  IF v_should_post THEN

    -- A) Cari Hesap Hareketi
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

    -- B) Stok Hareketleri (Maliyet ve Satış Fiyatı Ayrı Olarak)
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
      IF (v_item->>'productId') IS NOT NULL AND trim(v_item->>'productId') != '' THEN
        v_product_id := (v_item->>'productId')::UUID;
        v_quantity   := GREATEST(0, COALESCE((v_item->>'quantity')::NUMERIC, 0));
        v_unit_price := ROUND(COALESCE((v_item->>'unitPrice')::NUMERIC, 0), 2);

        IF v_quantity > 0 THEN
          -- Ürünün anlık Ağırlıklı Ortalama Maliyetini hesapla
          v_unit_cost  := public.get_product_moving_average_cost(v_product_id, p_warehouse_id);
          v_total_cost := ROUND(v_quantity * v_unit_cost, 2);

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
            p_customer_id,
            p_invoice_date,
            CASE WHEN v_is_return THEN 'GIRIS' ELSE 'CIKIS' END,
            v_quantity,
            v_unit_price,
            v_unit_cost,
            v_total_cost,
            v_invoice_number,
            CASE WHEN v_is_return THEN 'Fatura kaynaklı stok iade girişi' ELSE 'Fatura kaynaklı stok çıkışı' END,
            'FATURA',
            v_invoice_id
          );
        END IF;
      END IF;
    END LOOP;

    -- Toplam Gerçek STMM Tutarı (Sadece bu faturanın stok hareketlerinden)
    SELECT COALESCE(SUM(total_cost), 0)
    INTO v_total_stmm
    FROM public.stock_movements
    WHERE source = 'FATURA'
      AND source_id = v_invoice_id
      AND user_id = v_user_id
      AND deleted_at IS NULL;

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

    -- 621 Satılan Ticari Mallar Maliyeti
    IF v_total_stmm > 0 THEN
      SELECT id INTO v_acc_621_id
      FROM public.chart_of_accounts
      WHERE (code = '621' OR system_tag = 'COGS')
        AND (user_id = v_user_id OR user_id IS NULL)
        AND is_active = true
      ORDER BY user_id NULLS LAST
      LIMIT 1;

      IF v_acc_621_id IS NULL THEN
        RAISE EXCEPTION 'Muhasebe hesap planında 621 (Satılan Ticari Mallar Maliyeti) hesabı bulunamadı.';
      END IF;

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
      -- === NORMAL SATIŞ FATURASI (SATIS / TEVKIFAT / ISTISNA) ===
      
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

      -- 3. Satır (STMM > 0): 621 SATILAN TİCARİ MALLAR MALİYETİ ➔ BORÇ = Toplam STMM
      IF v_total_stmm > 0 THEN
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, v_acc_621_id,
          'Satılan Ticari Mallar Maliyeti (STMM): ' || v_invoice_number,
          v_total_stmm, 0, 'TRY', 1
        );
      END IF;

      -- 4. Satır: 600 YURTİÇİ SATIŞLAR ➔ ALACAK = Matrah
      IF p_taxable_amount > 0 THEN
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, v_acc_600_id,
          'Satış Geliri: ' || v_invoice_number,
          0, p_taxable_amount, p_currency, COALESCE(p_exchange_rate, 1)
        );
      END IF;

      -- 5. Satırlar: 391 HESAPLANAN KDV ➔ ALACAK = KDV Tutarları (Oran Bazında)
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

      -- 6. Satır (STMM > 0): 153 TİCARİ MALLAR ➔ ALACAK = Toplam STMM
      IF v_total_stmm > 0 THEN
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, v_acc_153_id,
          'Stoktan Çıkış Maliyeti (STMM): ' || v_invoice_number,
          0, v_total_stmm, 'TRY', 1
        );
      END IF;

    ELSE
      -- === SATIŞ İADE FATURASI (IADE) ===
      
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

      -- 3. Satır (STMM > 0): 153 TİCARİ MALLAR ➔ BORÇ = İade Alınan Stok Maliyeti
      IF v_total_stmm > 0 THEN
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, v_acc_153_id,
          'İade Alınan Stok Maliyeti (STMM Düzeltmesi): ' || v_invoice_number,
          v_total_stmm, 0, 'TRY', 1
        );
      END IF;

      -- 4. Satır: 120 ALICILAR ➔ ALACAK = Genel Toplam
      IF p_grand_total > 0 THEN
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, v_acc_120_id,
          'İade Faturası Alacak Kaydı: ' || v_invoice_number,
          0, p_grand_total, p_currency, COALESCE(p_exchange_rate, 1)
        );
      END IF;

      -- 5. Satır (STMM > 0): 621 STMM ➔ ALACAK = Satış Maliyeti İptal/Düzeltmesi
      IF v_total_stmm > 0 THEN
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, v_acc_621_id,
          'İade Edilen Satış Maliyeti Düzeltmesi (STMM): ' || v_invoice_number,
          0, v_total_stmm, 'TRY', 1
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

  -- 11. Sonuç Dönüşü
  RETURN jsonb_build_object(
    'id', v_invoice_id,
    'invoice_number', v_invoice_number,
    'status', p_status,
    'ettn', v_ettn,
    'posted', v_should_post,
    'journal_entry_id', v_journal_entry_id,
    'journal_entry_number', v_journal_number,
    'total_stmm', v_total_stmm
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_sales_invoice FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_sales_invoice TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_sales_invoice TO service_role;


-- =============================================================
-- FAZ 2.2.4 — IMPLEMENTATION 2/4: FİNANSAL RAPORLAMA SQL MOTORU
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-23
-- =============================================================
-- BU MİGRATION:
--   ✅ get_trial_balance RPC (Mizan Raporu) fonksiyonunu oluşturur:
--      - Açılış Bakiyesi, Dönem İçi Borç/Alacak, Kapanış Bakiyesi
--      - Sadece POSTED fişler, auth.uid() tenant izolasyonu
--   ✅ get_account_ledger RPC (Muavin Defter / Hesap Ekstresi) fonksiyonunu oluşturur:
--      - Kronolojik ve deterministik yürüyen bakiye (running balance)
--   ✅ get_income_statement RPC (Gelir Tablosu) fonksiyonunu oluşturur:
--      - 600 Net Satışlar, 610 İadeler, 621 STMM, Brüt Kâr, Faaliyet Kârı
--   ✅ v_account_balances güvenlik kontrollü görünümünü (security_invoker = on) oluşturur
--   ✅ Performans için gerekli ilave composite indeksleri ekler
-- =============================================================

-- 1. Performans İndeksleri
CREATE INDEX IF NOT EXISTS idx_journal_lines_user_acc_entry
  ON public.journal_lines(user_id, account_id, journal_entry_id);

CREATE INDEX IF NOT EXISTS idx_journal_entries_user_status_date
  ON public.journal_entries(user_id, status, entry_date);

-- 2. Anlık Hesap Bakiyeleri Görünümü (Security Invoker - RLS Uyumlu)
CREATE OR REPLACE VIEW public.v_account_balances
WITH (security_invoker = on) AS
SELECT
  coa.id AS account_id,
  coa.code AS account_code,
  coa.name AS account_name,
  coa.account_type,
  coa.normal_balance,
  coa.is_system,
  auth.uid() AS user_id,
  COALESCE(SUM(jl.debit), 0)  AS total_debit,
  COALESCE(SUM(jl.credit), 0) AS total_credit,
  CASE
    WHEN COALESCE(SUM(jl.debit), 0) >= COALESCE(SUM(jl.credit), 0)
      THEN COALESCE(SUM(jl.debit), 0) - COALESCE(SUM(jl.credit), 0)
    ELSE 0
  END AS debit_balance,
  CASE
    WHEN COALESCE(SUM(jl.credit), 0) > COALESCE(SUM(jl.debit), 0)
      THEN COALESCE(SUM(jl.credit), 0) - COALESCE(SUM(jl.debit), 0)
    ELSE 0
  END AS credit_balance,
  (COALESCE(SUM(jl.debit), 0) - COALESCE(SUM(jl.credit), 0)) AS net_balance
FROM public.chart_of_accounts coa
LEFT JOIN public.journal_lines jl
  ON jl.account_id = coa.id
  AND jl.user_id = auth.uid()
LEFT JOIN public.journal_entries je
  ON je.id = jl.journal_entry_id
  AND je.status = 'POSTED'
  AND je.user_id = auth.uid()
WHERE coa.is_active = true
  AND (coa.user_id = auth.uid() OR coa.user_id IS NULL)
GROUP BY
  coa.id, coa.code, coa.name, coa.account_type, coa.normal_balance, coa.is_system;

GRANT SELECT ON public.v_account_balances TO authenticated;
GRANT ALL ON public.v_account_balances TO service_role;

-- 3. Mizan Raporu RPC (get_trial_balance)
CREATE OR REPLACE FUNCTION public.get_trial_balance(
  p_start_date DATE DEFAULT NULL,
  p_end_date   DATE DEFAULT NULL
)
RETURNS TABLE (
  account_id        UUID,
  account_code      TEXT,
  account_name      TEXT,
  account_type      TEXT,
  normal_balance    TEXT,
  is_system         BOOLEAN,
  opening_debit     NUMERIC(14,2),
  opening_credit    NUMERIC(14,2),
  period_debit      NUMERIC(14,2),
  period_credit     NUMERIC(14,2),
  closing_debit     NUMERIC(14,2),
  closing_credit    NUMERIC(14,2),
  debit_balance     NUMERIC(14,2),
  credit_balance    NUMERIC(14,2),
  net_balance       NUMERIC(14,2)
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id    UUID;
  v_start_date DATE;
  v_end_date   DATE;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  v_start_date := COALESCE(p_start_date, '2000-01-01'::DATE);
  v_end_date   := COALESCE(p_end_date, CURRENT_DATE);

  RETURN QUERY
  WITH movement_summary AS (
    SELECT
      jl.account_id,
      -- Açılış hareketleri (p_start_date öncesi POSTED kayıtlar)
      COALESCE(SUM(CASE WHEN je.entry_date < v_start_date THEN jl.debit ELSE 0 END), 0)  AS op_debit,
      COALESCE(SUM(CASE WHEN je.entry_date < v_start_date THEN jl.credit ELSE 0 END), 0) AS op_credit,
      -- Dönem içi hareketler (v_start_date ile v_end_date arası POSTED kayıtlar)
      COALESCE(SUM(CASE WHEN je.entry_date >= v_start_date AND je.entry_date <= v_end_date THEN jl.debit ELSE 0 END), 0)  AS per_debit,
      COALESCE(SUM(CASE WHEN je.entry_date >= v_start_date AND je.entry_date <= v_end_date THEN jl.credit ELSE 0 END), 0) AS per_credit
    FROM public.journal_lines jl
    INNER JOIN public.journal_entries je
      ON je.id = jl.journal_entry_id
    WHERE jl.user_id = v_user_id
      AND je.user_id = v_user_id
      AND je.status = 'POSTED'
      AND je.entry_date <= v_end_date
    GROUP BY jl.account_id
  )
  SELECT
    coa.id AS account_id,
    coa.code AS account_code,
    coa.name AS account_name,
    coa.account_type,
    coa.normal_balance,
    coa.is_system,
    COALESCE(ms.op_debit, 0)::NUMERIC(14,2)  AS opening_debit,
    COALESCE(ms.op_credit, 0)::NUMERIC(14,2) AS opening_credit,
    COALESCE(ms.per_debit, 0)::NUMERIC(14,2)  AS period_debit,
    COALESCE(ms.per_credit, 0)::NUMERIC(14,2) AS period_credit,
    (COALESCE(ms.op_debit, 0) + COALESCE(ms.per_debit, 0))::NUMERIC(14,2)   AS closing_debit,
    (COALESCE(ms.op_credit, 0) + COALESCE(ms.per_credit, 0))::NUMERIC(14,2) AS closing_credit,
    -- Borç Bakiyesi
    CASE
      WHEN (COALESCE(ms.op_debit, 0) + COALESCE(ms.per_debit, 0)) >= (COALESCE(ms.op_credit, 0) + COALESCE(ms.per_credit, 0))
        THEN ((COALESCE(ms.op_debit, 0) + COALESCE(ms.per_debit, 0)) - (COALESCE(ms.op_credit, 0) + COALESCE(ms.per_credit, 0)))::NUMERIC(14,2)
      ELSE 0::NUMERIC(14,2)
    END AS debit_balance,
    -- Alacak Bakiyesi
    CASE
      WHEN (COALESCE(ms.op_credit, 0) + COALESCE(ms.per_credit, 0)) > (COALESCE(ms.op_debit, 0) + COALESCE(ms.per_debit, 0))
        THEN ((COALESCE(ms.op_credit, 0) + COALESCE(ms.per_credit, 0)) - (COALESCE(ms.op_debit, 0) + COALESCE(ms.per_debit, 0)))::NUMERIC(14,2)
      ELSE 0::NUMERIC(14,2)
    END AS credit_balance,
    -- Net Bakiye (Borç - Alacak)
    (((COALESCE(ms.op_debit, 0) + COALESCE(ms.per_debit, 0)) - (COALESCE(ms.op_credit, 0) + COALESCE(ms.per_credit, 0))))::NUMERIC(14,2) AS net_balance
  FROM public.chart_of_accounts coa
  LEFT JOIN movement_summary ms ON ms.account_id = coa.id
  WHERE coa.is_active = true
    AND (coa.user_id = v_user_id OR coa.user_id IS NULL)
  ORDER BY coa.code ASC;
END;
$$;

REVOKE ALL ON FUNCTION public.get_trial_balance FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_trial_balance TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_trial_balance TO service_role;

-- 4. Muavin Defter RPC (get_account_ledger)
CREATE OR REPLACE FUNCTION public.get_account_ledger(
  p_account_id UUID,
  p_start_date DATE DEFAULT NULL,
  p_end_date   DATE DEFAULT NULL
)
RETURNS TABLE (
  journal_entry_id  UUID,
  entry_number      TEXT,
  entry_date        DATE,
  description       TEXT,
  source_type       TEXT,
  source_id         UUID,
  journal_line_id   UUID,
  debit             NUMERIC(14,2),
  credit            NUMERIC(14,2),
  running_balance   NUMERIC(14,2)
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id        UUID;
  v_start_date     DATE;
  v_end_date       DATE;
  v_opening_debit  NUMERIC := 0;
  v_opening_credit NUMERIC := 0;
  v_opening_bal    NUMERIC := 0;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  IF p_account_id IS NULL THEN
    RAISE EXCEPTION 'Hesap seçimi (p_account_id) zorunludur.';
  END IF;

  -- Hesabın tenant aidiyet veya sistem hesabı doğrulaması
  IF NOT EXISTS (
    SELECT 1 FROM public.chart_of_accounts
    WHERE id = p_account_id
      AND (user_id = v_user_id OR user_id IS NULL)
      AND is_active = true
  ) THEN
    RAISE EXCEPTION 'Geçersiz hesap veya bu hesaba erişim yetkiniz yok. Hesap ID: %', p_account_id;
  END IF;

  v_start_date := COALESCE(p_start_date, '2000-01-01'::DATE);
  v_end_date   := COALESCE(p_end_date, CURRENT_DATE);

  -- Başlangıç tarihi öncesi devreden açılış bakiyesi
  SELECT
    COALESCE(SUM(jl.debit), 0),
    COALESCE(SUM(jl.credit), 0)
  INTO v_opening_debit, v_opening_credit
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je
    ON je.id = jl.journal_entry_id
  WHERE jl.account_id = p_account_id
    AND jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND je.entry_date < v_start_date;

  v_opening_bal := v_opening_debit - v_opening_credit;

  RETURN QUERY
  SELECT
    je.id AS journal_entry_id,
    je.entry_number,
    je.entry_date,
    COALESCE(jl.description, je.description, 'Muhasebe Kaydı') AS description,
    je.source_type,
    je.source_id,
    jl.id AS journal_line_id,
    jl.debit,
    jl.credit,
    (v_opening_bal + SUM(jl.debit - jl.credit) OVER (
      ORDER BY je.entry_date ASC, je.entry_number ASC, je.id ASC, jl.id ASC
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ))::NUMERIC(14,2) AS running_balance
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je
    ON je.id = jl.journal_entry_id
  WHERE jl.account_id = p_account_id
    AND jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND je.entry_date >= v_start_date
    AND je.entry_date <= v_end_date
  ORDER BY je.entry_date ASC, je.entry_number ASC, je.id ASC, jl.id ASC;
END;
$$;

REVOKE ALL ON FUNCTION public.get_account_ledger FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_account_ledger TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_account_ledger TO service_role;

-- 5. Gelir Tablosu RPC (get_income_statement)
CREATE OR REPLACE FUNCTION public.get_income_statement(
  p_start_date DATE DEFAULT NULL,
  p_end_date   DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id             UUID;
  v_start_date          DATE;
  v_end_date            DATE;
  
  -- Gelir Tablosu Kalemleri
  v_gross_sales         NUMERIC(14,2) := 0; -- 600
  v_sales_returns       NUMERIC(14,2) := 0; -- 610
  v_net_sales           NUMERIC(14,2) := 0; -- 600 - 610
  v_cogs                NUMERIC(14,2) := 0; -- 621 STMM (Yevmiye)
  v_stock_movements_cogs NUMERIC(14,2) := 0; -- stock_movements.total_cost (Mutabakat)
  v_gross_profit        NUMERIC(14,2) := 0; -- Net Satışlar - STMM
  v_gross_margin_pct    NUMERIC(5,2)  := 0;
  v_operating_expenses  NUMERIC(14,2) := 0; -- 770
  v_financing_expenses  NUMERIC(14,2) := 0; -- 780
  v_operating_profit    NUMERIC(14,2) := 0;
  v_net_profit          NUMERIC(14,2) := 0;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  v_start_date := COALESCE(p_start_date, '2000-01-01'::DATE);
  v_end_date   := COALESCE(p_end_date, CURRENT_DATE);

  -- 600 Yurtiçi Satışlar (Normal bakiye CREDIT olduğundan: credit - debit)
  SELECT COALESCE(SUM(jl.credit - jl.debit), 0)
  INTO v_gross_sales
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND je.entry_date >= v_start_date
    AND je.entry_date <= v_end_date
    AND (coa.code = '600' OR coa.system_tag = 'SATIS_GELIRI');

  -- 610 Satıştan İadeler (Normal bakiye DEBIT: debit - credit)
  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_sales_returns
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND je.entry_date >= v_start_date
    AND je.entry_date <= v_end_date
    AND (coa.code = '610' OR coa.system_tag = 'SATIS_IADE');

  v_net_sales := v_gross_sales - v_sales_returns;

  -- 621 Satılan Ticari Mallar Maliyeti (Normal bakiye DEBIT: debit - credit)
  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_cogs
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND je.entry_date >= v_start_date
    AND je.entry_date <= v_end_date
    AND (coa.code = '621' OR coa.system_tag = 'COGS');

  -- STMM Mutabakatı: stock_movements tablosundaki fiili satış maliyetleri
  SELECT COALESCE(SUM(
    CASE
      WHEN movement_type = 'CIKIS' THEN total_cost
      WHEN movement_type = 'GIRIS' AND source = 'FATURA' THEN -total_cost
      ELSE 0
    END
  ), 0)
  INTO v_stock_movements_cogs
  FROM public.stock_movements
  WHERE user_id = v_user_id
    AND deleted_at IS NULL
    AND source IN ('FATURA', 'FATURA_IPTAL')
    AND movement_date >= v_start_date
    AND movement_date <= v_end_date;

  v_gross_profit := v_net_sales - v_cogs;

  IF v_net_sales > 0 THEN
    v_gross_margin_pct := ROUND(((v_gross_profit / v_net_sales) * 100.0), 2);
  ELSE
    v_gross_margin_pct := 0;
  END IF;

  -- 770 Genel Yönetim Giderleri
  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_operating_expenses
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND je.entry_date >= v_start_date
    AND je.entry_date <= v_end_date
    AND (coa.code = '770' OR coa.code LIKE '770%');

  -- 780 Finansman Giderleri
  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_financing_expenses
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND je.entry_date >= v_start_date
    AND je.entry_date <= v_end_date
    AND (coa.code = '780' OR coa.code LIKE '780%');

  v_operating_profit := v_gross_profit - v_operating_expenses - v_financing_expenses;
  v_net_profit       := v_operating_profit;

  RETURN jsonb_build_object(
    'start_date', v_start_date,
    'end_date', v_end_date,
    'gross_sales', v_gross_sales,
    'sales_returns', v_sales_returns,
    'net_sales', v_net_sales,
    'cogs', v_cogs,
    'stock_movements_cogs', v_stock_movements_cogs,
    'cogs_reconciliation_difference', (v_cogs - v_stock_movements_cogs),
    'gross_profit', v_gross_profit,
    'gross_margin_pct', v_gross_margin_pct,
    'operating_expenses', v_operating_expenses,
    'financing_expenses', v_financing_expenses,
    'operating_profit', v_operating_profit,
    'net_profit', v_net_profit
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_income_statement FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_income_statement TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_income_statement TO service_role;


-- =============================================================
-- FAZ 2.2.4 — IMPLEMENTATION 3/4: MUTABAKAT VE MUHASEBE DENETİM MOTORU
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-23
-- =============================================================
-- BU MİGRATION:
--   ✅ run_accounting_audit RPC (Kapsamlı Muhasebe Denetim & Mutabakat Motoru):
--      1.  UNBALANCED_POSTED_JOURNAL (Dengesiz Fişler)
--      2.  POSTED_JOURNAL_WITHOUT_LINES (Satırsız Fişler)
--      3.  DUPLICATE_SOURCE_JOURNAL (Mükerrer Fişler)
--      4.  INVOICE_WITHOUT_JOURNAL (Yevmiyesiz Faturalar)
--      5.  JOURNAL_WITHOUT_INVOICE (Faturasız Yevmiyeler)
--      6.  STMM_621_MISMATCH (Stok Maliyeti ↔ 621 STMM Mutabakatı)
--      7.  STOCK_153_MISMATCH (Fiili Depo Stok Değeri ↔ 153 Mizan Mutabakatı)
--      8.  SALES_600_MISMATCH (Satış Matrahı ↔ 600 Yurtiçi Satışlar Mutabakatı)
--      9.  TAX_391_MISMATCH (KDV Satırları ↔ 391 Hesaplanan KDV Mutabakatı)
--      10. CUSTOMER_120_MISMATCH (Cari Hareketler ↔ 120 Alıcılar Mutabakatı)
--      11. NEGATIVE_STOCK (Negatif Stok Uyarıları)
--      12. ZERO_AMOUNT_JOURNAL_LINE (Sıfır Tutarlı Satırlar)
--      13. ORPHAN_JOURNAL_LINE (Yetim Yevmiye Satırları)
--   ✅ get_reconciliation_summary RPC (Özet Mutabakat Kartları):
--      - STMM (621), Stok (153), Satış (600), KDV (391), Cari (120) özet farkları
--   ✅ close_accounting_period RPC'sini kritik denetim kontrolleriyle güçlendirir
--   ✅ Performans indeksleri ve RLS tenant güvenliği sağlar
-- =============================================================

-- 1. Performans İndeksleri
CREATE INDEX IF NOT EXISTS idx_stock_movements_source_user
  ON public.stock_movements(user_id, source, source_id);

CREATE INDEX IF NOT EXISTS idx_invoices_user_posted_date
  ON public.invoices(user_id, posted, invoice_date);

CREATE INDEX IF NOT EXISTS idx_account_transactions_user_source
  ON public.account_transactions(user_id, source, source_id);

-- 2. Kapsamlı Muhasebe Denetim Motoru RPC (run_accounting_audit)
CREATE OR REPLACE FUNCTION public.run_accounting_audit(
  p_year  INTEGER DEFAULT NULL,
  p_month INTEGER DEFAULT NULL
)
RETURNS TABLE (
  check_name     TEXT,
  severity       TEXT,
  status         TEXT,
  expected_value NUMERIC(14,2),
  actual_value   NUMERIC(14,2),
  difference     NUMERIC(14,2),
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
  
  -- Mutabakat Değişkenleri
  v_stock_cogs_net      NUMERIC(14,2) := 0;
  v_journal_621_net     NUMERIC(14,2) := 0;
  v_stock_total_val     NUMERIC(14,2) := 0;
  v_journal_153_net     NUMERIC(14,2) := 0;
  v_inv_taxable_net     NUMERIC(14,2) := 0;
  v_journal_600_net     NUMERIC(14,2) := 0;
  v_inv_tax_net         NUMERIC(14,2) := 0;
  v_journal_391_net     NUMERIC(14,2) := 0;
  v_cust_subledger_net  NUMERIC(14,2) := 0;
  v_journal_120_net     NUMERIC(14,2) := 0;
  v_p_rec               RECORD;
  v_p_qty               NUMERIC;
  v_p_cost              NUMERIC;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  -- ========================================================
  -- KONTROL 1: UNBALANCED_POSTED_JOURNAL (Dengesiz Fişler)
  -- ========================================================
  FOR v_rec IN
    SELECT id, entry_number, entry_date, total_debit, total_credit
    FROM public.journal_entries
    WHERE user_id = v_user_id
      AND status = 'POSTED'
      AND total_debit != total_credit
      AND (p_year IS NULL OR period_year = p_year)
      AND (p_month IS NULL OR period_month = p_month)
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

  -- ========================================================
  -- KONTROL 2: POSTED_JOURNAL_WITHOUT_LINES (Satırsız Fişler)
  -- ========================================================
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

  -- ========================================================
  -- KONTROL 3: INVOICE_WITHOUT_JOURNAL (Yevmiyesiz Faturalar)
  -- ========================================================
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

  -- ========================================================
  -- KONTROL 4: NEGATIVE_STOCK (Negatif Stok Uyarıları)
  -- ========================================================
  FOR v_p_rec IN
    SELECT id, name
    FROM public.products
    WHERE user_id = v_user_id AND deleted_at IS NULL AND COALESCE(track_stock, true) = true
  LOOP
    v_p_qty := public.get_product_stock_quantity(v_p_rec.id);
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

  -- ========================================================
  -- KONTROL 5: STMM ↔ 621 MUTABAKATI
  -- ========================================================
  -- Fiili Satış Çıkış Maliyeti Net Toplamı
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

  -- 621 Hesabının Yevmiye Net Tutarı (Borç - Alacak)
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

  -- ========================================================
  -- KONTROL 6: SATIŞ ↔ 600 MUTABAKATI
  -- ========================================================
  -- Faturalardaki Net Satış Matrahı
  SELECT COALESCE(SUM(
    CASE
      WHEN type = 'IADE' THEN -taxable_amount
      ELSE taxable_amount
    END
  ), 0)
  INTO v_inv_taxable_net
  FROM public.invoices
  WHERE user_id = v_user_id
    AND posted = true
    AND status != 'IPTAL'
    AND (p_year IS NULL OR EXTRACT(YEAR FROM invoice_date) = p_year)
    AND (p_month IS NULL OR EXTRACT(MONTH FROM invoice_date) = p_month);

  -- 600 Hesabının Yevmiye Net Tutarı (Alacak - Borç)
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

  -- ========================================================
  -- KONTROL 7: KDV ↔ 391 MUTABAKATI
  -- ========================================================
  -- Faturalardaki Net KDV Toplamı
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

  -- 391 Hesabının Yevmiye Net Tutarı (Alacak - Borç)
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

  -- ========================================================
  -- KONTROL 8: CARİ ↔ 120 MUTABAKATI
  -- ========================================================
  -- Müşteri Cari Hareketleri Net Bakiyesi (BORC - ALACAK)
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

  -- 120 Hesabının Yevmiye Net Tutarı (Borç - Alacak)
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

REVOKE ALL ON FUNCTION public.run_accounting_audit FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.run_accounting_audit TO authenticated;
GRANT EXECUTE ON FUNCTION public.run_accounting_audit TO service_role;

-- 3. Özet Mutabakat Kartları RPC (get_reconciliation_summary)
CREATE OR REPLACE FUNCTION public.get_reconciliation_summary(
  p_year  INTEGER DEFAULT NULL,
  p_month INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id        UUID;
  v_audit_rows     JSONB;
  v_critical_count INTEGER := 0;
  v_warning_count  INTEGER := 0;
  v_pass_count     INTEGER := 0;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_agg(to_jsonb(a)),
         COUNT(*) FILTER (WHERE a.status = 'FAIL' OR a.severity = 'CRITICAL'),
         COUNT(*) FILTER (WHERE a.status = 'WARNING'),
         COUNT(*) FILTER (WHERE a.status = 'PASS')
  INTO v_audit_rows, v_critical_count, v_warning_count, v_pass_count
  FROM public.run_accounting_audit(p_year, p_month) a;

  RETURN jsonb_build_object(
    'period_year', p_year,
    'period_month', p_month,
    'critical_errors_count', COALESCE(v_critical_count, 0),
    'warnings_count', COALESCE(v_warning_count, 0),
    'passed_checks_count', COALESCE(v_pass_count, 0),
    'is_ready_for_close', (COALESCE(v_critical_count, 0) = 0),
    'audit_details', COALESCE(v_audit_rows, '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_reconciliation_summary FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_reconciliation_summary TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_reconciliation_summary TO service_role;

-- 4. close_accounting_period RPC'sinin Güçlendirilmesi (Denetim Kilidi Dahil)
CREATE OR REPLACE FUNCTION public.close_accounting_period(
  p_year  INTEGER,
  p_month INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id       UUID;
  v_status        TEXT;
  v_critical_cnt  INTEGER := 0;
  v_now           TIMESTAMPTZ := now();
  v_period_id     UUID;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  IF p_year NOT BETWEEN 2000 AND 2100 OR p_month NOT BETWEEN 1 AND 12 THEN
    RAISE EXCEPTION 'Geçersiz yıl (%) veya ay (%).', p_year, p_month;
  END IF;

  -- Mevcut dönem durumunu kilitleyerek kontrol et
  SELECT id, status INTO v_period_id, v_status
  FROM public.accounting_periods
  WHERE user_id = v_user_id
    AND period_year = p_year
    AND period_month = p_month
  FOR UPDATE;

  IF v_status = 'LOCKED' THEN
    RAISE EXCEPTION 'Bu dönem (%/%) kilitlidir (LOCKED). Yeniden kapatılamaz.', p_month, p_year;
  ELSIF v_status = 'CLOSED' THEN
    RAISE EXCEPTION 'Bu dönem (%/%) zaten kapatılmıştır (CLOSED).', p_month, p_year;
  END IF;

  -- Kapsamlı Denetim Kontrolü: Bu dönemde CRITICAL hata var mı?
  SELECT COUNT(*)
  INTO v_critical_cnt
  FROM public.run_accounting_audit(p_year, p_month)
  WHERE severity = 'CRITICAL' AND status = 'FAIL';

  IF v_critical_cnt > 0 THEN
    RAISE EXCEPTION 'Dönem içinde % adet kritik muhasebe/mutabakat hatası bulunmaktadır. Hatalar giderilmeden dönem kapatılamaz.',
      v_critical_cnt;
  END IF;

  -- Dönemi CLOSED olarak kaydet/güncelle
  INSERT INTO public.accounting_periods (
    user_id,
    period_year,
    period_month,
    status,
    closed_at,
    closed_by
  ) VALUES (
    v_user_id,
    p_year,
    p_month,
    'CLOSED',
    v_now,
    v_user_id
  )
  ON CONFLICT (user_id, period_year, period_month)
  DO UPDATE SET
    status = 'CLOSED',
    closed_at = v_now,
    closed_by = v_user_id,
    updated_at = v_now
  RETURNING id INTO v_period_id;

  RETURN jsonb_build_object(
    'period_id', v_period_id,
    'period_year', p_year,
    'period_month', p_month,
    'status', 'CLOSED',
    'closed_at', v_now
  );
END;
$$;

REVOKE ALL ON FUNCTION public.close_accounting_period FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.close_accounting_period TO authenticated;
GRANT EXECUTE ON FUNCTION public.close_accounting_period TO service_role;


-- =============================================================
-- FAZ 2.3 — VERGİ & BEYANNAME RAPORLAMA MOTORU (KDV-1, KDV-2, MUHTASAR)
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-23
-- =============================================================

-- 1. get_vat_declaration_summary RPC Fonksiyonu (KDV-1 & KDV-2 Beyanname Özeti)
CREATE OR REPLACE FUNCTION public.get_vat_declaration_summary(
  p_year  INTEGER DEFAULT NULL,
  p_month INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id             UUID;
  v_sales_taxable_breakdown JSONB := '[]'::jsonb;
  v_withholding_sales_breakdown JSONB := '[]'::jsonb;
  v_exempt_sales_breakdown JSONB := '[]'::jsonb;
  v_purchase_tax_breakdown JSONB := '[]'::jsonb;
  
  v_total_sales_taxable NUMERIC(14,2) := 0;
  v_total_sales_vat     NUMERIC(14,2) := 0;
  v_total_withholding_vat NUMERIC(14,2) := 0;
  v_declared_sales_vat  NUMERIC(14,2) := 0;
  
  v_total_purchase_taxable NUMERIC(14,2) := 0;
  v_total_purchase_vat     NUMERIC(14,2) := 0;
  v_sales_return_vat       NUMERIC(14,2) := 0;
  v_total_deductible_vat   NUMERIC(14,2) := 0;
  
  v_payable_vat         NUMERIC(14,2) := 0;
  v_transferred_vat     NUMERIC(14,2) := 0;
  
  v_result              JSONB;
BEGIN
  -- 1. Yetkilendirme Kontrolü
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Tevkifatsız Normal Satışlar (KDV Oran Kırılımı)
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'vat_rate', vat_rate,
      'taxable_amount', ROUND(taxable_sum, 2),
      'vat_amount', ROUND(vat_sum, 2)
    ) ORDER BY vat_rate ASC
  ), '[]'::jsonb)
  INTO v_sales_taxable_breakdown
  FROM (
    SELECT
      itl.vat_rate,
      SUM(itl.taxable_amount_try) AS taxable_sum,
      SUM(itl.tax_amount_try)     AS vat_sum
    FROM public.invoice_tax_lines itl
    INNER JOIN public.invoices inv ON inv.id = itl.invoice_id
    WHERE itl.user_id = v_user_id
      AND itl.direction = 'SATIS'
      AND itl.is_cancelled = false
      AND itl.is_exempt = false
      AND itl.withholding_amount = 0
      AND inv.posted = true
      AND inv.status != 'IPTAL'
      AND inv.type != 'IADE'
      AND (p_year IS NULL OR itl.period_year = p_year)
      AND (p_month IS NULL OR itl.period_month = p_month)
    GROUP BY itl.vat_rate
  ) normal_sales;

  -- 3. Kısmi Tevkifat Uygulanan Satışlar (Tevkifat Kırılımı)
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'vat_rate', vat_rate,
      'withholding_rate', withholding_rate,
      'taxable_amount', ROUND(taxable_sum, 2),
      'total_vat', ROUND(vat_sum, 2),
      'withheld_vat', ROUND(withheld_sum, 2),
      'declared_vat', ROUND(vat_sum - withheld_sum, 2)
    ) ORDER BY vat_rate ASC
  ), '[]'::jsonb)
  INTO v_withholding_sales_breakdown
  FROM (
    SELECT
      itl.vat_rate,
      itl.withholding_rate,
      SUM(itl.taxable_amount_try)     AS taxable_sum,
      SUM(itl.tax_amount_try)         AS vat_sum,
      SUM(itl.withholding_amount)     AS withheld_sum
    FROM public.invoice_tax_lines itl
    INNER JOIN public.invoices inv ON inv.id = itl.invoice_id
    WHERE itl.user_id = v_user_id
      AND itl.direction = 'SATIS'
      AND itl.is_cancelled = false
      AND itl.withholding_amount > 0
      AND inv.posted = true
      AND inv.status != 'IPTAL'
      AND (p_year IS NULL OR itl.period_year = p_year)
      AND (p_month IS NULL OR itl.period_month = p_month)
    GROUP BY itl.vat_rate, itl.withholding_rate
  ) tevkifat_sales;

  -- 4. İstisnalı Satışlar (%0 KDV)
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'exemption_code', COALESCE(exemption_code, '350'),
      'taxable_amount', ROUND(taxable_sum, 2)
    ) ORDER BY exemption_code ASC
  ), '[]'::jsonb)
  INTO v_exempt_sales_breakdown
  FROM (
    SELECT
      itl.exemption_code,
      SUM(itl.taxable_amount_try) AS taxable_sum
    FROM public.invoice_tax_lines itl
    INNER JOIN public.invoices inv ON inv.id = itl.invoice_id
    WHERE itl.user_id = v_user_id
      AND itl.direction = 'SATIS'
      AND itl.is_cancelled = false
      AND (itl.is_exempt = true OR itl.vat_rate = 0)
      AND inv.posted = true
      AND inv.status != 'IPTAL'
      AND (p_year IS NULL OR itl.period_year = p_year)
      AND (p_month IS NULL OR itl.period_month = p_month)
    GROUP BY itl.exemption_code
  ) exempt_sales;

  -- 5. Toplam Satış Matrahı ve Toplam Hesaplanan KDV
  SELECT
    COALESCE(SUM(itl.taxable_amount_try), 0),
    COALESCE(SUM(itl.tax_amount_try), 0),
    COALESCE(SUM(itl.withholding_amount), 0),
    COALESCE(SUM(itl.tax_amount_try - itl.withholding_amount), 0)
  INTO
    v_total_sales_taxable,
    v_total_sales_vat,
    v_total_withholding_vat,
    v_declared_sales_vat
  FROM public.invoice_tax_lines itl
  INNER JOIN public.invoices inv ON inv.id = itl.invoice_id
  WHERE itl.user_id = v_user_id
    AND itl.direction = 'SATIS'
    AND itl.is_cancelled = false
    AND inv.posted = true
    AND inv.status != 'IPTAL'
    AND inv.type != 'IADE'
    AND (p_year IS NULL OR itl.period_year = p_year)
    AND (p_month IS NULL OR itl.period_month = p_month);

  -- 6. Alış KDV Satırları Kırılımı (191 İndirimler)
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'vat_rate', vat_rate,
      'taxable_amount', ROUND(taxable_sum, 2),
      'vat_amount', ROUND(vat_sum, 2)
    ) ORDER BY vat_rate ASC
  ), '[]'::jsonb)
  INTO v_purchase_tax_breakdown
  FROM (
    SELECT
      itl.vat_rate,
      SUM(itl.taxable_amount_try) AS taxable_sum,
      SUM(itl.tax_amount_try)     AS vat_sum
    FROM public.invoice_tax_lines itl
    INNER JOIN public.invoices inv ON inv.id = itl.invoice_id
    WHERE itl.user_id = v_user_id
      AND itl.direction = 'ALIS'
      AND itl.is_cancelled = false
      AND inv.posted = true
      AND inv.status != 'IPTAL'
      AND (p_year IS NULL OR itl.period_year = p_year)
      AND (p_month IS NULL OR itl.period_month = p_month)
    GROUP BY itl.vat_rate
  ) purchases;

  -- 7. Toplam Alış Matrahı ve Toplam İndirilecek KDV
  SELECT
    COALESCE(SUM(itl.taxable_amount_try), 0),
    COALESCE(SUM(itl.tax_amount_try), 0)
  INTO
    v_total_purchase_taxable,
    v_total_purchase_vat
  FROM public.invoice_tax_lines itl
  INNER JOIN public.invoices inv ON inv.id = itl.invoice_id
  WHERE itl.user_id = v_user_id
    AND itl.direction = 'ALIS'
    AND itl.is_cancelled = false
    AND inv.posted = true
    AND inv.status != 'IPTAL'
    AND (p_year IS NULL OR itl.period_year = p_year)
    AND (p_month IS NULL OR itl.period_month = p_month);

  -- 8. Satış İadeleri Nedeniyle İndirilecek KDV (610/391 terslemesi)
  SELECT COALESCE(SUM(itl.tax_amount_try), 0)
  INTO v_sales_return_vat
  FROM public.invoice_tax_lines itl
  INNER JOIN public.invoices inv ON inv.id = itl.invoice_id
  WHERE itl.user_id = v_user_id
    AND inv.type = 'IADE'
    AND inv.posted = true
    AND inv.status != 'IPTAL'
    AND (p_year IS NULL OR itl.period_year = p_year)
    AND (p_month IS NULL OR itl.period_month = p_month);

  -- Toplam İndirilecek KDV
  v_total_deductible_vat := v_total_purchase_vat + v_sales_return_vat;

  -- 9. Sonuç Hesapları (Ödenecek KDV / Sonraki Döneme Devreden KDV)
  IF v_declared_sales_vat >= v_total_deductible_vat THEN
    v_payable_vat     := ROUND(v_declared_sales_vat - v_total_deductible_vat, 2);
    v_transferred_vat := 0;
  ELSE
    v_payable_vat     := 0;
    v_transferred_vat := ROUND(v_total_deductible_vat - v_declared_sales_vat, 2);
  END IF;

  -- 10. Sonuç JSON Paketi
  v_result := jsonb_build_object(
    'period_year', p_year,
    'period_month', p_month,
    'sales_section', jsonb_build_object(
      'total_taxable_amount', v_total_sales_taxable,
      'total_calculated_vat', v_total_sales_vat,
      'total_withheld_vat', v_total_withholding_vat,
      'declared_vat', v_declared_sales_vat,
      'normal_sales_breakdown', v_sales_taxable_breakdown,
      'withholding_sales_breakdown', v_withholding_sales_breakdown,
      'exempt_sales_breakdown', v_exempt_sales_breakdown
    ),
    'deductions_section', jsonb_build_object(
      'total_purchase_taxable', v_total_purchase_taxable,
      'purchase_vat', v_total_purchase_vat,
      'sales_return_vat', v_sales_return_vat,
      'total_deductible_vat', v_total_deductible_vat,
      'purchase_tax_breakdown', v_purchase_tax_breakdown
    ),
    'result_section', jsonb_build_object(
      'declared_vat', v_declared_sales_vat,
      'total_deductible_vat', v_total_deductible_vat,
      'payable_vat', v_payable_vat,
      'transferred_vat', v_transferred_vat,
      'status', CASE WHEN v_payable_vat > 0 THEN 'ODENECEK_KDV' ELSE 'DEVREDEN_KDV' END
    )
  );

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_vat_declaration_summary FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_vat_declaration_summary TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_vat_declaration_summary TO service_role;

-- 2. get_withholding_tax_summary RPC Fonksiyonu (Muhtasar / Stopaj Özeti)
CREATE OR REPLACE FUNCTION public.get_withholding_tax_summary(
  p_year  INTEGER DEFAULT NULL,
  p_month INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id            UUID;
  v_withholding_total  NUMERIC(14,2) := 0;
  v_tax_360_total      NUMERIC(14,2) := 0;
  v_kdv2_withheld      NUMERIC(14,2) := 0;
  v_result             JSONB;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  -- 1. Satış Faturalarından Alıcıların Kestiği Tevkifat Toplamı
  SELECT COALESCE(SUM(withholding_amount), 0)
  INTO v_withholding_total
  FROM public.invoice_tax_lines
  WHERE user_id = v_user_id
    AND direction = 'SATIS'
    AND is_cancelled = false
    AND (p_year IS NULL OR period_year = p_year)
    AND (p_month IS NULL OR period_month = p_month);

  -- 2. 360 Ödenecek Vergi ve Fonlar (Stopaj) Yevmiye Bakiye Toplamı
  SELECT COALESCE(SUM(jl.credit - jl.debit), 0)
  INTO v_tax_360_total
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND (coa.code = '360' OR coa.system_tag = 'ODENECEK_VERGI')
    AND (p_year IS NULL OR je.period_year = p_year)
    AND (p_month IS NULL OR je.period_month = p_month);

  -- 3. KDV-2 Alıcı Sıfatıyla Tevkif Edilen KDV (Alışlarda Varsa)
  SELECT COALESCE(SUM(withholding_amount), 0)
  INTO v_kdv2_withheld
  FROM public.invoice_tax_lines
  WHERE user_id = v_user_id
    AND direction = 'ALIS'
    AND is_cancelled = false
    AND (p_year IS NULL OR period_year = p_year)
    AND (p_month IS NULL OR period_month = p_month);

  v_result := jsonb_build_object(
    'period_year', p_year,
    'period_month', p_month,
    'sales_withholding_total', v_withholding_total,
    'withholding_tax_360', v_tax_360_total,
    'kdv2_withholding_total', v_kdv2_withheld,
    'total_withholding_payable', ROUND(v_tax_360_total + v_kdv2_withheld, 2)
  );

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_withholding_tax_summary FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_withholding_tax_summary TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_withholding_tax_summary TO service_role;


-- =============================================================
-- FAZ 2.4 — DÖVİZLİ İŞLEMLER VE KUR DEĞERLEME MOTORU
-- (646 KAMBİYO KÂRLARI / 656 KAMBİYO ZARARLARI)
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-23
-- =============================================================

-- 1. get_foreign_currency_balances RPC Fonksiyonu
-- Yabancı para birimindeki müşteri ve tedarikçi cari bakiyelerini listeler
CREATE OR REPLACE FUNCTION public.get_foreign_currency_balances()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
  v_result  JSONB;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'partner_id', partner_id,
      'partner_title', partner_title,
      'partner_type', partner_type,
      'currency', currency,
      'foreign_balance', foreign_balance,
      'try_cost_balance', try_cost_balance,
      'average_rate', CASE WHEN foreign_balance != 0 THEN ROUND(try_cost_balance / foreign_balance, 4) ELSE 1 END
    ) ORDER BY partner_title ASC
  ), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT
      c.id AS partner_id,
      c.title AS partner_title,
      c.partner_type,
      inv.currency,
      -- Dövizli Net Bakiye (Alacak - Borç veya Borç - Alacak)
      SUM(
        CASE
          WHEN c.partner_type = 'MUSTERI' THEN
            CASE WHEN inv.type = 'IADE' THEN -inv.grand_total ELSE inv.grand_total END
          ELSE
            CASE WHEN inv.type = 'ALIS_IADE' THEN -inv.grand_total ELSE inv.grand_total END
        END
      ) AS foreign_balance,
      -- Kayıtlı TRY Maliyet Bakiyesi
      SUM(
        CASE
          WHEN c.partner_type = 'MUSTERI' THEN
            CASE WHEN inv.type = 'IADE' THEN -(inv.grand_total * COALESCE(inv.exchange_rate, 1))
                 ELSE (inv.grand_total * COALESCE(inv.exchange_rate, 1)) END
          ELSE
            CASE WHEN inv.type = 'ALIS_IADE' THEN -(inv.grand_total * COALESCE(inv.exchange_rate, 1))
                 ELSE (inv.grand_total * COALESCE(inv.exchange_rate, 1)) END
        END
      ) AS try_cost_balance
    FROM public.invoices inv
    INNER JOIN public.customers c ON c.id = inv.customer_id
    WHERE inv.user_id = v_user_id
      AND inv.posted = true
      AND inv.status != 'IPTAL'
      AND inv.currency IS NOT NULL
      AND inv.currency != 'TRY'
    GROUP BY c.id, c.title, c.partner_type, inv.currency
    HAVING SUM(
      CASE
        WHEN c.partner_type = 'MUSTERI' THEN
          CASE WHEN inv.type = 'IADE' THEN -inv.grand_total ELSE inv.grand_total END
        ELSE
          CASE WHEN inv.type = 'ALIS_IADE' THEN -inv.grand_total ELSE inv.grand_total END
      END
    ) != 0
  ) fc;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_foreign_currency_balances FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_foreign_currency_balances TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_foreign_currency_balances TO service_role;

-- 2. run_fx_revaluation RPC Fonksiyonu
-- Dövizli carileri güncel kurlarla değerleyerek 646/656 yevmiye fişini oluşturur
CREATE OR REPLACE FUNCTION public.run_fx_revaluation(
  p_revaluation_date DATE,
  p_rates            JSONB,
  p_description      TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id          UUID;
  v_year             INTEGER;
  v_month            INTEGER;
  v_partner_rec      RECORD;
  v_currency         TEXT;
  v_current_rate     NUMERIC;
  v_foreign_balance  NUMERIC;
  v_try_cost_balance NUMERIC;
  v_revalued_try     NUMERIC;
  v_fx_diff          NUMERIC;
  
  v_journal_entry_id UUID;
  v_journal_number   TEXT;
  
  v_acc_120_id       UUID;
  v_acc_320_id       UUID;
  v_acc_646_id       UUID;
  v_acc_656_id       UUID;
  
  v_total_gain       NUMERIC(14,2) := 0;
  v_total_loss       NUMERIC(14,2) := 0;
  v_lines_count      INTEGER := 0;
  v_calc_total_debit NUMERIC := 0;
  v_calc_total_credit NUMERIC := 0;
BEGIN
  -- 1. Yetkilendirme Kontrolü
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  IF p_revaluation_date IS NULL THEN
    RAISE EXCEPTION 'Değerleme tarihi zorunludur.';
  END IF;

  IF p_rates IS NULL OR jsonb_typeof(p_rates) != 'object' THEN
    RAISE EXCEPTION 'Güncel döviz kurları (p_rates) JSON nesnesi olarak girilmelidir.';
  END IF;

  -- 2. Kapalı Dönem Kontrolü
  PERFORM public.assert_accounting_period_open(v_user_id, p_revaluation_date);

  v_year  := EXTRACT(YEAR FROM p_revaluation_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM p_revaluation_date)::INTEGER;

  -- 3. Muhasebe Hesaplarının Tespiti
  -- 120 Alıcılar
  SELECT id INTO v_acc_120_id FROM public.chart_of_accounts
  WHERE (code = '120' OR system_tag = 'ALICILAR') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true
  ORDER BY user_id NULLS LAST LIMIT 1;

  -- 320 Satıcılar
  SELECT id INTO v_acc_320_id FROM public.chart_of_accounts
  WHERE (code = '320' OR system_tag = 'SATICILAR') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true
  ORDER BY user_id NULLS LAST LIMIT 1;

  -- 646 Kambiyo Kârları
  SELECT id INTO v_acc_646_id FROM public.chart_of_accounts
  WHERE (code = '646' OR system_tag = 'KAMBIYO_KAR') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true
  ORDER BY user_id NULLS LAST LIMIT 1;

  -- 656 Kambiyo Zararları
  SELECT id INTO v_acc_656_id FROM public.chart_of_accounts
  WHERE (code = '656' OR system_tag = 'KAMBIYO_ZARAR') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true
  ORDER BY user_id NULLS LAST LIMIT 1;

  IF v_acc_646_id IS NULL OR v_acc_656_id IS NULL THEN
    RAISE EXCEPTION 'Muhasebe hesap planında 646 (Kambiyo Kârları) veya 656 (Kambiyo Zararları) hesabı bulunamadı.';
  END IF;

  -- 4. Yevmiye Fişi Başlığı Oluşturma
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
    p_revaluation_date,
    COALESCE(NULLIF(trim(p_description), ''), 'Dönem Sonu Kur Değerleme Kaydı (' || to_char(p_revaluation_date, 'DD.MM.YYYY') || ')'),
    'MAHSUP',
    'FX_REVALUATION',
    NULL,
    'DRAFT',
    v_year,
    v_month
  )
  RETURNING id INTO v_journal_entry_id;

  -- 5. Dövizli Cariler Üzerinde Döngü ve Kur Farkı Hesaplama
  FOR v_partner_rec IN
    SELECT
      c.id AS partner_id,
      c.title AS partner_title,
      c.partner_type,
      inv.currency,
      SUM(
        CASE
          WHEN c.partner_type = 'MUSTERI' THEN
            CASE WHEN inv.type = 'IADE' THEN -inv.grand_total ELSE inv.grand_total END
          ELSE
            CASE WHEN inv.type = 'ALIS_IADE' THEN -inv.grand_total ELSE inv.grand_total END
        END
      ) AS foreign_balance,
      SUM(
        CASE
          WHEN c.partner_type = 'MUSTERI' THEN
            CASE WHEN inv.type = 'IADE' THEN -(inv.grand_total * COALESCE(inv.exchange_rate, 1))
                 ELSE (inv.grand_total * COALESCE(inv.exchange_rate, 1)) END
          ELSE
            CASE WHEN inv.type = 'ALIS_IADE' THEN -(inv.grand_total * COALESCE(inv.exchange_rate, 1))
                 ELSE (inv.grand_total * COALESCE(inv.exchange_rate, 1)) END
        END
      ) AS try_cost_balance
    FROM public.invoices inv
    INNER JOIN public.customers c ON c.id = inv.customer_id
    WHERE inv.user_id = v_user_id
      AND inv.posted = true
      AND inv.status != 'IPTAL'
      AND inv.currency IS NOT NULL
      AND inv.currency != 'TRY'
    GROUP BY c.id, c.title, c.partner_type, inv.currency
    HAVING SUM(
      CASE
        WHEN c.partner_type = 'MUSTERI' THEN
          CASE WHEN inv.type = 'IADE' THEN -inv.grand_total ELSE inv.grand_total END
        ELSE
          CASE WHEN inv.type = 'ALIS_IADE' THEN -inv.grand_total ELSE inv.grand_total END
      END
    ) != 0
  LOOP
    v_currency := v_partner_rec.currency;
    v_current_rate := COALESCE((p_rates->>v_currency)::NUMERIC, 0);

    IF v_current_rate > 0 THEN
      v_foreign_balance  := v_partner_rec.foreign_balance;
      v_try_cost_balance := v_partner_rec.try_cost_balance;
      v_revalued_try     := ROUND(v_foreign_balance * v_current_rate, 2);
      v_fx_diff          := ROUND(v_revalued_try - v_try_cost_balance, 2);

      IF ABS(v_fx_diff) >= 0.01 THEN
        v_lines_count := v_lines_count + 1;

        -- A) MÜŞTERİ ALACAĞI DEĞERLEMESİ (120)
        IF v_partner_rec.partner_type = 'MUSTERI' THEN
          IF v_fx_diff > 0 THEN
            -- Kur Artışı: KÂR (120 Borç / 646 Alacak)
            v_total_gain := v_total_gain + v_fx_diff;
            INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit)
            VALUES (v_journal_entry_id, v_user_id, v_acc_120_id, 'Kur Farkı Değerleme: ' || v_partner_rec.partner_title, v_fx_diff, 0);

            INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit)
            VALUES (v_journal_entry_id, v_user_id, v_acc_646_id, 'Kambiyo Kârı: ' || v_partner_rec.partner_title || ' (' || v_currency || ')', 0, v_fx_diff);
          ELSE
            -- Kur Düşüşü: ZARAR (656 Borç / 120 Alacak)
            v_total_loss := v_total_loss + ABS(v_fx_diff);
            INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit)
            VALUES (v_journal_entry_id, v_user_id, v_acc_656_id, 'Kambiyo Zararı: ' || v_partner_rec.partner_title || ' (' || v_currency || ')', ABS(v_fx_diff), 0);

            INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit)
            VALUES (v_journal_entry_id, v_user_id, v_acc_120_id, 'Kur Farkı Değerleme: ' || v_partner_rec.partner_title, 0, ABS(v_fx_diff));
          END IF;

        -- B) TEDARİKÇİ BORCU DEĞERLEMESİ (320)
        ELSE
          IF v_fx_diff > 0 THEN
            -- Kur Artışı: Borç Arttığı İçin ZARAR (656 Borç / 320 Alacak)
            v_total_loss := v_total_loss + v_fx_diff;
            INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit)
            VALUES (v_journal_entry_id, v_user_id, v_acc_656_id, 'Kambiyo Zararı: ' || v_partner_rec.partner_title || ' (' || v_currency || ')', v_fx_diff, 0);

            INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit)
            VALUES (v_journal_entry_id, v_user_id, v_acc_320_id, 'Kur Farkı Değerleme: ' || v_partner_rec.partner_title, 0, v_fx_diff);
          ELSE
            -- Kur Düşüşü: Borç Azaldığı İçin KÂR (320 Borç / 646 Alacak)
            v_total_gain := v_total_gain + ABS(v_fx_diff);
            INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit)
            VALUES (v_journal_entry_id, v_user_id, v_acc_320_id, 'Kur Farkı Değerleme: ' || v_partner_rec.partner_title, ABS(v_fx_diff), 0);

            INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit)
            VALUES (v_journal_entry_id, v_user_id, v_acc_646_id, 'Kambiyo Kârı: ' || v_partner_rec.partner_title || ' (' || v_currency || ')', 0, ABS(v_fx_diff));
          END IF;
        END IF;

        -- Cari Hesap Hareketine Kur Farkı Kaydı Ekleme
        INSERT INTO public.account_transactions (
          user_id, customer_id, txn_date, txn_type, amount, document_no, description, source, source_id
        ) VALUES (
          v_user_id,
          v_partner_rec.partner_id,
          p_revaluation_date,
          CASE WHEN (v_partner_rec.partner_type = 'MUSTERI' AND v_fx_diff > 0) OR (v_partner_rec.partner_type = 'TEDARIKCI' AND v_fx_diff < 0) THEN 'BORC' ELSE 'ALACAK' END,
          ABS(v_fx_diff),
          v_journal_number,
          'Dönem Sonu Kur Değerlemesi (' || v_currency || ' Kur: ' || v_current_rate || ')',
          'KUR_DEGERLEME',
          v_journal_entry_id
        );
      END IF;
    END IF;
  END LOOP;

  IF v_lines_count = 0 THEN
    -- Değerlenecek fark yoksa fişi sil
    DELETE FROM public.journal_entries WHERE id = v_journal_entry_id;
    RETURN jsonb_build_object(
      'success', true,
      'message', 'Değerleme yapılacak kur farkı bulunamadı. Bakiyeler güncel kurlarla uyumlu.',
      'revalued_count', 0
    );
  END IF;

  -- 6. Fiş Toplamları ve POSTED Onayı
  SELECT COALESCE(SUM(debit), 0), COALESCE(SUM(credit), 0)
  INTO v_calc_total_debit, v_calc_total_credit
  FROM public.journal_lines
  WHERE journal_entry_id = v_journal_entry_id;

  IF ABS(v_calc_total_debit - v_calc_total_credit) > 0.05 THEN
    RAISE EXCEPTION 'Kur değerleme fişi denk değil! Borç: %, Alacak: %', v_calc_total_debit, v_calc_total_credit;
  END IF;

  UPDATE public.journal_entries SET
    status = 'POSTED',
    total_debit = v_calc_total_debit,
    total_credit = v_calc_total_credit,
    updated_at = now()
  WHERE id = v_journal_entry_id;

  RETURN jsonb_build_object(
    'success', true,
    'journal_entry_id', v_journal_entry_id,
    'journal_number', v_journal_number,
    'revalued_count', v_lines_count,
    'total_fx_gain', v_total_gain,
    'total_fx_loss', v_total_loss,
    'net_fx_impact', v_total_gain - v_total_loss
  );
END;
$$;

REVOKE ALL ON FUNCTION public.run_fx_revaluation FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.run_fx_revaluation TO authenticated;
GRANT EXECUTE ON FUNCTION public.run_fx_revaluation TO service_role;

-- 3. get_income_statement RPC Fonksiyonunun 646 ve 656 Kambiyo Hesapları ile Güncellenmesi
CREATE OR REPLACE FUNCTION public.get_income_statement(
  p_start_date DATE DEFAULT NULL,
  p_end_date   DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id                   UUID;
  v_gross_sales               NUMERIC(14,2) := 0;
  v_sales_returns             NUMERIC(14,2) := 0;
  v_sales_discounts           NUMERIC(14,2) := 0;
  v_net_sales                 NUMERIC(14,2) := 0;
  v_cogs                      NUMERIC(14,2) := 0;
  v_gross_profit              NUMERIC(14,2) := 0;
  v_operating_expenses        NUMERIC(14,2) := 0;
  v_operating_profit          NUMERIC(14,2) := 0;
  
  -- Kambiyo ve Finansman
  v_fx_gains                  NUMERIC(14,2) := 0;
  v_fx_losses                 NUMERIC(14,2) := 0;
  v_financing_expenses        NUMERIC(14,2) := 0;
  v_net_profit                NUMERIC(14,2) := 0;
  
  v_stock_cogs                NUMERIC(14,2) := 0;
  v_cogs_diff                 NUMERIC(14,2) := 0;
  
  v_result                    JSONB;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  -- 600 Yurtiçi Satışlar
  SELECT COALESCE(SUM(jl.credit - jl.debit), 0)
  INTO v_gross_sales
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND (coa.code = '600' OR coa.system_tag = 'SATIS_GELIRI')
    AND (p_start_date IS NULL OR je.entry_date >= p_start_date)
    AND (p_end_date IS NULL OR je.entry_date <= p_end_date);

  -- 610 Satıştan İadeler
  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_sales_returns
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND (coa.code = '610' OR coa.system_tag = 'SATIS_IADE')
    AND (p_start_date IS NULL OR je.entry_date >= p_start_date)
    AND (p_end_date IS NULL OR je.entry_date <= p_end_date);

  -- 621 Satılan Ticari Mallar Maliyeti (STMM)
  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_cogs
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND (coa.code = '621' OR coa.system_tag = 'COGS')
    AND (p_start_date IS NULL OR je.entry_date >= p_start_date)
    AND (p_end_date IS NULL OR je.entry_date <= p_end_date);

  -- 632 / 770 Genel Yönetim Giderleri
  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_operating_expenses
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND (coa.code LIKE '63%' OR coa.code LIKE '77%')
    AND (p_start_date IS NULL OR je.entry_date >= p_start_date)
    AND (p_end_date IS NULL OR je.entry_date <= p_end_date);

  -- 646 Kambiyo Kârları
  SELECT COALESCE(SUM(jl.credit - jl.debit), 0)
  INTO v_fx_gains
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND (coa.code = '646' OR coa.system_tag = 'KAMBIYO_KAR')
    AND (p_start_date IS NULL OR je.entry_date >= p_start_date)
    AND (p_end_date IS NULL OR je.entry_date <= p_end_date);

  -- 656 Kambiyo Zararları
  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_fx_losses
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND (coa.code = '656' OR coa.system_tag = 'KAMBIYO_ZARAR')
    AND (p_start_date IS NULL OR je.entry_date >= p_start_date)
    AND (p_end_date IS NULL OR je.entry_date <= p_end_date);

  -- 660 / 780 Finansman Giderleri
  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_financing_expenses
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND (coa.code LIKE '66%' OR coa.code LIKE '78%')
    AND (p_start_date IS NULL OR je.entry_date >= p_start_date)
    AND (p_end_date IS NULL OR je.entry_date <= p_end_date);

  -- STMM Stok Hareketleri Karşılaştırma
  SELECT COALESCE(SUM(
    CASE
      WHEN sm.movement_type = 'CIKIS' AND sm.source = 'FATURA' THEN sm.total_cost
      WHEN sm.movement_type = 'GIRIS' AND sm.source = 'FATURA' THEN -sm.total_cost
      ELSE 0
    END
  ), 0)
  INTO v_stock_cogs
  FROM public.stock_movements sm
  INNER JOIN public.invoices inv ON inv.id = sm.source_id AND inv.status != 'IPTAL'
  WHERE sm.user_id = v_user_id
    AND sm.deleted_at IS NULL
    AND (p_start_date IS NULL OR sm.movement_date >= p_start_date)
    AND (p_end_date IS NULL OR sm.movement_date <= p_end_date);

  v_net_sales          := v_gross_sales - v_sales_returns - v_sales_discounts;
  v_gross_profit       := v_net_sales - v_cogs;
  v_operating_profit   := v_gross_profit - v_operating_expenses;
  v_net_profit         := v_operating_profit + v_fx_gains - v_fx_losses - v_financing_expenses;
  v_cogs_diff          := v_cogs - v_stock_cogs;

  v_result := jsonb_build_object(
    'gross_sales', v_gross_sales,
    'sales_returns', v_sales_returns,
    'sales_discounts', v_sales_discounts,
    'net_sales', v_net_sales,
    'cogs', v_cogs,
    'gross_profit', v_gross_profit,
    'operating_expenses', v_operating_expenses,
    'operating_profit', v_operating_profit,
    'fx_gains', v_fx_gains,
    'fx_losses', v_fx_losses,
    'financing_expenses', v_financing_expenses,
    'net_profit', v_net_profit,
    'stock_movements_cogs', v_stock_cogs,
    'cogs_reconciliation_difference', v_cogs_diff,
    'period_start', p_start_date,
    'period_end', p_end_date
  );

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_income_statement FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_income_statement TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_income_statement TO service_role;


