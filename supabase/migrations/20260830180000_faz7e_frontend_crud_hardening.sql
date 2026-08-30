-- FAZ 7E - FRONTEND CRUD HARDENING
-- Replaces direct manual frontend inserts to financial tables with secure RPCs.

-- 1. process_manual_account_transaction
CREATE OR REPLACE FUNCTION public.process_manual_account_transaction(
  p_customer_id UUID,
  p_txn_type TEXT, -- 'BORC', 'ALACAK', 'TAHSILAT', 'ODEME'
  p_amount NUMERIC,
  p_txn_date DATE,
  p_due_date DATE DEFAULT NULL,
  p_document_no TEXT DEFAULT NULL,
  p_description TEXT DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
  v_year INTEGER;
  v_month INTEGER;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkisiz islem (Unauthenticated).';
  END IF;

  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Islem tutari 0 veya negatif olamaz.';
  END IF;

  v_year := EXTRACT(YEAR FROM p_txn_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM p_txn_date)::INTEGER;
  PERFORM public.assert_accounting_period_open(v_user_id, v_year, v_month);

  IF NOT EXISTS (SELECT 1 FROM public.customers WHERE id = p_customer_id AND user_id = v_user_id) THEN
    RAISE EXCEPTION 'Cari bulunamadi veya erisim izniniz yok.';
  END IF;

  INSERT INTO public.account_transactions (
    user_id, customer_id, txn_type, amount, txn_date, due_date, document_no, description, source
  ) VALUES (
    v_user_id, p_customer_id, p_txn_type, p_amount, p_txn_date, p_due_date, p_document_no, p_description, 'MANUEL'
  );

  RETURN jsonb_build_object('success', true, 'message', 'Cari hareket kaydedildi.');
END;
$$;


-- 2. process_customer_virman
CREATE OR REPLACE FUNCTION public.process_customer_virman(
  p_source_customer_id UUID,
  p_target_customer_id UUID,
  p_amount NUMERIC,
  p_txn_date DATE,
  p_description TEXT
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
  v_year INTEGER;
  v_month INTEGER;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkisiz islem (Unauthenticated).';
  END IF;

  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Islem tutari 0 veya negatif olamaz.';
  END IF;

  v_year := EXTRACT(YEAR FROM p_txn_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM p_txn_date)::INTEGER;
  PERFORM public.assert_accounting_period_open(v_user_id, v_year, v_month);

  IF NOT EXISTS (SELECT 1 FROM public.customers WHERE id = p_source_customer_id AND user_id = v_user_id) THEN
    RAISE EXCEPTION 'Kaynak cari bulunamadi veya erisim izniniz yok.';
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM public.customers WHERE id = p_target_customer_id AND user_id = v_user_id) THEN
    RAISE EXCEPTION 'Hedef cari bulunamadi veya erisim izniniz yok.';
  END IF;

  INSERT INTO public.account_transactions (
    user_id, customer_id, counter_customer_id, txn_type, amount, txn_date, description, source
  ) VALUES (
    v_user_id, p_source_customer_id, p_target_customer_id, 'ALACAK', p_amount, p_txn_date, p_description, 'VIRMAN'
  );

  INSERT INTO public.account_transactions (
    user_id, customer_id, counter_customer_id, txn_type, amount, txn_date, description, source
  ) VALUES (
    v_user_id, p_target_customer_id, p_source_customer_id, 'BORC', p_amount, p_txn_date, p_description, 'VIRMAN'
  );

  RETURN jsonb_build_object('success', true, 'message', 'Virman islemi basariyla gerceklesti.');
END;
$$;


-- 3. process_manual_stock_movement
CREATE OR REPLACE FUNCTION public.process_manual_stock_movement(
  p_product_id UUID,
  p_movement_type TEXT, -- 'GIRIS', 'CIKIS', 'TRANSFER'
  p_quantity NUMERIC,
  p_unit_price NUMERIC,
  p_warehouse_id UUID,
  p_target_warehouse_id UUID DEFAULT NULL,
  p_movement_date DATE DEFAULT CURRENT_DATE,
  p_document_no TEXT DEFAULT NULL,
  p_description TEXT DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
  v_year INTEGER;
  v_month INTEGER;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkisiz islem (Unauthenticated).';
  END IF;

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Miktar 0 veya negatif olamaz.';
  END IF;

  v_year := EXTRACT(YEAR FROM p_movement_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM p_movement_date)::INTEGER;
  PERFORM public.assert_accounting_period_open(v_user_id, v_year, v_month);

  IF NOT EXISTS (SELECT 1 FROM public.products WHERE id = p_product_id AND user_id = v_user_id) THEN
    RAISE EXCEPTION 'Urun bulunamadi veya erisim izniniz yok.';
  END IF;

  IF p_movement_type = 'TRANSFER' THEN
    IF p_warehouse_id IS NULL OR p_target_warehouse_id IS NULL OR p_warehouse_id = p_target_warehouse_id THEN
      RAISE EXCEPTION 'Farkli kaynak ve hedef depo seciniz.';
    END IF;

    -- Kaynak CIKIS
    INSERT INTO public.stock_movements (
      user_id, product_id, warehouse_id, target_warehouse_id, movement_type, quantity, unit_price, movement_date, document_no, description, source
    ) VALUES (
      v_user_id, p_product_id, p_warehouse_id, p_target_warehouse_id, 'CIKIS', p_quantity, p_unit_price, p_movement_date, p_document_no, p_description, 'TRANSFER'
    );

    -- Hedef GIRIS
    INSERT INTO public.stock_movements (
      user_id, product_id, warehouse_id, movement_type, quantity, unit_price, movement_date, document_no, description, source
    ) VALUES (
      v_user_id, p_product_id, p_target_warehouse_id, 'GIRIS', p_quantity, p_unit_price, p_movement_date, p_document_no, p_description, 'TRANSFER'
    );

  ELSE
    INSERT INTO public.stock_movements (
      user_id, product_id, warehouse_id, movement_type, quantity, unit_price, movement_date, document_no, description, source
    ) VALUES (
      v_user_id, p_product_id, p_warehouse_id, p_movement_type, p_quantity, p_unit_price, p_movement_date, p_document_no, p_description, 'MANUEL'
    );
  END IF;

  RETURN jsonb_build_object('success', true, 'message', 'Stok hareketi basariyla kaydedildi.');
END;
$$;

GRANT EXECUTE ON FUNCTION public.process_manual_account_transaction TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_customer_virman TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_manual_stock_movement TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_manual_account_transaction TO service_role;
GRANT EXECUTE ON FUNCTION public.process_customer_virman TO service_role;
GRANT EXECUTE ON FUNCTION public.process_manual_stock_movement TO service_role;
