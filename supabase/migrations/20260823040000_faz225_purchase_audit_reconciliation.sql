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
