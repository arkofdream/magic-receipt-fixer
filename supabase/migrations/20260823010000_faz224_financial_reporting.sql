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

  -- STMM Mutabakatı: stock_movements tablosundaki fiili satış maliyetleri (ürün alış fiyatı x miktar)
  SELECT COALESCE(SUM(
    CASE
      WHEN sm.movement_type = 'CIKIS' THEN sm.quantity * COALESCE(p.purchase_price, sm.unit_price, 0)
      WHEN sm.movement_type = 'GIRIS' AND sm.source = 'FATURA' THEN -sm.quantity * COALESCE(p.purchase_price, sm.unit_price, 0)
      ELSE 0
    END
  ), 0)
  INTO v_stock_movements_cogs
  FROM public.stock_movements sm
  LEFT JOIN public.products p ON p.id = sm.product_id
  WHERE sm.user_id = v_user_id
    AND sm.deleted_at IS NULL
    AND sm.source IN ('FATURA', 'FATURA_IPTAL')
    AND sm.movement_date >= v_start_date
    AND sm.movement_date <= v_end_date;

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
