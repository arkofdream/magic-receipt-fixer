-- FAZ 14 DATA FIX (ENHANCED): Clean empty journal entries and backfill missing journal lines for all invoices

-- 1. Clean orphaned journal entries that have NO lines in journal_lines
DELETE FROM public.journal_entries j
WHERE NOT EXISTS (SELECT 1 FROM public.journal_lines l WHERE l.journal_entry_id = j.id);

-- 2. Backfill missing journal entries and lines for approved invoices
DO $$
DECLARE
  v_inv RECORD;
  v_user_id UUID;
  v_year INTEGER;
  v_month INTEGER;
  v_now TIMESTAMPTZ := now();
  v_journal_entry_id UUID;
  v_journal_number TEXT;
  
  v_acc_120_id UUID;
  v_acc_600_id UUID;
  v_acc_391_id UUID;
  v_acc_320_id UUID;
  v_acc_191_id UUID;
  v_acc_153_id UUID;
  
  v_total_153 NUMERIC;
BEGIN
  FOR v_inv IN 
    SELECT i.* 
    FROM public.invoices i
    WHERE i.posted = true 
      AND i.status != 'IPTAL'
      AND NOT EXISTS (
        SELECT 1 FROM public.journal_entries j 
        JOIN public.journal_lines l ON l.journal_entry_id = j.id
        WHERE j.source_id = i.id 
          AND j.source_type IN ('INVOICE', 'PURCHASE_INVOICE')
      )
  LOOP
    v_user_id := v_inv.user_id;
    v_year := EXTRACT(YEAR FROM v_inv.invoice_date)::INTEGER;
    v_month := EXTRACT(MONTH FROM v_inv.invoice_date)::INTEGER;
    
    -- Remove any empty journal entry header for this invoice if it exists
    DELETE FROM public.journal_entries WHERE source_id = v_inv.id AND source_type IN ('INVOICE', 'PURCHASE_INVOICE');

    IF COALESCE(v_inv.type, 'SATIS') IN ('SATIS', 'SATIS_IADE') THEN
      SELECT id INTO v_acc_120_id FROM public.chart_of_accounts WHERE (code = '120' OR system_tag = 'ALICILAR') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
      SELECT id INTO v_acc_600_id FROM public.chart_of_accounts WHERE (code = '600' OR system_tag = 'YURTICI_SATIS') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
      SELECT id INTO v_acc_391_id FROM public.chart_of_accounts WHERE (code = '391' OR system_tag = 'HESAPLANAN_KDV') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;

      IF v_acc_120_id IS NOT NULL AND v_acc_600_id IS NOT NULL THEN
        v_journal_number := public.next_entry_number(v_user_id, v_year, 'JOURNAL');
        
        INSERT INTO public.journal_entries (
          user_id, entry_number, entry_date, description, entry_type, source_type, source_id, status, period_year, period_month, created_at, updated_at
        ) VALUES (
          v_user_id, v_journal_number, v_inv.invoice_date, 'Satış Faturası Tahakkuku (Data Fix): ' || COALESCE(v_inv.invoice_number, ''), 'MAHSUP', 'INVOICE', v_inv.id, 'DRAFT', v_year, v_month, v_now, v_now
        ) RETURNING id INTO v_journal_entry_id;

        IF COALESCE(v_inv.taxable_amount, 0) > 0 THEN
          INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
          VALUES (v_journal_entry_id, v_user_id, v_acc_600_id, 'Yurtiçi Satışlar', 0, v_inv.taxable_amount, COALESCE(v_inv.currency, 'TRY'), 1);
        ELSIF COALESCE(v_inv.grand_total, 0) > 0 AND COALESCE(v_inv.total_vat, 0) = 0 THEN
          INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
          VALUES (v_journal_entry_id, v_user_id, v_acc_600_id, 'Yurtiçi Satışlar', 0, v_inv.grand_total, COALESCE(v_inv.currency, 'TRY'), 1);
        END IF;

        IF COALESCE(v_inv.total_vat, 0) > 0 AND v_acc_391_id IS NOT NULL THEN
          INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
          VALUES (v_journal_entry_id, v_user_id, v_acc_391_id, 'Hesaplanan KDV', 0, v_inv.total_vat, COALESCE(v_inv.currency, 'TRY'), 1);
        END IF;

        IF COALESCE(v_inv.grand_total, 0) > 0 THEN
          INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
          VALUES (v_journal_entry_id, v_user_id, v_acc_120_id, 'Müşteri Borcu', v_inv.grand_total, 0, COALESCE(v_inv.currency, 'TRY'), 1);
        END IF;

        UPDATE public.journal_entries SET status = 'POSTED', updated_at = v_now WHERE id = v_journal_entry_id;
      END IF;

    ELSE
      -- PURCHASE INVOICE BACKFILL
      SELECT id INTO v_acc_320_id FROM public.chart_of_accounts WHERE (code = '320' OR system_tag = 'SATICILAR') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
      SELECT id INTO v_acc_191_id FROM public.chart_of_accounts WHERE (code = '191' OR system_tag = 'INDIRILECEK_KDV') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
      SELECT id INTO v_acc_153_id FROM public.chart_of_accounts WHERE (code = '153' OR system_tag = 'STOK') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;

      IF v_acc_320_id IS NOT NULL THEN
        v_journal_number := public.next_entry_number(v_user_id, v_year, 'JOURNAL');
        v_total_153 := COALESCE(v_inv.taxable_amount, v_inv.grand_total, 0);

        INSERT INTO public.journal_entries (
          user_id, entry_number, entry_date, description, entry_type, source_type, source_id, status, period_year, period_month, created_at, updated_at
        ) VALUES (
          v_user_id, v_journal_number, v_inv.invoice_date, 'Alış Faturası Tahakkuku (Data Fix): ' || COALESCE(v_inv.invoice_number, ''), 'MAHSUP', 'PURCHASE_INVOICE', v_inv.id, 'DRAFT', v_year, v_month, v_now, v_now
        ) RETURNING id INTO v_journal_entry_id;

        IF v_total_153 > 0 AND v_acc_153_id IS NOT NULL THEN
          INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
          VALUES (v_journal_entry_id, v_user_id, v_acc_153_id, 'Ticari Mallar', v_total_153, 0, COALESCE(v_inv.currency, 'TRY'), 1);
        END IF;

        IF COALESCE(v_inv.total_vat, 0) > 0 AND v_acc_191_id IS NOT NULL THEN
          INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
          VALUES (v_journal_entry_id, v_user_id, v_acc_191_id, 'İndirilecek KDV', v_inv.total_vat, 0, COALESCE(v_inv.currency, 'TRY'), 1);
        END IF;

        IF COALESCE(v_inv.grand_total, 0) > 0 THEN
          INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
          VALUES (v_journal_entry_id, v_user_id, v_acc_320_id, 'Satıcı Alacağı', 0, v_inv.grand_total, COALESCE(v_inv.currency, 'TRY'), 1);
        END IF;

        UPDATE public.journal_entries SET status = 'POSTED', updated_at = v_now WHERE id = v_journal_entry_id;
      END IF;
    END IF;

  END LOOP;
END $$;
