-- ============================================================================
-- MIGRATION: 20260826150000_add_is_closed_to_accounting_periods.sql
-- AMAÇ:
-- 1. public.accounting_periods tablosuna is_closed sütununu eklemek.
-- 2. status ('CLOSED', 'LOCKED') ile is_closed boolean alanını otomatik senkronize etmek.
-- 3. create_sales_invoice RPC fonksiyonunda is_closed / status denetimini tamamen güvenli kılmak.
-- ============================================================================

-- 1. accounting_periods tablosuna is_closed kolonunun güvenli eklenmesi
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema = 'public' 
      AND table_name = 'accounting_periods' 
      AND column_name = 'is_closed'
  ) THEN
    ALTER TABLE public.accounting_periods 
    ADD COLUMN is_closed BOOLEAN NOT NULL DEFAULT FALSE;

    -- Mevcut kapalı dönemlerin senkronizasyonu
    UPDATE public.accounting_periods
    SET is_closed = TRUE
    WHERE status IN ('CLOSED', 'LOCKED');
  END IF;
END $$;

-- 2. Otomatik Senkronizasyon Trigger'ı
CREATE OR REPLACE FUNCTION public.sync_accounting_period_is_closed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  NEW.is_closed := (NEW.status IN ('CLOSED', 'LOCKED'));
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_accounting_period_is_closed ON public.accounting_periods;
CREATE TRIGGER trg_sync_accounting_period_is_closed
  BEFORE INSERT OR UPDATE ON public.accounting_periods
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_accounting_period_is_closed();

-- 3. create_sales_invoice RPC Fonksiyonunun Güncellenmesi (Sütun Uyumsuzluğunu Tamamen Önler)
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

  -- 3. Dönem Kapanış Kontrolü (status veya is_closed güvenli kontrolü)
  v_year  := EXTRACT(YEAR FROM p_invoice_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM p_invoice_date)::INTEGER;

  SELECT COALESCE(status IN ('CLOSED', 'LOCKED'), is_closed, false) INTO v_is_period_closed
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

  -- 5. Müşteri Kilitleme
  IF p_customer_id IS NOT NULL THEN
    PERFORM id FROM public.customers
    WHERE id = p_customer_id AND user_id = v_user_id
    FOR UPDATE;
  END IF;

  -- 6. Stok Ürünlerini Kilitleme
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    IF (v_item->>'productId') IS NOT NULL AND trim(v_item->>'productId') != '' THEN
      PERFORM id FROM public.products
      WHERE id = (v_item->>'productId')::UUID AND user_id = v_user_id
      FOR UPDATE;
    END IF;
  END LOOP;

  -- 7. Atomik Fatura Numarası Üretimi
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

  -- 9. Fatura Kalemleri (invoice_items INSERT)
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

    v_unit_cost := 0;
    IF v_product_id IS NOT NULL THEN
      SELECT unit_cost INTO v_unit_cost FROM public.products WHERE id = v_product_id;
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

    -- Stok Hareketi
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
        total_price, reference_type, reference_id, description, movement_date
      ) VALUES (
        v_user_id, v_product_id, p_warehouse_id,
        CASE WHEN v_is_return THEN 'IN' ELSE 'OUT' END,
        v_quantity, v_unit_price, v_item_total, 'INVOICE', v_invoice_id,
        CASE WHEN v_is_return THEN 'Satış İade Faturası Kalemi' ELSE 'Satış Faturası Kalemi' END,
        p_invoice_date
      );
    END IF;
  END LOOP;

  -- 10. Yetkilerin Verilmesi
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.accounting_periods TO authenticated;
  GRANT ALL ON public.accounting_periods TO service_role;

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
