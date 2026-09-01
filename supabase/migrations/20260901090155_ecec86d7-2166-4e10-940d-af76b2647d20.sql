CREATE OR REPLACE FUNCTION public.get_customer_balances()
 RETURNS TABLE(customer_id uuid, balance numeric, total_debit numeric, total_credit numeric)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT
    c.id AS customer_id,
    COALESCE(c.opening_balance, 0)
      + COALESCE(SUM(CASE WHEN t.txn_type = 'BORC' THEN t.amount WHEN t.txn_type = 'ALACAK' THEN -t.amount ELSE 0 END), 0) AS balance,
    GREATEST(COALESCE(c.opening_balance, 0), 0)
      + COALESCE(SUM(CASE WHEN t.txn_type = 'BORC' THEN t.amount ELSE 0 END), 0) AS total_debit,
    GREATEST(-COALESCE(c.opening_balance, 0), 0)
      + COALESCE(SUM(CASE WHEN t.txn_type = 'ALACAK' THEN t.amount ELSE 0 END), 0) AS total_credit
  FROM public.customers c
  LEFT JOIN public.account_transactions t ON t.customer_id = c.id AND t.deleted_at IS NULL
  WHERE c.user_id = auth.uid() AND c.deleted_at IS NULL
  GROUP BY c.id, c.opening_balance;
$function$;

REVOKE EXECUTE ON FUNCTION public.get_customer_balances() FROM anon;