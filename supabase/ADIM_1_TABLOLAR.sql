-- =============================================================
-- ADIM 1 / 3: TEMEL TABLOLAR VE TEK DÜZEN HESAP PLANI
-- =============================================================

CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 1. HESAP PLANI TABLOSU (CHART OF ACCOUNTS)
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

CREATE UNIQUE INDEX IF NOT EXISTS coa_user_code_unique ON public.chart_of_accounts(user_id, code) WHERE user_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS coa_system_code_unique ON public.chart_of_accounts(code) WHERE user_id IS NULL;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.chart_of_accounts TO authenticated;
GRANT ALL ON public.chart_of_accounts TO service_role;
ALTER TABLE public.chart_of_accounts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "coa_select_own_or_system" ON public.chart_of_accounts;
CREATE POLICY "coa_select_own_or_system" ON public.chart_of_accounts FOR SELECT TO authenticated USING (user_id = auth.uid() OR user_id IS NULL);
DROP POLICY IF EXISTS "coa_insert_own" ON public.chart_of_accounts;
CREATE POLICY "coa_insert_own" ON public.chart_of_accounts FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid() AND is_system = false);
DROP POLICY IF EXISTS "coa_update_own" ON public.chart_of_accounts;
CREATE POLICY "coa_update_own" ON public.chart_of_accounts FOR UPDATE TO authenticated USING (user_id = auth.uid() AND is_system = false);

-- 2. YEVMİYE FİŞLERİ TABLOSU (JOURNAL ENTRIES)
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

CREATE UNIQUE INDEX IF NOT EXISTS je_user_entry_number_unique ON public.journal_entries(user_id, entry_number);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.journal_entries TO authenticated;
GRANT ALL ON public.journal_entries TO service_role;
ALTER TABLE public.journal_entries ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "je_all_own" ON public.journal_entries;
CREATE POLICY "je_all_own" ON public.journal_entries FOR ALL TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- 3. YEVMİYE SATIRLARI (JOURNAL LINES)
CREATE TABLE IF NOT EXISTS public.journal_lines (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  journal_entry_id  UUID NOT NULL REFERENCES public.journal_entries(id) ON DELETE CASCADE,
  user_id           UUID NOT NULL,
  account_id        UUID NOT NULL REFERENCES public.chart_of_accounts(id),
  description       TEXT NULL,
  debit             NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (debit >= 0),
  credit            NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
  currency          TEXT NOT NULL DEFAULT 'TRY',
  foreign_amount    NUMERIC(14,2) NULL,
  exchange_rate     NUMERIC(14,6) NOT NULL DEFAULT 1 CHECK (exchange_rate > 0),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT jl_one_side_check CHECK ((debit > 0 AND credit = 0) OR (credit > 0 AND debit = 0))
);

CREATE INDEX IF NOT EXISTS jl_entry_id_idx ON public.journal_lines(journal_entry_id);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.journal_lines TO authenticated;
GRANT ALL ON public.journal_lines TO service_role;
ALTER TABLE public.journal_lines ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "jl_all_own" ON public.journal_lines;
CREATE POLICY "jl_all_own" ON public.journal_lines FOR ALL TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- 4. MUHASEBE DÖNEMLERİ (ACCOUNTING PERIODS)
CREATE TABLE IF NOT EXISTS public.accounting_periods (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL,
  period_year     INTEGER NOT NULL CHECK (period_year BETWEEN 2000 AND 2100),
  period_month    INTEGER NOT NULL CHECK (period_month BETWEEN 1 AND 12),
  status          TEXT NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','CLOSED','LOCKED')),
  closed_at       TIMESTAMPTZ NULL,
  closed_by       UUID NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS periods_user_year_month_unique ON public.accounting_periods(user_id, period_year, period_month);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.accounting_periods TO authenticated;
GRANT ALL ON public.accounting_periods TO service_role;
ALTER TABLE public.accounting_periods ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "periods_all_own" ON public.accounting_periods;
CREATE POLICY "periods_all_own" ON public.accounting_periods FOR ALL TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- 5. STANDART TEK DÜZEN HESAPLARINI SEED ET (SİSTEM HESAPLARI)
INSERT INTO public.chart_of_accounts (code, name, account_type, normal_balance, level, is_system, system_tag)
VALUES
  ('100', 'Kasa Hesabı', 'ASSET', 'DEBIT', 2, true, 'CASH'),
  ('102', 'Bankalar Hesabı', 'ASSET', 'DEBIT', 2, true, 'BANK'),
  ('120', 'Alıcılar Hesabı (Müşteriler)', 'ASSET', 'DEBIT', 2, true, 'AR'),
  ('153', 'Ticari Mallar Hesabı', 'ASSET', 'DEBIT', 2, true, 'INVENTORY'),
  ('191', 'İndirilecek KDV Hesabı', 'ASSET', 'DEBIT', 2, true, 'VAT_IN'),
  ('320', 'Satıcılar Hesabı (Tedarikçiler)', 'LIABILITY', 'CREDIT', 2, true, 'AP'),
  ('360', 'Ödenecek Vergi ve Fonlar (Stopaj)', 'LIABILITY', 'CREDIT', 2, true, 'TAX_PAYABLE'),
  ('391', 'Hesaplanan KDV Hesabı', 'LIABILITY', 'CREDIT', 2, true, 'VAT_OUT'),
  ('600', 'Yurtiçi Satışlar Hesabı', 'INCOME', 'CREDIT', 2, true, 'SALES'),
  ('610', 'Satıştan İadeler Hesabı (-)', 'INCOME', 'DEBIT', 2, true, 'SALES_RETURN'),
  ('621', 'Satılan Ticari Mallar Maliyeti (STMM)', 'EXPENSE', 'DEBIT', 2, true, 'COGS'),
  ('646', 'Kambiyo Kârları Hesabı', 'INCOME', 'CREDIT', 2, true, 'FX_GAIN'),
  ('656', 'Kambiyo Zararları Hesabı', 'EXPENSE', 'DEBIT', 2, true, 'FX_LOSS'),
  ('770', 'Genel Yönetim Giderleri', 'EXPENSE', 'DEBIT', 2, true, 'EXPENSE')
ON CONFLICT (code) WHERE user_id IS NULL DO NOTHING;
