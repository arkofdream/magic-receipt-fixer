ALTER TABLE public.invoices
  ADD COLUMN IF NOT EXISTS customer_id uuid REFERENCES public.customers(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS warehouse_id uuid REFERENCES public.warehouses(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS posted boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS invoices_customer_id_idx ON public.invoices(customer_id);
CREATE INDEX IF NOT EXISTS account_transactions_source_idx ON public.account_transactions(source, source_id);
CREATE INDEX IF NOT EXISTS stock_movements_source_idx ON public.stock_movements(source, source_id);