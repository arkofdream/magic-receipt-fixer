-- FAZ 7D - PAYMENT HARDENING & FRONTEND CONTRACT FIX
-- This migration replaces direct account_transactions.insert with a secure RPC.

CREATE OR REPLACE FUNCTION public.process_invoice_payment(
  p_invoice_id UUID,
  p_amount NUMERIC,
  p_is_purchase BOOLEAN
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
  v_inv RECORD;
  v_customer_id UUID;
  v_date DATE;
  v_year INTEGER;
  v_month INTEGER;
  v_journal_id UUID;
  v_journal_number TEXT;
  v_acc_120_id UUID;
  v_acc_320_id UUID;
  v_acc_100_id UUID;
  v_now TIMESTAMPTZ := now();
  v_txn_type TEXT;
  v_source TEXT;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkisiz islem (Unauthenticated).';
  END IF;

  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Tahsilat/Odeme tutari 0 veya negatif olamaz.';
  END IF;

  v_date := CURRENT_DATE;
  v_year := EXTRACT(YEAR FROM v_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM v_date)::INTEGER;

  -- Period Check
  PERFORM public.assert_accounting_period_open(v_user_id, v_year, v_month);

  -- Get invoice and lock it
  SELECT * INTO v_inv
  FROM public.invoices
  WHERE id = p_invoice_id AND user_id = v_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fatura bulunamadi veya erisim izniniz yok.';
  END IF;

  IF v_inv.status != 'ONAYLANDI' THEN
    RAISE EXCEPTION 'Sadece onaylanmis faturalar icin tahsilat/odeme girilebilir.';
  END IF;

  v_customer_id := v_inv.customer_id;
  IF v_customer_id IS NULL THEN
    RAISE EXCEPTION 'Bu faturaya bagli bir cari bulunamadi.';
  END IF;

  -- Accounts
  SELECT id INTO v_acc_120_id FROM public.chart_of_accounts WHERE user_id = v_user_id AND account_code = '120' LIMIT 1;
  SELECT id INTO v_acc_320_id FROM public.chart_of_accounts WHERE user_id = v_user_id AND account_code = '320' LIMIT 1;
  SELECT id INTO v_acc_100_id FROM public.chart_of_accounts WHERE user_id = v_user_id AND account_code = '100' LIMIT 1;

  IF v_acc_100_id IS NULL THEN
    RAISE EXCEPTION '100 Kasa hesabi bulunamadi. Lutfen hesap planinizi kontrol edin.';
  END IF;

  v_journal_number := public.next_entry_number(v_user_id, v_year, 'JOURNAL');

  -- Create Journal (DRAFT -> POSTED flow to satisfy protect_posted_journal_lines trigger)
  INSERT INTO public.journal_entries (
    user_id, entry_number, entry_date, description, entry_type, source_type, source_id, status, period_year, period_month, created_at, updated_at
  ) VALUES (
    v_user_id, v_journal_number, v_date, 
    CASE WHEN p_is_purchase THEN 'Fatura Odemesi: ' ELSE 'Fatura Tahsilati: ' END || COALESCE(v_inv.invoice_number, 'Bilinmeyen'), 
    'TAHSILAT', 'INVOICE_PAYMENT', p_invoice_id, 'DRAFT', v_year, v_month, v_now, v_now
  ) RETURNING id INTO v_journal_id;

  IF p_is_purchase THEN
    -- Purchase Payment (Odeme)
    v_txn_type := 'ODEME';
    v_source := 'FATURA_ODEME';
    
    IF v_acc_320_id IS NULL THEN
      RAISE EXCEPTION '320 Saticilar hesabi bulunamadi.';
    END IF;

    -- 320 BORC, 100 ALACAK
    INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
    VALUES (v_journal_id, v_user_id, v_acc_320_id, 'Saticiya Odeme', p_amount, 0, COALESCE(v_inv.currency, 'TRY'), 1);

    INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
    VALUES (v_journal_id, v_user_id, v_acc_100_id, 'Kasa Cikisi', 0, p_amount, COALESCE(v_inv.currency, 'TRY'), 1);

  ELSE
    -- Sales Collection (Tahsilat)
    v_txn_type := 'TAHSILAT';
    v_source := 'FATURA_TAHSILAT';
    
    IF v_acc_120_id IS NULL THEN
      RAISE EXCEPTION '120 Alicilar hesabi bulunamadi.';
    END IF;

    -- 100 BORC, 120 ALACAK
    INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
    VALUES (v_journal_id, v_user_id, v_acc_100_id, 'Kasa Girisi', p_amount, 0, COALESCE(v_inv.currency, 'TRY'), 1);

    INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
    VALUES (v_journal_id, v_user_id, v_acc_120_id, 'Alicidan Tahsilat', 0, p_amount, COALESCE(v_inv.currency, 'TRY'), 1);

  END IF;

  UPDATE public.journal_entries SET status = 'POSTED', updated_at = v_now WHERE id = v_journal_id;

  -- Create Account Transaction
  INSERT INTO public.account_transactions (
    user_id, customer_id, txn_date, txn_type, amount, document_no, description, source, source_id, journal_entry_id, created_at, updated_at
  ) VALUES (
    v_user_id, v_customer_id, v_date, v_txn_type, p_amount, v_inv.invoice_number, 
    CASE WHEN p_is_purchase THEN 'Fatura Odemesi' ELSE 'Fatura Tahsilati' END, 
    v_source, p_invoice_id, v_journal_id, v_now, v_now
  );

  RETURN jsonb_build_object('success', true, 'message', 'Islem basariyla kaydedildi.');
END;
$$;

GRANT EXECUTE ON FUNCTION public.process_invoice_payment TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_invoice_payment TO service_role;
