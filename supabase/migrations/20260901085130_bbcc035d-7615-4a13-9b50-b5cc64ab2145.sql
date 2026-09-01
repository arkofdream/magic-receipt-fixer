DO $do$
DECLARE
  d text; b text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'create_purchase_return';
  b := d;

  -- remove guard from its current position (before step 7)
  d := replace(d,
    '  PERFORM public.assert_returnable_quantities(v_user_id, p_original_invoice_id, p_items, ''ALIS_IADE'');' || E'\n\n' ||
    '  -- 7. İade Toplamlarının Hesaplanması',
    '  -- 7. İade Toplamlarının Hesaplanması');

  -- place it before the stock availability check (step 6)
  d := replace(d,
    '  -- 6. Deterministik Ürün Kilit Dizisi ve Stok Kontrolü',
    '  PERFORM public.assert_returnable_quantities(v_user_id, p_original_invoice_id, p_items, ''ALIS_IADE'');' || E'\n\n' ||
    '  -- 6. Deterministik Ürün Kilit Dizisi ve Stok Kontrolü');

  IF d = b THEN RAISE EXCEPTION 'create_purchase_return sıralama yaması uygulanamadı'; END IF;
  EXECUTE d;
END
$do$;