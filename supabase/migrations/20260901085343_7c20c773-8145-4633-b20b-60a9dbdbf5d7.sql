-- 1) Auto-generate invoice_tax_lines for invoices that don't have them
CREATE OR REPLACE FUNCTION public.generate_invoice_tax_lines(p_invoice_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_inv RECORD;
  v_dir TEXT;
  v_rev BOOLEAN;
BEGIN
  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id;
  IF NOT FOUND THEN RETURN; END IF;

  IF EXISTS (SELECT 1 FROM public.invoice_tax_lines WHERE invoice_id = p_invoice_id) THEN
    RETURN;
  END IF;

  v_dir := CASE
             WHEN v_inv.type IN ('ALIS', 'GELEN_FATURA', 'GELEN_E_ARSIV', 'ALIS_IADE') THEN 'ALIS'
             ELSE 'SATIS'
           END;
  v_rev := v_inv.type IN ('ALIS_IADE', 'SATIS_IADE', 'IADE');

  INSERT INTO public.invoice_tax_lines (
    invoice_id, user_id, direction, vat_rate,
    taxable_amount, tax_amount, withholding_rate, withholding_amount,
    is_exempt, is_reversal, currency, exchange_rate,
    taxable_amount_try, tax_amount_try, period_year, period_month
  )
  SELECT
    p_invoice_id,
    v_inv.user_id,
    v_dir,
    ii.vat_rate,
    ROUND(SUM(ii.taxable_amount), 2),
    ROUND(SUM(ii.vat_amount), 2),
    0,
    0,
    ii.vat_rate = 0,
    v_rev,
    COALESCE(v_inv.currency, 'TRY'),
    COALESCE(v_inv.exchange_rate, 1),
    ROUND(SUM(ii.taxable_amount) * COALESCE(v_inv.exchange_rate, 1), 2),
    ROUND(SUM(ii.vat_amount) * COALESCE(v_inv.exchange_rate, 1), 2),
    EXTRACT(YEAR FROM v_inv.invoice_date)::INTEGER,
    EXTRACT(MONTH FROM v_inv.invoice_date)::INTEGER
  FROM public.invoice_items ii
  WHERE ii.invoice_id = p_invoice_id
  GROUP BY ii.vat_rate;
END;
$function$;

REVOKE ALL ON FUNCTION public.generate_invoice_tax_lines(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.generate_invoice_tax_lines(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.tg_generate_invoice_tax_lines()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.status <> 'IPTAL' THEN
    PERFORM public.generate_invoice_tax_lines(NEW.id);
  END IF;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_invoice_tax_lines_ins ON public.invoices;
CREATE CONSTRAINT TRIGGER trg_invoice_tax_lines_ins
  AFTER INSERT ON public.invoices
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.tg_generate_invoice_tax_lines();

DROP TRIGGER IF EXISTS trg_invoice_tax_lines_upd ON public.invoices;
CREATE CONSTRAINT TRIGGER trg_invoice_tax_lines_upd
  AFTER UPDATE ON public.invoices
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  WHEN (NEW.status = 'ONAYLANDI' AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.tg_generate_invoice_tax_lines();

-- Backfill existing invoices
DO $bf$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT i.id FROM public.invoices i
    WHERE i.status <> 'IPTAL'
      AND NOT EXISTS (SELECT 1 FROM public.invoice_tax_lines t WHERE t.invoice_id = i.id)
  LOOP
    PERFORM public.generate_invoice_tax_lines(r.id);
  END LOOP;
END
$bf$;

-- 2) VAT declaration summary: correct handling of sales/purchase returns
DO $do$
DECLARE d text; b text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_vat_declaration_summary';
  b := d;

  d := replace(d,
    '  v_sales_return_vat       NUMERIC(14,2) := 0;',
    '  v_sales_return_vat       NUMERIC(14,2) := 0;' || E'\n' ||
    '  v_purchase_return_vat    NUMERIC(14,2) := 0;');

  -- sales sections must ignore reversal (return) lines
  d := replace(d, E'      AND inv.type != ''IADE''\n', E'      AND itl.is_reversal = false\n');
  d := replace(d, E'    AND inv.type != ''IADE''\n',   E'    AND itl.is_reversal = false\n');
  d := replace(d,
    '      AND (itl.is_exempt = true OR itl.vat_rate = 0)',
    E'      AND (itl.is_exempt = true OR itl.vat_rate = 0)\n      AND itl.is_reversal = false');

  -- purchase sections must ignore purchase-return lines
  d := replace(d,
    E'      AND itl.direction = ''ALIS''\n      AND itl.is_cancelled = false',
    E'      AND itl.direction = ''ALIS''\n      AND itl.is_reversal = false\n      AND itl.is_cancelled = false');
  d := replace(d,
    E'    AND itl.direction = ''ALIS''\n    AND itl.is_cancelled = false',
    E'    AND itl.direction = ''ALIS''\n    AND itl.is_reversal = false\n    AND itl.is_cancelled = false');

  -- sales returns are deductible; purchase returns reduce the deduction
  d := replace(d, E'    AND inv.type = ''IADE''\n', E'    AND itl.direction = ''SATIS''\n    AND itl.is_reversal = true\n');

  d := replace(d,
    '  v_total_deductible_vat := v_total_purchase_vat + v_sales_return_vat;',
    E'  SELECT COALESCE(SUM(itl.tax_amount_try), 0)\n'
    || E'  INTO v_purchase_return_vat\n'
    || E'  FROM public.invoice_tax_lines itl\n'
    || E'  INNER JOIN public.invoices inv ON inv.id = itl.invoice_id\n'
    || E'  WHERE itl.user_id = v_user_id\n'
    || E'    AND itl.direction = ''ALIS''\n'
    || E'    AND itl.is_reversal = true\n'
    || E'    AND inv.posted = true\n'
    || E'    AND inv.status != ''IPTAL''\n'
    || E'    AND (p_year IS NULL OR itl.period_year = p_year)\n'
    || E'    AND (p_month IS NULL OR itl.period_month = p_month);\n\n'
    || '  v_total_deductible_vat := v_total_purchase_vat + v_sales_return_vat - v_purchase_return_vat;');

  d := replace(d,
    '      ''sales_return_vat'', v_sales_return_vat,',
    E'      ''sales_return_vat'', v_sales_return_vat,\n      ''purchase_return_vat'', v_purchase_return_vat,');

  IF d = b THEN RAISE EXCEPTION 'get_vat_declaration_summary yaması uygulanamadı'; END IF;
  EXECUTE d;
END
$do$;

-- 3) Income statement: gross margin overflow fix
DO $do$
DECLARE d text; b text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_income_statement';
  b := d;

  d := replace(d, 'v_gross_margin_pct    NUMERIC(5,2)  := 0;', 'v_gross_margin_pct    NUMERIC(14,2) := 0;');

  IF d = b THEN RAISE EXCEPTION 'get_income_statement yaması uygulanamadı'; END IF;
  EXECUTE d;
END
$do$;