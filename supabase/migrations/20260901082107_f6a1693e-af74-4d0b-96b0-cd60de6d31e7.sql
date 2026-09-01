REVOKE EXECUTE ON FUNCTION public.process_invoice_payment(uuid, numeric, boolean, text, date, text, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.process_manual_account_transaction(uuid, text, numeric, date, date, text, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.process_customer_virman(uuid, uuid, numeric, date, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.process_manual_stock_movement(uuid, text, numeric, numeric, uuid, uuid, date, text, text) FROM PUBLIC, anon;