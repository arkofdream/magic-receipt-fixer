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
