DO $$
DECLARE
  v_def TEXT;
  v_new TEXT;
  v_oid OID;
BEGIN
  FOR v_oid IN
    SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN ('create_sales_invoice', 'approve_sales_invoice')
  LOOP
    v_def := pg_get_functiondef(v_oid);
    v_new := replace(
      v_def,
      'user_id, name, unit, unit_price, vat_rate, track_stock, is_active, created_at, updated_at',
      'user_id, name, unit, unit_price, vat_rate, track_stock, created_at, updated_at'
    );
    v_new := replace(
      v_new,
      'v_user_id, v_item_name, v_unit, v_unit_price, v_vat_rate, true, true, v_now, v_now',
      'v_user_id, v_item_name, v_unit, v_unit_price, v_vat_rate, true, v_now, v_now'
    );
    IF v_new <> v_def THEN
      EXECUTE v_new;
    END IF;
  END LOOP;
END $$;