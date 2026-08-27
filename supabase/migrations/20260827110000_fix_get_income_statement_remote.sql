-- ============================================================================
-- FAZ 2.2.4 GELİR TABLOSU VE STMM SQL RPC DÜZELTMESİ (REMOTE COMPATIBLE)
-- ============================================================================

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
  v_user_id             UUID;
  v_start_date          DATE;
  v_end_date            DATE;
  
  v_gross_sales         NUMERIC(14,2) := 0; -- 600
  v_sales_returns       NUMERIC(14,2) := 0; -- 610
  v_net_sales           NUMERIC(14,2) := 0; -- 600 - 610
  v_cogs                NUMERIC(14,2) := 0; -- 621 STMM (Yevmiye)
  v_stock_movements_cogs NUMERIC(14,2) := 0; -- STMM Mutabakatı
  v_gross_profit        NUMERIC(14,2) := 0; -- Net Satışlar - STMM
  v_gross_margin_pct    NUMERIC(5,2)  := 0;
  v_operating_expenses  NUMERIC(14,2) := 0; -- 770
  v_fx_gains            NUMERIC(14,2) := 0; -- 646
  v_fx_losses           NUMERIC(14,2) := 0; -- 656
  v_financing_expenses  NUMERIC(14,2) := 0; -- 780
  v_operating_profit    NUMERIC(14,2) := 0;
  v_net_profit          NUMERIC(14,2) := 0;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  v_start_date := COALESCE(p_start_date, '2000-01-01'::DATE);
  v_end_date   := COALESCE(p_end_date, CURRENT_DATE);

  -- 600 Yurtiçi Satışlar
  SELECT COALESCE(SUM(jl.credit - jl.debit), 0)
  INTO v_gross_sales
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND je.entry_date >= v_start_date
    AND je.entry_date <= v_end_date
    AND (coa.code = '600' OR coa.system_tag = 'SATIS_GELIRI');

  -- 610 Satıştan İadeler
  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_sales_returns
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND je.entry_date >= v_start_date
    AND je.entry_date <= v_end_date
    AND (coa.code = '610' OR coa.system_tag = 'SATIS_IADE');

  v_net_sales := v_gross_sales - v_sales_returns;

  -- 621 Satılan Ticari Mallar Maliyeti
  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_cogs
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND je.entry_date >= v_start_date
    AND je.entry_date <= v_end_date
    AND (coa.code = '621' OR coa.system_tag = 'COGS');

  -- STMM Mutabakatı: Gerçek stock_movements + products tablosu birleştirmesi (ürün alış maliyeti)
  SELECT COALESCE(SUM(
    CASE
      WHEN sm.movement_type = 'CIKIS' THEN sm.quantity * COALESCE(p.purchase_price, 0)
      WHEN sm.movement_type = 'GIRIS' AND sm.source = 'FATURA' THEN -sm.quantity * COALESCE(p.purchase_price, 0)
      ELSE 0
    END
  ), 0)
  INTO v_stock_movements_cogs
  FROM public.stock_movements sm
  LEFT JOIN public.products p ON p.id = sm.product_id
  WHERE sm.user_id = v_user_id
    AND sm.deleted_at IS NULL
    AND sm.source IN ('FATURA', 'FATURA_IPTAL')
    AND sm.movement_date >= v_start_date
    AND sm.movement_date <= v_end_date;

  v_gross_profit := v_net_sales - v_cogs;

  IF v_net_sales > 0 THEN
    v_gross_margin_pct := ROUND(((v_gross_profit / v_net_sales) * 100.0), 2);
  ELSE
    v_gross_margin_pct := 0;
  END IF;

  -- 770 Genel Yönetim Giderleri
  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_operating_expenses
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND je.entry_date >= v_start_date
    AND je.entry_date <= v_end_date
    AND (coa.code = '770' OR coa.system_tag = 'GENEL_YONETIM');

  -- 646 Kambiyo Kârları
  SELECT COALESCE(SUM(jl.credit - jl.debit), 0)
  INTO v_fx_gains
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND je.entry_date >= v_start_date
    AND je.entry_date <= v_end_date
    AND (coa.code = '646' OR coa.system_tag = 'KAMBIYO_KARI');

  -- 656 Kambiyo Zararları
  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_fx_losses
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND je.entry_date >= v_start_date
    AND je.entry_date <= v_end_date
    AND (coa.code = '656' OR coa.system_tag = 'KAMBIYO_ZARARI');

  -- 780 Finansman Giderleri
  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_financing_expenses
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND je.entry_date >= v_start_date
    AND je.entry_date <= v_end_date
    AND (coa.code = '780' OR coa.system_tag = 'FINANSMAN_GIDERI');

  v_operating_profit := v_gross_profit - v_operating_expenses + v_fx_gains - v_fx_losses;
  v_net_profit       := v_operating_profit - v_financing_expenses;

  RETURN jsonb_build_object(
    'period_start',                      v_start_date,
    'period_end',                        v_end_date,
    'gross_sales',                       v_gross_sales,
    'sales_returns',                     v_sales_returns,
    'net_sales',                         v_net_sales,
    'cogs',                              v_cogs,
    'stock_movements_cogs',              v_stock_movements_cogs,
    'cogs_reconciliation_difference',    ROUND(v_cogs - v_stock_movements_cogs, 2),
    'gross_profit',                      v_gross_profit,
    'gross_margin_pct',                  v_gross_margin_pct,
    'operating_expenses',                v_operating_expenses,
    'fx_gains',                          v_fx_gains,
    'fx_losses',                         v_fx_losses,
    'operating_profit',                  v_operating_profit,
    'financing_expenses',                v_financing_expenses,
    'net_profit',                        v_net_profit
  );
END;
$$;
