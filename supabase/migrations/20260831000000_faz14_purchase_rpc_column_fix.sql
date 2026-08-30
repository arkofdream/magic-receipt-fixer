-- FAZ 14: Remove period_year and period_month from account_transactions inserts
-- These columns do not exist in account_transactions (they belong to journal_entries)

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
  IF v_inv.status = 'ONAYLANDI' THEN RETURN jsonb_build_object('success', true, 'invoice_id', p_invoice_id, 'message', 'Fatura zaten onaylı.'); END IF;
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

  RETURN jsonb_build_object('success', true, 'invoice_id', p_invoice_id, 'message', 'Alış faturası onaylandı ve muhasebeleşti.');
END;
$function$;

-- Drop both overloads of cancel_purchase_invoice to avoid PGRST203
DROP FUNCTION IF EXISTS public.cancel_purchase_invoice(uuid);
DROP FUNCTION IF EXISTS public.cancel_purchase_invoice(uuid, text);

CREATE OR REPLACE FUNCTION public.cancel_purchase_invoice(p_invoice_id uuid, p_cancel_reason text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id           UUID;
  v_inv               RECORD;
  v_sm                RECORD;
  v_journal_id        UUID;
  v_new_journal_id    UUID;
  v_year              INTEGER;
  v_month             INTEGER;
  v_now               TIMESTAMPTZ := now();
  v_journal_number    TEXT;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Yetkilendirme hatası.'; END IF;

  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id AND user_id = v_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fatura bulunamadı.'; END IF;
  IF v_inv.status = 'IPTAL' THEN RETURN jsonb_build_object('success', true, 'message', 'Zaten iptal edilmiş.'); END IF;
  IF v_inv.status = 'TASLAK' THEN
    UPDATE public.invoices SET status = 'IPTAL', notes = COALESCE(notes, '') || ' [İPTAL: ' || p_cancel_reason || ']', updated_at = v_now WHERE id = p_invoice_id;
    RETURN jsonb_build_object('success', true, 'message', 'Taslak fatura iptal edildi.');
  END IF;

  PERFORM public.assert_accounting_period_open(v_user_id, v_inv.invoice_date);

  v_year := EXTRACT(YEAR FROM v_inv.invoice_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM v_inv.invoice_date)::INTEGER;

  UPDATE public.invoices SET status = 'IPTAL', notes = COALESCE(notes, '') || ' [İPTAL: ' || p_cancel_reason || ']', updated_at = v_now WHERE id = p_invoice_id;

  IF v_inv.customer_id IS NOT NULL AND v_inv.grand_total > 0 THEN
    INSERT INTO public.account_transactions (
      user_id, customer_id, source_id, txn_date, txn_type, amount, document_no, description, source, created_at
    ) VALUES (
      v_user_id, v_inv.customer_id, p_invoice_id, v_inv.invoice_date, 'BORC', v_inv.grand_total, v_inv.invoice_number, 'Alış Faturası İptal (Ters Kayıt)', 'ALIS_FATURASI_IPTAL', v_now
    );
  END IF;

  FOR v_sm IN SELECT * FROM public.stock_movements WHERE source_id = p_invoice_id AND source = 'ALIS_FATURASI' AND movement_type = 'GIRIS'
  LOOP
    INSERT INTO public.stock_movements (
      user_id, product_id, warehouse_id, movement_type, quantity, unit_price, unit_cost, total_cost, movement_date, document_no, description, source, source_id, created_at
    ) VALUES (
      v_user_id, v_sm.product_id, v_sm.warehouse_id, 'CIKIS', v_sm.quantity, v_sm.unit_price, v_sm.unit_cost, v_sm.total_cost, v_inv.invoice_date, v_inv.invoice_number, 'Alış Faturası İptali (Stok Çıkışı)', 'ALIS_FATURASI_IPTAL', p_invoice_id, v_now
    );
    UPDATE public.products SET stock_quantity = stock_quantity - v_sm.quantity, updated_at = v_now WHERE id = v_sm.product_id;
  END LOOP;

  SELECT id INTO v_journal_id FROM public.journal_entries WHERE source_type = 'PURCHASE_INVOICE' AND source_id = p_invoice_id LIMIT 1;
  IF v_journal_id IS NOT NULL THEN
    v_journal_number := public.next_entry_number(v_user_id, v_year, 'JOURNAL');
    INSERT INTO public.journal_entries (
      user_id, entry_number, entry_date, description, entry_type, source_type, source_id, status, period_year, period_month, created_at, updated_at
    ) VALUES (
      v_user_id, v_journal_number, v_inv.invoice_date, 'İptal Yevmiyesi: ' || v_inv.invoice_number, 'MAHSUP', 'PURCHASE_INVOICE_CANCEL', p_invoice_id, 'DRAFT', v_year, v_month, v_now, v_now
    ) RETURNING id INTO v_new_journal_id;

    INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
    SELECT v_new_journal_id, user_id, account_id, description || ' (İptal)', credit, debit, currency, exchange_rate
    FROM public.journal_lines
    WHERE journal_entry_id = v_journal_id;
    
    UPDATE public.journal_entries SET status = 'POSTED', updated_at = v_now WHERE id = v_new_journal_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'invoice_id', p_invoice_id, 'message', 'Alış faturası iptal edildi ve ters kayıtlar oluşturuldu.');
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
  IF v_inv.status IN ('ONAYLANDI', 'SENT') THEN RETURN jsonb_build_object('success', true, 'invoice_id', p_invoice_id, 'message', 'Fatura zaten onaylı.'); END IF;
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

  RETURN jsonb_build_object('success', true, 'invoice_id', p_invoice_id, 'message', 'Fatura başarıyla onaylandı ve muhasebeleşti.');
END;
$function$;
