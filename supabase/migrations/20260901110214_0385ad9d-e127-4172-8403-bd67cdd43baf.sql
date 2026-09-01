-- 1) Stok miktarı fonksiyonunun search_path'ini sabitle
ALTER FUNCTION public.get_product_stock_quantity(uuid, uuid) SET search_path TO 'public';

-- 2) Anon rolünden tüm finansal / raporlama SECURITY DEFINER fonksiyonlarının EXECUTE yetkisini kaldır
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure::text AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prosecdef
      AND p.prokind = 'f'
      AND p.pronargs > 0                       -- trigger fonksiyonları hariç
      AND p.proname <> 'handle_new_user'
      AND has_function_privilege('anon', p.oid, 'EXECUTE')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM anon', r.sig);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', r.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', r.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', r.sig);
  END LOOP;
END $$;