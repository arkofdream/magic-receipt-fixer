-- ============================================================================
-- MIGRATION: 20260826160000_create_invoice_items_table.sql
-- AMAÇ:
-- 1. public.invoice_items tablosunu tüm ilişkisel kolonları, indeksleri ve RLS politikaları ile oluşturmak.
-- 2. create_sales_invoice RPC'sinin fatura kalemlerini veritabanına sorunsuz yazmasını sağlamak.
-- ============================================================================

-- 1. invoice_items Tablosunun Güvenli Oluşturulması
CREATE TABLE IF NOT EXISTS public.invoice_items (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id      UUID NOT NULL REFERENCES public.invoices(id) ON DELETE CASCADE,
  user_id         UUID NOT NULL,
  line_number     INTEGER NOT NULL DEFAULT 1,
  product_id      UUID NULL REFERENCES public.products(id) ON DELETE SET NULL,
  name            TEXT NOT NULL DEFAULT 'Ürün/Hizmet',
  description     TEXT NOT NULL DEFAULT '',
  unit            TEXT NOT NULL DEFAULT 'Adet',
  quantity        NUMERIC(14,4) NOT NULL DEFAULT 1,
  unit_price      NUMERIC(14,4) NOT NULL DEFAULT 0,
  discount_rate   NUMERIC(5,2) NOT NULL DEFAULT 0,
  subtotal        NUMERIC(14,2) NOT NULL DEFAULT 0,
  discount_amount NUMERIC(14,2) NOT NULL DEFAULT 0,
  taxable_amount  NUMERIC(14,2) NOT NULL DEFAULT 0,
  vat_rate        NUMERIC(5,2) NOT NULL DEFAULT 0,
  vat_amount      NUMERIC(14,2) NOT NULL DEFAULT 0,
  line_total      NUMERIC(14,2) NOT NULL DEFAULT 0,
  unit_cost       NUMERIC(14,4) NOT NULL DEFAULT 0,
  total_cost      NUMERIC(14,2) NOT NULL DEFAULT 0,
  currency        TEXT NOT NULL DEFAULT 'TRY',
  exchange_rate   NUMERIC(14,6) NOT NULL DEFAULT 1,
  foreign_amount  NUMERIC(14,2) NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2. Eksik Kolonların Güvenli Eklenmesi (Tablo Önceden Varsa Bile Tamamlar)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='invoice_items' AND column_name='name') THEN
    ALTER TABLE public.invoice_items ADD COLUMN name TEXT NOT NULL DEFAULT 'Ürün/Hizmet';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='invoice_items' AND column_name='subtotal') THEN
    ALTER TABLE public.invoice_items ADD COLUMN subtotal NUMERIC(14,2) NOT NULL DEFAULT 0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='invoice_items' AND column_name='discount_amount') THEN
    ALTER TABLE public.invoice_items ADD COLUMN discount_amount NUMERIC(14,2) NOT NULL DEFAULT 0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='invoice_items' AND column_name='unit_cost') THEN
    ALTER TABLE public.invoice_items ADD COLUMN unit_cost NUMERIC(14,4) NOT NULL DEFAULT 0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='invoice_items' AND column_name='total_cost') THEN
    ALTER TABLE public.invoice_items ADD COLUMN total_cost NUMERIC(14,2) NOT NULL DEFAULT 0;
  END IF;
END $$;

-- 3. İndekslerin Oluşturulması
CREATE INDEX IF NOT EXISTS ii_invoice_id_idx ON public.invoice_items(invoice_id);
CREATE INDEX IF NOT EXISTS ii_user_id_idx    ON public.invoice_items(user_id);
CREATE INDEX IF NOT EXISTS ii_product_id_idx ON public.invoice_items(product_id) WHERE product_id IS NOT NULL;

-- 4. Yetkilendirme ve RLS Güvenlik Politikası
GRANT SELECT, INSERT, UPDATE, DELETE ON public.invoice_items TO authenticated;
GRANT ALL ON public.invoice_items TO service_role;
ALTER TABLE public.invoice_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ii_all_own" ON public.invoice_items;
CREATE POLICY "ii_all_own" ON public.invoice_items
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());
