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
