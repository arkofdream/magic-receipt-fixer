DO $do$
DECLARE d text; b text;
BEGIN
  -- sales return invoices must be marked as posted
  SELECT pg_get_functiondef(p.oid) INTO d
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'create_sales_return';
  b := d;

  d := replace(d,
    E'    user_id, original_invoice_id, customer_id, warehouse_id, invoice_number, invoice_date,\n    type, status, currency, exchange_rate, ettn, notes, created_at, updated_at',
    E'    user_id, original_invoice_id, customer_id, warehouse_id, invoice_number, invoice_date,\n    type, status, posted, currency, exchange_rate, ettn, notes, created_at, updated_at');
  d := replace(d,
    E'    ''SATIS_IADE'',\n    ''ONAYLANDI'',',
    E'    ''SATIS_IADE'',\n    ''ONAYLANDI'',\n    true,');

  IF d = b THEN RAISE EXCEPTION 'create_sales_return posted yaması uygulanamadı'; END IF;
  EXECUTE d;

  -- COGS reconciliation should include sales returns
  SELECT pg_get_functiondef(p.oid) INTO d
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_income_statement';
  b := d;

  d := replace(d,
    E'      WHEN sm.movement_type = ''CIKIS'' THEN sm.quantity * COALESCE(p.purchase_price, 0)\n      WHEN sm.movement_type = ''GIRIS'' AND sm.source = ''FATURA'' THEN -sm.quantity * COALESCE(p.purchase_price, 0)',
    E'      WHEN sm.movement_type = ''CIKIS'' THEN sm.quantity * COALESCE(NULLIF(sm.unit_cost, 0), p.unit_cost, p.purchase_price, 0)\n      WHEN sm.movement_type = ''GIRIS'' AND sm.source IN (''FATURA'', ''SATIS_IADE'') THEN -sm.quantity * COALESCE(NULLIF(sm.unit_cost, 0), p.unit_cost, p.purchase_price, 0)');
  d := replace(d,
    '    AND sm.source IN (''FATURA'', ''FATURA_IPTAL'')',
    '    AND sm.source IN (''FATURA'', ''FATURA_IPTAL'', ''SATIS_IADE'')');

  IF d = b THEN RAISE EXCEPTION 'get_income_statement STMM yaması uygulanamadı'; END IF;
  EXECUTE d;
END
$do$;

-- existing sales returns should also be visible to VAT reporting
UPDATE public.invoices
SET posted = true
WHERE type = 'SATIS_IADE' AND status = 'ONAYLANDI' AND posted = false;