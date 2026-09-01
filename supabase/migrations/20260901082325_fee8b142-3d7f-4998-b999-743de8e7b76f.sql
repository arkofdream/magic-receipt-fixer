CREATE TABLE public.audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  action text NOT NULL,
  table_name text NOT NULL,
  record_id uuid,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT ON public.audit_logs TO authenticated;
GRANT ALL ON public.audit_logs TO service_role;

ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own audit logs"
  ON public.audit_logs FOR SELECT TO authenticated
  USING (auth.uid() = user_id);

CREATE INDEX idx_audit_logs_user_created ON public.audit_logs (user_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.log_soft_delete_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_action text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_action := 'DELETE';
    INSERT INTO public.audit_logs (user_id, action, table_name, record_id, details)
    VALUES (OLD.user_id, v_action, TG_TABLE_NAME, OLD.id, '{"hard_delete": true}'::jsonb);
    RETURN OLD;
  END IF;

  IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
    v_action := 'DELETE';
  ELSIF OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL THEN
    v_action := 'RESTORE';
  ELSE
    RETURN NEW;
  END IF;

  INSERT INTO public.audit_logs (user_id, action, table_name, record_id, details)
  VALUES (NEW.user_id, v_action, TG_TABLE_NAME, NEW.id, '{}'::jsonb);

  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.log_soft_delete_audit() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER audit_invoices_soft_delete
  AFTER UPDATE OR DELETE ON public.invoices
  FOR EACH ROW EXECUTE FUNCTION public.log_soft_delete_audit();

CREATE TRIGGER audit_customers_soft_delete
  AFTER UPDATE OR DELETE ON public.customers
  FOR EACH ROW EXECUTE FUNCTION public.log_soft_delete_audit();

CREATE TRIGGER audit_products_soft_delete
  AFTER UPDATE OR DELETE ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.log_soft_delete_audit();

CREATE TRIGGER audit_warehouses_soft_delete
  AFTER UPDATE OR DELETE ON public.warehouses
  FOR EACH ROW EXECUTE FUNCTION public.log_soft_delete_audit();

CREATE TRIGGER audit_stock_movements_soft_delete
  AFTER UPDATE OR DELETE ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION public.log_soft_delete_audit();

CREATE TRIGGER audit_account_transactions_soft_delete
  AFTER UPDATE OR DELETE ON public.account_transactions
  FOR EACH ROW EXECUTE FUNCTION public.log_soft_delete_audit();

CREATE TRIGGER audit_pos_sales_soft_delete
  AFTER UPDATE OR DELETE ON public.pos_sales
  FOR EACH ROW EXECUTE FUNCTION public.log_soft_delete_audit();