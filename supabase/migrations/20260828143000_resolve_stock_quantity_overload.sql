-- ============================================================================
-- RESOLVE get_product_stock_quantity FUNCTION OVERLOAD AMBIGUITY (PGRST203)
-- Date: 2026-08-28
-- ============================================================================

-- Drop both overloaded function definitions to clear pg_proc ambiguity
DROP FUNCTION IF EXISTS public.get_product_stock_quantity(UUID);
DROP FUNCTION IF EXISTS public.get_product_stock_quantity(UUID, UUID);

-- Single canonical definition for get_product_stock_quantity(UUID)
CREATE OR REPLACE FUNCTION public.get_product_stock_quantity(
  p_product_id UUID
)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
  v_qty     NUMERIC := 0;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    SELECT user_id INTO v_user_id FROM public.products WHERE id = p_product_id;
  END IF;

  IF v_user_id IS NULL THEN
    RETURN 0;
  END IF;

  SELECT COALESCE(SUM(
    CASE
      WHEN movement_type IN ('GIRIS', 'TRANSFER_IN') THEN quantity
      WHEN movement_type IN ('CIKIS', 'TRANSFER_OUT') THEN -quantity
      ELSE 0
    END
  ), 0)
  INTO v_qty
  FROM public.stock_movements
  WHERE user_id = v_user_id
    AND product_id = p_product_id;

  RETURN v_qty;
END;
$$;

-- Overload helper with p_warehouse_id if invoked with 2 arguments
CREATE OR REPLACE FUNCTION public.get_product_stock_quantity(
  p_product_id   UUID,
  p_warehouse_id UUID
)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
  v_qty     NUMERIC := 0;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    SELECT user_id INTO v_user_id FROM public.products WHERE id = p_product_id;
  END IF;

  IF v_user_id IS NULL THEN
    RETURN 0;
  END IF;

  SELECT COALESCE(SUM(
    CASE
      WHEN movement_type IN ('GIRIS', 'TRANSFER_IN') THEN quantity
      WHEN movement_type IN ('CIKIS', 'TRANSFER_OUT') THEN -quantity
      ELSE 0
    END
  ), 0)
  INTO v_qty
  FROM public.stock_movements
  WHERE user_id = v_user_id
    AND product_id = p_product_id
    AND (p_warehouse_id IS NULL OR warehouse_id = p_warehouse_id);

  RETURN v_qty;
END;
$$;

REVOKE ALL ON FUNCTION public.get_product_stock_quantity(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_product_stock_quantity(UUID) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.get_product_stock_quantity(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_product_stock_quantity(UUID, UUID) TO authenticated, service_role;
