REVOKE ALL ON FUNCTION public.generate_invoice_tax_lines(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.tg_generate_invoice_tax_lines() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.assert_returnable_quantities(uuid, uuid, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.generate_invoice_tax_lines(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.tg_generate_invoice_tax_lines() TO service_role;
GRANT EXECUTE ON FUNCTION public.assert_returnable_quantities(uuid, uuid, jsonb, text) TO service_role;