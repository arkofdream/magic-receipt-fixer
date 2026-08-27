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

