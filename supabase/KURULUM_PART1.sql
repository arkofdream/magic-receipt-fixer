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
  account_type    TEXT NOT NULL,
  normal_balance  TEXT NOT NULL,
  parent_id       UUID NULL REFERENCES public.chart_of_accounts(id) ON DELETE SET NULL,
  level           INTEGER NOT NULL DEFAULT 2,
  is_system       BOOLEAN NOT NULL DEFAULT false,
  is_active       BOOLEAN NOT NULL DEFAULT true,
  system_tag      TEXT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.chart_of_accounts
  ADD CONSTRAINT IF NOT EXISTS coa_account_type_check
    CHECK (account_type IN ('ASSET','LIABILITY','EQUITY','INCOME','EXPENSE')),
  ADD CONSTRAINT IF NOT EXISTS coa_normal_balance_check
    CHECK (normal_balance IN ('DEBIT','CREDIT')),
  ADD CONSTRAINT IF NOT EXISTS coa_level_check
    CHECK (level BETWEEN 1 AND 4),
  ADD CONSTRAINT IF NOT EXISTS coa_system_user_check
    CHECK (NOT (is_system = true AND user_id IS NOT NULL));

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
  status          TEXT NOT NULL DEFAULT 'DRAFT',
  total_debit     NUMERIC(14,2) NOT NULL DEFAULT 0,
  total_credit    NUMERIC(14,2) NOT NULL DEFAULT 0,
  period_year     INTEGER NOT NULL,
  period_month    INTEGER NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.journal_entries
  ADD CONSTRAINT IF NOT EXISTS je_status_check
    CHECK (status IN ('DRAFT','POSTED','CANCELLED')),
  ADD CONSTRAINT IF NOT EXISTS je_total_debit_check
    CHECK (total_debit >= 0),
  ADD CONSTRAINT IF NOT EXISTS je_total_credit_check
    CHECK (total_credit >= 0),
  -- POSTED fişte borç = alacak zorunlu; DRAFT/CANCELLED'de değil
  ADD CONSTRAINT IF NOT EXISTS je_posted_balanced_check
    CHECK (status != 'POSTED' OR total_debit = total_credit),
  ADD CONSTRAINT IF NOT EXISTS je_period_month_check
    CHECK (period_month BETWEEN 1 AND 12),
  ADD CONSTRAINT IF NOT EXISTS je_period_year_check
    CHECK (period_year BETWEEN 2000 AND 2100);

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
  ADD CONSTRAINT IF NOT EXISTS jl_debit_positive_check   CHECK (debit >= 0),
  ADD CONSTRAINT IF NOT EXISTS jl_credit_positive_check  CHECK (credit >= 0),
  -- Bir satır hem borç hem alacak olamaz
  ADD CONSTRAINT IF NOT EXISTS jl_debit_or_credit_check  CHECK (debit = 0 OR credit = 0),
  -- Tamamen sıfır satır reddedilir
  ADD CONSTRAINT IF NOT EXISTS jl_nonzero_check          CHECK (debit > 0 OR credit > 0),
  ADD CONSTRAINT IF NOT EXISTS jl_exchange_rate_check    CHECK (exchange_rate > 0);

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
  ADD CONSTRAINT IF NOT EXISTS ii_quantity_check       CHECK (quantity > 0),
  ADD CONSTRAINT IF NOT EXISTS ii_unit_price_check     CHECK (unit_price >= 0),
  ADD CONSTRAINT IF NOT EXISTS ii_taxable_check        CHECK (taxable_amount >= 0),
  ADD CONSTRAINT IF NOT EXISTS ii_vat_amount_check     CHECK (vat_amount >= 0),
  ADD CONSTRAINT IF NOT EXISTS ii_line_total_check     CHECK (line_total >= 0),
  ADD CONSTRAINT IF NOT EXISTS ii_vat_rate_check       CHECK (vat_rate BETWEEN 0 AND 100),
  ADD CONSTRAINT IF NOT EXISTS ii_exchange_rate_check  CHECK (exchange_rate > 0),
  ADD CONSTRAINT IF NOT EXISTS ii_discount_rate_check  CHECK (discount_rate BETWEEN 0 AND 100);

ALTER TABLE public.invoice_items
  ADD CONSTRAINT IF NOT EXISTS ii_invoice_line_unique UNIQUE (invoice_id, line_number);

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
  ADD CONSTRAINT IF NOT EXISTS itl_direction_check          CHECK (direction IN ('SATIS','ALIS')),
  ADD CONSTRAINT IF NOT EXISTS itl_vat_rate_check           CHECK (vat_rate BETWEEN 0 AND 100),
  ADD CONSTRAINT IF NOT EXISTS itl_taxable_check            CHECK (taxable_amount >= 0),
  ADD CONSTRAINT IF NOT EXISTS itl_tax_amount_check         CHECK (tax_amount >= 0),
  ADD CONSTRAINT IF NOT EXISTS itl_withholding_rate_check   CHECK (withholding_rate BETWEEN 0 AND 100),
  ADD CONSTRAINT IF NOT EXISTS itl_withholding_amount_check CHECK (withholding_amount >= 0),
  ADD CONSTRAINT IF NOT EXISTS itl_exchange_rate_check      CHECK (exchange_rate > 0),
  ADD CONSTRAINT IF NOT EXISTS itl_period_month_check       CHECK (period_month BETWEEN 1 AND 12),
  ADD CONSTRAINT IF NOT EXISTS itl_taxable_try_check        CHECK (taxable_amount_try >= 0),
  ADD CONSTRAINT IF NOT EXISTS itl_tax_try_check            CHECK (tax_amount_try >= 0);

-- UNIQUE: orijinal + ters kayıt ayrımı için is_reversal dahil
ALTER TABLE public.invoice_tax_lines
  ADD CONSTRAINT IF NOT EXISTS itl_unique_per_rate
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
  ADD CONSTRAINT IF NOT EXISTS pay_direction_check     CHECK (direction IN ('IN','OUT')),
  ADD CONSTRAINT IF NOT EXISTS pay_amount_check        CHECK (amount > 0),
  ADD CONSTRAINT IF NOT EXISTS pay_amount_try_check    CHECK (amount_try > 0),
  ADD CONSTRAINT IF NOT EXISTS pay_exchange_rate_check CHECK (exchange_rate > 0),
  ADD CONSTRAINT IF NOT EXISTS pay_method_check
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
  ADD CONSTRAINT IF NOT EXISTS pa_amount_check          CHECK (allocated_amount > 0),
  ADD CONSTRAINT IF NOT EXISTS pa_payment_invoice_unique UNIQUE (payment_id, invoice_id);

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
  ADD CONSTRAINT IF NOT EXISTS er_buying_rate_check  CHECK (buying_rate > 0),
  ADD CONSTRAINT IF NOT EXISTS er_selling_rate_check CHECK (selling_rate > 0),
  ADD CONSTRAINT IF NOT EXISTS er_rate_date_check    CHECK (rate_date <= CURRENT_DATE + 1),
  ADD CONSTRAINT IF NOT EXISTS er_rate_type_check    CHECK (rate_type IN ('TCMB','SERBEST','MANUEL'));

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
  ADD CONSTRAINT IF NOT EXISTS ec_last_number_check CHECK (last_number >= 0),
  ADD CONSTRAINT IF NOT EXISTS ec_year_check        CHECK (year BETWEEN 2000 AND 2100),
  ADD CONSTRAINT IF NOT EXISTS ec_type_check
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

