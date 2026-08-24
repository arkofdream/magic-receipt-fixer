-- =============================================================
-- FAZ 2.5 — E-FATURA KALICI VERİTABANI KAYDI VE IDEMPOTENCY ALTYAPISI
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-24
-- =============================================================

-- 1. Invoices tablosuna e-Fatura entegrasyon ve takip alanlarını ekle
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

-- 2. ETTN (UUID) seviyesinde veritabanı mükerrerlik engelleme (Unique Constraint)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'invoices_ettn_unique'
  ) THEN
    ALTER TABLE public.invoices ADD CONSTRAINT invoices_ettn_unique UNIQUE (ettn);
  END IF;
END $$;

-- 3. Provider + Fatura Numarası seviyesinde veritabanı mükerrerlik engelleme
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'invoices_provider_invoice_number_unique'
  ) THEN
    ALTER TABLE public.invoices ADD CONSTRAINT invoices_provider_invoice_number_unique UNIQUE (provider, invoice_number);
  END IF;
END $$;

-- 4. Arama ve filtreleme indeksleri
CREATE INDEX IF NOT EXISTS idx_invoices_provider_status ON public.invoices (provider, status);
CREATE INDEX IF NOT EXISTS idx_invoices_created_at ON public.invoices (created_at DESC);
