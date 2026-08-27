-- ============================================================================
-- MASTER MIGRATION: 20260826180000_master_einvoice_and_db_fix.sql
-- AMAÇ: Canlı Supabase veritabanındaki tüm eksik tabloları, e-Fatura kolonlarını,
--       RLS izinlerini ve saklı yordamları (RPC) TEK TIKLA tamir eder.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. INVOICES TABLOSUNA E-FATURA KOLONLARININ GÜVENLİ EKLENMESİ
-- ----------------------------------------------------------------------------
ALTER TABLE public.invoices
  ADD COLUMN IF NOT EXISTS provider TEXT NOT NULL DEFAULT 'EDM',
  ADD COLUMN IF NOT EXISTS provider_reference TEXT,
  ADD COLUMN IF NOT EXISTS trx_id TEXT,
  ADD COLUMN IF NOT EXISTS seller_tax_number TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS seller_name TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS buyer_tax_number TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS buyer_name TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS edm_status TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS edm_return_code TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS edm_return_message TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS error_code TEXT,
  ADD COLUMN IF NOT EXISTS error_message TEXT,
  ADD COLUMN IF NOT EXISTS raw_ubl_xml TEXT,
  ADD COLUMN IF NOT EXISTS response_metadata JSONB DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS sent_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS processed_at TIMESTAMPTZ;

-- ----------------------------------------------------------------------------
-- 2. INVOICE_ITEMS (FATURA KALEMLERİ) TABLOSUNUN OLUŞTURULMASI
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.invoice_items (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id      UUID NOT NULL REFERENCES public.invoices(id) ON DELETE CASCADE,
  user_id         UUID NOT NULL,
  line_number     INTEGER NOT NULL DEFAULT 1,
  product_id      UUID NULL REFERENCES public.products(id) ON DELETE SET NULL,
  name            TEXT NOT NULL DEFAULT 'Ürün/Hizmet',
  description     TEXT NOT NULL DEFAULT '',
  unit            TEXT NOT NULL DEFAULT 'Adet',
  quantity        NUMERIC(14,4) NOT NULL DEFAULT 1,
  unit_price      NUMERIC(14,4) NOT NULL DEFAULT 0,
  discount_rate   NUMERIC(5,2) NOT NULL DEFAULT 0,
  subtotal        NUMERIC(14,2) NOT NULL DEFAULT 0,
  discount_amount NUMERIC(14,2) NOT NULL DEFAULT 0,
  taxable_amount  NUMERIC(14,2) NOT NULL DEFAULT 0,
  vat_rate        NUMERIC(5,2) NOT NULL DEFAULT 0,
  vat_amount      NUMERIC(14,2) NOT NULL DEFAULT 0,
  line_total      NUMERIC(14,2) NOT NULL DEFAULT 0,
  unit_cost       NUMERIC(14,4) NOT NULL DEFAULT 0,
  total_cost      NUMERIC(14,2) NOT NULL DEFAULT 0,
  currency        TEXT NOT NULL DEFAULT 'TRY',
  exchange_rate   NUMERIC(14,6) NOT NULL DEFAULT 1,
  foreign_amount  NUMERIC(14,2) NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Kolon tamamlama güvencesi (Tablo varsa bile kolonları ekler)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='invoice_items' AND column_name='name') THEN
    ALTER TABLE public.invoice_items ADD COLUMN name TEXT NOT NULL DEFAULT 'Ürün/Hizmet';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='invoice_items' AND column_name='subtotal') THEN
    ALTER TABLE public.invoice_items ADD COLUMN subtotal NUMERIC(14,2) NOT NULL DEFAULT 0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='invoice_items' AND column_name='discount_amount') THEN
    ALTER TABLE public.invoice_items ADD COLUMN discount_amount NUMERIC(14,2) NOT NULL DEFAULT 0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='invoice_items' AND column_name='unit_cost') THEN
    ALTER TABLE public.invoice_items ADD COLUMN unit_cost NUMERIC(14,4) NOT NULL DEFAULT 0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='invoice_items' AND column_name='total_cost') THEN
    ALTER TABLE public.invoice_items ADD COLUMN total_cost NUMERIC(14,2) NOT NULL DEFAULT 0;
  END IF;

  -- stock_movements maliyet kolonları güvencesi (FAZ 2.2.2 Ağırlıklı Ortalama Maliyet Motoru)
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='stock_movements' AND column_name='unit_cost') THEN
    ALTER TABLE public.stock_movements ADD COLUMN unit_cost NUMERIC(14,4) NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='stock_movements' AND column_name='total_cost') THEN
    ALTER TABLE public.stock_movements ADD COLUMN total_cost NUMERIC(14,2) NULL;
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 3. ACCOUNTING_PERIODS TABLOSUNA IS_CLOSED EKLENMESİ
-- ----------------------------------------------------------------------------
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

    UPDATE public.accounting_periods
    SET is_closed = TRUE
    WHERE status IN ('CLOSED', 'LOCKED');
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 4. EFATURA_CONNECTION_SETTINGS RLS VE İZİN DÜZELTMESİ
-- ----------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON public.efatura_connection_settings TO authenticated;
GRANT ALL ON public.efatura_connection_settings TO service_role;

DROP POLICY IF EXISTS "No direct client access to connection settings" ON public.efatura_connection_settings;
DROP POLICY IF EXISTS "Users read own connection settings" ON public.efatura_connection_settings;
DROP POLICY IF EXISTS "Users insert own connection settings" ON public.efatura_connection_settings;
DROP POLICY IF EXISTS "Users update own connection settings" ON public.efatura_connection_settings;

ALTER TABLE public.efatura_connection_settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users read own connection settings"
  ON public.efatura_connection_settings FOR SELECT TO authenticated USING (auth.uid() = user_id);

CREATE POLICY "Users insert own connection settings"
  ON public.efatura_connection_settings FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users update own connection settings"
  ON public.efatura_connection_settings FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- ----------------------------------------------------------------------------
-- 5. INVOICE_ITEMS RLS İZİNLERİ
-- ----------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON public.invoice_items TO authenticated;
GRANT ALL ON public.invoice_items TO service_role;
ALTER TABLE public.invoice_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ii_all_own" ON public.invoice_items;
CREATE POLICY "ii_all_own" ON public.invoice_items
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- ----------------------------------------------------------------------------
-- 6. CREATE_SALES_INVOICE RPC GÜNCELLEMESİ
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
  v_is_period_closed  BOOLEAN;
  v_now               TIMESTAMPTZ := now();
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

  SELECT COALESCE(status IN ('CLOSED', 'LOCKED'), is_closed, false) INTO v_is_period_closed
  FROM public.accounting_periods
  WHERE user_id = v_user_id
    AND period_year = v_year
    AND period_month = v_month;

  IF v_is_period_closed = true THEN
    RAISE EXCEPTION 'İşlem engellendi: %/% dönemi muhasebe açısından kapatılmıştır. Kapalı döneme fatura kesilemez.', v_year, v_month;
  END IF;

  v_should_post := (p_status = 'ONAYLANDI' OR p_status = 'SENT');
  v_is_return   := (p_type = 'SATIS_IADE' OR p_type = 'IADE');

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
