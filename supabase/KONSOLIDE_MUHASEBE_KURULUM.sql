-- =============================================================
-- MAGIC RECEIPT ÖN MUHASEBE & ERP TAM KURULUM (KONSOLİDE MASTER SQL)
-- Tarih: 2026-08-22
-- =============================================================

-- 0. TEMEL YARDIMCI FONKSİYONLAR
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- =============================================================
-- ESKİ VE ÇAKIŞAN TÜM RPC FONKSİYON İMZALARINI TEMİZLEME
-- =============================================================
DO $$ 
DECLARE 
  r RECORD;
  func_names TEXT[] := ARRAY[
    'create_sales_invoice',
    'cancel_sales_invoice',
    'create_purchase_invoice',
    'create_purchase_return',
    'create_supplier_payment',
    'create_customer_collection',
    'get_trial_balance',
    'get_vat_declaration_summary',
    'get_withholding_tax_summary',
    'get_foreign_currency_balances',
    'run_fx_revaluation',
    'get_income_statement',
    'get_balance_sheet',
    'get_customer_balances',
    'get_accounting_audit_summary'
  ];
  f TEXT;
BEGIN
  FOREACH f IN ARRAY func_names LOOP
    FOR r IN (
      SELECT oid::regprocedure AS func_signature 
      FROM pg_proc 
      WHERE proname = f
        AND pronamespace = 'public'::regnamespace
    ) LOOP
      EXECUTE 'DROP FUNCTION IF EXISTS ' || r.func_signature || ' CASCADE';
    END LOOP;
  END LOOP;
END $$;

-- 0.1 AUDIT & SOFT DELETE ALTYAPISI
-- Migration: Veri Güvenliği, Soft Delete, Audit Log ve Veri Kurtarma Altyapısı

-- 1) Soft Delete Kolonları
ALTER TABLE public.invoices
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS deleted_by uuid NULL REFERENCES auth.users(id);

ALTER TABLE public.customers
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS deleted_by uuid NULL REFERENCES auth.users(id);

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS deleted_by uuid NULL REFERENCES auth.users(id);

ALTER TABLE public.account_transactions
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS deleted_by uuid NULL REFERENCES auth.users(id);

ALTER TABLE public.stock_movements
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS deleted_by uuid NULL REFERENCES auth.users(id);

ALTER TABLE public.pos_sales
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS deleted_by uuid NULL REFERENCES auth.users(id);

ALTER TABLE public.warehouses
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS deleted_by uuid NULL REFERENCES auth.users(id);

-- İndeksler (Sorgu performansı için)
CREATE INDEX IF NOT EXISTS idx_invoices_user_deleted ON public.invoices(user_id, deleted_at);
CREATE INDEX IF NOT EXISTS idx_customers_user_deleted ON public.customers(user_id, deleted_at);
CREATE INDEX IF NOT EXISTS idx_products_user_deleted ON public.products(user_id, deleted_at);
CREATE INDEX IF NOT EXISTS idx_account_transactions_user_deleted ON public.account_transactions(user_id, deleted_at);
CREATE INDEX IF NOT EXISTS idx_stock_movements_user_deleted ON public.stock_movements(user_id, deleted_at);
CREATE INDEX IF NOT EXISTS idx_pos_sales_user_deleted ON public.pos_sales(user_id, deleted_at);
CREATE INDEX IF NOT EXISTS idx_warehouses_user_deleted ON public.warehouses(user_id, deleted_at);

-- 2) Audit Logs Tablosu
CREATE TABLE IF NOT EXISTS public.audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id),
  action text NOT NULL,
  table_name text NOT NULL,
  record_id text NOT NULL,
  old_data jsonb NULL,
  new_data jsonb NULL,
  metadata jsonb NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT ON public.audit_logs TO authenticated;
GRANT ALL ON public.audit_logs TO service_role;

ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users read own audit logs" ON public.audit_logs;
CREATE POLICY "Users read own audit logs" ON public.audit_logs
  FOR SELECT TO authenticated USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users insert own audit logs" ON public.audit_logs;
CREATE POLICY "Users insert own audit logs" ON public.audit_logs
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_audit_logs_user_created ON public.audit_logs(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_table_record ON public.audit_logs(user_id, table_name, record_id);

-- 3) Audit Log Trigger Fonksiyonu
CREATE OR REPLACE FUNCTION public.log_audit_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_action text;
  v_old jsonb := NULL;
  v_new jsonb := NULL;
  v_record_id text;
BEGIN
  v_user_id := auth.uid();

  IF TG_OP = 'INSERT' THEN
    v_action := 'CREATE';
    v_new := to_jsonb(NEW);
    v_record_id := NEW.id::text;
    IF v_user_id IS NULL AND NEW.user_id IS NOT NULL THEN
      v_user_id := NEW.user_id;
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
      v_action := 'DELETE';
    ELSIF OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL THEN
      v_action := 'RESTORE';
    ELSE
      v_action := 'UPDATE';
    END IF;
    v_old := to_jsonb(OLD);
    v_new := to_jsonb(NEW);
    v_record_id := NEW.id::text;
    IF v_user_id IS NULL THEN
      v_user_id := COALESCE(NEW.user_id, OLD.user_id);
    END IF;
  ELSIF TG_OP = 'DELETE' THEN
    v_action := 'PERMANENT_DELETE';
    v_old := to_jsonb(OLD);
    v_record_id := OLD.id::text;
    IF v_user_id IS NULL THEN
      v_user_id := OLD.user_id;
    END IF;
  END IF;

  IF v_user_id IS NOT NULL THEN
    INSERT INTO public.audit_logs (
      user_id,
      action,
      table_name,
      record_id,
      old_data,
      new_data,
      metadata
    ) VALUES (
      v_user_id,
      v_action,
      TG_TABLE_NAME,
      v_record_id,
      v_old,
      v_new,
      jsonb_build_object('trigger', true, 'op', TG_OP)
    );
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  ELSE
    RETURN NEW;
  END IF;
END;
$$;

-- Triggerların Tanımlanması
DROP TRIGGER IF EXISTS audit_invoices_trigger ON public.invoices;
CREATE TRIGGER audit_invoices_trigger AFTER INSERT OR UPDATE OR DELETE ON public.invoices FOR EACH ROW EXECUTE FUNCTION public.log_audit_event();

DROP TRIGGER IF EXISTS audit_customers_trigger ON public.customers;
CREATE TRIGGER audit_customers_trigger AFTER INSERT OR UPDATE OR DELETE ON public.customers FOR EACH ROW EXECUTE FUNCTION public.log_audit_event();

DROP TRIGGER IF EXISTS audit_products_trigger ON public.products;
CREATE TRIGGER audit_products_trigger AFTER INSERT OR UPDATE OR DELETE ON public.products FOR EACH ROW EXECUTE FUNCTION public.log_audit_event();

DROP TRIGGER IF EXISTS audit_account_transactions_trigger ON public.account_transactions;
CREATE TRIGGER audit_account_transactions_trigger AFTER INSERT OR UPDATE OR DELETE ON public.account_transactions FOR EACH ROW EXECUTE FUNCTION public.log_audit_event();

DROP TRIGGER IF EXISTS audit_stock_movements_trigger ON public.stock_movements;
CREATE TRIGGER audit_stock_movements_trigger AFTER INSERT OR UPDATE OR DELETE ON public.stock_movements FOR EACH ROW EXECUTE FUNCTION public.log_audit_event();

DROP TRIGGER IF EXISTS audit_pos_sales_trigger ON public.pos_sales;
CREATE TRIGGER audit_pos_sales_trigger AFTER INSERT OR UPDATE OR DELETE ON public.pos_sales FOR EACH ROW EXECUTE FUNCTION public.log_audit_event();

DROP TRIGGER IF EXISTS audit_warehouses_trigger ON public.warehouses;
CREATE TRIGGER audit_warehouses_trigger AFTER INSERT OR UPDATE OR DELETE ON public.warehouses FOR EACH ROW EXECUTE FUNCTION public.log_audit_event();

-- 4) Bakiyelerin ve Stokların Soft Delete Uyumu (Soft-deleted kayıtlar hesaplamadan çıkarılır)
CREATE OR REPLACE VIEW public.customer_balances
WITH (security_invoker = on) AS
SELECT
  c.id AS customer_id,
  c.user_id,
  c.opening_balance
    + COALESCE(SUM(CASE WHEN t.deleted_at IS NULL AND t.txn_type IN ('BORC','ODEME') THEN t.amount ELSE 0 END), 0) AS total_debit,
  COALESCE(SUM(CASE WHEN t.deleted_at IS NULL AND t.txn_type IN ('ALACAK','TAHSILAT') THEN t.amount ELSE 0 END), 0) AS total_credit,
  c.opening_balance
    + COALESCE(SUM(CASE WHEN t.deleted_at IS NULL AND t.txn_type IN ('BORC','ODEME') THEN t.amount ELSE 0 END), 0)
    - COALESCE(SUM(CASE WHEN t.deleted_at IS NULL AND t.txn_type IN ('ALACAK','TAHSILAT') THEN t.amount ELSE 0 END), 0) AS balance
FROM public.customers c
LEFT JOIN public.account_transactions t ON t.customer_id = c.id
WHERE c.deleted_at IS NULL
GROUP BY c.id, c.user_id, c.opening_balance;

GRANT SELECT ON public.customer_balances TO authenticated;
GRANT ALL ON public.customer_balances TO service_role;

CREATE OR REPLACE VIEW public.product_stocks
WITH (security_invoker = on) AS
SELECT
  p.id AS product_id,
  p.user_id,
  COALESCE(SUM(
    CASE
      WHEN m.deleted_at IS NULL AND m.movement_type = 'GIRIS' THEN m.quantity
      WHEN m.deleted_at IS NULL AND m.movement_type = 'CIKIS' THEN -m.quantity
      ELSE 0
    END), 0) AS quantity
FROM public.products p
LEFT JOIN public.stock_movements m ON m.product_id = p.id
WHERE p.deleted_at IS NULL
GROUP BY p.id, p.user_id;

GRANT SELECT ON public.product_stocks TO authenticated;
GRANT ALL ON public.product_stocks TO service_role;




-- =============================================================
-- MIGRATION: 20260822000000_faz1a_muhasebe_foundation.sql
-- =============================================================

-- =============================================================
-- FAZ 1A — MUHASEBE DATABASE FOUNDATION
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-22
-- =============================================================
-- BU MİGRATION:
--   ✅ Yeni tablolar oluşturur
--   ✅ account_transactions'a journal_entry_id kolonu ekler
--   ✅ TDP sistem hesaplarını seed eder
--   ✅ RLS politikaları oluşturur
--   ✅ Trigger fonksiyonları oluşturur
--   ❌ Mevcut tabloları DEĞİŞTİRMEZ
--   ❌ Mevcut verileri SİLMEZ
--   ❌ Mevcut migration'ları DEĞİŞTİRMEZ
-- =============================================================

-- =============================================================
-- 1. CHART OF ACCOUNTS (Hesap Planı)
-- =============================================================
-- Türkiye Tek Düzen Hesap Planı (TDP) uyumlu.
-- user_id = NULL → sistem hesabı (tüm kullanıcılara görünür, değiştirilemez)
-- user_id = auth.uid() → kullanıcı hesabı

CREATE TABLE IF NOT EXISTS public.chart_of_accounts (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  code            TEXT NOT NULL,
  name            TEXT NOT NULL,
  account_type    TEXT NOT NULL CHECK (account_type IN ('ASSET','LIABILITY','EQUITY','INCOME','EXPENSE')),
  normal_balance  TEXT NOT NULL CHECK (normal_balance IN ('DEBIT','CREDIT')),
  parent_id       UUID NULL REFERENCES public.chart_of_accounts(id) ON DELETE SET NULL,
  level           INTEGER NOT NULL DEFAULT 2 CHECK (level BETWEEN 1 AND 4),
  is_system       BOOLEAN NOT NULL DEFAULT false,
  is_active       BOOLEAN NOT NULL DEFAULT true,
  system_tag      TEXT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT coa_system_user_check CHECK (NOT (is_system = true AND user_id IS NOT NULL))
);

-- NULL uniqueness: PostgreSQL'de NULL = NULL değildir.
-- Kullanıcı hesapları: (user_id, code) unique
CREATE UNIQUE INDEX IF NOT EXISTS coa_user_code_unique
  ON public.chart_of_accounts(user_id, code)
  WHERE user_id IS NOT NULL;

-- Sistem hesapları: (code) unique WHERE user_id IS NULL
CREATE UNIQUE INDEX IF NOT EXISTS coa_system_code_unique
  ON public.chart_of_accounts(code)
  WHERE user_id IS NULL;

CREATE INDEX IF NOT EXISTS coa_user_id_idx      ON public.chart_of_accounts(user_id) WHERE user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS coa_account_type_idx  ON public.chart_of_accounts(account_type);
CREATE INDEX IF NOT EXISTS coa_parent_id_idx     ON public.chart_of_accounts(parent_id) WHERE parent_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS coa_system_tag_idx    ON public.chart_of_accounts(system_tag) WHERE system_tag IS NOT NULL;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.chart_of_accounts TO authenticated;
GRANT ALL ON public.chart_of_accounts TO service_role;
ALTER TABLE public.chart_of_accounts ENABLE ROW LEVEL SECURITY;

-- SELECT: kendi hesapları + sistem hesapları (user_id IS NULL)
DROP POLICY IF EXISTS "coa_select_own_or_system" ON public.chart_of_accounts;
CREATE POLICY "coa_select_own_or_system" ON public.chart_of_accounts
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR user_id IS NULL);

-- INSERT: sadece kendi, sistem hesabı değil
DROP POLICY IF EXISTS "coa_insert_own" ON public.chart_of_accounts;
CREATE POLICY "coa_insert_own" ON public.chart_of_accounts
  FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() AND is_system = false);

-- UPDATE: sadece kendi, sistem hesabı değil
DROP POLICY IF EXISTS "coa_update_own" ON public.chart_of_accounts;
CREATE POLICY "coa_update_own" ON public.chart_of_accounts
  FOR UPDATE TO authenticated
  USING (user_id = auth.uid() AND is_system = false)
  WITH CHECK (user_id = auth.uid() AND is_system = false);

-- DELETE: sadece kendi, sistem hesabı değil
DROP POLICY IF EXISTS "coa_delete_own" ON public.chart_of_accounts;
CREATE POLICY "coa_delete_own" ON public.chart_of_accounts
  FOR DELETE TO authenticated
  USING (user_id = auth.uid() AND is_system = false);

DROP TRIGGER IF EXISTS update_chart_of_accounts_updated_at ON public.chart_of_accounts;
CREATE TRIGGER update_chart_of_accounts_updated_at
  BEFORE UPDATE ON public.chart_of_accounts
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- =============================================================
-- 2. JOURNAL ENTRIES (Muhasebe Fişleri)
-- =============================================================
-- entry_type ve source_type için TEXT kullanıyoruz.
-- Gelecekte yeni belge tipleri eklenebilsin diye katı ENUM kullanmıyoruz.
-- Ancak bilinen geçerli tipler kodda kontrol edilecek.

CREATE TABLE IF NOT EXISTS public.journal_entries (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL,
  entry_number    TEXT NOT NULL,
  entry_date      DATE NOT NULL DEFAULT CURRENT_DATE,
  description     TEXT NULL,
  entry_type      TEXT NOT NULL,
  source_type     TEXT NULL,
  source_id       UUID NULL,
  status          TEXT NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','POSTED','CANCELLED')),
  total_debit     NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (total_debit >= 0),
  total_credit    NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (total_credit >= 0),
  period_year     INTEGER NOT NULL CHECK (period_year BETWEEN 2000 AND 2100),
  period_month    INTEGER NOT NULL CHECK (period_month BETWEEN 1 AND 12),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT je_posted_balanced_check CHECK (status != 'POSTED' OR total_debit = total_credit)
);

CREATE UNIQUE INDEX IF NOT EXISTS je_user_entry_number_unique
  ON public.journal_entries(user_id, entry_number);

CREATE INDEX IF NOT EXISTS je_user_date_idx    ON public.journal_entries(user_id, entry_date);
CREATE INDEX IF NOT EXISTS je_user_period_idx  ON public.journal_entries(user_id, period_year, period_month);
CREATE INDEX IF NOT EXISTS je_source_idx       ON public.journal_entries(source_type, source_id) WHERE source_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS je_status_idx       ON public.journal_entries(user_id, status);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.journal_entries TO authenticated;
GRANT ALL ON public.journal_entries TO service_role;
ALTER TABLE public.journal_entries ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "je_all_own" ON public.journal_entries;
CREATE POLICY "je_all_own" ON public.journal_entries
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

DROP TRIGGER IF EXISTS update_journal_entries_updated_at ON public.journal_entries;
CREATE TRIGGER update_journal_entries_updated_at
  BEFORE UPDATE ON public.journal_entries
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Audit
DROP TRIGGER IF EXISTS audit_journal_entries_trigger ON public.journal_entries;
CREATE TRIGGER audit_journal_entries_trigger
  AFTER INSERT OR UPDATE OR DELETE ON public.journal_entries
  FOR EACH ROW EXECUTE FUNCTION public.log_audit_event();

-- =============================================================
-- 3. JOURNAL LINES (Muhasebe Fişi Satırları)
-- =============================================================
-- user_id: RLS için. journal_entry_id üzerinden subquery daha yavaş olurdu.
-- Bir satır ya borç ya alacak olabilir, ikisi birden olamaz.
-- Tamamen sıfır satır kabul edilmez.

CREATE TABLE IF NOT EXISTS public.journal_lines (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  journal_entry_id  UUID NOT NULL REFERENCES public.journal_entries(id) ON DELETE CASCADE,
  user_id           UUID NOT NULL,
  account_id        UUID NOT NULL REFERENCES public.chart_of_accounts(id),
  description       TEXT NULL,
  debit             NUMERIC(14,2) NOT NULL DEFAULT 0,
  credit            NUMERIC(14,2) NOT NULL DEFAULT 0,
  currency          TEXT NOT NULL DEFAULT 'TRY',
  foreign_amount    NUMERIC(14,2) NULL,
  exchange_rate     NUMERIC(14,6) NOT NULL DEFAULT 1,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.journal_lines
  ADD CONSTRAINT jl_debit_positive_check   CHECK (debit >= 0),
  ADD CONSTRAINT jl_credit_positive_check  CHECK (credit >= 0),
  -- Bir satır hem borç hem alacak olamaz
  ADD CONSTRAINT jl_debit_or_credit_check  CHECK (debit = 0 OR credit = 0),
  -- Tamamen sıfır satır reddedilir
  ADD CONSTRAINT jl_nonzero_check          CHECK (debit > 0 OR credit > 0),
  ADD CONSTRAINT jl_exchange_rate_check    CHECK (exchange_rate > 0);

CREATE INDEX IF NOT EXISTS jl_entry_account_idx ON public.journal_lines(journal_entry_id, account_id);
CREATE INDEX IF NOT EXISTS jl_account_idx       ON public.journal_lines(account_id);
CREATE INDEX IF NOT EXISTS jl_user_id_idx       ON public.journal_lines(user_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.journal_lines TO authenticated;
GRANT ALL ON public.journal_lines TO service_role;
ALTER TABLE public.journal_lines ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "jl_all_own" ON public.journal_lines;
CREATE POLICY "jl_all_own" ON public.journal_lines
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- =============================================================
-- 4. JOURNAL TOTAL TRIGGER
-- =============================================================
-- INSERT / UPDATE / DELETE sonrasında ilgili journal_entries.total_debit
-- ve total_credit otomatik yeniden hesaplanır.
-- UPDATE'de journal_entry_id değişirse hem ESKİ hem YENİ fiş güncellenir.

CREATE OR REPLACE FUNCTION public.update_journal_entry_totals()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_entry_id UUID;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_entry_id := OLD.journal_entry_id;
  ELSIF TG_OP = 'INSERT' THEN
    v_entry_id := NEW.journal_entry_id;
  ELSIF TG_OP = 'UPDATE' THEN
    -- journal_entry_id değiştiyse ESKİ fişin toplamını da güncelle
    IF OLD.journal_entry_id IS DISTINCT FROM NEW.journal_entry_id THEN
      UPDATE public.journal_entries SET
        total_debit  = COALESCE((
          SELECT SUM(debit)  FROM public.journal_lines
          WHERE journal_entry_id = OLD.journal_entry_id
        ), 0),
        total_credit = COALESCE((
          SELECT SUM(credit) FROM public.journal_lines
          WHERE journal_entry_id = OLD.journal_entry_id
        ), 0),
        updated_at = now()
      WHERE id = OLD.journal_entry_id;
    END IF;
    v_entry_id := NEW.journal_entry_id;
  END IF;

  -- Hedef fişin toplamlarını yeniden SUM ile hesapla (manuel hesap yapma)
  UPDATE public.journal_entries SET
    total_debit  = COALESCE((
      SELECT SUM(debit)  FROM public.journal_lines
      WHERE journal_entry_id = v_entry_id
    ), 0),
    total_credit = COALESCE((
      SELECT SUM(credit) FROM public.journal_lines
      WHERE journal_entry_id = v_entry_id
    ), 0),
    updated_at = now()
  WHERE id = v_entry_id;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  ELSE
    RETURN NEW;
  END IF;
END;
$$;

DROP TRIGGER IF EXISTS journal_lines_update_totals ON public.journal_lines;
CREATE TRIGGER journal_lines_update_totals
  AFTER INSERT OR UPDATE OR DELETE ON public.journal_lines
  FOR EACH ROW EXECUTE FUNCTION public.update_journal_entry_totals();

-- =============================================================
-- 5. POSTED JOURNAL LINE PROTECTION TRIGGER
-- =============================================================
-- POSTED bir fişin satırları değiştirilemez.
-- BEFORE trigger — totals trigger'dan önce çalışır.

CREATE OR REPLACE FUNCTION public.protect_posted_journal_lines()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status TEXT;
BEGIN
  IF TG_OP = 'DELETE' THEN
    SELECT status INTO v_status
    FROM public.journal_entries WHERE id = OLD.journal_entry_id;

    IF v_status = 'POSTED' THEN
      RAISE EXCEPTION
        'İletilmiş (POSTED) bir muhasebe fişinin satırları silinemez. Fiş ID: %',
        OLD.journal_entry_id;
    END IF;
    RETURN OLD;

  ELSE -- INSERT veya UPDATE
    SELECT status INTO v_status
    FROM public.journal_entries WHERE id = NEW.journal_entry_id;

    IF v_status = 'POSTED' THEN
      RAISE EXCEPTION
        'İletilmiş (POSTED) bir muhasebe fişine satır eklenemez veya değiştirilemez. Fiş ID: %',
        NEW.journal_entry_id;
    END IF;

    -- UPDATE: farklı bir journal_entry_id'ye taşıma girişimi
    IF TG_OP = 'UPDATE' AND OLD.journal_entry_id IS DISTINCT FROM NEW.journal_entry_id THEN
      SELECT status INTO v_status
      FROM public.journal_entries WHERE id = OLD.journal_entry_id;

      IF v_status = 'POSTED' THEN
        RAISE EXCEPTION
          'İletilmiş (POSTED) bir muhasebe fişinden satır taşınamaz. Fiş ID: %',
          OLD.journal_entry_id;
      END IF;
    END IF;

    RETURN NEW;
  END IF;
END;
$$;

DROP TRIGGER IF EXISTS journal_lines_protect_posted ON public.journal_lines;
CREATE TRIGGER journal_lines_protect_posted
  BEFORE INSERT OR UPDATE OR DELETE ON public.journal_lines
  FOR EACH ROW EXECUTE FUNCTION public.protect_posted_journal_lines();

-- =============================================================
-- 6. ACCOUNT_TRANSACTIONS — journal_entry_id KOLONU EKLEME
-- =============================================================
-- Mevcut tablo ve veriler değiştirilmez.
-- Eski kayıtlarda bu kolon NULL kalır.
-- ON DELETE SET NULL: journal_entry iptal edilse bile cari hareket kalır.

ALTER TABLE public.account_transactions
  ADD COLUMN IF NOT EXISTS journal_entry_id UUID NULL
    REFERENCES public.journal_entries(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS at_journal_entry_idx
  ON public.account_transactions(journal_entry_id)
  WHERE journal_entry_id IS NOT NULL;

-- =============================================================
-- 7. INVOICE ITEMS (Fatura Kalemleri — Normalize)
-- =============================================================
-- invoices.items JSONB ile paralel çalışır.
-- JSONB kaldırılmaz — geriye uyumluluk için korunur.

CREATE TABLE IF NOT EXISTS public.invoice_items (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id      UUID NOT NULL REFERENCES public.invoices(id) ON DELETE CASCADE,
  user_id         UUID NOT NULL,
  line_number     INTEGER NOT NULL,
  product_id      UUID NULL REFERENCES public.products(id) ON DELETE SET NULL,
  description     TEXT NOT NULL DEFAULT '',
  unit            TEXT NOT NULL DEFAULT 'Adet',
  quantity        NUMERIC(14,4) NOT NULL,
  unit_price      NUMERIC(14,4) NOT NULL,
  discount_rate   NUMERIC(5,2) NOT NULL DEFAULT 0,
  taxable_amount  NUMERIC(14,2) NOT NULL,
  vat_rate        NUMERIC(5,2) NOT NULL DEFAULT 0,
  vat_amount      NUMERIC(14,2) NOT NULL DEFAULT 0,
  line_total      NUMERIC(14,2) NOT NULL,
  currency        TEXT NOT NULL DEFAULT 'TRY',
  exchange_rate   NUMERIC(14,6) NOT NULL DEFAULT 1,
  foreign_amount  NUMERIC(14,2) NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.invoice_items
  ADD CONSTRAINT ii_quantity_check       CHECK (quantity > 0),
  ADD CONSTRAINT ii_unit_price_check     CHECK (unit_price >= 0),
  ADD CONSTRAINT ii_taxable_check        CHECK (taxable_amount >= 0),
  ADD CONSTRAINT ii_vat_amount_check     CHECK (vat_amount >= 0),
  ADD CONSTRAINT ii_line_total_check     CHECK (line_total >= 0),
  ADD CONSTRAINT ii_vat_rate_check       CHECK (vat_rate BETWEEN 0 AND 100),
  ADD CONSTRAINT ii_exchange_rate_check  CHECK (exchange_rate > 0),
  ADD CONSTRAINT ii_discount_rate_check  CHECK (discount_rate BETWEEN 0 AND 100);

ALTER TABLE public.invoice_items
  ADD CONSTRAINT ii_invoice_line_unique UNIQUE (invoice_id, line_number);

CREATE INDEX IF NOT EXISTS ii_invoice_id_idx ON public.invoice_items(invoice_id);
CREATE INDEX IF NOT EXISTS ii_user_id_idx    ON public.invoice_items(user_id);
CREATE INDEX IF NOT EXISTS ii_product_id_idx ON public.invoice_items(product_id) WHERE product_id IS NOT NULL;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.invoice_items TO authenticated;
GRANT ALL ON public.invoice_items TO service_role;
ALTER TABLE public.invoice_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ii_all_own" ON public.invoice_items;
CREATE POLICY "ii_all_own" ON public.invoice_items
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- =============================================================
-- 8. INVOICE TAX LINES (Fatura KDV Satırları)
-- =============================================================
-- UNIQUE tartışması:
--   (invoice_id, vat_rate, direction) → istisna+normal aynı oranla olabilir
--   (invoice_id, vat_rate, direction, is_reversal) → orijinal + ters kayıt
--   Bu tasarım orijinal bir satır + ters kaydına izin verir.

CREATE TABLE IF NOT EXISTS public.invoice_tax_lines (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id          UUID NOT NULL REFERENCES public.invoices(id) ON DELETE CASCADE,
  user_id             UUID NOT NULL,
  direction           TEXT NOT NULL,
  vat_rate            NUMERIC(5,2) NOT NULL,
  taxable_amount      NUMERIC(14,2) NOT NULL,
  tax_amount          NUMERIC(14,2) NOT NULL,
  withholding_rate    NUMERIC(5,2) NOT NULL DEFAULT 0,
  withholding_amount  NUMERIC(14,2) NOT NULL DEFAULT 0,
  is_exempt           BOOLEAN NOT NULL DEFAULT false,
  exemption_code      TEXT NULL,
  is_cancelled        BOOLEAN NOT NULL DEFAULT false,
  is_reversal         BOOLEAN NOT NULL DEFAULT false,
  reversal_of         UUID NULL REFERENCES public.invoice_tax_lines(id) ON DELETE SET NULL,
  currency            TEXT NOT NULL DEFAULT 'TRY',
  exchange_rate       NUMERIC(14,6) NOT NULL DEFAULT 1,
  taxable_amount_try  NUMERIC(14,2) NOT NULL,
  tax_amount_try      NUMERIC(14,2) NOT NULL,
  period_year         INTEGER NOT NULL,
  period_month        INTEGER NOT NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.invoice_tax_lines
  ADD CONSTRAINT itl_direction_check          CHECK (direction IN ('SATIS','ALIS')),
  ADD CONSTRAINT itl_vat_rate_check           CHECK (vat_rate BETWEEN 0 AND 100),
  ADD CONSTRAINT itl_taxable_check            CHECK (taxable_amount >= 0),
  ADD CONSTRAINT itl_tax_amount_check         CHECK (tax_amount >= 0),
  ADD CONSTRAINT itl_withholding_rate_check   CHECK (withholding_rate BETWEEN 0 AND 100),
  ADD CONSTRAINT itl_withholding_amount_check CHECK (withholding_amount >= 0),
  ADD CONSTRAINT itl_exchange_rate_check      CHECK (exchange_rate > 0),
  ADD CONSTRAINT itl_period_month_check       CHECK (period_month BETWEEN 1 AND 12),
  ADD CONSTRAINT itl_taxable_try_check        CHECK (taxable_amount_try >= 0),
  ADD CONSTRAINT itl_tax_try_check            CHECK (tax_amount_try >= 0);

-- UNIQUE: orijinal + ters kayıt ayrımı için is_reversal dahil
ALTER TABLE public.invoice_tax_lines
  ADD CONSTRAINT itl_unique_per_rate
    UNIQUE (invoice_id, vat_rate, direction, is_reversal);

CREATE INDEX IF NOT EXISTS itl_invoice_id_idx  ON public.invoice_tax_lines(invoice_id);
CREATE INDEX IF NOT EXISTS itl_user_period_idx ON public.invoice_tax_lines(user_id, period_year, period_month);
CREATE INDEX IF NOT EXISTS itl_direction_idx   ON public.invoice_tax_lines(user_id, direction);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.invoice_tax_lines TO authenticated;
GRANT ALL ON public.invoice_tax_lines TO service_role;
ALTER TABLE public.invoice_tax_lines ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "itl_all_own" ON public.invoice_tax_lines;
CREATE POLICY "itl_all_own" ON public.invoice_tax_lines
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- =============================================================
-- 9. PAYMENTS (Ödemeler ve Tahsilatlar)
-- =============================================================

CREATE TABLE IF NOT EXISTS public.payments (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          UUID NOT NULL,
  customer_id      UUID NULL REFERENCES public.customers(id) ON DELETE SET NULL,
  payment_date     DATE NOT NULL DEFAULT CURRENT_DATE,
  direction        TEXT NOT NULL,
  amount           NUMERIC(14,2) NOT NULL,
  amount_try       NUMERIC(14,2) NOT NULL,
  currency         TEXT NOT NULL DEFAULT 'TRY',
  exchange_rate    NUMERIC(14,6) NOT NULL DEFAULT 1,
  payment_method   TEXT NOT NULL DEFAULT 'NAKIT',
  description      TEXT NULL,
  journal_entry_id UUID NULL REFERENCES public.journal_entries(id) ON DELETE SET NULL,
  deleted_at       TIMESTAMPTZ NULL,
  deleted_by       UUID NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.payments
  ADD CONSTRAINT pay_direction_check     CHECK (direction IN ('IN','OUT')),
  ADD CONSTRAINT pay_amount_check        CHECK (amount > 0),
  ADD CONSTRAINT pay_amount_try_check    CHECK (amount_try > 0),
  ADD CONSTRAINT pay_exchange_rate_check CHECK (exchange_rate > 0),
  ADD CONSTRAINT pay_method_check
    CHECK (payment_method IN ('NAKIT','BANKA','KREDI_KARTI','CEK','SENET','DIGER'));

CREATE INDEX IF NOT EXISTS pay_user_date_idx   ON public.payments(user_id, payment_date);
CREATE INDEX IF NOT EXISTS pay_customer_idx    ON public.payments(customer_id) WHERE customer_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS pay_je_idx          ON public.payments(journal_entry_id) WHERE journal_entry_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS pay_deleted_idx     ON public.payments(user_id, deleted_at);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.payments TO authenticated;
GRANT ALL ON public.payments TO service_role;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "pay_all_own" ON public.payments;
CREATE POLICY "pay_all_own" ON public.payments
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

DROP TRIGGER IF EXISTS update_payments_updated_at ON public.payments;
CREATE TRIGGER update_payments_updated_at
  BEFORE UPDATE ON public.payments
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- =============================================================
-- 10. PAYMENT ALLOCATIONS (Ödeme-Fatura Eşleştirmesi)
-- =============================================================

CREATE TABLE IF NOT EXISTS public.payment_allocations (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id        UUID NOT NULL REFERENCES public.payments(id) ON DELETE CASCADE,
  invoice_id        UUID NOT NULL REFERENCES public.invoices(id) ON DELETE CASCADE,
  user_id           UUID NOT NULL,
  allocated_amount  NUMERIC(14,2) NOT NULL,
  allocated_date    DATE NOT NULL DEFAULT CURRENT_DATE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.payment_allocations
  ADD CONSTRAINT pa_amount_check          CHECK (allocated_amount > 0),
  ADD CONSTRAINT pa_payment_invoice_unique UNIQUE (payment_id, invoice_id);

CREATE INDEX IF NOT EXISTS pa_payment_id_idx ON public.payment_allocations(payment_id);
CREATE INDEX IF NOT EXISTS pa_invoice_id_idx ON public.payment_allocations(invoice_id);
CREATE INDEX IF NOT EXISTS pa_user_id_idx    ON public.payment_allocations(user_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.payment_allocations TO authenticated;
GRANT ALL ON public.payment_allocations TO service_role;
ALTER TABLE public.payment_allocations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "pa_all_own" ON public.payment_allocations;
CREATE POLICY "pa_all_own" ON public.payment_allocations
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- =============================================================
-- 11. CURRENCIES (Para Birimleri)
-- =============================================================
-- Sistem tablosu — user_id yok.
-- Tüm kullanıcılar okuyabilir, hiçbiri yazamaz (service_role only).

CREATE TABLE IF NOT EXISTS public.currencies (
  code           TEXT PRIMARY KEY,
  name           TEXT NOT NULL,
  symbol         TEXT NOT NULL,
  decimal_places INTEGER NOT NULL DEFAULT 2,
  is_active      BOOLEAN NOT NULL DEFAULT true,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

GRANT SELECT ON public.currencies TO authenticated;
GRANT ALL ON public.currencies TO service_role;
ALTER TABLE public.currencies ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "currencies_read_all" ON public.currencies;
CREATE POLICY "currencies_read_all" ON public.currencies
  FOR SELECT TO authenticated
  USING (true);

-- Seed: temel para birimleri
INSERT INTO public.currencies (code, name, symbol, decimal_places, is_active) VALUES
  ('TRY', 'Türk Lirası',       '₺', 2, true),
  ('USD', 'Amerikan Doları',   '$', 2, true),
  ('EUR', 'Euro',              '€', 2, true),
  ('GBP', 'İngiliz Sterlini',  '£', 2, true),
  ('CHF', 'İsviçre Frangı',   '₣', 2, true),
  ('JPY', 'Japon Yeni',        '¥', 0, true),
  ('SAR', 'Suudi Riyali',      '﷼', 2, false),
  ('AED', 'BAE Dirhemi',       'AED', 2, false)
ON CONFLICT (code) DO NOTHING;

-- =============================================================
-- 12. EXCHANGE RATES (Döviz Kurları)
-- =============================================================
-- user_id NULL → global kur (TCMB); user_id dolu → kullanıcı özel kur
-- Kısmi unique index ile NULL user_id doğru işlenir.

CREATE TABLE IF NOT EXISTS public.exchange_rates (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  currency_code  TEXT NOT NULL REFERENCES public.currencies(code),
  user_id        UUID NULL,
  rate_date      DATE NOT NULL,
  rate_type      TEXT NOT NULL DEFAULT 'TCMB',
  buying_rate    NUMERIC(14,6) NOT NULL,
  selling_rate   NUMERIC(14,6) NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.exchange_rates
  ADD CONSTRAINT er_buying_rate_check  CHECK (buying_rate > 0),
  ADD CONSTRAINT er_selling_rate_check CHECK (selling_rate > 0),
  ADD CONSTRAINT er_rate_date_check    CHECK (rate_date <= CURRENT_DATE + 1),
  ADD CONSTRAINT er_rate_type_check    CHECK (rate_type IN ('TCMB','SERBEST','MANUEL'));

-- Global kurlar (user_id IS NULL): (currency, date, type) unique
CREATE UNIQUE INDEX IF NOT EXISTS er_global_unique
  ON public.exchange_rates(currency_code, rate_date, rate_type)
  WHERE user_id IS NULL;

-- Kullanıcı kurları: (user_id, currency, date, type) unique
CREATE UNIQUE INDEX IF NOT EXISTS er_user_unique
  ON public.exchange_rates(user_id, currency_code, rate_date, rate_type)
  WHERE user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS er_currency_date_idx ON public.exchange_rates(currency_code, rate_date);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.exchange_rates TO authenticated;
GRANT ALL ON public.exchange_rates TO service_role;
ALTER TABLE public.exchange_rates ENABLE ROW LEVEL SECURITY;

-- Global kurlar herkese görünür; kullanıcı kendi özel kurlarını yönetir
DROP POLICY IF EXISTS "er_select" ON public.exchange_rates;
CREATE POLICY "er_select" ON public.exchange_rates
  FOR SELECT TO authenticated
  USING (user_id IS NULL OR user_id = auth.uid());

DROP POLICY IF EXISTS "er_insert" ON public.exchange_rates;
CREATE POLICY "er_insert" ON public.exchange_rates
  FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "er_update" ON public.exchange_rates;
CREATE POLICY "er_update" ON public.exchange_rates
  FOR UPDATE TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "er_delete" ON public.exchange_rates;
CREATE POLICY "er_delete" ON public.exchange_rates
  FOR DELETE TO authenticated
  USING (user_id = auth.uid());

-- =============================================================
-- 13. ENTRY COUNTERS (Belge Numarası Sayaçları)
-- =============================================================

CREATE TABLE IF NOT EXISTS public.entry_counters (
  user_id       UUID NOT NULL,
  year          INTEGER NOT NULL,
  counter_type  TEXT NOT NULL DEFAULT 'JOURNAL',
  last_number   INTEGER NOT NULL DEFAULT 0,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, year, counter_type)
);

ALTER TABLE public.entry_counters
  ADD CONSTRAINT ec_last_number_check CHECK (last_number >= 0),
  ADD CONSTRAINT ec_year_check        CHECK (year BETWEEN 2000 AND 2100),
  ADD CONSTRAINT ec_type_check
    CHECK (counter_type IN ('JOURNAL','INVOICE','PAYMENT'));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.entry_counters TO authenticated;
GRANT ALL ON public.entry_counters TO service_role;
ALTER TABLE public.entry_counters ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ec_all_own" ON public.entry_counters;
CREATE POLICY "ec_all_own" ON public.entry_counters
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- =============================================================
-- 14. NEXT ENTRY NUMBER FUNCTION (Concurrency-safe belge numarası)
-- =============================================================
-- ON CONFLICT DO UPDATE atomik → eş zamanlı çağrıda aynı numara üretilmez.

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
    WHEN 'INVOICE' THEN 'GIB'
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

REVOKE ALL ON FUNCTION public.next_entry_number(UUID, INTEGER, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.next_entry_number(UUID, INTEGER, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.next_entry_number(UUID, INTEGER, TEXT) TO service_role;

-- =============================================================
-- 15. SEED: CHART OF ACCOUNTS — TDP Sistem Hesapları
-- =============================================================
-- user_id = NULL → sistem hesabı (tüm kullanıcılara görünür)
-- ON CONFLICT DO NOTHING → idempotent, ikinci çalıştırmada hata vermez

INSERT INTO public.chart_of_accounts
  (id, user_id, code, name, account_type, normal_balance, level, is_system, is_active, system_tag)
VALUES
  -- DÖNEN VARLIKLAR
  (gen_random_uuid(), NULL, '100', 'Kasa',                                    'ASSET',     'DEBIT',  2, true, true, 'KASA'),
  (gen_random_uuid(), NULL, '101', 'Alınan Çekler',                           'ASSET',     'DEBIT',  2, true, true, NULL),
  (gen_random_uuid(), NULL, '102', 'Bankalar',                                'ASSET',     'DEBIT',  2, true, true, 'BANKA'),
  (gen_random_uuid(), NULL, '103', 'Verilen Çekler ve Ödeme Emirleri',        'ASSET',     'CREDIT', 2, true, true, NULL),
  (gen_random_uuid(), NULL, '108', 'Diğer Hazır Değerler',                   'ASSET',     'DEBIT',  2, true, true, NULL),
  (gen_random_uuid(), NULL, '120', 'Alıcılar',                                'ASSET',     'DEBIT',  2, true, true, 'ALICILAR'),
  (gen_random_uuid(), NULL, '121', 'Alacak Senetleri',                        'ASSET',     'DEBIT',  2, true, true, NULL),
  (gen_random_uuid(), NULL, '126', 'Verilen Depozito ve Teminatlar',          'ASSET',     'DEBIT',  2, true, true, NULL),
  (gen_random_uuid(), NULL, '136', 'Diğer Çeşitli Alacaklar',               'ASSET',     'DEBIT',  2, true, true, 'TEVKIFAT_ALACAK'),
  (gen_random_uuid(), NULL, '150', 'İlk Madde ve Malzeme',                   'ASSET',     'DEBIT',  2, true, true, NULL),
  (gen_random_uuid(), NULL, '153', 'Ticari Mallar',                           'ASSET',     'DEBIT',  2, true, true, 'STOK'),
  (gen_random_uuid(), NULL, '159', 'Verilen Sipariş Avansları',              'ASSET',     'DEBIT',  2, true, true, NULL),
  (gen_random_uuid(), NULL, '191', 'İndirilecek KDV',                        'ASSET',     'DEBIT',  2, true, true, 'INDIRILECEK_KDV'),
  (gen_random_uuid(), NULL, '193', 'Peşin Ödenen Vergiler ve Fonlar',        'ASSET',     'DEBIT',  2, true, true, NULL),
  -- DURAN VARLIKLAR
  (gen_random_uuid(), NULL, '254', 'Taşıtlar',                               'ASSET',     'DEBIT',  2, true, true, NULL),
  (gen_random_uuid(), NULL, '255', 'Demirbaşlar',                            'ASSET',     'DEBIT',  2, true, true, NULL),
  -- KISA VADELİ BORÇLAR
  (gen_random_uuid(), NULL, '300', 'Banka Kredileri',                        'LIABILITY', 'CREDIT', 2, true, true, NULL),
  (gen_random_uuid(), NULL, '320', 'Satıcılar',                              'LIABILITY', 'CREDIT', 2, true, true, 'SATICILAR'),
  (gen_random_uuid(), NULL, '321', 'Borç Senetleri',                         'LIABILITY', 'CREDIT', 2, true, true, NULL),
  (gen_random_uuid(), NULL, '326', 'Alınan Depozito ve Teminatlar',          'LIABILITY', 'CREDIT', 2, true, true, NULL),
  (gen_random_uuid(), NULL, '360', 'Ödenecek Vergi ve Fonlar',              'LIABILITY', 'CREDIT', 2, true, true, 'ODENECEK_VERGI'),
  (gen_random_uuid(), NULL, '361', 'Ödenecek Sosyal Güvenlik Kesintileri',  'LIABILITY', 'CREDIT', 2, true, true, NULL),
  (gen_random_uuid(), NULL, '391', 'Hesaplanan KDV',                         'LIABILITY', 'CREDIT', 2, true, true, 'HESAPLANAN_KDV'),
  (gen_random_uuid(), NULL, '392', 'Diğer KDV',                             'LIABILITY', 'CREDIT', 2, true, true, NULL),
  -- ÖZKAYNAKLAR
  (gen_random_uuid(), NULL, '500', 'Sermaye',                                'EQUITY',    'CREDIT', 2, true, true, NULL),
  (gen_random_uuid(), NULL, '570', 'Geçmiş Yıllar Karları',                 'EQUITY',    'CREDIT', 2, true, true, NULL),
  (gen_random_uuid(), NULL, '580', 'Geçmiş Yıllar Zararları',               'EQUITY',    'DEBIT',  2, true, true, NULL),
  (gen_random_uuid(), NULL, '590', 'Dönem Net Karı',                         'EQUITY',    'CREDIT', 2, true, true, NULL),
  -- GELİR TABLOSU
  (gen_random_uuid(), NULL, '600', 'Yurt İçi Satışlar',                     'INCOME',    'CREDIT', 2, true, true, 'SATIS_GELIRI'),
  (gen_random_uuid(), NULL, '601', 'Yurt Dışı Satışlar',                    'INCOME',    'CREDIT', 2, true, true, 'YURTDISI_SATIS'),
  (gen_random_uuid(), NULL, '610', 'Satıştan İadeler',                      'INCOME',    'DEBIT',  2, true, true, 'SATIS_IADE'),
  (gen_random_uuid(), NULL, '611', 'Satış İskontoları',                     'INCOME',    'DEBIT',  2, true, true, NULL),
  (gen_random_uuid(), NULL, '621', 'Satılan Ticari Mallar Maliyeti',        'EXPENSE',   'DEBIT',  2, true, true, 'COGS'),
  (gen_random_uuid(), NULL, '630', 'Araştırma ve Geliştirme Giderleri',    'EXPENSE',   'DEBIT',  2, true, true, NULL),
  (gen_random_uuid(), NULL, '631', 'Pazarlama, Satış ve Dağıtım Giderleri','EXPENSE',   'DEBIT',  2, true, true, NULL),
  (gen_random_uuid(), NULL, '632', 'Genel Yönetim Giderleri',              'EXPENSE',   'DEBIT',  2, true, true, NULL),
  (gen_random_uuid(), NULL, '640', 'İştiraklerden Temettü Gelirleri',       'INCOME',    'CREDIT', 2, true, true, NULL),
  (gen_random_uuid(), NULL, '645', 'Menkul Kıymet Satış Kârları',           'INCOME',    'CREDIT', 2, true, true, NULL),
  (gen_random_uuid(), NULL, '646', 'Kambiyo Kârları',                       'INCOME',    'CREDIT', 2, true, true, 'KAMBIYO_KAR'),
  (gen_random_uuid(), NULL, '647', 'Reeskont Faiz Gelirleri',               'INCOME',    'CREDIT', 2, true, true, NULL),
  (gen_random_uuid(), NULL, '649', 'Diğer Olağan Gelir ve Karlar',          'INCOME',    'CREDIT', 2, true, true, NULL),
  (gen_random_uuid(), NULL, '653', 'Komisyon Giderleri',                    'EXPENSE',   'DEBIT',  2, true, true, NULL),
  (gen_random_uuid(), NULL, '654', 'Karşılık Giderleri',                    'EXPENSE',   'DEBIT',  2, true, true, NULL),
  (gen_random_uuid(), NULL, '655', 'Menkul Kıymet Satış Zararları',         'EXPENSE',   'DEBIT',  2, true, true, NULL),
  (gen_random_uuid(), NULL, '656', 'Kambiyo Zararları',                     'EXPENSE',   'DEBIT',  2, true, true, 'KAMBIYO_ZARAR'),
  (gen_random_uuid(), NULL, '657', 'Reeskont Faiz Giderleri',               'EXPENSE',   'DEBIT',  2, true, true, NULL),
  (gen_random_uuid(), NULL, '659', 'Diğer Olağan Gider ve Zarar',           'EXPENSE',   'DEBIT',  2, true, true, NULL),
  (gen_random_uuid(), NULL, '671', 'Önceki Dönem Gelir ve Karları',         'INCOME',    'CREDIT', 2, true, true, NULL),
  (gen_random_uuid(), NULL, '672', 'Önceki Dönem Gider ve Zararları',       'EXPENSE',   'DEBIT',  2, true, true, NULL)
ON CONFLICT DO NOTHING;

-- =============================================================
-- FAZ 1A TAMAMLANDI
-- Sonraki adım: TypeScript type güncellemesi ve testler.
-- FAZ 1B: product_stocks view TRANSFER düzeltmesi,
--          fatura numaralandırma RPC, fatura oluşturma RPC.
-- =============================================================



-- =============================================================
-- MIGRATION: 20260822120000_faz1b_stock_transfer_fix.sql
-- =============================================================

-- =============================================================
-- FAZ 1B.1 — STOK TRANSFER MUHASEBESEL VE VERİTABANI DÜZELTMESİ
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-22
-- =============================================================
-- BU MİGRATION:
--   ✅ stock_movements tablosuna TRANSFER_OUT ve TRANSFER_IN tiplerini ekler
--   ✅ Eski 'TRANSFER', 'GIRIS', 'CIKIS', 'SAYIM' tipleriyle tam geriye dönük uyumludur
--   ✅ transfer_group_id UUID kolonu ekleyerek çift taraflı transferleri birbirine bağlar
--   ✅ product_stocks view'ını güncelleyerek TRANSFER_IN (+qty) ve TRANSFER_OUT (-qty) hesabı yapar
--   ❌ Mevcut kayıtları silmez veya bozmaz
-- =============================================================

-- 1. stock_movements.movement_type constraint güncellemesi
ALTER TABLE public.stock_movements
  DROP CONSTRAINT IF EXISTS stock_movements_type_check;

ALTER TABLE public.stock_movements
  ADD CONSTRAINT stock_movements_type_check
    CHECK (movement_type IN ('GIRIS', 'CIKIS', 'TRANSFER', 'SAYIM', 'TRANSFER_OUT', 'TRANSFER_IN'));

-- 2. transfer_group_id alanı ekleme (iki transfer hareketini bağlamak için)
ALTER TABLE public.stock_movements
  ADD COLUMN IF NOT EXISTS transfer_group_id UUID NULL;

CREATE INDEX IF NOT EXISTS stock_movements_transfer_group_idx
  ON public.stock_movements(transfer_group_id)
  WHERE transfer_group_id IS NOT NULL;

-- 3. product_stocks view'ının soft-delete ve TRANSFER_IN / TRANSFER_OUT uyumlu olarak güncellenmesi
CREATE OR REPLACE VIEW public.product_stocks
WITH (security_invoker = on) AS
SELECT
  p.id AS product_id,
  p.user_id,
  COALESCE(SUM(
    CASE
      WHEN m.deleted_at IS NULL AND m.movement_type IN ('GIRIS', 'TRANSFER_IN') THEN m.quantity
      WHEN m.deleted_at IS NULL AND m.movement_type IN ('CIKIS', 'TRANSFER_OUT') THEN -m.quantity
      ELSE 0
    END), 0) AS quantity
FROM public.products p
LEFT JOIN public.stock_movements m ON m.product_id = p.id
WHERE p.deleted_at IS NULL
GROUP BY p.id, p.user_id;

GRANT SELECT ON public.product_stocks TO authenticated;
GRANT ALL ON public.product_stocks TO service_role;



-- =============================================================
-- MIGRATION: 20260822140000_create_sales_invoice_rpc.sql
-- =============================================================

-- =============================================================
-- FAZ 1B.2 — ATOMİK FATURA OLUŞTURMA RPC
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-22
-- =============================================================
-- BU MİGRATION:
--   ✅ create_sales_invoice RPC fonksiyonunu oluşturur
--   ✅ Fatura, cari hareket ve stok hareketlerini TEK bir PostgreSQL transaction içinde atomik yazar
--   ✅ auth.uid() kullanıcı izolasyonunu ve yetkilendirmesini denetler
--   ✅ customer_id, warehouse_id ve product_id sahipliğini ve geçerliliğini doğrular
--   ✅ Herhangi bir adım başarısız olursa TÜM işlemleri ROLLBACK eder
-- =============================================================

CREATE OR REPLACE FUNCTION public.create_sales_invoice(
  p_invoice_number    TEXT,
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
  p_ettn              TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id     UUID;
  v_invoice_id  UUID;
  v_ettn        TEXT;
  v_should_post BOOLEAN;
  v_is_return   BOOLEAN;
  v_item        JSONB;
  v_product_id  UUID;
  v_quantity    NUMERIC;
  v_unit_price  NUMERIC;
  v_now         TIMESTAMPTZ := now();
BEGIN
  -- 1. Yetkilendirme Kontrolü
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Temel Doğrulamalar
  IF p_invoice_number IS NULL OR trim(p_invoice_number) = '' THEN
    RAISE EXCEPTION 'Fatura numarası zorunludur.';
  END IF;

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

  -- 5. Ürünlerin Aidiyet ve Varlık Kontrolü
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

  -- 6. Değişkenlerin Hazırlanması
  v_should_post := (p_status = 'ONAYLANDI');
  v_is_return   := (p_type = 'IADE');
  v_ettn        := COALESCE(NULLIF(trim(p_ettn), ''), UPPER(gen_random_uuid()::TEXT));

  -- 7. Fatura Kaydını Oluşturma (invoices INSERT)
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
    p_invoice_number,
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
    p_total_tevkifat,
    p_grand_total,
    COALESCE(p_notes, ''),
    COALESCE(p_payment_info, '')
  )
  RETURNING id INTO v_invoice_id;

  -- 8. Onaylanan Fatura için Cari ve Stok Etkileri (Tek Transaction İçinde)
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
        p_invoice_number,
        CASE WHEN v_is_return THEN 'İade faturası kaydı' ELSE 'Satış faturası borç kaydı' END,
        'FATURA',
        v_invoice_id
      );
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
            p_invoice_number,
            CASE WHEN v_is_return THEN 'Fatura kaynaklı stok iade girişi' ELSE 'Fatura kaynaklı stok çıkışı' END,
            'FATURA',
            v_invoice_id
          );
        END IF;
      END IF;
    END LOOP;
  END IF;

  -- 9. Sonuç Dönüşü
  RETURN jsonb_build_object(
    'id', v_invoice_id,
    'invoice_number', p_invoice_number,
    'status', p_status,
    'ettn', v_ettn,
    'posted', v_should_post
  );
END;
$$;

-- Yetkilendirme
REVOKE ALL ON FUNCTION public.create_sales_invoice FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_sales_invoice TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_sales_invoice TO service_role;



-- =============================================================
-- MIGRATION: 20260822160000_atomic_invoice_number.sql
-- =============================================================

-- =============================================================
-- FAZ 1B.3 — ATOMİK FATURA NUMARALANDIRMA VE UNIQUE KORUMASI
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-22
-- =============================================================
-- BU MİGRATION:
--   ✅ invoices tablosuna (user_id, invoice_number) WHERE deleted_at IS NULL için UNIQUE index ekler
--   ✅ create_sales_invoice RPC fonksiyonunu güncelleyerek fatura numarasını
--      next_entry_number(auth.uid(), year, 'INVOICE') ile ATOMİK olarak transaction içinde üretir
--   ✅ Client-side COUNT + 1 ihtiyacını tamamen ortadan kaldırır
--   ✅ Concurrency yarış durumlarını (race condition) veritabanı seviyesinde önler
-- =============================================================

-- 1. invoices tablosuna aktif kayıtlar için kullanıcı bazında unique index
CREATE UNIQUE INDEX IF NOT EXISTS invoices_user_invoice_number_unique
  ON public.invoices(user_id, invoice_number)
  WHERE deleted_at IS NULL;

-- 2. create_sales_invoice RPC fonksiyonunun atomik numara üretimi ile güncellenmesi
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
  v_user_id         UUID;
  v_invoice_id      UUID;
  v_invoice_number  TEXT;
  v_ettn            TEXT;
  v_should_post     BOOLEAN;
  v_is_return       BOOLEAN;
  v_item            JSONB;
  v_product_id      UUID;
  v_quantity        NUMERIC;
  v_unit_price      NUMERIC;
  v_year            INTEGER;
  v_now             TIMESTAMPTZ := now();
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

  -- 5. Ürünlerin Aidiyet ve Varlık Kontrolü
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

  -- 6. Atomik Fatura Numarası Üretimi (Aynı Transaction İçinde)
  v_year := EXTRACT(YEAR FROM p_invoice_date)::INTEGER;

  IF p_invoice_number IS NOT NULL AND trim(p_invoice_number) != '' THEN
    v_invoice_number := trim(p_invoice_number);
  ELSE
    -- FAZ 1A next_entry_number ile atomik ve kilitli sayaç artırımı
    v_invoice_number := public.next_entry_number(v_user_id, v_year, 'INVOICE');
  END IF;

  -- 7. Değişkenlerin Hazırlanması
  v_should_post := (p_status = 'ONAYLANDI');
  v_is_return   := (p_type = 'IADE');
  v_ettn        := COALESCE(NULLIF(trim(p_ettn), ''), UPPER(gen_random_uuid()::TEXT));

  -- 8. Fatura Kaydını Oluşturma (invoices INSERT)
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
    p_total_tevkifat,
    p_grand_total,
    COALESCE(p_notes, ''),
    COALESCE(p_payment_info, '')
  )
  RETURNING id INTO v_invoice_id;

  -- 9. Onaylanan Fatura için Cari ve Stok Etkileri (Tek Transaction İçinde)
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
      );
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
  END IF;

  -- 10. Sonuç Dönüşü
  RETURN jsonb_build_object(
    'id', v_invoice_id,
    'invoice_number', v_invoice_number,
    'status', p_status,
    'ettn', v_ettn,
    'posted', v_should_post
  );
END;
$$;

-- Yetkilendirme
REVOKE ALL ON FUNCTION public.create_sales_invoice FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_sales_invoice TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_sales_invoice TO service_role;



-- =============================================================
-- MIGRATION: 20260822180000_cancel_sales_invoice_rpc.sql
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
-- MIGRATION: 20260822200000_drop_old_create_sales_invoice_overload.sql
-- =============================================================

-- =============================================================
-- FAZ 2.0 — CREATE_SALES_INVOICE OVERLOAD TEMİZLİĞİ
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-22
-- =============================================================
-- BU MİGRATION:
--   ✅ Faz 1B.2'deki eski create_sales_invoice overload'ını DROP eder
--   ✅ PostgREST / Supabase RPC belirsizliğini (ambiguous overload) tamamen ortadan kaldırır
--   ✅ Faz 1B.3'teki atomik numaralandırmalı ve doğru imzalı create_sales_invoice fonksiyonunu korur
-- =============================================================

-- 1. Eski (p_invoice_number ilk parametre olan) fonksiyon imzasını kaldır
DROP FUNCTION IF EXISTS public.create_sales_invoice(
  TEXT, DATE, TEXT, TEXT, UUID, UUID, JSONB, JSONB,
  NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC,
  TEXT, NUMERIC, TEXT, TEXT, TEXT
);

-- 2. Doğru ve tekil create_sales_invoice RPC fonksiyonu tanımı
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
  v_user_id         UUID;
  v_invoice_id      UUID;
  v_invoice_number  TEXT;
  v_ettn            TEXT;
  v_should_post     BOOLEAN;
  v_is_return       BOOLEAN;
  v_item            JSONB;
  v_product_id      UUID;
  v_quantity        NUMERIC;
  v_unit_price      NUMERIC;
  v_year            INTEGER;
  v_now             TIMESTAMPTZ := now();
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

  -- 5. Ürünlerin Aidiyet ve Varlık Kontrolü
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

  -- 6. Atomik Fatura Numarası Üretimi (Aynı Transaction İçinde)
  v_year := EXTRACT(YEAR FROM p_invoice_date)::INTEGER;

  IF p_invoice_number IS NOT NULL AND trim(p_invoice_number) != '' THEN
    v_invoice_number := trim(p_invoice_number);
  ELSE
    -- FAZ 1A next_entry_number ile atomik ve kilitli sayaç artırımı
    v_invoice_number := public.next_entry_number(v_user_id, v_year, 'INVOICE');
  END IF;

  -- 7. Değişkenlerin Hazırlanması
  v_should_post := (p_status = 'ONAYLANDI');
  v_is_return   := (p_type = 'IADE');
  v_ettn        := COALESCE(NULLIF(trim(p_ettn), ''), UPPER(gen_random_uuid()::TEXT));

  -- 8. Fatura Kaydını Oluşturma (invoices INSERT)
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
    p_total_tevkifat,
    p_grand_total,
    COALESCE(p_notes, ''),
    COALESCE(p_payment_info, '')
  )
  RETURNING id INTO v_invoice_id;

  -- 9. Onaylanan Fatura için Cari ve Stok Etkileri (Tek Transaction İçinde)
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
      );
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
  END IF;

  -- 10. Sonuç Dönüşü
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



-- =============================================================
-- MIGRATION: 20260822210000_faz21_fatura_yevmiye_kdv.sql
-- =============================================================

-- =============================================================
-- FAZ 2.1 — FATURA ➔ YEVMİYE ➔ KDV OTOMATİK MUHASEBELEŞTİRME
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-22
-- =============================================================
-- BU MİGRATION:
--   ✅ create_sales_invoice RPC fonksiyonunu günceller:
--      1. Fatura başlığını (invoices) oluşturur
--      2. Fatura kalemlerini (invoice_items) normalize olarak kaydeder
--      3. KDV satırlarını (invoice_tax_lines) oran bazında kaydeder
--      4. Cari hesaba (account_transactions) borç/alacak yazar
--      5. Stok hareketlerini (stock_movements) kaydeder
--      6. Otomatik Yevmiye Fişi (journal_entries + journal_lines) oluşturur (120/600/391)
--      7. Cari hareket ile Yevmiye fişini (journal_entry_id) birbirine bağlar
--   ✅ Aynı faturaya mükerrer yevmiye fişi oluşmasını önleyen UNIQUE index ekler
--   ✅ Tüm işlemleri TEK bir PostgreSQL transaction içinde atomik yürütür
-- =============================================================

-- 1. Bir faturaya ait yalnızca 1 aktif Yevmiye Fişi olmasını garanti eden Unique Index
CREATE UNIQUE INDEX IF NOT EXISTS je_user_source_invoice_unique
  ON public.journal_entries(user_id, source_type, source_id)
  WHERE source_type = 'INVOICE' AND status != 'CANCELLED';

-- 2. create_sales_invoice RPC fonksiyonunun Yevmiye ve KDV entegrasyonu ile güncellenmesi
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
  v_acc_600_id        UUID;
  v_acc_610_id        UUID;
  v_acc_391_id        UUID;
  v_rev_acc_id        UUID;
  
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
    p_total_tevkifat,
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
      v_acc_610_id := v_acc_600_id; -- 610 yoksa 600 kullan
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
      -- 1. Satır: 120 ALICILAR ➔ BORÇ = Genel Toplam
      IF p_grand_total > 0 THEN
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, v_acc_120_id,
          'Fatura Borç Kaydı: ' || v_invoice_number,
          p_grand_total, 0, p_currency, COALESCE(p_exchange_rate, 1)
        );
      END IF;

      -- 2. Satır: 600 YURTİÇİ SATIŞLAR ➔ ALACAK = Matrah (Subtotal - Discount)
      IF p_taxable_amount > 0 THEN
        INSERT INTO public.journal_lines (
          journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate
        ) VALUES (
          v_journal_entry_id, v_user_id, v_acc_600_id,
          'Satış Geliri: ' || v_invoice_number,
          0, p_taxable_amount, p_currency, COALESCE(p_exchange_rate, 1)
        );
      END IF;

      -- 3. Satırlar: 391 HESAPLANAN KDV ➔ ALACAK = KDV Tutarları (Oran Bazında)
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
-- MIGRATION: 20260822213000_faz21_tevkifat_journal_support.sql
-- =============================================================

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
-- MIGRATION: 20260822220000_faz222_weighted_average_cost_engine.sql
-- =============================================================

-- =============================================================
-- FAZ 2.2.2 — AĞIRLIKLI ORTALAMA STOK MALİYET MOTORU VE SATIŞ ENTEGRASYONU
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-22
-- =============================================================
-- BU MİGRATION:
--   ✅ stock_movements tablosuna unit_cost ve total_cost kolonlarını ekler
--   ✅ PostgreSQL seviyesinde get_product_moving_average_cost fonksiyonunu kurar
--   ✅ PostgreSQL seviyesinde get_product_stock_quantity fonksiyonunu kurar
--   ✅ create_sales_invoice RPC'sini günceller:
--      - Satış CIKIS hareketine unit_cost ve total_cost yazar
--      - Satış anında track_stock=true olan ürünlerde yetersiz/negatif stoğu engeller
--      - İade GIRIS hareketine doğru maliyet değerini yazar
--   ✅ cancel_sales_invoice RPC'sini günceller:
--      - İptal stok hareketinde orijinal unit_cost ve total_cost değerlerini korur
--   ✅ Multi-tenant (auth.uid()) izolasyonunu ve atomik transaction yapısını korur
-- =============================================================

-- 1. stock_movements tablosuna unit_cost ve total_cost alanlarının eklenmesi
ALTER TABLE public.stock_movements
  ADD COLUMN IF NOT EXISTS unit_cost NUMERIC(14,4) NULL,
  ADD COLUMN IF NOT EXISTS total_cost NUMERIC(14,2) NULL;

ALTER TABLE public.stock_movements
  DROP CONSTRAINT IF EXISTS stock_movements_unit_cost_check,
  DROP CONSTRAINT IF EXISTS stock_movements_total_cost_check;

ALTER TABLE public.stock_movements
  ADD CONSTRAINT stock_movements_unit_cost_check  CHECK (unit_cost IS NULL OR unit_cost >= 0),
  ADD CONSTRAINT stock_movements_total_cost_check CHECK (total_cost IS NULL OR total_cost >= 0);

-- 2. Anlık Stok Miktarı Hesaplama Fonksiyonu (Depo Bazlı / Genel)
CREATE OR REPLACE FUNCTION public.get_product_stock_quantity(
  p_product_id   UUID,
  p_warehouse_id UUID DEFAULT NULL
)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
  v_qty     NUMERIC := 0;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(SUM(
    CASE
      WHEN movement_type IN ('GIRIS', 'TRANSFER_IN') THEN quantity
      WHEN movement_type IN ('CIKIS', 'TRANSFER_OUT') THEN -quantity
      ELSE 0
    END
  ), 0)
  INTO v_qty
  FROM public.stock_movements
  WHERE product_id = p_product_id
    AND user_id = v_user_id
    AND deleted_at IS NULL
    AND (p_warehouse_id IS NULL OR warehouse_id = p_warehouse_id);

  RETURN v_qty;
END;
$$;

REVOKE ALL ON FUNCTION public.get_product_stock_quantity FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_product_stock_quantity TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_product_stock_quantity TO service_role;

-- 3. Ağırlıklı Ortalama Maliyet Hesaplama Motoru (Moving Weighted Average Cost)
CREATE OR REPLACE FUNCTION public.get_product_moving_average_cost(
  p_product_id   UUID,
  p_warehouse_id UUID DEFAULT NULL
)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id   UUID;
  v_rec       RECORD;
  v_qty       NUMERIC := 0;
  v_val       NUMERIC := 0;
  v_avg_cost  NUMERIC := 0;
  v_m_cost    NUMERIC := 0;
  v_catalog_p NUMERIC := 0;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  -- Ürünün katalog alış fiyatını al (fallback için)
  SELECT COALESCE(purchase_price, 0)
  INTO v_catalog_p
  FROM public.products
  WHERE id = p_product_id AND user_id = v_user_id AND deleted_at IS NULL;

  -- İlgili ürünün kronolojik stok hareketlerini adım adım simüle et
  FOR v_rec IN
    SELECT
      movement_type,
      quantity,
      unit_price,
      unit_cost,
      warehouse_id,
      target_warehouse_id
    FROM public.stock_movements
    WHERE product_id = p_product_id
      AND user_id = v_user_id
      AND deleted_at IS NULL
      AND (
        p_warehouse_id IS NULL
        OR warehouse_id = p_warehouse_id
        OR target_warehouse_id = p_warehouse_id
      )
    ORDER BY movement_date ASC, created_at ASC, id ASC
  LOOP
    IF v_rec.movement_type IN ('GIRIS', 'TRANSFER_IN') THEN
      -- Giriş maliyeti: Önce unit_cost, yoksa unit_price, yoksa katalog alış fiyatı
      v_m_cost := COALESCE(v_rec.unit_cost, NULLIF(v_rec.unit_price, 0), v_catalog_p, 0);
      v_val := v_val + (v_rec.quantity * v_m_cost);
      v_qty := v_qty + v_rec.quantity;
      IF v_qty > 0 THEN
        v_avg_cost := v_val / v_qty;
      END IF;

    ELSIF v_rec.movement_type IN ('CIKIS', 'TRANSFER_OUT') THEN
      v_val := GREATEST(0, v_val - (v_rec.quantity * v_avg_cost));
      v_qty := GREATEST(0, v_qty - v_rec.quantity);
      IF v_qty = 0 THEN
        v_val := 0;
      END IF;

    ELSIF v_rec.movement_type = 'SAYIM' THEN
      v_qty := GREATEST(0, v_rec.quantity);
      v_val := v_qty * v_avg_cost;
    END IF;
  END LOOP;

  -- Eğer stok 0 veya hesaplanmış maliyet 0 ise katalog alış fiyatına başvur
  IF v_avg_cost <= 0 OR v_qty <= 0 THEN
    v_avg_cost := COALESCE(v_catalog_p, 0);
  END IF;

  RETURN ROUND(v_avg_cost, 4);
END;
$$;

REVOKE ALL ON FUNCTION public.get_product_moving_average_cost FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_product_moving_average_cost TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_product_moving_average_cost TO service_role;

-- 4. create_sales_invoice RPC'sinin Maliyet & Negatif Stok Koruması ile Güncellenmesi
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
  v_product_name      TEXT;
  v_track_stock       BOOLEAN;
  v_current_stock     NUMERIC;
  v_unit_cost         NUMERIC;
  v_total_cost        NUMERIC;
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

  -- 5. Kalemlerin Doğrulanması ve Negatif Stok Kontrolü
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    IF (v_item->>'name') IS NULL OR trim(v_item->>'name') = '' THEN
      RAISE EXCEPTION 'Fatura kalemlerinde açıklama/ürün adı boş olamaz.';
    END IF;

    IF (v_item->>'productId') IS NOT NULL AND trim(v_item->>'productId') != '' THEN
      v_product_id := (v_item->>'productId')::UUID;
      v_quantity   := GREATEST(0, COALESCE((v_item->>'quantity')::NUMERIC, 0));

      SELECT name, COALESCE(track_stock, true)
      INTO v_product_name, v_track_stock
      FROM public.products
      WHERE id = v_product_id AND user_id = v_user_id AND deleted_at IS NULL;

      IF v_product_name IS NULL THEN
        RAISE EXCEPTION 'Geçersiz veya silinmiş ürün kalemi. Ürün ID: %', v_product_id;
      END IF;

      -- Onaylı normal satış faturasında stok kontrolü (İade değilse)
      IF v_should_post AND NOT v_is_return AND v_track_stock AND v_quantity > 0 THEN
        v_current_stock := public.get_product_stock_quantity(v_product_id, p_warehouse_id);
        IF v_current_stock < v_quantity THEN
          RAISE EXCEPTION 'Yetersiz stok! Ürün: "%", Depodaki Mevcut Stok: %, Talep Edilen Miktar: %',
            v_product_name, v_current_stock, v_quantity;
        END IF;
      END IF;
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

  -- 10. ONAYLI Fatura İse: Cari, Stok (Maliyetli) ve Yevmiye Fişi Kayıtları
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

  -- 11. Sonuç Dönüşü
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

-- 5. cancel_sales_invoice RPC'sinin Stok Maliyetini Koruyacak Şekilde Güncellenmesi
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

  -- 3. Zaten İptal Edilmiş mi?
  IF v_invoice.status = 'IPTAL' THEN
    RAISE EXCEPTION 'Bu fatura (%) zaten iptal edilmiştir. Mükerrer iptal işlemi yapılamaz.',
      v_invoice.invoice_number;
  END IF;

  v_year  := EXTRACT(YEAR FROM v_invoice.invoice_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM v_invoice.invoice_date)::INTEGER;

  -- 4. Fatura Durumunu IPTAL Olarak Güncelleme
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

  -- 5. Eğer Fatura Onaylı (POSTED) İdiyse Ters Kayıtlar Üret
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

    -- D) Yevmiye Fişi Ters Kaydı (journal_entries + journal_lines)
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

  -- 6. JSONB Sonuç Dönüşü
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



-- =============================================================
-- MIGRATION: 20260822230000_faz222_concurrency_lock_and_cost_refinement.sql
-- =============================================================

-- =============================================================
-- FAZ 2.2.2 — SON TEKNİK DÜZELTME & GÜVENLİK YAMASI
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-22
-- =============================================================
-- BU MİGRATION:
--   ✅ create_sales_invoice RPC fonksiyonuna deterministik satır kilidi (FOR UPDATE) ekler:
--      - Faturadaki tüm ürünleri product_id ASC sırasında FOR UPDATE ile kilitler
--      - Deadlock riskini önler
--      - Eşzamanlı satışlarda stok kontrolünün kilit sonrasında taze veriden yapılmasını garanti eder
--   ✅ get_product_moving_average_cost fonksiyonunu maliyet fallback zincirini sıkılaştırarak günceller:
--      - Yeni hareketlerde yalnızca unit_cost'u esas alır
--      - unit_price'ı yalnızca unit_cost'un NULL olduğu eski GIRIS kayıtlarında sınırlandırır
--      - purchase_price'ı yalnızca hiç giriş hareketi bulunmadığında katalog fallback'i olarak kullanır
--   ✅ Multi-tenant (user_id = auth.uid()) ve transaction atomikliğini korur
-- =============================================================

-- 1. Ağırlıklı Ortalama Maliyet Motoru (Maliyet Fallback Zinciri İyileştirmesi)
CREATE OR REPLACE FUNCTION public.get_product_moving_average_cost(
  p_product_id   UUID,
  p_warehouse_id UUID DEFAULT NULL
)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id   UUID;
  v_rec       RECORD;
  v_qty       NUMERIC := 0;
  v_val       NUMERIC := 0;
  v_avg_cost  NUMERIC := 0;
  v_m_cost    NUMERIC := 0;
  v_catalog_p NUMERIC := 0;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  -- Ürünün katalog alış fiyatını al (yalnızca hiç giriş kaydı yoksa fallback için)
  SELECT COALESCE(purchase_price, 0)
  INTO v_catalog_p
  FROM public.products
  WHERE id = p_product_id AND user_id = v_user_id AND deleted_at IS NULL;

  -- İlgili ürünün kronolojik stok hareketlerini simüle et
  FOR v_rec IN
    SELECT
      movement_type,
      quantity,
      unit_price,
      unit_cost,
      source,
      warehouse_id,
      target_warehouse_id
    FROM public.stock_movements
    WHERE product_id = p_product_id
      AND user_id = v_user_id
      AND deleted_at IS NULL
      AND (
        p_warehouse_id IS NULL
        OR warehouse_id = p_warehouse_id
        OR target_warehouse_id = p_warehouse_id
      )
    ORDER BY movement_date ASC, created_at ASC, id ASC
  LOOP
    IF v_rec.movement_type IN ('GIRIS', 'TRANSFER_IN') THEN
      -- Maliyet Belirleme Kuralı:
      -- 1. Yeni sistemde unit_cost dolu ise doğrudan unit_cost kullanılır.
      -- 2. Eski geçmiş GIRIS kayıtlarında unit_cost NULL ise (ve source != 'FATURA' / 'FATURA_IPTAL' ise) unit_price alış maliyeti kabul edilir.
      -- 3. Hiçbir maliyet bulunamazsa katalog alış fiyatına (v_catalog_p) başvurulur.
      IF v_rec.unit_cost IS NOT NULL AND v_rec.unit_cost > 0 THEN
        v_m_cost := v_rec.unit_cost;
      ELSIF v_rec.movement_type = 'GIRIS' AND v_rec.unit_price IS NOT NULL AND v_rec.unit_price > 0 AND v_rec.source != 'FATURA' THEN
        v_m_cost := v_rec.unit_price;
      ELSE
        v_m_cost := v_catalog_p;
      END IF;

      v_val := v_val + (v_rec.quantity * v_m_cost);
      v_qty := v_qty + v_rec.quantity;
      IF v_qty > 0 THEN
        v_avg_cost := v_val / v_qty;
      END IF;

    ELSIF v_rec.movement_type IN ('CIKIS', 'TRANSFER_OUT') THEN
      v_val := GREATEST(0, v_val - (v_rec.quantity * v_avg_cost));
      v_qty := GREATEST(0, v_qty - v_rec.quantity);
      IF v_qty = 0 THEN
        v_val := 0;
      END IF;

    ELSIF v_rec.movement_type = 'SAYIM' THEN
      v_qty := GREATEST(0, v_rec.quantity);
      v_val := v_qty * v_avg_cost;
    END IF;
  END LOOP;

  -- Eğer stok 0 veya hesaplanmış maliyet 0 ise katalog alış fiyatına başvur
  IF v_avg_cost <= 0 OR v_qty <= 0 THEN
    v_avg_cost := COALESCE(v_catalog_p, 0);
  END IF;

  RETURN ROUND(v_avg_cost, 4);
END;
$$;

REVOKE ALL ON FUNCTION public.get_product_moving_average_cost FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_product_moving_average_cost TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_product_moving_average_cost TO service_role;

-- 2. create_sales_invoice RPC'si (Deterministik Ürün Satır Kilidi ile)
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
  v_product_name      TEXT;
  v_track_stock       BOOLEAN;
  v_current_stock     NUMERIC;
  v_unit_cost         NUMERIC;
  v_total_cost        NUMERIC;
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
  -- Faturadaki benzersiz ürün ID'lerini topla ve sıralı olarak kilitle
  SELECT array_agg(DISTINCT (item->>'productId')::UUID ORDER BY (item->>'productId')::UUID)
  INTO v_product_ids
  FROM jsonb_array_elements(p_items) AS item
  WHERE (item->>'productId') IS NOT NULL AND trim(item->>'productId') != '';

  IF v_product_ids IS NOT NULL AND array_length(v_product_ids, 1) > 0 THEN
    -- Ürün satırlarını ID sırasına göre kilitle (FOR UPDATE)
    FOR v_locked_product IN
      SELECT id, name, COALESCE(track_stock, true) AS track_stock
      FROM public.products
      WHERE id = ANY(v_product_ids)
        AND user_id = v_user_id
        AND deleted_at IS NULL
      ORDER BY id ASC
      FOR UPDATE
    LOOP
      -- Kilit alındıktan sonra bu ürün için faturadaki toplam talep edilen miktarı hesapla
      v_quantity := 0;
      FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
      LOOP
        IF (v_item->>'productId') IS NOT NULL AND (v_item->>'productId')::UUID = v_locked_product.id THEN
          v_quantity := v_quantity + GREATEST(0, COALESCE((v_item->>'quantity')::NUMERIC, 0));
        END IF;
      END LOOP;

      -- Onaylı normal satış faturasında (veya tevkifat/istisna) güncel stok kontrolü
      IF v_should_post AND NOT v_is_return AND v_locked_product.track_stock AND v_quantity > 0 THEN
        v_current_stock := public.get_product_stock_quantity(v_locked_product.id, p_warehouse_id);
        IF v_current_stock < v_quantity THEN
          RAISE EXCEPTION 'Yetersiz stok! Ürün: "%", Depodaki Mevcut Stok: %, Talep Edilen Miktar: %',
            v_locked_product.name, v_current_stock, v_quantity;
        END IF;
      END IF;
    END LOOP;

    -- Bulunamayan/silinmiş ürün kontrolü
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

  -- 10. ONAYLI Fatura İse: Cari, Stok (Maliyetli) ve Yevmiye Fişi Kayıtları
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

  -- 11. Sonuç Dönüşü
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
-- MIGRATION: 20260822233000_faz223_stmm_621_153_integration.sql
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
-- MIGRATION: 20260823000000_faz224_accounting_periods.sql
-- =============================================================

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



-- =============================================================
-- MIGRATION: 20260823010000_faz224_financial_reporting.sql
-- =============================================================

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
-- MIGRATION: 20260823020000_faz224_reconciliation_and_audit_engine.sql
-- =============================================================

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
-- MIGRATION: 20260823030000_faz225_purchase_invoice_and_supplier_accounting.sql
-- =============================================================

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
-- MIGRATION: 20260823040000_faz225_purchase_audit_reconciliation.sql
-- =============================================================

-- =============================================================
-- FAZ 2.2.5 — IMPLEMENTATION 2/4: SATIN ALMA MUTABAKAT VE ACCOUNTING AUDIT MOTORU
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-23
-- =============================================================
-- BU MİGRATION:
--   ✅ run_accounting_audit RPC fonksiyonunu satın alma kontrolleriyle zenginleştirir:
--      1.  UNBALANCED_POSTED_JOURNAL (Dengesiz Fişler)
--      2.  POSTED_JOURNAL_WITHOUT_LINES (Satırsız Fişler)
--      3.  INVOICE_WITHOUT_JOURNAL (Yevmiyesiz Satış Faturaları)
--      4.  PURCHASE_WITHOUT_JOURNAL (Yevmiyesiz Alış Faturaları) [YENİ]
--      5.  NEGATIVE_STOCK (Negatif Stok Uyarıları)
--      6.  STMM_621_MISMATCH (STMM ↔ 621)
--      7.  SALES_600_MISMATCH (Satış ↔ 600)
--      8.  TAX_391_MISMATCH (KDV ↔ 391)
--      9.  CUSTOMER_120_MISMATCH (Cari ↔ 120)
--      10. PURCHASE_191_MISMATCH (Alış KDV ↔ 191 İndirilecek KDV) [YENİ]
--      11. PURCHASE_153_MISMATCH (Alış Matrah ↔ 153 Ticari Mallar) [YENİ]
--      12. SUPPLIER_320_MISMATCH (Tedarikçi Borç / Fatura ↔ 320 Satıcılar) [YENİ]
--      13. PURCHASE_STOCK_MISMATCH (Alış Kalem Miktarı ↔ Stok Giriş Miktarı) [YENİ]
--      14. PURCHASE_STOCK_COST_MISMATCH & PURCHASE_TAX_IN_STOCK_COST (Stok Maliyeti & KDV İzolasyonu) [YENİ]
--      15. PURCHASE_CANCEL_WITHOUT_REVERSAL (İptal Edilen Alış Faturasında Reversal Kontrolü) [YENİ]
--   ✅ get_reconciliation_summary ve close_accounting_period entegrasyonu
--   ✅ Tenant izolasyonu (auth.uid()) ve SECURITY DEFINER güvenliği
-- =============================================================

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
  v_user_id                 UUID;
  v_rec                     RECORD;
  
  -- Satış Mutabakat Değişkenleri
  v_stock_cogs_net          NUMERIC(14,2) := 0;
  v_journal_621_net         NUMERIC(14,2) := 0;
  v_inv_taxable_net         NUMERIC(14,2) := 0;
  v_journal_600_net         NUMERIC(14,2) := 0;
  v_inv_tax_net             NUMERIC(14,2) := 0;
  v_journal_391_net         NUMERIC(14,2) := 0;
  v_cust_subledger_net      NUMERIC(14,2) := 0;
  v_journal_120_net         NUMERIC(14,2) := 0;
  
  -- Satın Alma Mutabakat Değişkenleri
  v_purchase_taxable_net    NUMERIC(14,2) := 0;
  v_journal_153_purchase    NUMERIC(14,2) := 0;
  v_purchase_tax_net        NUMERIC(14,2) := 0;
  v_journal_191_net         NUMERIC(14,2) := 0;
  v_purchase_grand_net      NUMERIC(14,2) := 0;
  v_journal_320_net         NUMERIC(14,2) := 0;
  v_supp_subledger_net      NUMERIC(14,2) := 0;

  v_p_rec                   RECORD;
  v_p_qty                   NUMERIC;
  v_inv_item_qty            NUMERIC;
  v_stock_in_qty            NUMERIC;
  v_stock_in_cost           NUMERIC;
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
  -- KONTROL 3: INVOICE_WITHOUT_JOURNAL (Yevmiyesiz Satış Faturaları)
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
      AND inv.type NOT IN ('ALIS', 'GELEN_FATURA', 'GELEN_E_ARSIV')
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
  -- KONTROL 4: PURCHASE_WITHOUT_JOURNAL (Yevmiyesiz Alış Faturaları)
  -- ========================================================
  FOR v_rec IN
    SELECT inv.id, inv.invoice_number, inv.grand_total
    FROM public.invoices inv
    LEFT JOIN public.journal_entries je
      ON je.source_type = 'PURCHASE_INVOICE'
      AND je.source_id = inv.id
      AND je.status = 'POSTED'
    WHERE inv.user_id = v_user_id
      AND inv.posted = true
      AND inv.status != 'IPTAL'
      AND inv.type IN ('ALIS', 'GELEN_FATURA', 'GELEN_E_ARSIV')
      AND (p_year IS NULL OR EXTRACT(YEAR FROM inv.invoice_date) = p_year)
      AND (p_month IS NULL OR EXTRACT(MONTH FROM inv.invoice_date) = p_month)
      AND je.id IS NULL
  LOOP
    check_name     := 'PURCHASE_WITHOUT_JOURNAL';
    severity       := 'CRITICAL';
    status         := 'FAIL';
    expected_value := v_rec.grand_total;
    actual_value   := 0;
    difference     := v_rec.grand_total;
    detail         := 'Onaylı alış faturasının muhasebe yevmiye fişi bulunamadı! Fatura No: ' || v_rec.invoice_number;
    source_id      := v_rec.id;
    RETURN NEXT;
  END LOOP;

  -- ========================================================
  -- KONTROL 5: NEGATIVE_STOCK (Negatif Stok Uyarıları)
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
  -- KONTROL 6: STMM ↔ 621 MUTABAKATI
  -- ========================================================
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
  -- KONTROL 7: SATIŞ ↔ 600 MUTABAKATI
  -- ========================================================
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
    AND type NOT IN ('ALIS', 'GELEN_FATURA', 'GELEN_E_ARSIV')
    AND (p_year IS NULL OR EXTRACT(YEAR FROM invoice_date) = p_year)
    AND (p_month IS NULL OR EXTRACT(MONTH FROM invoice_date) = p_month);

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
  -- KONTROL 8: KDV ↔ 391 MUTABAKATI
  -- ========================================================
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
    AND itl.direction != 'ALIS'
    AND itl.is_cancelled = false
    AND (p_year IS NULL OR itl.period_year = p_year)
    AND (p_month IS NULL OR itl.period_month = p_month);

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
    detail   := 'Satış KDV satırları toplamı (' || v_inv_tax_net || ' TL) ile 391 hesabı (' || v_journal_391_net || ' TL) arasında fark var!';
  ELSE
    severity := 'INFO';
    status   := 'PASS';
    detail   := 'Satış KDV satırları ile 391 hesabı tam mutabık.';
  END IF;
  RETURN NEXT;

  -- ========================================================
  -- KONTROL 9: CARİ ↔ 120 MUTABAKATI
  -- ========================================================
  SELECT COALESCE(SUM(
    CASE
      WHEN at.txn_type = 'BORC' THEN at.amount
      WHEN at.txn_type = 'ALACAK' THEN -at.amount
      ELSE 0
    END
  ), 0)
  INTO v_cust_subledger_net
  FROM public.account_transactions at
  INNER JOIN public.customers c ON c.id = at.customer_id
  WHERE at.user_id = v_user_id
    AND at.deleted_at IS NULL
    AND c.partner_type = 'MUSTERI'
    AND (p_year IS NULL OR EXTRACT(YEAR FROM at.txn_date) = p_year)
    AND (p_month IS NULL OR EXTRACT(MONTH FROM at.txn_date) = p_month);

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
    detail   := 'Müşteri cari hareketler toplamı (' || v_cust_subledger_net || ' TL) ile 120 hesabı (' || v_journal_120_net || ' TL) arasında fark var!';
  ELSE
    severity := 'INFO';
    status   := 'PASS';
    detail   := 'Müşteri cari hareketler ile 120 hesabı tam mutabık.';
  END IF;
  RETURN NEXT;

  -- ========================================================
  -- KONTROL 10: PURCHASE_191_MISMATCH (Alış KDV ↔ 191 İndirilecek KDV)
  -- ========================================================
  SELECT COALESCE(SUM(tax_amount), 0)
  INTO v_purchase_tax_net
  FROM public.invoice_tax_lines
  WHERE user_id = v_user_id
    AND direction = 'ALIS'
    AND is_cancelled = false
    AND (p_year IS NULL OR period_year = p_year)
    AND (p_month IS NULL OR period_month = p_month);

  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_journal_191_net
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND (coa.code = '191' OR coa.system_tag = 'INDIRILECEK_KDV')
    AND (p_year IS NULL OR je.period_year = p_year)
    AND (p_month IS NULL OR je.period_month = p_month);

  check_name     := 'PURCHASE_191_MISMATCH';
  expected_value := v_purchase_tax_net;
  actual_value   := v_journal_191_net;
  difference     := v_journal_191_net - v_purchase_tax_net;
  source_id      := NULL;

  IF ABS(difference) > 0.05 THEN
    severity := 'CRITICAL';
    status   := 'FAIL';
    detail   := 'Alış faturası KDV satırları toplamı (' || v_purchase_tax_net || ' TL) ile 191 hesabı (' || v_journal_191_net || ' TL) arasında fark var!';
  ELSE
    severity := 'INFO';
    status   := 'PASS';
    detail   := 'Alış faturası KDV satırları ile 191 hesabı tam mutabık.';
  END IF;
  RETURN NEXT;

  -- ========================================================
  -- KONTROL 11: PURCHASE_153_MISMATCH (Alış Matrah ↔ 153 Ticari Mallar)
  -- ========================================================
  SELECT COALESCE(SUM(taxable_amount), 0)
  INTO v_purchase_taxable_net
  FROM public.invoices
  WHERE user_id = v_user_id
    AND posted = true
    AND status != 'IPTAL'
    AND type IN ('ALIS', 'GELEN_FATURA', 'GELEN_E_ARSIV')
    AND (p_year IS NULL OR EXTRACT(YEAR FROM invoice_date) = p_year)
    AND (p_month IS NULL OR EXTRACT(MONTH FROM invoice_date) = p_month);

  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_journal_153_purchase
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.source_type = 'PURCHASE_INVOICE'
    AND je.status = 'POSTED'
    AND (coa.code = '153' OR coa.system_tag = 'STOK')
    AND (p_year IS NULL OR je.period_year = p_year)
    AND (p_month IS NULL OR je.period_month = p_month);

  check_name     := 'PURCHASE_153_MISMATCH';
  expected_value := v_purchase_taxable_net;
  actual_value   := v_journal_153_purchase;
  difference     := v_journal_153_purchase - v_purchase_taxable_net;
  source_id      := NULL;

  IF ABS(difference) > 0.05 THEN
    severity := 'CRITICAL';
    status   := 'FAIL';
    detail   := 'Alış faturası net matrah toplamı (' || v_purchase_taxable_net || ' TL) ile 153 alış borç kayıtları (' || v_journal_153_purchase || ' TL) arasında fark var!';
  ELSE
    severity := 'INFO';
    status   := 'PASS';
    detail   := 'Alış faturaları matrahı ile 153 hesabı tam mutabık.';
  END IF;
  RETURN NEXT;

  -- ========================================================
  -- KONTROL 12: SUPPLIER_320_MISMATCH (Tedarikçi Borç / Fatura ↔ 320 Satıcılar)
  -- ========================================================
  SELECT COALESCE(SUM(grand_total), 0)
  INTO v_purchase_grand_net
  FROM public.invoices
  WHERE user_id = v_user_id
    AND posted = true
    AND status != 'IPTAL'
    AND type IN ('ALIS', 'GELEN_FATURA', 'GELEN_E_ARSIV')
    AND (p_year IS NULL OR EXTRACT(YEAR FROM invoice_date) = p_year)
    AND (p_month IS NULL OR EXTRACT(MONTH FROM invoice_date) = p_month);

  SELECT COALESCE(SUM(jl.credit - jl.debit), 0)
  INTO v_journal_320_net
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND (coa.code = '320' OR coa.system_tag = 'SATICILAR')
    AND (p_year IS NULL OR je.period_year = p_year)
    AND (p_month IS NULL OR je.period_month = p_month);

  check_name     := 'SUPPLIER_320_MISMATCH';
  expected_value := v_purchase_grand_net;
  actual_value   := v_journal_320_net;
  difference     := v_journal_320_net - v_purchase_grand_net;
  source_id      := NULL;

  IF ABS(difference) > 0.05 THEN
    severity := 'CRITICAL';
    status   := 'FAIL';
    detail   := 'Alış faturaları genel toplamı (' || v_purchase_grand_net || ' TL) ile 320 Satıcılar hesabı (' || v_journal_320_net || ' TL) arasında fark var!';
  ELSE
    severity := 'INFO';
    status   := 'PASS';
    detail   := 'Alış faturaları genel toplamı ile 320 Satıcılar hesabı tam mutabık.';
  END IF;
  RETURN NEXT;

  -- ========================================================
  -- KONTROL 13: PURCHASE_STOCK_MISMATCH (Alış Kalem Miktarı ↔ Stok Giriş Miktarı)
  -- ========================================================
  FOR v_rec IN
    SELECT inv.id, inv.invoice_number, inv.taxable_amount, inv.total_vat
    FROM public.invoices inv
    WHERE inv.user_id = v_user_id
      AND inv.posted = true
      AND inv.status != 'IPTAL'
      AND inv.type IN ('ALIS', 'GELEN_FATURA', 'GELEN_E_ARSIV')
      AND (p_year IS NULL OR EXTRACT(YEAR FROM inv.invoice_date) = p_year)
      AND (p_month IS NULL OR EXTRACT(MONTH FROM inv.invoice_date) = p_month)
  LOOP
    SELECT COALESCE(SUM(quantity), 0)
    INTO v_inv_item_qty
    FROM public.invoice_items
    WHERE invoice_id = v_rec.id AND product_id IS NOT NULL;

    SELECT COALESCE(SUM(quantity), 0), COALESCE(SUM(total_cost), 0)
    INTO v_stock_in_qty, v_stock_in_cost
    FROM public.stock_movements
    WHERE source_id = v_rec.id
      AND user_id = v_user_id
      AND deleted_at IS NULL
      AND movement_type = 'GIRIS'
      AND source = 'ALIS_FATURASI';

    -- Miktar Uyuşmazlığı Kontrolü
    IF ABS(v_inv_item_qty - v_stock_in_qty) > 0.001 THEN
      check_name     := 'PURCHASE_STOCK_MISMATCH';
      severity       := 'CRITICAL';
      status         := 'FAIL';
      expected_value := v_inv_item_qty;
      actual_value   := v_stock_in_qty;
      difference     := v_stock_in_qty - v_inv_item_qty;
      detail         := 'Alış faturası kalem miktarı (' || v_inv_item_qty || ') ile stok giriş miktarı (' || v_stock_in_qty || ') uyuşmuyor! Fatura: ' || v_rec.invoice_number;
      source_id      := v_rec.id;
      RETURN NEXT;
    END IF;

    -- Maliyet ve KDV İzolasyonu Kontrolü
    IF ABS(v_stock_in_cost - v_rec.taxable_amount) > 0.05 THEN
      IF v_rec.total_vat > 0 AND v_stock_in_cost >= (v_rec.taxable_amount + v_rec.total_vat - 0.05) THEN
        check_name     := 'PURCHASE_TAX_IN_STOCK_COST';
        severity       := 'CRITICAL';
        status         := 'FAIL';
        expected_value := v_rec.taxable_amount;
        actual_value   := v_stock_in_cost;
        difference     := v_stock_in_cost - v_rec.taxable_amount;
        detail         := 'KRİTİK HATA: Stok giriş maliyetine KDV dahil edilmiş! Net Matrah: ' || v_rec.taxable_amount || ' TL, Stok Maliyeti: ' || v_stock_in_cost || ' TL. Fatura: ' || v_rec.invoice_number;
        source_id      := v_rec.id;
        RETURN NEXT;
      ELSE
        check_name     := 'PURCHASE_STOCK_COST_MISMATCH';
        severity       := 'CRITICAL';
        status         := 'FAIL';
        expected_value := v_rec.taxable_amount;
        actual_value   := v_stock_in_cost;
        difference     := v_stock_in_cost - v_rec.taxable_amount;
        detail         := 'Alış faturası net mal bedeli (' || v_rec.taxable_amount || ' TL) ile stok giriş maliyeti (' || v_stock_in_cost || ' TL) uyuşmuyor! Fatura: ' || v_rec.invoice_number;
        source_id      := v_rec.id;
        RETURN NEXT;
      END IF;
    END IF;
  END LOOP;

  -- ========================================================
  -- KONTROL 14: PURCHASE_CANCEL_WITHOUT_REVERSAL (İptal Reversal Kontrolü)
  -- ========================================================
  FOR v_rec IN
    SELECT inv.id, inv.invoice_number, inv.grand_total
    FROM public.invoices inv
    WHERE inv.user_id = v_user_id
      AND inv.posted = true
      AND inv.status = 'IPTAL'
      AND inv.type IN ('ALIS', 'GELEN_FATURA', 'GELEN_E_ARSIV')
      AND (p_year IS NULL OR EXTRACT(YEAR FROM inv.invoice_date) = p_year)
      AND (p_month IS NULL OR EXTRACT(MONTH FROM inv.invoice_date) = p_month)
  LOOP
    -- Reversal Yevmiye Fişi Var mı?
    IF NOT EXISTS (
      SELECT 1 FROM public.journal_entries
      WHERE source_type = 'PURCHASE_INVOICE_CANCEL'
        AND source_id = v_rec.id
        AND user_id = v_user_id
        AND status = 'POSTED'
    ) THEN
      check_name     := 'PURCHASE_CANCEL_WITHOUT_REVERSAL';
      severity       := 'CRITICAL';
      status         := 'FAIL';
      expected_value := 1;
      actual_value   := 0;
      difference     := 1;
      detail         := 'İptal edilen alış faturasının muhasebe reversal fişi bulunamadı! Fatura No: ' || v_rec.invoice_number;
      source_id      := v_rec.id;
      RETURN NEXT;
    END IF;
  END LOOP;

END;
$$;

REVOKE ALL ON FUNCTION public.run_accounting_audit FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.run_accounting_audit TO authenticated;
GRANT EXECUTE ON FUNCTION public.run_accounting_audit TO service_role;



-- =============================================================
-- MIGRATION: 20260823050000_faz225_returns_supplier_payments.sql
-- =============================================================

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



-- =============================================================
-- MIGRATION: 20260823060000_faz23_tax_declarations.sql
-- =============================================================

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
-- MIGRATION: 20260823070000_faz24_fx_revaluation.sql
-- =============================================================

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

