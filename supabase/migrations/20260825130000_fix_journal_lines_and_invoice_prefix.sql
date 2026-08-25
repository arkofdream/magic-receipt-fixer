-- ============================================================================
-- MIGRATION: 20260825130000_fix_journal_lines_and_invoice_prefix.sql
-- AMAÇ:
-- 1. next_entry_number fonksiyonundaki varsayılan 'GIB' önekini 'EAR' olarak güncellemek.
-- 2. next_entry_number_with_prefix fonksiyonu ekleyerek müşteriye özel 3 harfli seri desteği sağlamak.
-- 3. create_sales_invoice RPC'sinde:
--    - Müşteriye özel veya parametreyle gelen 3 harfli seriyi (p_prefix / customer.code / customPrefix) kullanmak.
--    - journal_lines tablosuna INSERT yaparken ROUND(..., 2) > 0 kontrolü uygulayarak
--      jl_one_side_check (0.00 TL satır ekleme) kısıt ihlalini kesin olarak önlemek.
-- ============================================================================

-- 1. next_entry_number Güncellemesi ('GIB' -> 'EAR')
CREATE OR REPLACE FUNCTION public.next_entry_number(
  p_user_id    UUID,
  p_year       INTEGER,
  p_type       TEXT DEFAULT 'JOURNAL'
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_next   INTEGER;
  v_prefix TEXT;
BEGIN
  v_prefix := CASE p_type
    WHEN 'JOURNAL' THEN 'MF'
    WHEN 'INVOICE' THEN 'EAR'
    WHEN 'PAYMENT' THEN 'OD'
    ELSE                'DOC'
  END;

  INSERT INTO public.entry_counters (user_id, year, counter_type, last_number, updated_at)
  VALUES (p_user_id, p_year, p_type, 1, now())
  ON CONFLICT (user_id, year, counter_type)
  DO UPDATE SET
    last_number = entry_counters.last_number + 1,
    updated_at  = now()
  RETURNING last_number INTO v_next;

  RETURN v_prefix
    || p_year::TEXT
    || CASE p_type
         WHEN 'INVOICE' THEN LPAD(v_next::TEXT, 9, '0')
         ELSE                LPAD(v_next::TEXT, 6, '0')
       END;
END;
$$;

-- 2. next_entry_number_with_prefix Fonksiyonu (Müşteriye/Seriye Özel Sayaç)
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
  v_next         INTEGER;
  v_clean_prefix TEXT;
BEGIN
  v_clean_prefix := UPPER(COALESCE(NULLIF(trim(p_prefix), ''), 'EAR'));
  IF LENGTH(v_clean_prefix) > 3 THEN
    v_clean_prefix := SUBSTRING(v_clean_prefix FROM 1 FOR 3);
  ELSIF LENGTH(v_clean_prefix) < 3 THEN
    v_clean_prefix := RPAD(v_clean_prefix, 3, 'X');
  END IF;

  INSERT INTO public.entry_counters (user_id, year, counter_type, last_number, updated_at)
  VALUES (p_user_id, p_year, 'INVOICE_' || v_clean_prefix, 1, now())
  ON CONFLICT (user_id, year, counter_type)
  DO UPDATE SET
    last_number = entry_counters.last_number + 1,
    updated_at  = now()
  RETURNING last_number INTO v_next;

  RETURN v_clean_prefix || p_year::TEXT || LPAD(v_next::TEXT, 9, '0');
END;
$$;

GRANT EXECUTE ON FUNCTION public.next_entry_number_with_prefix TO authenticated;
GRANT EXECUTE ON FUNCTION public.next_entry_number_with_prefix TO service_role;

-- 3. create_sales_invoice RPC Güncellemesi
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
  v_is_period_closed  BOOLEAN;
  v_txn_id            UUID;
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
  v_now               TIMESTAMPTZ := now();
BEGIN
  -- 1. Yetkilendirme
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.' USING ERRCODE = '42501';
  END IF;

  -- 2. Zorunlu Alan Kontrolleri
  IF p_invoice_date IS NULL THEN
    RAISE EXCEPTION 'Fatura tarihi zorunludur.';
  END IF;

  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Fatura en az bir kalem içermelidir.';
  END IF;

  -- 3. Dönem Kapanış Kontrolü
  v_year  := EXTRACT(YEAR FROM p_invoice_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM p_invoice_date)::INTEGER;

  SELECT is_closed INTO v_is_period_closed
  FROM public.accounting_periods
  WHERE user_id = v_user_id
    AND period_year = v_year
    AND period_month = v_month;

  IF v_is_period_closed = true THEN
    RAISE EXCEPTION 'İşlem engellendi: %/% dönemi muhasebe açısından kapatılmıştır. Kapalı döneme fatura kesilemez.', v_year, v_month;
  END IF;

  -- 4. Temel Değişkenlerin Hazırlanması
  v_should_post := (p_status = 'ONAYLANDI' OR p_status = 'SENT');
  v_is_return   := (p_type = 'SATIS_IADE' OR p_type = 'IADE');

  -- 5. Müşteri Kilitleme (Concurrency Protection)
  IF p_customer_id IS NOT NULL THEN
    PERFORM id FROM public.customers
    WHERE id = p_customer_id AND user_id = v_user_id
    FOR UPDATE;
  END IF;

  -- 6. Stok Ürünlerini Kilitleme (WAC ve Bakiye Tutarlılığı İçin)
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    IF (v_item->>'productId') IS NOT NULL AND trim(v_item->>'productId') != '' THEN
      PERFORM id FROM public.products
      WHERE id = (v_item->>'productId')::UUID AND user_id = v_user_id
      FOR UPDATE;
    END IF;
  END LOOP;

  -- 7. Atomik Fatura Numarası Üretimi (Müşteriye Özel Seri Desteği)
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
    ROUND(SUM(taxable_amount), 2),
    ROUND(SUM(vat_amount), 2),
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

  -- 11. Onaylı Fatura Durumunda Cari, Stok ve Yevmiye Hareketlerinin Üretilmesi
  IF v_should_post THEN
    -- A) Cari Hesap Hareketi
    IF p_customer_id IS NOT NULL THEN
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

    -- Toplam Gerçek STMM Tutarı
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
    IF ROUND(COALESCE(p_total_tevkifat, 0), 2) > 0 THEN
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

    -- 610 Satıştan İadeler
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

    IF v_acc_391_id IS NULL AND ROUND(COALESCE(p_total_vat, 0), 2) > 0 THEN
      RAISE EXCEPTION 'Muhasebe hesap planında 391 (Hesaplanan KDV) hesabı bulunamadı.';
    END IF;

    -- 621 / 153 STMM Hesapları
    IF ROUND(COALESCE(v_total_stmm, 0), 2) > 0 THEN
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

    -- E) Yevmiye Fişi Satırları (jl_one_side_check korumalı INSERT)
    IF NOT v_is_return THEN
      -- 1. Satır: 120 ALICILAR ➔ BORÇ = Alıcıdan Tahsil Edilecek Tutar
      IF ROUND(COALESCE(p_grand_total, 0), 2) > 0 THEN
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, v_acc_120_id,
          'Fatura Borç Kaydı: ' || v_invoice_number,
          ROUND(p_grand_total, 2), 0, p_currency, COALESCE(p_exchange_rate, 1)
        );
      END IF;

      -- 2. Satır: 136 TEVKİFAT ALACAĞI ➔ BORÇ = Tevkifat Tutarı
      IF ROUND(COALESCE(p_total_tevkifat, 0), 2) > 0 AND v_acc_136_id IS NOT NULL THEN
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, v_acc_136_id,
          'Tevkifat KDV Alacağı: ' || v_invoice_number,
          ROUND(p_total_tevkifat, 2), 0, p_currency, COALESCE(p_exchange_rate, 1)
        );
      END IF;

      -- 3. Satır: 621 SATILAN TİCARİ MALLAR MALİYETİ ➔ BORÇ = Toplam STMM
      IF ROUND(COALESCE(v_total_stmm, 0), 2) > 0 AND v_acc_621_id IS NOT NULL THEN
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, v_acc_621_id,
          'Satılan Ticari Mallar Maliyeti (STMM): ' || v_invoice_number,
          ROUND(v_total_stmm, 2), 0, 'TRY', 1
        );
      END IF;

      -- 4. Satır: 600 YURTİÇİ SATIŞLAR ➔ ALACAK = Matrah
      IF ROUND(COALESCE(p_taxable_amount, 0), 2) > 0 THEN
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, v_acc_600_id,
          'Satış Geliri: ' || v_invoice_number,
          0, ROUND(p_taxable_amount, 2), p_currency, COALESCE(p_exchange_rate, 1)
        );
      END IF;

      -- 5. Satırlar: 391 HESAPLANAN KDV ➔ ALACAK = KDV Tutarları (Sadece > 0 olanlar)
      IF v_acc_391_id IS NOT NULL THEN
        FOR v_tax_rec IN
          SELECT vat_rate, ROUND(tax_amount, 2) AS rounded_tax_amount
          FROM public.invoice_tax_lines
          WHERE invoice_id = v_invoice_id AND ROUND(tax_amount, 2) > 0
        LOOP
          INSERT INTO public.journal_lines (
            journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
          ) VALUES (
            v_journal_entry_id, v_user_id, v_acc_391_id,
            'Hesaplanan KDV (%' || v_tax_rec.vat_rate || '): ' || v_invoice_number,
            0, v_tax_rec.rounded_tax_amount, p_currency, COALESCE(p_exchange_rate, 1)
          );
        END LOOP;
      END IF;

      -- 6. Satır: 153 TİCARİ MALLAR ➔ ALACAK = Toplam STMM
      IF ROUND(COALESCE(v_total_stmm, 0), 2) > 0 AND v_acc_153_id IS NOT NULL THEN
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, v_acc_153_id,
          'Stoktan Çıkış Maliyeti (STMM): ' || v_invoice_number,
          0, ROUND(v_total_stmm, 2), 'TRY', 1
        );
      END IF;

    ELSE
      -- 1. Satır: 610 SATIŞTAN İADELER ➔ BORÇ = Matrah
      IF ROUND(COALESCE(p_taxable_amount, 0), 2) > 0 THEN
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, COALESCE(v_acc_610_id, v_acc_600_id),
          'Satıştan İade: ' || v_invoice_number,
          ROUND(p_taxable_amount, 2), 0, p_currency, COALESCE(p_exchange_rate, 1)
        );
      END IF;

      -- 2. Satırlar: 391 HESAPLANAN KDV ➔ BORÇ = KDV Tutarları
      IF v_acc_391_id IS NOT NULL THEN
        FOR v_tax_rec IN
          SELECT vat_rate, ROUND(tax_amount, 2) AS rounded_tax_amount
          FROM public.invoice_tax_lines
          WHERE invoice_id = v_invoice_id AND ROUND(tax_amount, 2) > 0
        LOOP
          INSERT INTO public.journal_lines (
            journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
          ) VALUES (
            v_journal_entry_id, v_user_id, v_acc_391_id,
            'İade KDV (%' || v_tax_rec.vat_rate || '): ' || v_invoice_number,
            v_tax_rec.rounded_tax_amount, 0, p_currency, COALESCE(p_exchange_rate, 1)
          );
        END LOOP;
      END IF;

      -- 3. Satır: 153 TİCARİ MALLAR ➔ BORÇ = İade Alınan Stok Maliyeti
      IF ROUND(COALESCE(v_total_stmm, 0), 2) > 0 AND v_acc_153_id IS NOT NULL THEN
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, v_acc_153_id,
          'İade Alınan Stok Maliyeti (STMM Düzeltmesi): ' || v_invoice_number,
          ROUND(v_total_stmm, 2), 0, 'TRY', 1
        );
      END IF;

      -- 4. Satır: 120 ALICILAR ➔ ALACAK = Genel Toplam
      IF ROUND(COALESCE(p_grand_total, 0), 2) > 0 THEN
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, v_acc_120_id,
          'İade Alacak Kaydı: ' || v_invoice_number,
          0, ROUND(p_grand_total, 2), p_currency, COALESCE(p_exchange_rate, 1)
        );
      END IF;

      -- 5. Satır: 621 STMM DÜZELTMESİ ➔ ALACAK = Toplam STMM
      IF ROUND(COALESCE(v_total_stmm, 0), 2) > 0 AND v_acc_621_id IS NOT NULL THEN
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, v_acc_621_id,
          'İade Edilen Satış Maliyeti Düzeltmesi (STMM): ' || v_invoice_number,
          0, ROUND(v_total_stmm, 2), 'TRY', 1
        );
      END IF;
    END IF;

    -- Yevmiye Fişini Onaylandı Yapma
    UPDATE public.journal_entries
    SET status = 'POSTED',
        updated_at = v_now
    WHERE id = v_journal_entry_id;
  END IF;

  -- 12. Sonuç Dönüşü
  RETURN jsonb_build_object(
    'id', v_invoice_id,
    'invoice_number', v_invoice_number,
    'status', p_status,
    'ettn', v_ettn,
    'posted', v_should_post
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_sales_invoice FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_sales_invoice TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_sales_invoice TO service_role;
