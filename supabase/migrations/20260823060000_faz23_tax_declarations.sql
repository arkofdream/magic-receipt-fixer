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
