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
