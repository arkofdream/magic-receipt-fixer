DO $do$
DECLARE
  v_src TEXT;
  v_old TEXT;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'create_purchase_return';

  v_old := E'  IF v_txn_id IS NOT NULL THEN\n    UPDATE public.account_transactions\n    SET journal_entry_id = v_journal_entry_id\n    WHERE id = v_txn_id;\n  END IF;\n';

  IF position(v_old IN v_src) = 0 THEN
    RAISE EXCEPTION 'Beklenen blok bulunamadı';
  END IF;

  v_src := replace(v_src, v_old, '');
  v_src := replace(v_src,
    E'  RETURN jsonb_build_object(\n    ''return_invoice_id'', v_return_invoice_id,',
    E'  RETURN jsonb_build_object(\n    ''success'', true,\n    ''return_invoice_id'', v_return_invoice_id,');

  EXECUTE v_src;
END
$do$;