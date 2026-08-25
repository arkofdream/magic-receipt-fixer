-- =============================================================
-- FAZ 2.2.4 — IMPLEMENTATION 1/4: MUHASEBE DÖNEM YÖNETİMİ VE KAPALI DÖNEM GÜVENLİĞİ
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-23
-- =============================================================
-- BU MİGRATION:
--   ✅ accounting_periods tablosunu oluşturur (OPEN, CLOSED, LOCKED)
--   ✅ RLS politikaları ile tenant (user_id = auth.uid()) izolasyonunu sağlar
--   ✅ assert_accounting_period_open güvenlik doğrulama fonksiyonunu kurar
--   ✅ close_accounting_period ve reopen_accounting_period RPC fonksiyonlarını oluşturur
--   ✅ journal_entries üzerinde kapalı dönem denetim trigger'ı kurar
--   ✅ create_sales_invoice RPC'sine kapalı dönem kilidi entegrasyonu ekler (FAZ 2.2.2 lock ve FAZ 2.2.3 STMM korunarak)
--   ✅ cancel_sales_invoice RPC'sine kapalı dönem kilidi kontrolü ekler
-- =============================================================

-- 1. accounting_periods Tablosunun Oluşturulması
CREATE TABLE IF NOT EXISTS public.accounting_periods (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL,
  period_year   INTEGER NOT NULL,
  period_month  INTEGER NOT NULL,
  status        TEXT NOT NULL DEFAULT 'OPEN',
  opened_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  closed_at     TIMESTAMPTZ NULL,
  closed_by     UUID NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ap_user_year_month_unique UNIQUE (user_id, period_year, period_month),
  CONSTRAINT ap_status_check           CHECK (status IN ('OPEN', 'CLOSED', 'LOCKED')),
  CONSTRAINT ap_year_check             CHECK (period_year BETWEEN 2000 AND 2100),
  CONSTRAINT ap_month_check            CHECK (period_month BETWEEN 1 AND 12)
);

CREATE INDEX IF NOT EXISTS ap_user_period_idx
  ON public.accounting_periods(user_id, period_year, period_month);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.accounting_periods TO authenticated;
GRANT ALL ON public.accounting_periods TO service_role;
ALTER TABLE public.accounting_periods ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ap_all_own" ON public.accounting_periods;
CREATE POLICY "ap_all_own" ON public.accounting_periods
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

DROP TRIGGER IF EXISTS update_accounting_periods_updated_at ON public.accounting_periods;
CREATE TRIGGER update_accounting_periods_updated_at
  BEFORE UPDATE ON public.accounting_periods
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- 2. Güvenli Dönem Açıklık Doğrulama Fonksiyonu (Helper)
CREATE OR REPLACE FUNCTION public.assert_accounting_period_open(
  p_user_id UUID,
  p_date    DATE
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_year   INTEGER;
  v_month  INTEGER;
  v_status TEXT;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Kullanıcı ID zorunludur.' USING ERRCODE = '42501';
  END IF;

  IF p_date IS NULL THEN
    RAISE EXCEPTION 'Tarih bilgisi zorunludur.';
  END IF;

  v_year  := EXTRACT(YEAR FROM p_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM p_date)::INTEGER;

  SELECT status INTO v_status
  FROM public.accounting_periods
  WHERE user_id = p_user_id
    AND period_year = v_year
    AND period_month = v_month;

  -- Eğer dönem kaydı mevcut ve CLOSED veya LOCKED ise işlem durdurulur
  IF v_status IN ('CLOSED', 'LOCKED') THEN
    RAISE EXCEPTION 'Muhasebe dönemi (%/%) kapatılmış veya kilitlenmiştir. Kapalı döneme yeni kayıt yapılamaz veya mevcut kayıtlar değiştirilemez.',
      v_month, v_year
      USING ERRCODE = '22023';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.assert_accounting_period_open FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.assert_accounting_period_open TO authenticated;
GRANT EXECUTE ON FUNCTION public.assert_accounting_period_open TO service_role;

-- 3. Dönem Kapatma RPC'si (close_accounting_period)
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
  v_unbalanced    INTEGER;
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

  -- Dönemdeki POSTED fişlerin denklik kontrolü
  SELECT COUNT(*)
  INTO v_unbalanced
  FROM public.journal_entries
  WHERE user_id = v_user_id
    AND period_year = p_year
    AND period_month = p_month
    AND status = 'POSTED'
    AND total_debit != total_credit;

  IF v_unbalanced > 0 THEN
    RAISE EXCEPTION 'Dönem içinde borç-alacak toplamı denk olmayan % adet POSTED fiş bulunmaktadır. Dönem kapatılamaz.',
      v_unbalanced;
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

-- 4. Dönem Yeniden Açma RPC'si (reopen_accounting_period)
CREATE OR REPLACE FUNCTION public.reopen_accounting_period(
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
  v_period_id     UUID;
  v_now           TIMESTAMPTZ := now();
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  IF p_year NOT BETWEEN 2000 AND 2100 OR p_month NOT BETWEEN 1 AND 12 THEN
    RAISE EXCEPTION 'Geçersiz yıl (%) veya ay (%).', p_year, p_month;
  END IF;

  SELECT id, status INTO v_period_id, v_status
  FROM public.accounting_periods
  WHERE user_id = v_user_id
    AND period_year = p_year
    AND period_month = p_month
  FOR UPDATE;

  IF v_status = 'LOCKED' THEN
    RAISE EXCEPTION 'Bu dönem (%/%) kilitlidir (LOCKED) ve açılamaz.', p_month, p_year;
  ELSIF v_status IS NULL OR v_status = 'OPEN' THEN
    RAISE EXCEPTION 'Bu dönem (%/%) zaten açıktır (OPEN).', p_month, p_year;
  END IF;

  -- Dönemi OPEN durumuna getir
  UPDATE public.accounting_periods
  SET
    status = 'OPEN',
    closed_at = NULL,
    closed_by = NULL,
    opened_at = v_now,
    updated_at = v_now
  WHERE id = v_period_id;

  RETURN jsonb_build_object(
    'period_id', v_period_id,
    'period_year', p_year,
    'period_month', p_month,
    'status', 'OPEN',
    'reopened_at', v_now
  );
END;
$$;

REVOKE ALL ON FUNCTION public.reopen_accounting_period FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reopen_accounting_period TO authenticated;
GRANT EXECUTE ON FUNCTION public.reopen_accounting_period TO service_role;

-- 5. journal_entries Tablosu için Kapalı Dönem Koruma Trigger'ı
CREATE OR REPLACE FUNCTION public.check_journal_entry_period_open()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_date DATE;
  v_uid  UUID;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_date := OLD.entry_date;
    v_uid  := OLD.user_id;
  ELSE
    v_date := NEW.entry_date;
    v_uid  := NEW.user_id;
  END IF;

  PERFORM public.assert_accounting_period_open(v_uid, v_date);

  IF TG_OP = 'UPDATE' AND OLD.entry_date IS DISTINCT FROM NEW.entry_date THEN
    PERFORM public.assert_accounting_period_open(OLD.user_id, OLD.entry_date);
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_check_journal_entry_period ON public.journal_entries;
CREATE TRIGGER trg_check_journal_entry_period
  BEFORE INSERT OR UPDATE OR DELETE ON public.journal_entries
  FOR EACH ROW EXECUTE FUNCTION public.check_journal_entry_period_open();

-- 6. create_sales_invoice RPC Güncellemesi (Kapalı Dönem Koruması Dahil)
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

  -- 3. KAPALI DÖNEM KONTROLÜ (Dönem kapalıysa fatura ve muhasebe engellenir)
  PERFORM public.assert_accounting_period_open(v_user_id, p_invoice_date);

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

  -- 4. Müşteri Aidiyet ve Varlık Kontrolü
  IF p_customer_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.customers
      WHERE id = p_customer_id AND user_id = v_user_id AND deleted_at IS NULL
    ) THEN
      RAISE EXCEPTION 'Geçersiz veya silinmiş müşteri seçimi. Müşteri ID: %', p_customer_id;
    END IF;
  END IF;

  -- 5. Depo Aidiyet ve Varlık Kontrolü
  IF p_warehouse_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.warehouses
      WHERE id = p_warehouse_id AND user_id = v_user_id AND deleted_at IS NULL
    ) THEN
      RAISE EXCEPTION 'Geçersiz veya silinmiş depo seçimi. Depo ID: %', p_warehouse_id;
    END IF;
  END IF;

  -- 6. DETERMINISTIK KİLİTLEME (FOR UPDATE ile Deadlock & Race Condition Koruması)
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

  -- 7. Atomik Fatura Numarası Üretimi
  IF p_invoice_number IS NOT NULL AND trim(p_invoice_number) != '' THEN
    v_invoice_number := trim(p_invoice_number);
  ELSE
    v_invoice_number := public.next_entry_number(v_user_id, v_year, 'INVOICE');
  END IF;

  v_ettn := COALESCE(NULLIF(trim(p_ettn), ''), UPPER(gen_random_uuid()::TEXT));

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

  -- 11. ONAYLI Fatura İse: Cari, Stok (Maliyetli) ve Yevmiye Fişi (STMM Dahil) Kayıtları
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

  -- 12. Sonuç Dönüşü
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

-- 7. cancel_sales_invoice RPC Güncellemesi (Kapalı Dönem Koruması Dahil)
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
  v_year                INTEGER;
  v_month               INTEGER;
  v_now                 TIMESTAMPTZ := now();
BEGIN
  -- 1. Yetkilendirme Kontrolü
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Fatura Varlık ve Aidiyet Kontrolü
  SELECT *
  INTO v_invoice
  FROM public.invoices
  WHERE id = p_invoice_id AND user_id = v_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'İptal edilecek fatura bulunamadı veya bu faturaya erişim yetkiniz yok. Fatura ID: %', p_invoice_id;
  END IF;

  -- 3. Kapalı Dönem Kontrolü (Faturanın ait olduğu dönem veya iptal tarihi dönemi kapalıysa işlem engellenir)
  PERFORM public.assert_accounting_period_open(v_user_id, v_invoice.invoice_date);
  PERFORM public.assert_accounting_period_open(v_user_id, CURRENT_DATE);

  -- 4. Zaten İptal Edilmiş mi?
  IF v_invoice.status = 'IPTAL' THEN
    RAISE EXCEPTION 'Bu fatura (%) zaten iptal edilmiştir. Mükerrer iptal işlemi yapılamaz.',
      v_invoice.invoice_number;
  END IF;

  v_year  := EXTRACT(YEAR FROM v_invoice.invoice_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM v_invoice.invoice_date)::INTEGER;

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

    -- A) Cari Hesap Ters Kaydı
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
        CASE WHEN v_invoice.type = 'IADE' THEN 'BORC' ELSE 'ALACAK' END,
        v_invoice.grand_total,
        v_invoice.invoice_number,
        'Fatura İptali Ters Kaydı (' || v_invoice.invoice_number || ')' ||
          CASE WHEN trim(p_cancel_reason) != '' THEN ' - Sebep: ' || trim(p_cancel_reason) ELSE '' END,
        'FATURA_IPTAL',
        p_invoice_id
      );
      v_rev_count_txn := 1;
    END IF;

    -- B) Stok Hareketleri Ters Kaydı (Maliyet ve Satış Fiyatı Korunarak)
    FOR v_orig_stock IN
      SELECT *
      FROM public.stock_movements
      WHERE source_id = p_invoice_id
        AND user_id = v_user_id
        AND deleted_at IS NULL
        AND source = 'FATURA'
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
        CASE
          WHEN v_orig_stock.movement_type = 'CIKIS' THEN 'GIRIS'
          WHEN v_orig_stock.movement_type = 'GIRIS' THEN 'CIKIS'
          ELSE 'GIRIS'
        END,
        v_orig_stock.quantity,
        v_orig_stock.unit_price,
        v_orig_stock.unit_cost,
        v_orig_stock.total_cost,
        v_invoice.invoice_number,
        'Fatura İptali Stok İadesi (' || v_invoice.invoice_number || ')',
        'FATURA_IPTAL',
        p_invoice_id
      );
      v_rev_count_stock := v_rev_count_stock + 1;
    END LOOP;

    -- C) KDV Satırları Ters Kaydı (invoice_tax_lines)
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

    -- D) Yevmiye Fişi Ters Kaydı (STMM 621/153 Dahil Otomatik Reversal)
    SELECT *
    INTO v_orig_journal
    FROM public.journal_entries
    WHERE source_type = 'INVOICE'
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
        'Fatura İptal Ters Kaydı - ' || v_invoice.invoice_number ||
          CASE WHEN trim(p_cancel_reason) != '' THEN ' (' || trim(p_cancel_reason) || ')' ELSE '' END,
        'MAHSUP',
        'INVOICE_CANCEL',
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
          v_orig_line.credit,
          v_orig_line.debit,
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
    'status', 'IPTAL',
    'posted', v_invoice.posted,
    'reversal_journal_id', v_reversal_journal_id,
    'reversal_journal_number', v_reversal_entry_no,
    'reversal_transactions_count', v_rev_count_txn,
    'reversal_stock_movements_count', v_rev_count_stock
  );
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_sales_invoice FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_sales_invoice TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_sales_invoice TO service_role;
