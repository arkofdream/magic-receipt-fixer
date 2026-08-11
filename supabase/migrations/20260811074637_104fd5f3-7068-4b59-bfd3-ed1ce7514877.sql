CREATE TABLE public.pos_sales (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  sale_date DATE NOT NULL DEFAULT CURRENT_DATE,
  description TEXT NOT NULL DEFAULT '',
  document_no TEXT NOT NULL DEFAULT '',
  payment_type TEXT NOT NULL DEFAULT 'NAKIT',
  vat_rate NUMERIC NOT NULL DEFAULT 20,
  net_amount NUMERIC NOT NULL DEFAULT 0,
  vat_amount NUMERIC NOT NULL DEFAULT 0,
  gross_amount NUMERIC NOT NULL DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.pos_sales TO authenticated;
GRANT ALL ON public.pos_sales TO service_role;

ALTER TABLE public.pos_sales ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users manage own pos sales"
ON public.pos_sales FOR ALL TO authenticated
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);

CREATE INDEX pos_sales_user_date_idx ON public.pos_sales (user_id, sale_date DESC);

CREATE TRIGGER update_pos_sales_updated_at
BEFORE UPDATE ON public.pos_sales
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();