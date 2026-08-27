-- ============================================================================
-- FAZ 4.0: MUHASEBE DÖNEM YÖNETİMİ, DEĞERLEME FİŞİ VE KAPALI DÖNEM GÜVENCESİ
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-27
-- ============================================================================

-- 1. accounting_periods Tablosu Güvencesi
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

-- stock_movements maliyet sütunları güvencesi
ALTER TABLE public.stock_movements
  ADD COLUMN IF NOT EXISTS total_cost NUMERIC(14,2) NULL,
  ADD COLUMN IF NOT EXISTS unit_cost NUMERIC(14,2) NULL;

-- 2. Güvenli Dönem Açıklık Doğrulama Fonksiyonu (assert_accounting_period_open)
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

  SELECT ap.status INTO v_status
  FROM public.accounting_periods ap
  WHERE ap.user_id = p_user_id
    AND ap.period_year = v_year
    AND ap.period_month = v_month;

  IF v_status IN ('CLOSED', 'LOCKED') THEN
    RAISE EXCEPTION 'Muhasebe dönemi (%/%) kapatılmış veya kilitlenmiştir. Kapalı döneme yeni kayıt yapılamaz veya mevcut kayıtlar değiştirilemez.',
      v_month, v_year
      USING ERRCODE = '22023';
  END IF;
END;
$$;

-- Tek parametreli assert_accounting_period_open (auth.uid() varsayılanı ile)
CREATE OR REPLACE FUNCTION public.assert_accounting_period_open(
  p_date DATE
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.' USING ERRCODE = '42501';
  END IF;

  PERFORM public.assert_accounting_period_open(v_user_id, p_date);
END;
$$;

REVOKE ALL ON FUNCTION public.assert_accounting_period_open(UUID, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.assert_accounting_period_open(UUID, DATE) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.assert_accounting_period_open(DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.assert_accounting_period_open(DATE) TO authenticated, service_role;


-- 3. Kapsamlı Muhasebe Denetim Motoru (run_accounting_audit) - "status" ambiguous hatası giderilmiş
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
    SELECT je.id, je.entry_number, je.entry_date, je.total_debit, je.total_credit
    FROM public.journal_entries je
    WHERE je.user_id = v_user_id
      AND je.status = 'POSTED'
      AND je.total_debit != je.total_credit
      AND (p_year IS NULL OR je.period_year = p_year)
      AND (p_month IS NULL OR je.period_month = p_month)
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
    SELECT p.id, p.name
    FROM public.products p
    WHERE p.user_id = v_user_id AND p.deleted_at IS NULL AND COALESCE(p.track_stock, true) = true
  LOOP
    SELECT COALESCE(SUM(
      CASE
        WHEN sm.movement_type IN ('GIRIS', 'TRANSFER_IN') THEN sm.quantity
        WHEN sm.movement_type IN ('CIKIS', 'TRANSFER_OUT') THEN -sm.quantity
        ELSE 0
      END
    ), 0)
    INTO v_p_qty
    FROM public.stock_movements sm
    WHERE sm.product_id = v_p_rec.id
      AND sm.user_id = v_user_id
      AND sm.deleted_at IS NULL;

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
  -- KONTROL 6: SATIŞ ↔ 600 MUTABAKATI
  -- ========================================================
  SELECT COALESCE(SUM(
    CASE
      WHEN inv.type = 'IADE' THEN -inv.taxable_amount
      ELSE inv.taxable_amount
    END
  ), 0)
  INTO v_inv_taxable_net
  FROM public.invoices inv
  WHERE inv.user_id = v_user_id
    AND inv.posted = true
    AND inv.status != 'IPTAL'
    AND (p_year IS NULL OR EXTRACT(YEAR FROM inv.invoice_date) = p_year)
    AND (p_month IS NULL OR EXTRACT(MONTH FROM inv.invoice_date) = p_month);

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
GRANT EXECUTE ON FUNCTION public.run_accounting_audit TO authenticated, service_role;


-- 4. Dönem Kapatma RPC'si (close_accounting_period)
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
  SELECT ap.id, ap.status INTO v_period_id, v_status
  FROM public.accounting_periods ap
  WHERE ap.user_id = v_user_id
    AND ap.period_year = p_year
    AND ap.period_month = p_month
  FOR UPDATE;

  IF v_status = 'LOCKED' THEN
    RAISE EXCEPTION 'Bu dönem (%/%) kilitlidir (LOCKED). Yeniden kapatılamaz.', p_month, p_year;
  ELSIF v_status = 'CLOSED' THEN
    RETURN jsonb_build_object(
      'period_id', v_period_id,
      'period_year', p_year,
      'period_month', p_month,
      'status', 'CLOSED',
      'message', 'Dönem zaten kapalı durumdadır.'
    );
  END IF;

  -- Kapsamlı Denetim Kontrolü: Bu dönemde CRITICAL hata var mı?
  SELECT COUNT(*)
  INTO v_critical_cnt
  FROM public.run_accounting_audit(p_year, p_month) audit_res
  WHERE audit_res.severity = 'CRITICAL' AND audit_res.status = 'FAIL';

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
GRANT EXECUTE ON FUNCTION public.close_accounting_period TO authenticated, service_role;


-- 5. Dönem Yeniden Açma RPC'si (reopen_accounting_period)
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

  SELECT ap.id, ap.status INTO v_period_id, v_status
  FROM public.accounting_periods ap
  WHERE ap.user_id = v_user_id
    AND ap.period_year = p_year
    AND ap.period_month = p_month
  FOR UPDATE;

  IF v_status = 'LOCKED' THEN
    RAISE EXCEPTION 'Bu dönem (%/%) kilitlidir (LOCKED) ve açılamaz.', p_month, p_year;
  ELSIF v_status IS NULL OR v_status = 'OPEN' THEN
    RETURN jsonb_build_object(
      'period_id', v_period_id,
      'period_year', p_year,
      'period_month', p_month,
      'status', 'OPEN',
      'message', 'Dönem zaten açıktır.'
    );
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
GRANT EXECUTE ON FUNCTION public.reopen_accounting_period TO authenticated, service_role;


-- 6. Atomik Stok Değerleme & Maliyet Düzeltme RPC'si (create_stock_valuation_adjustment)
CREATE OR REPLACE FUNCTION public.create_stock_valuation_adjustment(
  p_product_id      UUID,
  p_warehouse_id    UUID,
  p_valuation_date  DATE,
  p_new_unit_cost   NUMERIC,
  p_adjustment_qty  NUMERIC DEFAULT 0,
  p_description     TEXT DEFAULT 'Stok Değerleme ve Maliyet Düzeltme Fişi',
  p_document_no     TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id         UUID;
  v_p_name          TEXT;
  v_cur_qty         NUMERIC := 0;
  v_cur_cost        NUMERIC := 0;
  v_diff_qty        NUMERIC := 0;
  v_cost_impact     NUMERIC(14,2) := 0;
  v_year            INTEGER;
  v_month           INTEGER;
  v_sm_id           UUID;
  v_je_id           UUID;
  v_je_number       TEXT;
  v_seq             INTEGER;
  v_now             TIMESTAMPTZ := now();
  v_doc_no          TEXT;
  v_acc_153_id      UUID;
  v_acc_rev_id      UUID;
  v_line_order      INTEGER := 1;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.' USING ERRCODE = '42501';
  END IF;

  IF p_product_id IS NULL OR p_warehouse_id IS NULL THEN
    RAISE EXCEPTION 'Ürün ve depo seçimi zorunludur.';
  END IF;

  IF p_valuation_date IS NULL THEN
    RAISE EXCEPTION 'Değerleme tarihi zorunludur.';
  END IF;

  -- Kapalı Dönem Denetimi
  PERFORM public.assert_accounting_period_open(v_user_id, p_valuation_date);

  v_year  := EXTRACT(YEAR FROM p_valuation_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM p_valuation_date)::INTEGER;

  -- Ürün bilgisi ve kilit
  SELECT p.name, COALESCE(p.purchase_price, 0)
  INTO v_p_name, v_cur_cost
  FROM public.products p
  WHERE p.id = p_product_id AND p.user_id = v_user_id
  FOR UPDATE;

  IF v_p_name IS NULL THEN
    RAISE EXCEPTION 'Ürün bulunamadı veya yetkiniz yok.';
  END IF;

  -- Mevcut stok miktarı
  SELECT COALESCE(SUM(
    CASE
      WHEN sm.movement_type IN ('GIRIS', 'TRANSFER_IN') THEN sm.quantity
      WHEN sm.movement_type IN ('CIKIS', 'TRANSFER_OUT') THEN -sm.quantity
      ELSE 0
    END
  ), 0)
  INTO v_cur_qty
  FROM public.stock_movements sm
  WHERE sm.product_id = p_product_id
    AND sm.user_id = v_user_id
    AND sm.deleted_at IS NULL;

  v_diff_qty := COALESCE(p_adjustment_qty, 0);

  -- Maliyet farkı hesabı
  IF p_new_unit_cost > 0 AND p_new_unit_cost != v_cur_cost THEN
    v_cost_impact := ROUND(((p_new_unit_cost - v_cur_cost) * GREATEST(v_cur_qty + v_diff_qty, 0)), 2);
  ELSIF v_diff_qty != 0 THEN
    v_cost_impact := ROUND((v_diff_qty * COALESCE(NULLIF(p_new_unit_cost, 0), v_cur_cost)), 2);
  END IF;

  v_doc_no := COALESCE(NULLIF(TRIM(p_document_no), ''), 'DEG-' || to_char(p_valuation_date, 'YYYYMMDD') || '-' || substring(p_product_id::text from 1 for 4));

  -- 1. Stok Hareketi Kaydı (ADJUSTMENT)
  INSERT INTO public.stock_movements (
    user_id,
    product_id,
    warehouse_id,
    movement_type,
    quantity,
    unit_price,
    total_cost,
    movement_date,
    document_no,
    description,
    source,
    created_at
  ) VALUES (
    v_user_id,
    p_product_id,
    p_warehouse_id,
    CASE WHEN v_diff_qty >= 0 THEN 'GIRIS' ELSE 'CIKIS' END,
    ABS(v_diff_qty),
    COALESCE(NULLIF(p_new_unit_cost, 0), v_cur_cost),
    ABS(v_cost_impact),
    p_valuation_date,
    v_doc_no,
    COALESCE(p_description, 'Stok Değerleme Fişi: ' || v_p_name),
    'MANUAL',
    v_now
  ) RETURNING id INTO v_sm_id;

  -- 2. Ürün birim alış maliyeti güncellemesi
  IF p_new_unit_cost > 0 THEN
    UPDATE public.products
    SET purchase_price = p_new_unit_cost,
        updated_at = v_now
    WHERE id = p_product_id;
  END IF;

  -- 3. Muhasebe Yevmiye Fişi Oluşturma (Fark varsa)
  IF ABS(v_cost_impact) >= 0.01 THEN
    -- 153 Ticari Mallar Hesabı
    SELECT coa.id INTO v_acc_153_id FROM public.chart_of_accounts coa
    WHERE (coa.code = '153' OR coa.system_tag = 'TICARI_MALLAR') AND (coa.user_id = v_user_id OR coa.user_id IS NULL) AND coa.is_active = true
    ORDER BY coa.user_id NULLS LAST LIMIT 1;

    -- Değer artışı ise 649 (Diğer Olağan Gelir ve Kârlar), azalış ise 659 (Diğer Olağan Gider ve Zararlar)
    IF v_cost_impact > 0 THEN
      SELECT coa.id INTO v_acc_rev_id FROM public.chart_of_accounts coa
      WHERE (coa.code = '649' OR coa.code = '679' OR coa.system_tag = 'DIGER_GELIR') AND (coa.user_id = v_user_id OR coa.user_id IS NULL) AND coa.is_active = true
      ORDER BY coa.user_id NULLS LAST LIMIT 1;
    ELSE
      SELECT coa.id INTO v_acc_rev_id FROM public.chart_of_accounts coa
      WHERE (coa.code = '659' OR coa.code = '689' OR coa.system_tag = 'DIGER_GIDER') AND (coa.user_id = v_user_id OR coa.user_id IS NULL) AND coa.is_active = true
      ORDER BY coa.user_id NULLS LAST LIMIT 1;
    END IF;

    IF v_acc_153_id IS NOT NULL AND v_acc_rev_id IS NOT NULL THEN
      -- Yevmiye Sıra No
      SELECT COALESCE(MAX(je.sequence_number), 0) + 1 INTO v_seq
      FROM public.journal_entries je
      WHERE je.user_id = v_user_id AND je.period_year = v_year;

      v_je_number := 'YEV-' || v_year || '-' || LPAD(v_seq::text, 6, '0');

      INSERT INTO public.journal_entries (
        user_id,
        period_year,
        period_month,
        entry_number,
        sequence_number,
        entry_date,
        entry_type,
        source_type,
        source_id,
        description,
        total_debit,
        total_credit,
        status,
        posted_at,
        created_at
      ) VALUES (
        v_user_id,
        v_year,
        v_month,
        v_je_number,
        v_seq,
        p_valuation_date,
        'DEGERLEME',
        'STOCK_VALUATION',
        v_sm_id,
        'Stok Değerleme & Maliyet Farkı: ' || v_p_name || ' (' || v_doc_no || ')',
        ABS(v_cost_impact),
        ABS(v_cost_impact),
        'POSTED',
        v_now,
        v_now
      ) RETURNING id INTO v_je_id;

      -- Yevmiye Satırları
      IF v_cost_impact > 0 THEN
        -- Borç 153 Ticari Mallar (+Değer), Alacak 649 Gelir
        INSERT INTO public.journal_lines (user_id, journal_entry_id, line_number, account_id, description, debit, credit)
        VALUES (v_user_id, v_je_id, 1, v_acc_153_id, 'Stok Değer Artışı - ' || v_p_name, ABS(v_cost_impact), 0);

        INSERT INTO public.journal_lines (user_id, journal_entry_id, line_number, account_id, description, debit, credit)
        VALUES (v_user_id, v_je_id, 2, v_acc_rev_id, 'Stok Değerleme Kârı - ' || v_p_name, 0, ABS(v_cost_impact));
      ELSE
        -- Borç 659 Gider, Alacak 153 Ticari Mallar (-Değer)
        INSERT INTO public.journal_lines (user_id, journal_entry_id, line_number, account_id, description, debit, credit)
        VALUES (v_user_id, v_je_id, 1, v_acc_rev_id, 'Stok Değer Düşüklüğü / Sayım Farkı - ' || v_p_name, ABS(v_cost_impact), 0);

        INSERT INTO public.journal_lines (user_id, journal_entry_id, line_number, account_id, description, debit, credit)
        VALUES (v_user_id, v_je_id, 2, v_acc_153_id, 'Stok Değer Azalışı - ' || v_p_name, 0, ABS(v_cost_impact));
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'product_id', p_product_id,
    'product_name', v_p_name,
    'stock_movement_id', v_sm_id,
    'journal_entry_id', v_je_id,
    'journal_number', v_je_number,
    'cost_impact', v_cost_impact,
    'new_unit_cost', p_new_unit_cost,
    'document_no', v_doc_no
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_stock_valuation_adjustment FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_stock_valuation_adjustment TO authenticated, service_role;


-- 7. Kapalı Dönem Koruma Trigger'ları (invoices, journal_entries, stock_movements, account_transactions)
-- Mevcut açık dönem işlemlerini ASLA aksatmaz; yalnızca CLOSED veya LOCKED dönemlerde 22023 hatası fırlatır.

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


CREATE OR REPLACE FUNCTION public.check_invoice_period_open()
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
    v_date := OLD.invoice_date;
    v_uid  := OLD.user_id;
  ELSE
    v_date := NEW.invoice_date;
    v_uid  := NEW.user_id;
  END IF;

  IF v_date IS NOT NULL AND v_uid IS NOT NULL THEN
    PERFORM public.assert_accounting_period_open(v_uid, v_date);
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.invoice_date IS DISTINCT FROM NEW.invoice_date THEN
    PERFORM public.assert_accounting_period_open(OLD.user_id, OLD.invoice_date);
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_check_invoice_period ON public.invoices;
CREATE TRIGGER trg_check_invoice_period
  BEFORE INSERT OR UPDATE OR DELETE ON public.invoices
  FOR EACH ROW EXECUTE FUNCTION public.check_invoice_period_open();


CREATE OR REPLACE FUNCTION public.check_stock_movement_period_open()
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
    v_date := OLD.movement_date;
    v_uid  := OLD.user_id;
  ELSE
    v_date := NEW.movement_date;
    v_uid  := NEW.user_id;
  END IF;

  IF v_date IS NOT NULL AND v_uid IS NOT NULL THEN
    PERFORM public.assert_accounting_period_open(v_uid, v_date);
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.movement_date IS DISTINCT FROM NEW.movement_date THEN
    PERFORM public.assert_accounting_period_open(OLD.user_id, OLD.movement_date);
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_check_stock_movement_period ON public.stock_movements;
CREATE TRIGGER trg_check_stock_movement_period
  BEFORE INSERT OR UPDATE OR DELETE ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION public.check_stock_movement_period_open();


CREATE OR REPLACE FUNCTION public.check_account_transaction_period_open()
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
    v_date := OLD.txn_date;
    v_uid  := OLD.user_id;
  ELSE
    v_date := NEW.txn_date;
    v_uid  := NEW.user_id;
  END IF;

  IF v_date IS NOT NULL AND v_uid IS NOT NULL THEN
    PERFORM public.assert_accounting_period_open(v_uid, v_date);
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.txn_date IS DISTINCT FROM NEW.txn_date THEN
    PERFORM public.assert_accounting_period_open(OLD.user_id, OLD.txn_date);
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_check_account_transaction_period ON public.account_transactions;
CREATE TRIGGER trg_check_account_transaction_period
  BEFORE INSERT OR UPDATE OR DELETE ON public.account_transactions
  FOR EACH ROW EXECUTE FUNCTION public.check_account_transaction_period_open();

-- PostgREST şema önbelleğini anında tazele
NOTIFY pgrst, 'reload schema';
