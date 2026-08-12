CREATE OR REPLACE FUNCTION public.has_active_subscription(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.subscriptions
    WHERE user_id = _user_id
      AND status IN ('ACTIVE', 'UPCOMING_EXPIRY')
      AND end_date >= CURRENT_DATE
  )
$$;

REVOKE EXECUTE ON FUNCTION public.has_active_subscription(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.has_active_subscription(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.has_active_subscription(uuid) TO authenticated;

DROP POLICY "Users manage own invoices" ON public.invoices;
CREATE POLICY "Users read own invoices" ON public.invoices
FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Users update own invoices" ON public.invoices
FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users delete own invoices" ON public.invoices
FOR DELETE TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Subscribed users create own invoices" ON public.invoices
FOR INSERT TO authenticated
WITH CHECK (auth.uid() = user_id AND public.has_active_subscription(auth.uid()));

DROP POLICY "Users manage own pos sales" ON public.pos_sales;
CREATE POLICY "Users read own pos sales" ON public.pos_sales
FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Users update own pos sales" ON public.pos_sales
FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users delete own pos sales" ON public.pos_sales
FOR DELETE TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Subscribed users create own pos sales" ON public.pos_sales
FOR INSERT TO authenticated
WITH CHECK (auth.uid() = user_id AND public.has_active_subscription(auth.uid()));