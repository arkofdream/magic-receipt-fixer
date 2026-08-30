-- FAZ 14: RPC Düzeltmeleri ve Gelişmiş Denetim (Audit) Fonksiyonu

CREATE OR REPLACE FUNCTION public.approve_purchase_invoice(p_invoice_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id             UUID;
  v_inv                 RECORD;
  v_item                RECORD;
  v_year                INTEGER;
  v_month               INTEGER;
  v_now                 TIMESTAMPTZ := now();
  v_journal_entry_id    UUID;
  v_journal_number      TEXT;
  
  v_acc_320_id          UUID;
  v_acc_191_id          UUID;
  v_acc_153_id          UUID;
  
  v_total_153           NUMERIC := 0;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id AND user_id = v_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fatura bulunamadı.'; END IF;
  IF v_inv.status = 'ONAYLANDI' THEN RETURN jsonb_build_object('success', true, 'invoice_id', p_invoice_id, 'invoice_number', v_inv.invoice_number, 'message', 'Fatura zaten onaylı.'); END IF;
  IF v_inv.status = 'IPTAL' THEN RAISE EXCEPTION 'İptal edilmiş fatura onaylanamaz.'; END IF;

  PERFORM public.assert_accounting_period_open(v_user_id, v_inv.invoice_date);

  v_year := EXTRACT(YEAR FROM v_inv.invoice_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM v_inv.invoice_date)::INTEGER;

  FOR v_item IN SELECT * FROM public.invoice_items WHERE invoice_id = p_invoice_id
  LOOP
    IF v_item.product_id IS NOT NULL THEN
      IF NOT EXISTS (SELECT 1 FROM public.stock_movements WHERE source = 'ALIS_FATURASI' AND source_id = p_invoice_id AND product_id = v_item.product_id) THEN
        INSERT INTO public.stock_movements (
          user_id, product_id, warehouse_id, movement_type, quantity, unit_price, unit_cost, total_cost, movement_date, document_no, description, source, source_id, created_at
        ) VALUES (
          v_user_id, v_item.product_id, v_inv.warehouse_id, 'GIRIS', v_item.quantity, v_item.unit_price, v_item.unit_price, v_item.quantity * COALESCE(v_item.unit_price, 0), v_inv.invoice_date, v_inv.invoice_number, 'Alış Faturası Stok Girişi', 'ALIS_FATURASI', p_invoice_id, v_now
        );
        UPDATE public.products SET stock_quantity = stock_quantity + v_item.quantity, updated_at = v_now WHERE id = v_item.product_id;
      END IF;
      v_total_153 := v_total_153 + (v_item.quantity * COALESCE(v_item.unit_price, 0));
    END IF;
  END LOOP;

  SELECT id INTO v_acc_320_id FROM public.chart_of_accounts WHERE (code = '320' OR system_tag = 'SATICILAR') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
  SELECT id INTO v_acc_191_id FROM public.chart_of_accounts WHERE (code = '191' OR system_tag = 'INDIRILECEK_KDV') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
  SELECT id INTO v_acc_153_id FROM public.chart_of_accounts WHERE (code = '153' OR system_tag = 'STOK') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;

  IF v_acc_320_id IS NULL OR v_acc_191_id IS NULL THEN RAISE EXCEPTION 'Satıcılar (320) veya İndirilecek KDV (191) hesabı bulunamadı.'; END IF;

  UPDATE public.invoices SET status = 'ONAYLANDI', posted = true, updated_at = v_now WHERE id = p_invoice_id;

  IF v_inv.customer_id IS NOT NULL AND v_inv.grand_total > 0 THEN
    INSERT INTO public.account_transactions (
      user_id, customer_id, source_id, txn_date, txn_type, amount, document_no, description, source, created_at
    ) VALUES (
      v_user_id, v_inv.customer_id, p_invoice_id, v_inv.invoice_date, 'ALACAK', v_inv.grand_total, v_inv.invoice_number, 'Alış Faturası Alacak Kaydı', 'ALIS_FATURASI', v_now
    ) ON CONFLICT (source, source_id) DO NOTHING;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.journal_entries WHERE source_type = 'PURCHASE_INVOICE' AND source_id = p_invoice_id) THEN
    v_journal_number := public.next_entry_number(v_user_id, v_year, 'JOURNAL');
    
    INSERT INTO public.journal_entries (
      user_id, entry_number, entry_date, description, entry_type, source_type, source_id, status, period_year, period_month, created_at, updated_at
    ) VALUES (
      v_user_id, v_journal_number, v_inv.invoice_date, 'Alış Faturası Tahakkuku: ' || v_inv.invoice_number, 'MAHSUP', 'PURCHASE_INVOICE', p_invoice_id, 'DRAFT', v_year, v_month, v_now, v_now
    ) RETURNING id INTO v_journal_entry_id;

    IF v_total_153 > 0 THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_153_id, 'Ticari Mallar', v_total_153, 0, COALESCE(v_inv.currency, 'TRY'), 1);
    END IF;

    IF v_inv.total_vat > 0 THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_191_id, 'İndirilecek KDV', v_inv.total_vat, 0, COALESCE(v_inv.currency, 'TRY'), 1);
    END IF;

    IF v_inv.grand_total > 0 THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_320_id, 'Satıcı Alacağı', 0, v_inv.grand_total, COALESCE(v_inv.currency, 'TRY'), 1);
    END IF;

    UPDATE public.journal_entries SET status = 'POSTED', updated_at = v_now WHERE id = v_journal_entry_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'invoice_id', p_invoice_id, 'invoice_number', v_inv.invoice_number, 'message', 'Alış faturası onaylandı ve muhasebeleşti.');
END;
$function$;

CREATE OR REPLACE FUNCTION public.approve_sales_invoice(p_invoice_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id             UUID;
  v_inv                 RECORD;
  v_item                RECORD;
  v_year                INTEGER;
  v_month               INTEGER;
  v_now                 TIMESTAMPTZ := now();
  v_journal_entry_id    UUID;
  v_journal_number      TEXT;
  
  v_acc_120_id          UUID;
  v_acc_600_id          UUID;
  v_acc_391_id          UUID;
  v_acc_153_id          UUID;
  v_acc_621_id          UUID;
  
  v_calc_cost_total     NUMERIC := 0;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'; END IF;

  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id AND user_id = v_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fatura bulunamadı.'; END IF;
  IF v_inv.status IN ('ONAYLANDI', 'SENT') THEN RETURN jsonb_build_object('success', true, 'invoice_id', p_invoice_id, 'invoice_number', v_inv.invoice_number, 'message', 'Fatura zaten onaylı.'); END IF;
  IF v_inv.status = 'IPTAL' THEN RAISE EXCEPTION 'İptal edilmiş fatura onaylanamaz.'; END IF;

  PERFORM public.assert_accounting_period_open(v_user_id, v_inv.invoice_date);

  v_year := EXTRACT(YEAR FROM v_inv.invoice_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM v_inv.invoice_date)::INTEGER;

  UPDATE public.invoices SET status = 'ONAYLANDI', posted = true, gib_approval_date = v_now, updated_at = v_now WHERE id = p_invoice_id;

  IF v_inv.customer_id IS NOT NULL AND v_inv.grand_total > 0 THEN
    IF NOT EXISTS (SELECT 1 FROM public.account_transactions WHERE source = 'FATURA' AND source_id = p_invoice_id) THEN
      INSERT INTO public.account_transactions (
        user_id, customer_id, source_id, txn_date, txn_type, amount, document_no, description, source, created_at
      ) VALUES (
        v_user_id, v_inv.customer_id, p_invoice_id, v_inv.invoice_date, 'BORC', v_inv.grand_total, v_inv.invoice_number, 'Satış Faturası Borç Kaydı', 'FATURA', v_now
      );
    END IF;
  END IF;

  FOR v_item IN SELECT * FROM public.invoice_items WHERE invoice_id = p_invoice_id
  LOOP
    IF v_item.product_id IS NOT NULL THEN
      IF NOT EXISTS (SELECT 1 FROM public.stock_movements WHERE source = 'FATURA' AND source_id = p_invoice_id AND product_id = v_item.product_id) THEN
        INSERT INTO public.stock_movements (
          user_id, product_id, warehouse_id, movement_type, quantity, unit_price, unit_cost, total_cost, movement_date, document_no, description, source, source_id, created_at
        ) VALUES (
          v_user_id, v_item.product_id, v_inv.warehouse_id, 'CIKIS', v_item.quantity, v_item.unit_price, v_item.purchase_price, v_item.quantity * COALESCE(v_item.purchase_price, 0), v_inv.invoice_date, v_inv.invoice_number, 'Satış Faturası Stok Çıkışı', 'FATURA', p_invoice_id, v_now
        );
        UPDATE public.products SET stock_quantity = stock_quantity - v_item.quantity, updated_at = v_now WHERE id = v_item.product_id;
        v_calc_cost_total := v_calc_cost_total + (v_item.quantity * COALESCE(v_item.purchase_price, 0));
      END IF;
    END IF;
  END LOOP;

  SELECT id INTO v_acc_120_id FROM public.chart_of_accounts WHERE (code = '120' OR system_tag = 'ALICILAR') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
  SELECT id INTO v_acc_600_id FROM public.chart_of_accounts WHERE (code = '600' OR system_tag = 'YURTICI_SATIS') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
  SELECT id INTO v_acc_391_id FROM public.chart_of_accounts WHERE (code = '391' OR system_tag = 'HESAPLANAN_KDV') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
  SELECT id INTO v_acc_153_id FROM public.chart_of_accounts WHERE (code = '153' OR system_tag = 'STOK') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
  SELECT id INTO v_acc_621_id FROM public.chart_of_accounts WHERE (code = '621' OR system_tag = 'STMM') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;

  IF NOT EXISTS (SELECT 1 FROM public.journal_entries WHERE source_type = 'INVOICE' AND source_id = p_invoice_id) THEN
    v_journal_number := public.next_entry_number(v_user_id, v_year, 'JOURNAL');
    
    INSERT INTO public.journal_entries (
      user_id, entry_number, entry_date, description, entry_type, source_type, source_id, status, period_year, period_month, created_at, updated_at
    ) VALUES (
      v_user_id, v_journal_number, v_inv.invoice_date, 'Satış Faturası Tahakkuku: ' || v_inv.invoice_number, 'MAHSUP', 'INVOICE', p_invoice_id, 'POSTED', v_year, v_month, v_now, v_now
    ) RETURNING id INTO v_journal_entry_id;

    IF v_inv.taxable_amount > 0 AND v_acc_600_id IS NOT NULL THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_600_id, 'Yurtiçi Satışlar', 0, v_inv.taxable_amount, COALESCE(v_inv.currency, 'TRY'), 1);
    END IF;

    IF v_inv.total_vat > 0 AND v_acc_391_id IS NOT NULL THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_391_id, 'Hesaplanan KDV', 0, v_inv.total_vat, COALESCE(v_inv.currency, 'TRY'), 1);
    END IF;

    IF v_inv.grand_total > 0 AND v_acc_120_id IS NOT NULL THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_120_id, 'Müşteri Borcu', v_inv.grand_total, 0, COALESCE(v_inv.currency, 'TRY'), 1);
    END IF;

    IF v_calc_cost_total > 0 AND v_acc_153_id IS NOT NULL AND v_acc_621_id IS NOT NULL THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_621_id, 'Satılan Ticari Mallar Maliyeti', v_calc_cost_total, 0, COALESCE(v_inv.currency, 'TRY'), 1);
      
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_153_id, 'Stok Çıkışı', 0, v_calc_cost_total, COALESCE(v_inv.currency, 'TRY'), 1);
    END IF;
  END IF;

  RETURN jsonb_build_object('success', true, 'invoice_id', p_invoice_id, 'invoice_number', v_inv.invoice_number, 'message', 'Fatura başarıyla onaylandı ve muhasebeleşti.');
END;
$function$;

-- KONTROL VE AUDIT FONKSİYONUNUN GELİŞTİRİLMİŞ SÜRÜMÜ
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

  -- KONTROL 3: INVOICE_WITHOUT_JOURNAL (Alış ve Satış faturalarını kapsar)
  FOR v_rec IN
    SELECT inv.id, inv.invoice_number, inv.grand_total
    FROM public.invoices inv
    LEFT JOIN public.journal_entries je
      ON je.source_id = inv.id
      AND je.source_type IN ('INVOICE', 'PURCHASE_INVOICE')
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

  -- KONTROL 5: STMM ↔ 621 MUTABAKATI
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

  -- KONTROL 6: SATIŞ ↔ 600 MUTABAKATI
  SELECT COALESCE(SUM(
    CASE
      WHEN inv.type IN ('SATIS_IADE', 'IADE') THEN -inv.taxable_amount
      ELSE inv.taxable_amount
    END
  ), 0)
  INTO v_inv_taxable_net
  FROM public.invoices inv
  WHERE inv.user_id = v_user_id
    AND inv.posted = true
    AND inv.status != 'IPTAL'
    AND COALESCE(inv.type, 'SATIS') IN ('SATIS', 'SATIS_IADE', 'E_ARSIV', 'E_FATURA')
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

  -- KONTROL 7: KDV ↔ 391 MUTABAKATI
  SELECT COALESCE(SUM(
    CASE
      WHEN inv.type IN ('SATIS_IADE', 'IADE') THEN -inv.total_vat
      ELSE inv.total_vat
    END
  ), 0)
  INTO v_inv_tax_net
  FROM public.invoices inv
  WHERE inv.user_id = v_user_id
    AND inv.posted = true
    AND inv.status != 'IPTAL'
    AND COALESCE(inv.type, 'SATIS') IN ('SATIS', 'SATIS_IADE', 'E_ARSIV', 'E_FATURA')
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

  -- KONTROL 8: CARİ ↔ 120 MUTABAKATI
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
    detail   := 'Cari hareketler toplamı (' || v_cust_subledger_net || ' TL) ile 120 hesabı (' || v_journal_120_net || ' TL) arasında fark var!';
  ELSE
    severity := 'INFO';
    status   := 'PASS';
    detail   := 'Cari hareketler ile 120 hesabı tam mutabık.';
  END IF;
  RETURN NEXT;

END;
$function$;
