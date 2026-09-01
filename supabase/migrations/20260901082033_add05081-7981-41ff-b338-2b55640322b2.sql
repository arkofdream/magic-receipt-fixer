CREATE OR REPLACE FUNCTION public.process_invoice_payment(
  p_invoice_id uuid,
  p_amount numeric,
  p_is_purchase boolean DEFAULT false,
  p_payment_method text DEFAULT 'KASA',
  p_payment_date date DEFAULT CURRENT_DATE,
  p_document_no text DEFAULT '',
  p_description text DEFAULT ''
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id UUID;
  v_inv RECORD;
  v_paid NUMERIC;
  v_remaining NUMERIC;
  v_source TEXT;
  v_txn_type TEXT;
  v_txn_id UUID;
  v_journal_id UUID;
  v_counter_acc UUID;
  v_cash_acc UUID;
  v_year INT;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.' USING ERRCODE = '42501';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'Tutar sıfırdan büyük olmalıdır.');
  END IF;

  SELECT * INTO v_inv FROM public.invoices
   WHERE id = p_invoice_id AND user_id = v_user_id AND deleted_at IS NULL;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'Fatura bulunamadı.');
  END IF;

  IF v_inv.customer_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Faturaya bağlı cari bulunamadı.');
  END IF;

  v_source := CASE WHEN p_is_purchase THEN 'FATURA_ODEME' ELSE 'FATURA_TAHSILAT' END;
  v_txn_type := CASE WHEN p_is_purchase THEN 'BORC' ELSE 'ALACAK' END;

  SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM public.account_transactions
   WHERE user_id = v_user_id AND source = v_source AND source_id = p_invoice_id AND deleted_at IS NULL;

  v_remaining := ROUND(v_inv.grand_total - v_paid, 2);
  IF v_remaining <= 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'Bu fatura için kalan bakiye bulunmuyor.');
  END IF;
  IF ROUND(p_amount, 2) > v_remaining THEN
    RETURN jsonb_build_object('success', false, 'message',
      'Girilen tutar kalan bakiyeden (' || v_remaining::TEXT || ') büyük olamaz.');
  END IF;

  v_year := EXTRACT(YEAR FROM p_payment_date)::INT;

  INSERT INTO public.account_transactions (
    user_id, customer_id, txn_date, txn_type, amount, document_no, description, source, source_id
  ) VALUES (
    v_user_id, v_inv.customer_id, p_payment_date, v_txn_type, ROUND(p_amount, 2),
    COALESCE(NULLIF(p_document_no, ''), v_inv.invoice_number),
    COALESCE(NULLIF(p_description, ''),
      CASE WHEN p_is_purchase THEN 'Fatura ödemesi' ELSE 'Fatura tahsilatı' END
      || ': ' || v_inv.invoice_number),
    v_source, p_invoice_id
  ) RETURNING id INTO v_txn_id;

  SELECT id INTO v_counter_acc FROM public.chart_of_accounts
   WHERE code = (CASE WHEN p_is_purchase THEN '320' ELSE '120' END) LIMIT 1;
  SELECT id INTO v_cash_acc FROM public.chart_of_accounts
   WHERE code = (CASE WHEN p_payment_method = 'BANKA' THEN '102' ELSE '100' END) LIMIT 1;

  IF v_counter_acc IS NOT NULL AND v_cash_acc IS NOT NULL THEN
    INSERT INTO public.journal_entries (
      user_id, entry_number, entry_date, description, entry_type, source_type, source_id,
      status, total_debit, total_credit, period_year, period_month
    ) VALUES (
      v_user_id, public.next_entry_number(v_user_id, v_year, 'JOURNAL'), p_payment_date,
      CASE WHEN p_is_purchase THEN 'Tediye Fişi: ' ELSE 'Tahsil Fişi: ' END || v_inv.invoice_number,
      CASE WHEN p_is_purchase THEN 'PAYMENT' ELSE 'COLLECTION' END,
      'ACCOUNT_TXN', v_txn_id, 'POSTED', ROUND(p_amount, 2), ROUND(p_amount, 2),
      v_year, EXTRACT(MONTH FROM p_payment_date)::INT
    ) RETURNING id INTO v_journal_id;

    IF p_is_purchase THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit)
      VALUES (v_journal_id, v_user_id, v_counter_acc, 'Satıcılar borç kapanışı', ROUND(p_amount, 2), 0);
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit)
      VALUES (v_journal_id, v_user_id, v_cash_acc, 'Kasa/Banka çıkışı', 0, ROUND(p_amount, 2));
    ELSE
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit)
      VALUES (v_journal_id, v_user_id, v_cash_acc, 'Kasa/Banka girişi', ROUND(p_amount, 2), 0);
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit)
      VALUES (v_journal_id, v_user_id, v_counter_acc, 'Alıcılar alacak kapanışı', 0, ROUND(p_amount, 2));
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'İşlem başarıyla kaydedildi.',
    'transaction_id', v_txn_id,
    'amount', ROUND(p_amount, 2),
    'remaining', ROUND(v_remaining - p_amount, 2)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.process_invoice_payment(uuid, numeric, boolean, text, date, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.process_manual_account_transaction(
  p_customer_id uuid,
  p_txn_type text,
  p_amount numeric,
  p_txn_date date DEFAULT CURRENT_DATE,
  p_due_date date DEFAULT NULL,
  p_document_no text DEFAULT '',
  p_description text DEFAULT ''
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id UUID;
  v_txn_id UUID;
  v_type TEXT;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.' USING ERRCODE = '42501';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'Tutar sıfırdan büyük olmalıdır.');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.customers
                  WHERE id = p_customer_id AND user_id = v_user_id AND deleted_at IS NULL) THEN
    RETURN jsonb_build_object('success', false, 'message', 'Cari bulunamadı.');
  END IF;

  v_type := UPPER(COALESCE(p_txn_type, ''));
  IF v_type = 'TAHSILAT' THEN v_type := 'ALACAK'; END IF;
  IF v_type = 'ODEME' THEN v_type := 'BORC'; END IF;
  IF v_type NOT IN ('BORC', 'ALACAK') THEN
    RETURN jsonb_build_object('success', false, 'message', 'Geçersiz hareket türü.');
  END IF;

  INSERT INTO public.account_transactions (
    user_id, customer_id, txn_date, due_date, txn_type, amount, document_no, description, source
  ) VALUES (
    v_user_id, p_customer_id, p_txn_date, p_due_date, v_type, ROUND(p_amount, 2),
    COALESCE(p_document_no, ''), COALESCE(NULLIF(p_description, ''), 'Manuel cari hareket'), 'MANUEL'
  ) RETURNING id INTO v_txn_id;

  RETURN jsonb_build_object('success', true, 'message', 'Cari hareket kaydedildi.', 'transaction_id', v_txn_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.process_manual_account_transaction(uuid, text, numeric, date, date, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.process_customer_virman(
  p_source_customer_id uuid,
  p_target_customer_id uuid,
  p_amount numeric,
  p_txn_date date DEFAULT CURRENT_DATE,
  p_description text DEFAULT ''
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id UUID;
  v_desc TEXT;
  v_doc TEXT;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.' USING ERRCODE = '42501';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'Tutar sıfırdan büyük olmalıdır.');
  END IF;

  IF p_source_customer_id = p_target_customer_id THEN
    RETURN jsonb_build_object('success', false, 'message', 'Kaynak ve hedef cari aynı olamaz.');
  END IF;

  IF (SELECT COUNT(*) FROM public.customers
       WHERE id IN (p_source_customer_id, p_target_customer_id)
         AND user_id = v_user_id AND deleted_at IS NULL) <> 2 THEN
    RETURN jsonb_build_object('success', false, 'message', 'Cari kayıtları bulunamadı.');
  END IF;

  v_desc := COALESCE(NULLIF(p_description, ''), 'Cari virman');
  v_doc := 'VIRMAN-' || TO_CHAR(NOW(), 'YYYYMMDDHH24MISS');

  INSERT INTO public.account_transactions (
    user_id, customer_id, counter_customer_id, txn_date, txn_type, amount, document_no, description, source
  ) VALUES (
    v_user_id, p_source_customer_id, p_target_customer_id, p_txn_date, 'ALACAK',
    ROUND(p_amount, 2), v_doc, v_desc || ' (çıkış)', 'VIRMAN'
  );

  INSERT INTO public.account_transactions (
    user_id, customer_id, counter_customer_id, txn_date, txn_type, amount, document_no, description, source
  ) VALUES (
    v_user_id, p_target_customer_id, p_source_customer_id, p_txn_date, 'BORC',
    ROUND(p_amount, 2), v_doc, v_desc || ' (giriş)', 'VIRMAN'
  );

  RETURN jsonb_build_object('success', true, 'message', 'Virman tamamlandı.', 'document_no', v_doc);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.process_customer_virman(uuid, uuid, numeric, date, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.process_manual_stock_movement(
  p_product_id uuid,
  p_movement_type text,
  p_quantity numeric,
  p_unit_price numeric DEFAULT 0,
  p_warehouse_id uuid DEFAULT NULL,
  p_target_warehouse_id uuid DEFAULT NULL,
  p_movement_date date DEFAULT CURRENT_DATE,
  p_document_no text DEFAULT '',
  p_description text DEFAULT ''
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id UUID;
  v_type TEXT;
  v_qty NUMERIC;
  v_stock NUMERIC;
  v_desc TEXT;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.' USING ERRCODE = '42501';
  END IF;

  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'Miktar sıfırdan büyük olmalıdır.');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.products
                  WHERE id = p_product_id AND user_id = v_user_id AND deleted_at IS NULL) THEN
    RETURN jsonb_build_object('success', false, 'message', 'Ürün bulunamadı.');
  END IF;

  v_type := UPPER(COALESCE(p_movement_type, ''));
  IF v_type NOT IN ('GIRIS', 'CIKIS', 'TRANSFER', 'SAYIM') THEN
    RETURN jsonb_build_object('success', false, 'message', 'Geçersiz hareket türü.');
  END IF;

  v_qty := ROUND(p_quantity, 4);
  v_desc := COALESCE(NULLIF(p_description, ''), 'Manuel stok hareketi');

  IF v_type = 'TRANSFER' THEN
    IF p_warehouse_id IS NULL OR p_target_warehouse_id IS NULL OR p_warehouse_id = p_target_warehouse_id THEN
      RETURN jsonb_build_object('success', false, 'message', 'Farklı kaynak ve hedef depo seçiniz.');
    END IF;

    v_stock := public.get_product_stock_quantity(p_product_id, p_warehouse_id);
    IF v_stock < v_qty THEN
      RETURN jsonb_build_object('success', false, 'message',
        'Kaynak depoda yeterli stok yok. Mevcut: ' || v_stock::TEXT);
    END IF;

    INSERT INTO public.stock_movements (
      user_id, product_id, warehouse_id, target_warehouse_id, movement_date, movement_type,
      quantity, unit_price, document_no, description, source
    ) VALUES (
      v_user_id, p_product_id, p_warehouse_id, p_target_warehouse_id, p_movement_date, 'CIKIS',
      v_qty, COALESCE(p_unit_price, 0), COALESCE(p_document_no, ''), v_desc || ' (transfer çıkış)', 'TRANSFER'
    );

    INSERT INTO public.stock_movements (
      user_id, product_id, warehouse_id, target_warehouse_id, movement_date, movement_type,
      quantity, unit_price, document_no, description, source
    ) VALUES (
      v_user_id, p_product_id, p_target_warehouse_id, p_warehouse_id, p_movement_date, 'GIRIS',
      v_qty, COALESCE(p_unit_price, 0), COALESCE(p_document_no, ''), v_desc || ' (transfer giriş)', 'TRANSFER'
    );

    RETURN jsonb_build_object('success', true, 'message', 'Depo transferi tamamlandı.');
  END IF;

  IF v_type = 'CIKIS' THEN
    v_stock := public.get_product_stock_quantity(p_product_id, p_warehouse_id);
    IF v_stock < v_qty THEN
      RETURN jsonb_build_object('success', false, 'message',
        'Yeterli stok yok. Mevcut: ' || v_stock::TEXT);
    END IF;
  END IF;

  INSERT INTO public.stock_movements (
    user_id, product_id, warehouse_id, movement_date, movement_type,
    quantity, unit_price, document_no, description, source
  ) VALUES (
    v_user_id, p_product_id, p_warehouse_id, p_movement_date, v_type,
    v_qty, COALESCE(p_unit_price, 0), COALESCE(p_document_no, ''), v_desc, 'MANUEL'
  );

  RETURN jsonb_build_object('success', true, 'message', 'Stok hareketi kaydedildi.');
END;
$function$;

GRANT EXECUTE ON FUNCTION public.process_manual_stock_movement(uuid, text, numeric, numeric, uuid, uuid, date, text, text) TO authenticated;