DO $do$
DECLARE d text; b text; guard text;
BEGIN
  guard := E'\n  IF EXISTS (\n    SELECT 1 FROM public.invoices r\n    WHERE r.original_invoice_id = p_invoice_id\n      AND r.user_id = v_user_id\n      AND r.status <> ''IPTAL''\n      AND r.deleted_at IS NULL\n  ) THEN\n    RAISE EXCEPTION ''Bu faturaya iade işlemi yapılmış. Önce iade faturasını iptal edin.'';\n  END IF;\n';

  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='cancel_sales_invoice';
  b := d;
  d := replace(d,
    E'    RAISE EXCEPTION ''Bu fatura zaten iptal edilmiştir. Fatura No: %'', v_invoice.invoice_number;\n  END IF;\n',
    E'    RAISE EXCEPTION ''Bu fatura zaten iptal edilmiştir. Fatura No: %'', v_invoice.invoice_number;\n  END IF;\n' || guard);
  IF d = b THEN RAISE EXCEPTION 'cancel_sales_invoice yaması uygulanamadı'; END IF;
  EXECUTE d;

  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='cancel_purchase_invoice';
  b := d;
  d := replace(d,
    E'    RETURN jsonb_build_object(''success'', true, ''message'', ''Fatura zaten iptal edilmiş.'');\n  END IF;\n',
    E'    RETURN jsonb_build_object(''success'', true, ''message'', ''Fatura zaten iptal edilmiş.'');\n  END IF;\n' || guard);
  IF d = b THEN RAISE EXCEPTION 'cancel_purchase_invoice yaması uygulanamadı'; END IF;
  EXECUTE d;
END
$do$;