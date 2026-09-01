-- 1) Return invoices link back to their original invoice
ALTER TABLE public.invoices
  ADD COLUMN IF NOT EXISTS original_invoice_id uuid REFERENCES public.invoices(id);

CREATE INDEX IF NOT EXISTS idx_invoices_original_invoice_id
  ON public.invoices(original_invoice_id) WHERE original_invoice_id IS NOT NULL;

-- Best-effort backfill for legacy return invoices (matched by description text)
UPDATE public.invoices r
SET original_invoice_id = o.id
FROM public.invoices o
WHERE r.original_invoice_id IS NULL
  AND r.type IN ('SATIS_IADE', 'ALIS_IADE')
  AND o.user_id = r.user_id
  AND o.id <> r.id
  AND o.type NOT IN ('SATIS_IADE', 'ALIS_IADE')
  AND COALESCE(o.invoice_number, '') <> ''
  AND r.notes LIKE '%' || o.invoice_number || '%';

-- 2) Returnable quantity guard
CREATE OR REPLACE FUNCTION public.assert_returnable_quantities(
  p_user_id uuid,
  p_original_invoice_id uuid,
  p_items jsonb,
  p_return_type text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_rec RECORD;
BEGIN
  IF p_original_invoice_id IS NULL OR p_items IS NULL THEN
    RETURN;
  END IF;

  -- Lock prior return invoices for this original invoice so concurrent
  -- return requests cannot both pass the check.
  PERFORM 1
  FROM public.invoices
  WHERE original_invoice_id = p_original_invoice_id
    AND user_id = p_user_id
    AND type = p_return_type
    AND status <> 'IPTAL'
  FOR UPDATE;

  FOR v_rec IN
    WITH orig AS (
      SELECT
        COALESCE(ii.product_id::text, lower(trim(COALESCE(ii.name, '')))) AS k,
        max(COALESCE(NULLIF(trim(ii.name), ''), 'Kalem')) AS label,
        sum(COALESCE(ii.quantity, 0)) AS qty
      FROM public.invoice_items ii
      WHERE ii.invoice_id = p_original_invoice_id
        AND ii.user_id = p_user_id
      GROUP BY 1
    ),
    prev AS (
      SELECT
        COALESCE(ii.product_id::text, lower(trim(COALESCE(ii.name, '')))) AS k,
        sum(COALESCE(ii.quantity, 0)) AS qty
      FROM public.invoice_items ii
      JOIN public.invoices r ON r.id = ii.invoice_id
      WHERE r.original_invoice_id = p_original_invoice_id
        AND r.user_id = p_user_id
        AND r.type = p_return_type
        AND r.status <> 'IPTAL'
      GROUP BY 1
    ),
    req AS (
      SELECT
        COALESCE(
          NULLIF(trim(item->>'productId'), ''),
          lower(trim(COALESCE(item->>'name', '')))
        ) AS k,
        max(COALESCE(NULLIF(trim(item->>'name'), ''), 'Kalem')) AS label,
        sum(GREATEST(0, COALESCE((item->>'quantity')::numeric, 0))) AS qty
      FROM jsonb_array_elements(p_items) AS item
      GROUP BY 1
    )
    SELECT
      req.k,
      COALESCE(orig.label, req.label) AS label,
      COALESCE(orig.qty, 0) AS orig_qty,
      COALESCE(prev.qty, 0) AS prev_qty,
      req.qty AS req_qty
    FROM req
    LEFT JOIN orig ON orig.k = req.k
    LEFT JOIN prev ON prev.k = req.k
  LOOP
    IF ROUND(v_rec.req_qty, 4) > ROUND(v_rec.orig_qty - v_rec.prev_qty, 4) THEN
      RAISE EXCEPTION
        'İade miktarı, kalan iade edilebilir miktarı aşamaz. Ürün: % (Fatura miktarı: %, Daha önce iade edilen: %, Kalan iade edilebilir: %, Talep edilen: %)',
        v_rec.label,
        ROUND(v_rec.orig_qty, 4),
        ROUND(v_rec.prev_qty, 4),
        GREATEST(0, ROUND(v_rec.orig_qty - v_rec.prev_qty, 4)),
        ROUND(v_rec.req_qty, 4)
        USING ERRCODE = '23514';
    END IF;
  END LOOP;
END;
$function$;

REVOKE ALL ON FUNCTION public.assert_returnable_quantities(uuid, uuid, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.assert_returnable_quantities(uuid, uuid, jsonb, text) TO authenticated, service_role;

-- 3) Patch the two working return RPCs in place (no rewrite: definition is read
--    from the catalog and only the guard + linkage lines are injected).
DO $do$
DECLARE
  d text;
  b text;
BEGIN
  -- ---------- create_purchase_return ----------
  SELECT pg_get_functiondef(p.oid) INTO d
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'create_purchase_return';

  IF d IS NULL THEN RAISE EXCEPTION 'create_purchase_return bulunamadı'; END IF;
  b := d;

  d := replace(d,
    '  -- 7. İade Toplamlarının Hesaplanması',
    '  PERFORM public.assert_returnable_quantities(v_user_id, p_original_invoice_id, p_items, ''ALIS_IADE'');' || E'\n\n' ||
    '  -- 7. İade Toplamlarının Hesaplanması');

  d := replace(d,
    E'INSERT INTO public.invoices (\n    user_id,\n    customer_id,',
    E'INSERT INTO public.invoices (\n    user_id,\n    original_invoice_id,\n    customer_id,');

  d := replace(d,
    E') VALUES (\n    v_user_id,\n    v_orig_invoice.customer_id,',
    E') VALUES (\n    v_user_id,\n    p_original_invoice_id,\n    v_orig_invoice.customer_id,');

  IF d = b THEN RAISE EXCEPTION 'create_purchase_return yaması uygulanamadı'; END IF;
  EXECUTE d;

  -- ---------- create_sales_return ----------
  SELECT pg_get_functiondef(p.oid) INTO d
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'create_sales_return';

  IF d IS NULL THEN RAISE EXCEPTION 'create_sales_return bulunamadı'; END IF;
  b := d;

  d := replace(d,
    E'    RAISE EXCEPTION ''Orijinal satış faturası bulunamadı (ID: %)'', p_original_invoice_id;\n  END IF;',
    E'    RAISE EXCEPTION ''Orijinal satış faturası bulunamadı (ID: %)'', p_original_invoice_id;\n  END IF;\n\n'
    || E'  IF v_orig_invoice.status = ''IPTAL'' THEN\n'
    || E'    RAISE EXCEPTION ''İptal edilmiş bir faturaya iade işlemi yapılamaz.'';\n'
    || E'  END IF;\n\n'
    || E'  PERFORM public.assert_returnable_quantities(v_user_id, p_original_invoice_id, p_items, ''SATIS_IADE'');');

  d := replace(d,
    E'INSERT INTO public.invoices (\n    user_id, customer_id,',
    E'INSERT INTO public.invoices (\n    user_id, original_invoice_id, customer_id,');

  d := replace(d,
    E'  ) VALUES (\n    v_user_id,\n    v_orig_invoice.customer_id,',
    E'  ) VALUES (\n    v_user_id,\n    p_original_invoice_id,\n    v_orig_invoice.customer_id,');

  IF d = b THEN RAISE EXCEPTION 'create_sales_return yaması uygulanamadı'; END IF;
  EXECUTE d;
END
$do$;