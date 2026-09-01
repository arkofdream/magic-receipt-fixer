DO $do$
DECLARE
  v_src TEXT;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'create_purchase_return';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'create_purchase_return bulunamadı';
  END IF;

  IF position('p_calc_vat' IN v_src) = 0 THEN
    RAISE NOTICE 'Zaten düzeltilmiş';
    RETURN;
  END IF;

  v_src := replace(v_src, 'IF p_calc_vat > 0 OR v_calc_vat > 0 THEN', 'IF v_calc_vat > 0 THEN');

  IF position('p_calc_vat' IN v_src) > 0 THEN
    RAISE EXCEPTION 'Beklenmeyen p_calc_vat kullanımı kaldı';
  END IF;

  EXECUTE v_src;
END
$do$;