DO $$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'create_sales_invoice';

  v_def := replace(
    v_def,
    'v_user_id, v_item_name, v_unit, v_unit_price, v_vat_rate, true, v_now, v_now',
    'v_user_id, v_item_name, v_unit, v_unit_price, v_vat_rate, false, v_now, v_now'
  );

  EXECUTE v_def;
END $$;