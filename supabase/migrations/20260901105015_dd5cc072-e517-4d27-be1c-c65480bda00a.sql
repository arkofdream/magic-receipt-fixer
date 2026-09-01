CREATE OR REPLACE FUNCTION public.create_and_approve_sales_invoice(
  p_invoice_date date,
  p_type text DEFAULT 'SATIS'::text,
  p_customer_id uuid DEFAULT NULL::uuid,
  p_warehouse_id uuid DEFAULT NULL::uuid,
  p_customer_info jsonb DEFAULT '{}'::jsonb,
  p_items jsonb DEFAULT '[]'::jsonb,
  p_subtotal numeric DEFAULT 0,
  p_total_discount numeric DEFAULT 0,
  p_taxable_amount numeric DEFAULT 0,
  p_total_vat numeric DEFAULT 0,
  p_total_tevkifat numeric DEFAULT 0,
  p_grand_total numeric DEFAULT 0,
  p_currency text DEFAULT 'TRY'::text,
  p_exchange_rate numeric DEFAULT 1,
  p_notes text DEFAULT ''::text,
  p_payment_info text DEFAULT ''::text,
  p_ettn text DEFAULT NULL::text,
  p_invoice_number text DEFAULT NULL::text,
  p_prefix text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_res        JSONB;
  v_invoice_id UUID;
  v_approve    JSONB;
BEGIN
  -- Önce TASLAK olarak oluştur, ardından tam muhasebe onay akışından geçir.
  v_res := public.create_sales_invoice(
    p_invoice_date => p_invoice_date,
    p_type => p_type,
    p_status => 'TASLAK',
    p_customer_id => p_customer_id,
    p_warehouse_id => p_warehouse_id,
    p_customer_info => p_customer_info,
    p_items => p_items,
    p_subtotal => p_subtotal,
    p_total_discount => p_total_discount,
    p_taxable_amount => p_taxable_amount,
    p_total_vat => p_total_vat,
    p_total_tevkifat => p_total_tevkifat,
    p_grand_total => p_grand_total,
    p_currency => p_currency,
    p_exchange_rate => p_exchange_rate,
    p_notes => p_notes,
    p_payment_info => p_payment_info,
    p_ettn => p_ettn,
    p_invoice_number => p_invoice_number,
    p_prefix => p_prefix
  );

  v_invoice_id := (v_res->>'invoice_id')::UUID;
  v_approve := public.approve_sales_invoice(v_invoice_id);

  RETURN COALESCE(v_res, '{}'::jsonb)
         || COALESCE(v_approve, '{}'::jsonb)
         || jsonb_build_object('invoice_id', v_invoice_id, 'status', 'ONAYLANDI');
END;
$function$;

GRANT EXECUTE ON FUNCTION public.create_and_approve_sales_invoice(date, text, uuid, uuid, jsonb, jsonb, numeric, numeric, numeric, numeric, numeric, numeric, text, numeric, text, text, text, text, text) TO authenticated, service_role;