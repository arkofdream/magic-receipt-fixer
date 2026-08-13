DROP POLICY IF EXISTS "Subscribed users create own invoices" ON public.invoices;
CREATE POLICY "Users create own invoices" ON public.invoices
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Subscribed users create own pos sales" ON public.pos_sales;
CREATE POLICY "Users create own pos sales" ON public.pos_sales
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

CREATE TABLE public.subscription_reminders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  email text NOT NULL,
  end_date date NOT NULL,
  threshold_days integer NOT NULL,
  sent_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, end_date, threshold_days)
);

GRANT SELECT ON public.subscription_reminders TO authenticated;
GRANT ALL ON public.subscription_reminders TO service_role;

ALTER TABLE public.subscription_reminders ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins read reminders" ON public.subscription_reminders
  FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'::app_role));

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

SELECT cron.schedule(
  'subscription-expiry-reminders',
  '0 6 * * *',
  $$
  SELECT net.http_post(
    url := 'https://project--7b27b8c3-f4a3-47de-9e34-d10a15f800e4.lovable.app/api/public/subscription-reminders',
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := '{}'::jsonb
  );
  $$
);