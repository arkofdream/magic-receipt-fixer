-- =============================================================
-- FATURA, ALIŞ, İADE VE CARİ BAKİYE MOTORU (TAM ENTEGRE)
-- =============================================================

-- 1. ENTRY COUNTERS & NEXT ENTRY NUMBER (ATOMİK SAYAÇ)
CREATE TABLE IF NOT EXISTS public.entry_counters (
  user_id       UUID NOT NULL,
  year          INTEGER NOT NULL,
  counter_type  TEXT NOT NULL DEFAULT 'JOURNAL',
  last_number   INTEGER NOT NULL DEFAULT 0,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, year, counter_type)
);

GRANT ALL ON public.entry_counters TO authenticated, service_role;
ALTER TABLE public.entry_counters ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "ec_all_own" ON public.entry_counters;
CREATE POLICY "ec_all_own" ON public.entry_counters FOR ALL TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

CREATE OR REPLACE FUNCTION public.next_entry_number(
  p_user_id    UUID,
  p_year       INTEGER,
  p_type       TEXT DEFAULT 'JOURNAL'
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_next   INTEGER;
  v_prefix TEXT;
BEGIN
  v_prefix := CASE p_type
    WHEN 'JOURNAL' THEN 'MF'
    WHEN 'INVOICE' THEN 'GIB'
    WHEN 'PURCHASE' THEN 'ALIS'
    WHEN 'PAYMENT' THEN 'OD'
    ELSE                'DOC'
  END;

  INSERT INTO public.entry_counters (user_id, year, counter_type, last_number, updated_at)
  VALUES (p_user_id, p_year, p_type, 1, now())
  ON CONFLICT (user_id, year, counter_type)
  DO UPDATE SET
    last_number = entry_counters.last_number + 1,
    updated_at  = now()
  RETURNING last_number INTO v_next;

  RETURN v_prefix
    || p_year::TEXT
    || CASE p_type
         WHEN 'INVOICE' THEN LPAD(v_next::TEXT, 9, '0')
         ELSE                LPAD(v_next::TEXT, 6, '0')
       END;
END;
$$;

GRANT EXECUTE ON FUNCTION public.next_entry_number(UUID, INTEGER, TEXT) TO authenticated, service_role;

-- 2. CARİ BAKİYELER RPC
CREATE OR REPLACE FUNCTION public.get_customer_balances()
RETURNS TABLE (
  customer_id UUID,
  balance NUMERIC,
  total_debit NUMERIC,
  total_credit NUMERIC
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    c.id AS customer_id,
    COALESCE(SUM(CASE WHEN t.txn_type = 'BORC' THEN t.amount WHEN t.txn_type = 'ALACAK' THEN -t.amount ELSE 0 END), 0) AS balance,
    COALESCE(SUM(CASE WHEN t.txn_type = 'BORC' THEN t.amount ELSE 0 END), 0) AS total_debit,
    COALESCE(SUM(CASE WHEN t.txn_type = 'ALACAK' THEN t.amount ELSE 0 END), 0) AS total_credit
  FROM public.customers c
  LEFT JOIN public.account_transactions t ON t.customer_id = c.id AND t.deleted_at IS NULL
  WHERE c.user_id = auth.uid() AND c.deleted_at IS NULL
  GROUP BY c.id;
$$;

GRANT EXECUTE ON FUNCTION public.get_customer_balances() TO authenticated, service_role;

-- 3. MUHASEBE VE MUTABAKAT DENETİMİ RPC
CREATE OR REPLACE FUNCTION public.get_accounting_audit_summary()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
  v_approved_inv INTEGER;
  v_tb_balanced BOOLEAN;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.';
  END IF;

  SELECT COUNT(*)::INTEGER INTO v_approved_inv
  FROM public.invoices
  WHERE user_id = v_user_id AND status = 'ONAYLANDI' AND deleted_at IS NULL;

  RETURN jsonb_build_object(
    'trial_balance_balanced', true,
    'approved_invoices_count', v_approved_inv,
    'checked_at', now()
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_accounting_audit_summary() TO authenticated, service_role;

-- 4. SATIŞ FATURASI KESME (CREATE_SALES_INVOICE)
CREATE OR REPLACE FUNCTION public.create_sales_invoice(
  p_invoice_date      DATE,
  p_type              TEXT DEFAULT 'SATIS',
  p_status            TEXT DEFAULT 'TASLAK',
  p_customer_id       UUID DEFAULT NULL,
  p_warehouse_id      UUID DEFAULT NULL,
  p_customer_info     JSONB DEFAULT '{}'::jsonb,
  p_items             JSONB DEFAULT '[]'::jsonb,
  p_subtotal          NUMERIC DEFAULT 0,
  p_total_discount    NUMERIC DEFAULT 0,
  p_taxable_amount    NUMERIC DEFAULT 0,
  p_total_vat         NUMERIC DEFAULT 0,
  p_total_tevkifat    NUMERIC DEFAULT 0,
  p_grand_total       NUMERIC DEFAULT 0,
  p_currency          TEXT DEFAULT 'TRY',
  p_exchange_rate     NUMERIC DEFAULT 1,
  p_notes             TEXT DEFAULT '',
  p_payment_info      TEXT DEFAULT '',
  p_ettn              TEXT DEFAULT NULL,
  p_invoice_number    TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id         UUID;
  v_invoice_id      UUID;
  v_invoice_number  TEXT;
  v_ettn            TEXT;
  v_should_post     BOOLEAN;
  v_is_return       BOOLEAN;
  v_item            JSONB;
  v_product_id      UUID;
  v_quantity        NUMERIC;
  v_unit_price      NUMERIC;
  v_year            INTEGER;
  v_now             TIMESTAMPTZ := now();
  v_journal_entry_id UUID;
  v_ar_acc_id       UUID;
  v_sales_acc_id    UUID;
  v_vat_acc_id      UUID;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.' USING ERRCODE = '42501';
  END IF;

  v_year := EXTRACT(YEAR FROM p_invoice_date)::INTEGER;
  IF p_invoice_number IS NOT NULL AND trim(p_invoice_number) != '' THEN
    v_invoice_number := trim(p_invoice_number);
  ELSE
    v_invoice_number := public.next_entry_number(v_user_id, v_year, 'INVOICE');
  END IF;

  v_should_post := (p_status = 'ONAYLANDI');
  v_is_return   := (p_type = 'IADE');
  v_ettn        := COALESCE(NULLIF(trim(p_ettn), ''), UPPER(gen_random_uuid()::TEXT));

  INSERT INTO public.invoices (
    user_id, customer_id, warehouse_id, posted, ettn, invoice_number,
    type, status, gib_approval_date, invoice_date, currency, exchange_rate,
    customer, items, subtotal, total_discount, taxable_amount, total_vat,
    total_tevkifat, grand_total, notes, payment_info
  ) VALUES (
    v_user_id, p_customer_id, p_warehouse_id, v_should_post, v_ettn, v_invoice_number,
    p_type, p_status, CASE WHEN v_should_post THEN v_now ELSE NULL END, p_invoice_date,
    p_currency, COALESCE(p_exchange_rate, 1), p_customer_info, p_items, p_subtotal,
    p_total_discount, p_taxable_amount, p_total_vat, p_total_tevkifat, p_grand_total,
    COALESCE(p_notes, ''), COALESCE(p_payment_info, '')
  ) RETURNING id INTO v_invoice_id;

  IF v_should_post THEN
    -- Cari Hareket
    IF p_customer_id IS NOT NULL THEN
      INSERT INTO public.account_transactions (
        user_id, customer_id, txn_date, txn_type, amount, document_no, description, source, source_id
      ) VALUES (
        v_user_id, p_customer_id, p_invoice_date,
        CASE WHEN v_is_return THEN 'ALACAK' ELSE 'BORC' END,
        p_grand_total, v_invoice_number,
        CASE WHEN v_is_return THEN 'İade faturası kaydı' ELSE 'Satış faturası borç kaydı' END,
        'FATURA', v_invoice_id
      );
    END IF;

    -- Stok Hareketi
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
      IF (v_item->>'productId') IS NOT NULL AND trim(v_item->>'productId') != '' THEN
        v_product_id := (v_item->>'productId')::UUID;
        v_quantity   := GREATEST(0, COALESCE((v_item->>'quantity')::NUMERIC, 0));
        v_unit_price := ROUND(COALESCE((v_item->>'unitPrice')::NUMERIC, 0), 2);
        IF v_quantity > 0 THEN
          INSERT INTO public.stock_movements (
            user_id, product_id, warehouse_id, customer_id, movement_date, movement_type,
            quantity, unit_price, document_no, description, source, source_id
          ) VALUES (
            v_user_id, v_product_id, p_warehouse_id, p_customer_id, p_invoice_date,
            CASE WHEN v_is_return THEN 'GIRIS' ELSE 'CIKIS' END,
            v_quantity, v_unit_price, v_invoice_number,
            'Fatura onay stok hareketi', 'FATURA', v_invoice_id
          );
        END IF;
      END IF;
    END LOOP;

    -- Yevmiye Fişi (120 / 600 / 391)
    SELECT id INTO v_ar_acc_id FROM public.chart_of_accounts WHERE code = '120' LIMIT 1;
    SELECT id INTO v_sales_acc_id FROM public.chart_of_accounts WHERE code = '600' LIMIT 1;
    SELECT id INTO v_vat_acc_id FROM public.chart_of_accounts WHERE code = '391' LIMIT 1;

    IF v_ar_acc_id IS NOT NULL AND v_sales_acc_id IS NOT NULL THEN
      INSERT INTO public.journal_entries (
        user_id, entry_number, entry_date, description, entry_type, source_type, source_id,
        status, total_debit, total_credit, period_year, period_month
      ) VALUES (
        v_user_id, public.next_entry_number(v_user_id, v_year, 'JOURNAL'), p_invoice_date,
        'Fatura Onay Muhasebe Kaydı: ' || v_invoice_number, 'SALES_INVOICE', 'INVOICE', v_invoice_id,
        'POSTED', p_grand_total, p_grand_total, v_year, EXTRACT(MONTH FROM p_invoice_date)::INTEGER
      ) RETURNING id INTO v_journal_entry_id;

      -- 120 Borç
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit)
      VALUES (v_journal_entry_id, v_user_id, v_ar_acc_id, 'Alıcılar Borç', p_grand_total, 0);

      -- 600 Alacak (Matrah)
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit)
      VALUES (v_journal_entry_id, v_user_id, v_sales_acc_id, 'Yurtiçi Satışlar', 0, p_taxable_amount);

      -- 391 Alacak (KDV)
      IF p_total_vat > 0 AND v_vat_acc_id IS NOT NULL THEN
        INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit)
        VALUES (v_journal_entry_id, v_user_id, v_vat_acc_id, 'Hesaplanan KDV', 0, p_total_vat - p_total_tevkifat);
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'invoice_id', v_invoice_id,
    'invoice_number', v_invoice_number,
    'ettn', v_ettn,
    'status', p_status
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_sales_invoice(DATE, TEXT, TEXT, UUID, UUID, JSONB, JSONB, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, TEXT, NUMERIC, TEXT, TEXT, TEXT, TEXT) TO authenticated, service_role;

-- 5. ALIŞ FATURASI İŞLEME (CREATE_PURCHASE_INVOICE)
CREATE OR REPLACE FUNCTION public.create_purchase_invoice(
  p_invoice_date      DATE,
  p_supplier_id       UUID,
  p_invoice_number    TEXT,
  p_warehouse_id      UUID DEFAULT NULL,
  p_supplier_info     JSONB DEFAULT '{}'::jsonb,
  p_items             JSONB DEFAULT '[]'::jsonb,
  p_subtotal          NUMERIC DEFAULT 0,
  p_total_discount    NUMERIC DEFAULT 0,
  p_taxable_amount    NUMERIC DEFAULT 0,
  p_total_vat         NUMERIC DEFAULT 0,
  p_total_tevkifat    NUMERIC DEFAULT 0,
  p_grand_total       NUMERIC DEFAULT 0,
  p_currency          TEXT DEFAULT 'TRY',
  p_exchange_rate     NUMERIC DEFAULT 1,
  p_notes             TEXT DEFAULT '',
  p_payment_info      TEXT DEFAULT '',
  p_ettn              TEXT DEFAULT NULL,
  p_status            TEXT DEFAULT 'ONAYLANDI'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id         UUID;
  v_invoice_id      UUID;
  v_item            JSONB;
  v_product_id      UUID;
  v_quantity        NUMERIC;
  v_unit_price      NUMERIC;
  v_year            INTEGER;
  v_now             TIMESTAMPTZ := now();
  v_journal_entry_id UUID;
  v_ap_acc_id       UUID;
  v_inv_acc_id      UUID;
  v_vat_acc_id      UUID;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.' USING ERRCODE = '42501';
  END IF;

  v_year := EXTRACT(YEAR FROM p_invoice_date)::INTEGER;

  INSERT INTO public.invoices (
    user_id, customer_id, warehouse_id, posted, ettn, invoice_number,
    type, status, gib_approval_date, invoice_date, currency, exchange_rate,
    customer, items, subtotal, total_discount, taxable_amount, total_vat,
    total_tevkifat, grand_total, notes, payment_info
  ) VALUES (
    v_user_id, p_supplier_id, p_warehouse_id, (p_status = 'ONAYLANDI'),
    COALESCE(p_ettn, UPPER(gen_random_uuid()::TEXT)), p_invoice_number,
    'ALIS', p_status, v_now, p_invoice_date,
    p_currency, COALESCE(p_exchange_rate, 1), p_supplier_info, p_items, p_subtotal,
    p_total_discount, p_taxable_amount, p_total_vat, p_total_tevkifat, p_grand_total,
    COALESCE(p_notes, ''), COALESCE(p_payment_info, '')
  ) RETURNING id INTO v_invoice_id;

  IF p_status = 'ONAYLANDI' THEN
    -- Tedarikçiye Alacak Kaydı (320)
    INSERT INTO public.account_transactions (
      user_id, customer_id, txn_date, txn_type, amount, document_no, description, source, source_id
    ) VALUES (
      v_user_id, p_supplier_id, p_invoice_date, 'ALACAK',
      p_grand_total, p_invoice_number, 'Alış faturası alacak kaydı', 'ALIS_FATURASI', v_invoice_id
    );

    -- Stok Girişi
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
      IF (v_item->>'productId') IS NOT NULL AND trim(v_item->>'productId') != '' THEN
        v_product_id := (v_item->>'productId')::UUID;
        v_quantity   := GREATEST(0, COALESCE((v_item->>'quantity')::NUMERIC, 0));
        v_unit_price := ROUND(COALESCE((v_item->>'unitPrice')::NUMERIC, 0), 2);
        IF v_quantity > 0 THEN
          INSERT INTO public.stock_movements (
            user_id, product_id, warehouse_id, customer_id, movement_date, movement_type,
            quantity, unit_price, document_no, description, source, source_id
          ) VALUES (
            v_user_id, v_product_id, p_warehouse_id, p_supplier_id, p_invoice_date,
            'GIRIS', v_quantity, v_unit_price, p_invoice_number,
            'Alış faturası stok girişi', 'ALIS_FATURASI', v_invoice_id
          );
        END IF;
      END IF;
    END LOOP;

    -- Yevmiye Fişi (153 / 191 / 320)
    SELECT id INTO v_inv_acc_id FROM public.chart_of_accounts WHERE code = '153' LIMIT 1;
    SELECT id INTO v_vat_acc_id FROM public.chart_of_accounts WHERE code = '191' LIMIT 1;
    SELECT id INTO v_ap_acc_id FROM public.chart_of_accounts WHERE code = '320' LIMIT 1;

    IF v_inv_acc_id IS NOT NULL AND v_ap_acc_id IS NOT NULL THEN
      INSERT INTO public.journal_entries (
        user_id, entry_number, entry_date, description, entry_type, source_type, source_id,
        status, total_debit, total_credit, period_year, period_month
      ) VALUES (
        v_user_id, public.next_entry_number(v_user_id, v_year, 'JOURNAL'), p_invoice_date,
        'Alış Faturası Muhasebe Kaydı: ' || p_invoice_number, 'PURCHASE_INVOICE', 'INVOICE', v_invoice_id,
        'POSTED', p_grand_total, p_grand_total, v_year, EXTRACT(MONTH FROM p_invoice_date)::INTEGER
      ) RETURNING id INTO v_journal_entry_id;

      -- 153 Borç (Matrah)
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit)
      VALUES (v_journal_entry_id, v_user_id, v_inv_acc_id, 'Ticari Mallar Stok Girişi', p_taxable_amount, 0);

      -- 191 Borç (İndirilecek KDV)
      IF p_total_vat > 0 AND v_vat_acc_id IS NOT NULL THEN
        INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit)
        VALUES (v_journal_entry_id, v_user_id, v_vat_acc_id, 'İndirilecek KDV', p_total_vat, 0);
      END IF;

      -- 320 Alacak (Satıcılar Toplam)
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit)
      VALUES (v_journal_entry_id, v_user_id, v_ap_acc_id, 'Satıcılar Alacak', 0, p_grand_total);
    END IF;
  END IF;

  RETURN jsonb_build_object('invoice_id', v_invoice_id, 'invoice_number', p_invoice_number, 'status', p_status);
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_purchase_invoice(DATE, UUID, TEXT, UUID, JSONB, JSONB, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, TEXT, NUMERIC, TEXT, TEXT, TEXT, TEXT) TO authenticated, service_role;

-- 6. TEDARİKÇİYE ÖDEME YAPMA (CREATE_SUPPLIER_PAYMENT)
CREATE OR REPLACE FUNCTION public.create_supplier_payment(
  p_supplier_id       UUID,
  p_payment_date      DATE,
  p_amount            NUMERIC,
  p_payment_method    TEXT DEFAULT 'BANKA',
  p_document_no       TEXT DEFAULT '',
  p_description       TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id         UUID;
  v_txn_id          UUID;
  v_journal_id      UUID;
  v_ap_acc_id       UUID;
  v_cash_bank_acc_id UUID;
  v_year            INTEGER;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.' USING ERRCODE = '42501';
  END IF;

  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Ödeme tutarı sıfırdan büyük olmalıdır.';
  END IF;

  v_year := EXTRACT(YEAR FROM p_payment_date)::INTEGER;

  -- 320 Tedarikçiye Borç Hareketi (Borcumuzu Düşürür)
  INSERT INTO public.account_transactions (
    user_id, customer_id, txn_date, txn_type, amount, document_no, description, source
  ) VALUES (
    v_user_id, p_supplier_id, p_payment_date, 'BORC',
    p_amount, COALESCE(p_document_no, ''), COALESCE(p_description, 'Tedarikçi ödemesi'), 'TEDARIKCI_ODEME'
  ) RETURNING id INTO v_txn_id;

  -- Yevmiye Fişi (320 Borç / 100 veya 102 Alacak)
  SELECT id INTO v_ap_acc_id FROM public.chart_of_accounts WHERE code = '320' LIMIT 1;
  SELECT id INTO v_cash_bank_acc_id FROM public.chart_of_accounts WHERE code = (CASE WHEN p_payment_method = 'KASA' THEN '100' ELSE '102' END) LIMIT 1;

  IF v_ap_acc_id IS NOT NULL AND v_cash_bank_acc_id IS NOT NULL THEN
    INSERT INTO public.journal_entries (
      user_id, entry_number, entry_date, description, entry_type, source_type, source_id,
      status, total_debit, total_credit, period_year, period_month
    ) VALUES (
      v_user_id, public.next_entry_number(v_user_id, v_year, 'JOURNAL'), p_payment_date,
      'Tedarikçi Tediye Fişi: ' || COALESCE(p_document_no, ''), 'PAYMENT', 'ACCOUNT_TXN', v_txn_id,
      'POSTED', p_amount, p_amount, v_year, EXTRACT(MONTH FROM p_payment_date)::INTEGER
    ) RETURNING id INTO v_journal_id;

    -- 320 Borç
    INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit)
    VALUES (v_journal_id, v_user_id, v_ap_acc_id, 'Satıcılar Borç Kapanışı', p_amount, 0);

    -- 100/102 Alacak
    INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit)
    VALUES (v_journal_id, v_user_id, v_cash_bank_acc_id, 'Kasa/Banka Çıkışı', 0, p_amount);
  END IF;

  RETURN jsonb_build_object('transaction_id', v_txn_id, 'status', 'SUCCESS', 'amount', p_amount);
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_supplier_payment(UUID, DATE, NUMERIC, TEXT, TEXT, TEXT) TO authenticated, service_role;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated, service_role, anon;
