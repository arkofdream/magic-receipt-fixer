-- 1) customers genişletme
ALTER TABLE public.customers
  ADD COLUMN IF NOT EXISTS partner_type text NOT NULL DEFAULT 'MUSTERI',
  ADD COLUMN IF NOT EXISTS code text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS contact_name text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS partner_group text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS payment_term_days integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS risk_limit numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS opening_balance numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS note text NOT NULL DEFAULT '';

ALTER TABLE public.customers
  DROP CONSTRAINT IF EXISTS customers_partner_type_check;
ALTER TABLE public.customers
  ADD CONSTRAINT customers_partner_type_check CHECK (partner_type IN ('MUSTERI','TEDARIKCI'));

CREATE INDEX IF NOT EXISTS customers_user_type_idx ON public.customers(user_id, partner_type);

-- 2) products genişletme
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS code text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS barcode text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS description text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS category text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS purchase_price numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS discount_rate numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS min_stock numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS track_stock boolean NOT NULL DEFAULT true;

CREATE INDEX IF NOT EXISTS products_user_idx ON public.products(user_id);

-- 3) cari hareketler
CREATE TABLE IF NOT EXISTS public.account_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  customer_id uuid NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  counter_customer_id uuid REFERENCES public.customers(id) ON DELETE SET NULL,
  txn_date date NOT NULL DEFAULT CURRENT_DATE,
  due_date date,
  txn_type text NOT NULL DEFAULT 'BORC',
  amount numeric NOT NULL DEFAULT 0,
  document_no text NOT NULL DEFAULT '',
  description text NOT NULL DEFAULT '',
  source text NOT NULL DEFAULT 'MANUEL',
  source_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT account_transactions_type_check CHECK (txn_type IN ('BORC','ALACAK','TAHSILAT','ODEME','VIRMAN')),
  CONSTRAINT account_transactions_amount_check CHECK (amount >= 0)
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.account_transactions TO authenticated;
GRANT ALL ON public.account_transactions TO service_role;
ALTER TABLE public.account_transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users manage own account transactions"
  ON public.account_transactions FOR ALL TO authenticated
  USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS account_transactions_user_customer_idx
  ON public.account_transactions(user_id, customer_id, txn_date);

CREATE TRIGGER update_account_transactions_updated_at
  BEFORE UPDATE ON public.account_transactions
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- 4) depolar
CREATE TABLE IF NOT EXISTS public.warehouses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  name text NOT NULL,
  address text NOT NULL DEFAULT '',
  is_default boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.warehouses TO authenticated;
GRANT ALL ON public.warehouses TO service_role;
ALTER TABLE public.warehouses ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users manage own warehouses"
  ON public.warehouses FOR ALL TO authenticated
  USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

CREATE TRIGGER update_warehouses_updated_at
  BEFORE UPDATE ON public.warehouses
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- 5) stok hareketleri
CREATE TABLE IF NOT EXISTS public.stock_movements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  warehouse_id uuid REFERENCES public.warehouses(id) ON DELETE SET NULL,
  target_warehouse_id uuid REFERENCES public.warehouses(id) ON DELETE SET NULL,
  customer_id uuid REFERENCES public.customers(id) ON DELETE SET NULL,
  movement_date date NOT NULL DEFAULT CURRENT_DATE,
  movement_type text NOT NULL DEFAULT 'GIRIS',
  quantity numeric NOT NULL DEFAULT 0,
  unit_price numeric NOT NULL DEFAULT 0,
  document_no text NOT NULL DEFAULT '',
  description text NOT NULL DEFAULT '',
  source text NOT NULL DEFAULT 'MANUEL',
  source_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT stock_movements_type_check CHECK (movement_type IN ('GIRIS','CIKIS','TRANSFER','SAYIM')),
  CONSTRAINT stock_movements_qty_check CHECK (quantity >= 0)
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.stock_movements TO authenticated;
GRANT ALL ON public.stock_movements TO service_role;
ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users manage own stock movements"
  ON public.stock_movements FOR ALL TO authenticated
  USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS stock_movements_user_product_idx
  ON public.stock_movements(user_id, product_id, movement_date);

CREATE TRIGGER update_stock_movements_updated_at
  BEFORE UPDATE ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- 6) özet görünümler (RLS kullanıcı bazlı uygulanır)
CREATE OR REPLACE VIEW public.customer_balances
WITH (security_invoker = on) AS
SELECT
  c.id AS customer_id,
  c.user_id,
  c.opening_balance
    + COALESCE(SUM(CASE WHEN t.txn_type IN ('BORC','ODEME') THEN t.amount ELSE 0 END), 0) AS total_debit,
  COALESCE(SUM(CASE WHEN t.txn_type IN ('ALACAK','TAHSILAT') THEN t.amount ELSE 0 END), 0) AS total_credit,
  c.opening_balance
    + COALESCE(SUM(CASE WHEN t.txn_type IN ('BORC','ODEME') THEN t.amount ELSE 0 END), 0)
    - COALESCE(SUM(CASE WHEN t.txn_type IN ('ALACAK','TAHSILAT') THEN t.amount ELSE 0 END), 0) AS balance
FROM public.customers c
LEFT JOIN public.account_transactions t ON t.customer_id = c.id
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
      WHEN m.movement_type = 'GIRIS' THEN m.quantity
      WHEN m.movement_type = 'CIKIS' THEN -m.quantity
      ELSE 0
    END), 0) AS quantity
FROM public.products p
LEFT JOIN public.stock_movements m ON m.product_id = p.id
GROUP BY p.id, p.user_id;

GRANT SELECT ON public.product_stocks TO authenticated;
GRANT ALL ON public.product_stocks TO service_role;