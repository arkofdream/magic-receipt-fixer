-- Migration: Veri Güvenliği, Soft Delete, Audit Log ve Veri Kurtarma Altyapısı

-- 1) Soft Delete Kolonları
ALTER TABLE public.invoices
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS deleted_by uuid NULL REFERENCES auth.users(id);

ALTER TABLE public.customers
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS deleted_by uuid NULL REFERENCES auth.users(id);

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS deleted_by uuid NULL REFERENCES auth.users(id);

ALTER TABLE public.account_transactions
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS deleted_by uuid NULL REFERENCES auth.users(id);

ALTER TABLE public.stock_movements
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS deleted_by uuid NULL REFERENCES auth.users(id);

ALTER TABLE public.pos_sales
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS deleted_by uuid NULL REFERENCES auth.users(id);

ALTER TABLE public.warehouses
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS deleted_by uuid NULL REFERENCES auth.users(id);

-- İndeksler (Sorgu performansı için)
CREATE INDEX IF NOT EXISTS idx_invoices_user_deleted ON public.invoices(user_id, deleted_at);
CREATE INDEX IF NOT EXISTS idx_customers_user_deleted ON public.customers(user_id, deleted_at);
CREATE INDEX IF NOT EXISTS idx_products_user_deleted ON public.products(user_id, deleted_at);
CREATE INDEX IF NOT EXISTS idx_account_transactions_user_deleted ON public.account_transactions(user_id, deleted_at);
CREATE INDEX IF NOT EXISTS idx_stock_movements_user_deleted ON public.stock_movements(user_id, deleted_at);
CREATE INDEX IF NOT EXISTS idx_pos_sales_user_deleted ON public.pos_sales(user_id, deleted_at);
CREATE INDEX IF NOT EXISTS idx_warehouses_user_deleted ON public.warehouses(user_id, deleted_at);

-- 2) Audit Logs Tablosu
CREATE TABLE IF NOT EXISTS public.audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id),
  action text NOT NULL,
  table_name text NOT NULL,
  record_id text NOT NULL,
  old_data jsonb NULL,
  new_data jsonb NULL,
  metadata jsonb NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT ON public.audit_logs TO authenticated;
GRANT ALL ON public.audit_logs TO service_role;

ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users read own audit logs" ON public.audit_logs;
CREATE POLICY "Users read own audit logs" ON public.audit_logs
  FOR SELECT TO authenticated USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users insert own audit logs" ON public.audit_logs;
CREATE POLICY "Users insert own audit logs" ON public.audit_logs
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_audit_logs_user_created ON public.audit_logs(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_table_record ON public.audit_logs(user_id, table_name, record_id);

-- 3) Audit Log Trigger Fonksiyonu
CREATE OR REPLACE FUNCTION public.log_audit_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_action text;
  v_old jsonb := NULL;
  v_new jsonb := NULL;
  v_record_id text;
BEGIN
  v_user_id := auth.uid();

  IF TG_OP = 'INSERT' THEN
    v_action := 'CREATE';
    v_new := to_jsonb(NEW);
    v_record_id := NEW.id::text;
    IF v_user_id IS NULL AND NEW.user_id IS NOT NULL THEN
      v_user_id := NEW.user_id;
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
      v_action := 'DELETE';
    ELSIF OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL THEN
      v_action := 'RESTORE';
    ELSE
      v_action := 'UPDATE';
    END IF;
    v_old := to_jsonb(OLD);
    v_new := to_jsonb(NEW);
    v_record_id := NEW.id::text;
    IF v_user_id IS NULL THEN
      v_user_id := COALESCE(NEW.user_id, OLD.user_id);
    END IF;
  ELSIF TG_OP = 'DELETE' THEN
    v_action := 'PERMANENT_DELETE';
    v_old := to_jsonb(OLD);
    v_record_id := OLD.id::text;
    IF v_user_id IS NULL THEN
      v_user_id := OLD.user_id;
    END IF;
  END IF;

  IF v_user_id IS NOT NULL THEN
    INSERT INTO public.audit_logs (
      user_id,
      action,
      table_name,
      record_id,
      old_data,
      new_data,
      metadata
    ) VALUES (
      v_user_id,
      v_action,
      TG_TABLE_NAME,
      v_record_id,
      v_old,
      v_new,
      jsonb_build_object('trigger', true, 'op', TG_OP)
    );
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  ELSE
    RETURN NEW;
  END IF;
END;
$$;

-- Triggerların Tanımlanması
DROP TRIGGER IF EXISTS audit_invoices_trigger ON public.invoices;
CREATE TRIGGER audit_invoices_trigger AFTER INSERT OR UPDATE OR DELETE ON public.invoices FOR EACH ROW EXECUTE FUNCTION public.log_audit_event();

DROP TRIGGER IF EXISTS audit_customers_trigger ON public.customers;
CREATE TRIGGER audit_customers_trigger AFTER INSERT OR UPDATE OR DELETE ON public.customers FOR EACH ROW EXECUTE FUNCTION public.log_audit_event();

DROP TRIGGER IF EXISTS audit_products_trigger ON public.products;
CREATE TRIGGER audit_products_trigger AFTER INSERT OR UPDATE OR DELETE ON public.products FOR EACH ROW EXECUTE FUNCTION public.log_audit_event();

DROP TRIGGER IF EXISTS audit_account_transactions_trigger ON public.account_transactions;
CREATE TRIGGER audit_account_transactions_trigger AFTER INSERT OR UPDATE OR DELETE ON public.account_transactions FOR EACH ROW EXECUTE FUNCTION public.log_audit_event();

DROP TRIGGER IF EXISTS audit_stock_movements_trigger ON public.stock_movements;
CREATE TRIGGER audit_stock_movements_trigger AFTER INSERT OR UPDATE OR DELETE ON public.stock_movements FOR EACH ROW EXECUTE FUNCTION public.log_audit_event();

DROP TRIGGER IF EXISTS audit_pos_sales_trigger ON public.pos_sales;
CREATE TRIGGER audit_pos_sales_trigger AFTER INSERT OR UPDATE OR DELETE ON public.pos_sales FOR EACH ROW EXECUTE FUNCTION public.log_audit_event();

DROP TRIGGER IF EXISTS audit_warehouses_trigger ON public.warehouses;
CREATE TRIGGER audit_warehouses_trigger AFTER INSERT OR UPDATE OR DELETE ON public.warehouses FOR EACH ROW EXECUTE FUNCTION public.log_audit_event();

-- 4) Bakiyelerin ve Stokların Soft Delete Uyumu (Soft-deleted kayıtlar hesaplamadan çıkarılır)
CREATE OR REPLACE VIEW public.customer_balances
WITH (security_invoker = on) AS
SELECT
  c.id AS customer_id,
  c.user_id,
  c.opening_balance
    + COALESCE(SUM(CASE WHEN t.deleted_at IS NULL AND t.txn_type IN ('BORC','ODEME') THEN t.amount ELSE 0 END), 0) AS total_debit,
  COALESCE(SUM(CASE WHEN t.deleted_at IS NULL AND t.txn_type IN ('ALACAK','TAHSILAT') THEN t.amount ELSE 0 END), 0) AS total_credit,
  c.opening_balance
    + COALESCE(SUM(CASE WHEN t.deleted_at IS NULL AND t.txn_type IN ('BORC','ODEME') THEN t.amount ELSE 0 END), 0)
    - COALESCE(SUM(CASE WHEN t.deleted_at IS NULL AND t.txn_type IN ('ALACAK','TAHSILAT') THEN t.amount ELSE 0 END), 0) AS balance
FROM public.customers c
LEFT JOIN public.account_transactions t ON t.customer_id = c.id
WHERE c.deleted_at IS NULL
GROUP BY c.id, c.user_id, c.opening_balance;

GRANT SELECT ON public.customer_balances TO authenticated;
GRANT ALL ON public.customer_balances TO service_role;

CREATE OR REPLACE VIEW public.product_stocks
WITH (security_invoker = on) AS
SELECT
  p.id AS product_id,
  p.user_id,
  COALESCE(SUM(
    CASE
      WHEN m.deleted_at IS NULL AND m.movement_type = 'GIRIS' THEN m.quantity
      WHEN m.deleted_at IS NULL AND m.movement_type = 'CIKIS' THEN -m.quantity
      ELSE 0
    END), 0) AS quantity
FROM public.products p
LEFT JOIN public.stock_movements m ON m.product_id = p.id
WHERE p.deleted_at IS NULL
GROUP BY p.id, p.user_id;

GRANT SELECT ON public.product_stocks TO authenticated;
GRANT ALL ON public.product_stocks TO service_role;
