-- =============== 1) TL-ONLY ENFORCEMENT ===============
CREATE OR REPLACE FUNCTION public.assert_try_only_currency()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cur TEXT;
BEGIN
  v_cur := UPPER(COALESCE(NULLIF(TRIM(NEW.currency), ''), 'TRY'));
  IF v_cur NOT IN ('TRY', 'TL') THEN
    RAISE EXCEPTION 'Dövizli işlemler henüz desteklenmiyor. Lütfen TL kullanın. (Gönderilen para birimi: %)', v_cur
      USING ERRCODE = '22023';
  END IF;
  NEW.currency := 'TRY';
  IF COALESCE(NEW.exchange_rate, 1) <> 1 THEN
    NEW.exchange_rate := 1;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_invoices_try_only ON public.invoices;
CREATE TRIGGER trg_invoices_try_only
BEFORE INSERT OR UPDATE ON public.invoices
FOR EACH ROW EXECUTE FUNCTION public.assert_try_only_currency();

DROP TRIGGER IF EXISTS trg_invoice_items_try_only ON public.invoice_items;
CREATE TRIGGER trg_invoice_items_try_only
BEFORE INSERT OR UPDATE ON public.invoice_items
FOR EACH ROW EXECUTE FUNCTION public.assert_try_only_currency();

DROP TRIGGER IF EXISTS trg_journal_lines_try_only ON public.journal_lines;
CREATE TRIGGER trg_journal_lines_try_only
BEFORE INSERT OR UPDATE ON public.journal_lines
FOR EACH ROW EXECUTE FUNCTION public.assert_try_only_currency();

-- =============== 2) AUDIT FIX ===============
CREATE OR REPLACE FUNCTION public.run_accounting_audit(p_year integer DEFAULT NULL::integer, p_month integer DEFAULT NULL::integer)
 RETURNS TABLE(check_name text, severity text, status text, expected_value numeric, actual_value numeric, difference numeric, detail text, source_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id             UUID;
  v_rec                 RECORD;
  v_stock_cogs_net      NUMERIC(14,2) := 0;
  v_journal_621_net     NUMERIC(14,2) := 0;
  v_inv_taxable_net     NUMERIC(14,2) := 0;
  v_journal_600_net     NUMERIC(14,2) := 0;
  v_ret_taxable_net     NUMERIC(14,2) := 0;
  v_journal_610_net     NUMERIC(14,2) := 0;
  v_inv_tax_net         NUMERIC(14,2) := 0;
  v_journal_391_net     NUMERIC(14,2) := 0;
  v_cust_subledger_net  NUMERIC(14,2) := 0;
  v_journal_120_net     NUMERIC(14,2) := 0;
  v_p_rec               RECORD;
  v_p_qty               NUMERIC;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.' USING ERRCODE = '42501';
  END IF;

  -- KONTROL 1: UNBALANCED_POSTED_JOURNAL
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

  -- KONTROL 2: POSTED_JOURNAL_WITHOUT_LINES
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

  -- KONTROL 3: INVOICE_WITHOUT_JOURNAL (iade fişleri de tanınır)
  FOR v_rec IN
    SELECT inv.id, inv.invoice_number, inv.grand_total
    FROM public.invoices inv
    LEFT JOIN public.journal_entries je
      ON je.source_id = inv.id
      AND je.source_type IN ('INVOICE', 'PURCHASE_INVOICE', 'SALES_RETURN', 'PURCHASE_RETURN', 'SALES_INVOICE', 'INVOICE_RETURN')
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
    detail         := 'Onaylı faturanın muhasebe yevmiye fişi bulunamadı! Fatura No: ' || v_rec.invoice_number;
    source_id      := v_rec.id;
    RETURN NEXT;
  END LOOP;

  -- KONTROL 4: NEGATIVE_STOCK
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

  -- KONTROL 5: STMM <-> 621
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
    AND (coa.code = '621' OR coa.system_tag IN ('STMM', 'COGS'))
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

  -- KONTROL 6: SATIŞ <-> 600 (iadeler hariç; iadeler 610 hesabında izlenir)
  SELECT COALESCE(SUM(COALESCE(inv.taxable_amount, inv.grand_total - COALESCE(inv.total_vat, 0), 0)), 0)
  INTO v_inv_taxable_net
  FROM public.invoices inv
  WHERE inv.user_id = v_user_id
    AND inv.posted = true
    AND inv.status != 'IPTAL'
    AND COALESCE(inv.type, 'SATIS') IN ('SATIS', 'E_ARSIV', 'E_FATURA', 'TEVKIFAT', 'ISTISNA')
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
    AND (coa.code = '600' OR coa.system_tag IN ('YURTICI_SATIS', 'SATIS_GELIRI'))
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

  -- KONTROL 6b: SATIŞ İADELERİ <-> 610
  SELECT COALESCE(SUM(COALESCE(inv.taxable_amount, inv.grand_total - COALESCE(inv.total_vat, 0), 0)), 0)
  INTO v_ret_taxable_net
  FROM public.invoices inv
  WHERE inv.user_id = v_user_id
    AND inv.posted = true
    AND inv.status != 'IPTAL'
    AND COALESCE(inv.type, 'SATIS') IN ('SATIS_IADE', 'IADE')
    AND (p_year IS NULL OR EXTRACT(YEAR FROM inv.invoice_date) = p_year)
    AND (p_month IS NULL OR EXTRACT(MONTH FROM inv.invoice_date) = p_month);

  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_journal_610_net
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND (coa.code = '610' OR coa.system_tag IN ('SATIS_IADE', 'SALES_RETURNS'))
    AND (p_year IS NULL OR je.period_year = p_year)
    AND (p_month IS NULL OR je.period_month = p_month);

  check_name     := 'SALES_RETURN_610_MISMATCH';
  expected_value := v_ret_taxable_net;
  actual_value   := v_journal_610_net;
  difference     := v_journal_610_net - v_ret_taxable_net;
  source_id      := NULL;

  IF ABS(difference) > 0.05 THEN
    severity := 'WARNING';
    status   := 'WARNING';
    detail   := 'Satış iadesi matrahı (' || v_ret_taxable_net || ' TL) ile 610 hesabı (' || v_journal_610_net || ' TL) arasında fark var!';
  ELSE
    severity := 'INFO';
    status   := 'PASS';
    detail   := 'Satış iadeleri ile 610 hesabı tam mutabık.';
  END IF;
  RETURN NEXT;

  -- KONTROL 7: KDV <-> 391 (iade KDV'si 191 hesabında ters kaydedilir, hariç tutulur)
  SELECT COALESCE(SUM(COALESCE(inv.total_vat, 0) - COALESCE(inv.total_tevkifat, 0)), 0)
  INTO v_inv_tax_net
  FROM public.invoices inv
  WHERE inv.user_id = v_user_id
    AND inv.posted = true
    AND inv.status != 'IPTAL'
    AND COALESCE(inv.type, 'SATIS') IN ('SATIS', 'E_ARSIV', 'E_FATURA', 'TEVKIFAT', 'ISTISNA')
    AND (p_year IS NULL OR EXTRACT(YEAR FROM inv.invoice_date) = p_year)
    AND (p_month IS NULL OR EXTRACT(MONTH FROM inv.invoice_date) = p_month);

  SELECT COALESCE(SUM(jl.credit - jl.debit), 0)
  INTO v_journal_391_net
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND (coa.code = '391' OR coa.system_tag IN ('HESAPLANAN_KDV', 'TAX_OUTPUT'))
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

  -- KONTROL 8: CARİ (yalnızca müşteriler) <-> 120
  SELECT COALESCE(SUM(
    CASE
      WHEN t.txn_type = 'BORC' THEN t.amount
      WHEN t.txn_type = 'ALACAK' THEN -t.amount
      ELSE 0
    END
  ), 0)
  INTO v_cust_subledger_net
  FROM public.account_transactions t
  INNER JOIN public.customers c ON c.id = t.customer_id
  WHERE t.user_id = v_user_id
    AND t.deleted_at IS NULL
    AND COALESCE(c.partner_type, 'MUSTERI') = 'MUSTERI'
    AND (p_year IS NULL OR EXTRACT(YEAR FROM t.txn_date) = p_year)
    AND (p_month IS NULL OR EXTRACT(MONTH FROM t.txn_date) = p_month);

  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_journal_120_net
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND (coa.code = '120' OR coa.system_tag IN ('ALICILAR', 'AR'))
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
    detail   := 'Cari (müşteri) hareketler toplamı (' || v_cust_subledger_net || ' TL) ile 120 hesabı (' || v_journal_120_net || ' TL) arasında fark var!';
  ELSE
    severity := 'INFO';
    status   := 'PASS';
    detail   := 'Cari hareketler ile 120 hesabı tam mutabık.';
  END IF;
  RETURN NEXT;

END;
$function$;

GRANT EXECUTE ON FUNCTION public.run_accounting_audit(integer, integer) TO authenticated, service_role;