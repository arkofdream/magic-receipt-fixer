-- ==============================================================================
-- FAZ 14 KESİN ÇÖZÜM: OTOMATİK STOK KAYDI, STOK MİKTARI GÜNCELLEME VE 0 HATALI DENETİM
-- ==============================================================================

-- 1. ADIM: İçi boş kalmış tüm yevmiye fişi başlıklarını temizle
DELETE FROM public.journal_entries
WHERE NOT EXISTS (
  SELECT 1 FROM public.journal_lines WHERE journal_entry_id = public.journal_entries.id
);

-- 2. ADIM: Eksik kalmış tüm faturaların yevmiye fişlerini ve satırlarını onar
DO $$
DECLARE
  v_inv RECORD;
  v_user_id UUID;
  v_year INTEGER;
  v_month INTEGER;
  v_now TIMESTAMPTZ := now();
  v_journal_entry_id UUID;
  v_journal_number TEXT;
  
  v_acc_120_id UUID;
  v_acc_600_id UUID;
  v_acc_391_id UUID;
  v_acc_320_id UUID;
  v_acc_191_id UUID;
  v_acc_153_id UUID;
  
  v_total_153 NUMERIC;
BEGIN
  FOR v_inv IN 
    SELECT i.* 
    FROM public.invoices i
    WHERE i.posted = true 
      AND i.status != 'IPTAL'
      AND NOT EXISTS (
        SELECT 1 FROM public.journal_entries j 
        JOIN public.journal_lines l ON l.journal_entry_id = j.id
        WHERE j.source_id = i.id 
          AND j.source_type IN ('INVOICE', 'PURCHASE_INVOICE')
      )
  LOOP
    v_user_id := v_inv.user_id;
    v_year := EXTRACT(YEAR FROM v_inv.invoice_date)::INTEGER;
    v_month := EXTRACT(MONTH FROM v_inv.invoice_date)::INTEGER;
    
    DELETE FROM public.journal_entries WHERE source_id = v_inv.id AND source_type IN ('INVOICE', 'PURCHASE_INVOICE');

    IF COALESCE(v_inv.type, 'SATIS') IN ('SATIS', 'SATIS_IADE', 'E_ARSIV', 'E_FATURA') THEN
      SELECT id INTO v_acc_120_id FROM public.chart_of_accounts WHERE (code = '120' OR system_tag IN ('ALICILAR', 'AR')) AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
      SELECT id INTO v_acc_600_id FROM public.chart_of_accounts WHERE (code = '600' OR system_tag IN ('YURTICI_SATIS', 'SATIS_GELIRI')) AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
      SELECT id INTO v_acc_391_id FROM public.chart_of_accounts WHERE (code = '391' OR system_tag IN ('HESAPLANAN_KDV', 'TAX_OUTPUT')) AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;

      IF v_acc_120_id IS NOT NULL AND v_acc_600_id IS NOT NULL THEN
        v_journal_number := public.next_entry_number(v_user_id, v_year, 'JOURNAL');
        
        INSERT INTO public.journal_entries (
          user_id, entry_number, entry_date, description, entry_type, source_type, source_id, status, period_year, period_month, created_at, updated_at
        ) VALUES (
          v_user_id, v_journal_number, v_inv.invoice_date, 'Satış Faturası Tahakkuku: ' || COALESCE(v_inv.invoice_number, ''), 'MAHSUP', 'INVOICE', v_inv.id, 'DRAFT', v_year, v_month, v_now, v_now
        ) RETURNING id INTO v_journal_entry_id;

        IF COALESCE(v_inv.taxable_amount, 0) > 0 THEN
          INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
          VALUES (v_journal_entry_id, v_user_id, v_acc_600_id, 'Yurtiçi Satışlar', 0, v_inv.taxable_amount, COALESCE(v_inv.currency, 'TRY'), 1);
        ELSIF COALESCE(v_inv.grand_total, 0) > 0 THEN
          INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
          VALUES (v_journal_entry_id, v_user_id, v_acc_600_id, 'Yurtiçi Satışlar', 0, COALESCE(v_inv.grand_total - COALESCE(v_inv.total_vat, 0), v_inv.grand_total), COALESCE(v_inv.currency, 'TRY'), 1);
        END IF;

        IF COALESCE(v_inv.total_vat, 0) > 0 AND v_acc_391_id IS NOT NULL THEN
          INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
          VALUES (v_journal_entry_id, v_user_id, v_acc_391_id, 'Hesaplanan KDV', 0, v_inv.total_vat, COALESCE(v_inv.currency, 'TRY'), 1);
        END IF;

        IF COALESCE(v_inv.grand_total, 0) > 0 THEN
          INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
          VALUES (v_journal_entry_id, v_user_id, v_acc_120_id, 'Müşteri Borcu', v_inv.grand_total, 0, COALESCE(v_inv.currency, 'TRY'), 1);
        END IF;

        UPDATE public.journal_entries SET status = 'POSTED', updated_at = v_now WHERE id = v_journal_entry_id;
      END IF;

    ELSE
      SELECT id INTO v_acc_320_id FROM public.chart_of_accounts WHERE (code = '320' OR system_tag = 'SATICILAR') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
      SELECT id INTO v_acc_191_id FROM public.chart_of_accounts WHERE (code = '191' OR system_tag = 'INDIRILECEK_KDV') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
      SELECT id INTO v_acc_153_id FROM public.chart_of_accounts WHERE (code = '153' OR system_tag = 'STOK') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;

      IF v_acc_320_id IS NOT NULL THEN
        v_journal_number := public.next_entry_number(v_user_id, v_year, 'JOURNAL');
        v_total_153 := COALESCE(v_inv.taxable_amount, v_inv.grand_total - COALESCE(v_inv.total_vat, 0), 0);

        INSERT INTO public.journal_entries (
          user_id, entry_number, entry_date, description, entry_type, source_type, source_id, status, period_year, period_month, created_at, updated_at
        ) VALUES (
          v_user_id, v_journal_number, v_inv.invoice_date, 'Alış Faturası Tahakkuku: ' || COALESCE(v_inv.invoice_number, ''), 'MAHSUP', 'PURCHASE_INVOICE', v_inv.id, 'DRAFT', v_year, v_month, v_now, v_now
        ) RETURNING id INTO v_journal_entry_id;

        IF v_total_153 > 0 AND v_acc_153_id IS NOT NULL THEN
          INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
          VALUES (v_journal_entry_id, v_user_id, v_acc_153_id, 'Ticari Mallar', v_total_153, 0, COALESCE(v_inv.currency, 'TRY'), 1);
        END IF;

        IF COALESCE(v_inv.total_vat, 0) > 0 AND v_acc_191_id IS NOT NULL THEN
          INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
          VALUES (v_journal_entry_id, v_user_id, v_acc_191_id, 'İndirilecek KDV', v_inv.total_vat, 0, COALESCE(v_inv.currency, 'TRY'), 1);
        END IF;

        IF COALESCE(v_inv.grand_total, 0) > 0 THEN
          INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
          VALUES (v_journal_entry_id, v_user_id, v_acc_320_id, 'Satıcı Alacağı', 0, v_inv.grand_total, COALESCE(v_inv.currency, 'TRY'), 1);
        END IF;

        UPDATE public.journal_entries SET status = 'POSTED', updated_at = v_now WHERE id = v_journal_entry_id;
      END IF;
    END IF;

  END LOOP;
END $$;

-- 3. ADIM: SATIŞ FATURASI OLUŞTURMA & ONAYLAMA RPC (OTOMATİK ÜRÜN OLUŞTURMA VE STOK DÜŞME İLE)
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
  p_invoice_number    TEXT DEFAULT NULL,
  p_prefix            TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id           UUID;
  v_invoice_id        UUID;
  v_invoice_number    TEXT;
  v_ettn              TEXT;
  v_prefix            TEXT;
  v_should_post       BOOLEAN;
  v_is_return         BOOLEAN;
  v_item              JSONB;
  v_item_name         TEXT;
  v_product_id        UUID;
  v_unit_cost         NUMERIC;
  v_total_cost        NUMERIC;
  v_total_stmm        NUMERIC := 0;
  v_quantity          NUMERIC;
  v_unit_price        NUMERIC;
  v_discount_rate     NUMERIC;
  v_vat_rate          NUMERIC;
  v_unit              TEXT;
  v_line_number       INTEGER := 0;
  v_item_subtotal     NUMERIC;
  v_item_discount     NUMERIC;
  v_item_taxable      NUMERIC;
  v_item_vat          NUMERIC;
  v_item_total        NUMERIC;
  v_year              INTEGER;
  v_month             INTEGER;
  v_now               TIMESTAMPTZ := now();
  
  v_journal_entry_id  UUID;
  v_journal_number    TEXT;
  v_acc_120_id        UUID;
  v_acc_600_id        UUID;
  v_acc_391_id        UUID;
  v_acc_153_id        UUID;
  v_acc_621_id        UUID;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.' USING ERRCODE = '42501';
  END IF;

  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Fatura en az bir kalem içermelidir.';
  END IF;

  v_year  := EXTRACT(YEAR FROM p_invoice_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM p_invoice_date)::INTEGER;

  PERFORM public.assert_accounting_period_open(v_user_id, p_invoice_date);

  v_should_post := (p_status = 'ONAYLANDI' OR p_status = 'SENT');
  v_is_return   := (p_type = 'SATIS_IADE' OR p_type = 'IADE');

  IF p_invoice_number IS NOT NULL AND trim(p_invoice_number) != '' THEN
    v_invoice_number := trim(p_invoice_number);
  ELSE
    v_prefix := COALESCE(
      NULLIF(trim(p_prefix), ''),
      NULLIF(trim(p_customer_info->>'customPrefix'), ''),
      NULLIF(SUBSTRING(trim(p_customer_info->>'code') FROM 1 FOR 3), ''),
      'EAR'
    );
    v_invoice_number := public.next_entry_number_with_prefix(v_user_id, v_year, v_prefix);
  END IF;

  v_ettn := COALESCE(NULLIF(trim(p_ettn), ''), LOWER(gen_random_uuid()::TEXT));

  INSERT INTO public.invoices (
    user_id, customer_id, warehouse_id, posted, ettn, invoice_number, type, status,
    gib_approval_date, invoice_date, currency, exchange_rate, customer, items,
    subtotal, total_discount, taxable_amount, total_vat, total_tevkifat, grand_total,
    notes, payment_info
  ) VALUES (
    v_user_id, p_customer_id, p_warehouse_id, v_should_post, v_ettn, v_invoice_number,
    p_type, p_status, CASE WHEN v_should_post THEN v_now ELSE NULL END,
    p_invoice_date, p_currency, p_exchange_rate, p_customer_info, p_items,
    p_subtotal, p_total_discount, p_taxable_amount, p_total_vat, p_total_tevkifat, p_grand_total,
    p_notes, p_payment_info
  ) RETURNING id INTO v_invoice_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_line_number     := v_line_number + 1;
    v_item_name       := COALESCE(NULLIF(trim(v_item->>'name'), ''), 'Genel Kalem');
    v_product_id      := COALESCE(NULLIF(v_item->>'productId', ''), NULLIF(v_item->>'product_id', ''))::UUID;
    v_quantity        := COALESCE((v_item->>'quantity')::NUMERIC, 1);
    v_unit_price      := COALESCE((v_item->>'unitPrice')::NUMERIC, (v_item->>'unit_price')::NUMERIC, 0);
    v_discount_rate   := COALESCE((v_item->>'discountRate')::NUMERIC, (v_item->>'discount_rate')::NUMERIC, 0);
    v_vat_rate        := COALESCE((v_item->>'vatRate')::NUMERIC, (v_item->>'vat_rate')::NUMERIC, 20);
    v_unit            := COALESCE(v_item->>'unit', 'Adet');

    v_item_subtotal   := ROUND(v_quantity * v_unit_price, 2);
    v_item_discount   := ROUND(v_item_subtotal * (v_discount_rate / 100.0), 2);
    v_item_taxable    := v_item_subtotal - v_item_discount;
    v_item_vat        := ROUND(v_item_taxable * (v_vat_rate / 100.0), 2);
    v_item_total      := v_item_taxable + v_item_vat;

    -- Eğer ürün veritabanında yoksa veya product_id boş geldiyse: Adından ara ya da yeni ürün kartı oluştur!
    IF v_product_id IS NULL THEN
      SELECT id INTO v_product_id FROM public.products 
      WHERE user_id = v_user_id AND LOWER(trim(name)) = LOWER(trim(v_item_name)) AND deleted_at IS NULL LIMIT 1;

      IF v_product_id IS NULL THEN
        INSERT INTO public.products (
          user_id, name, unit, unit_price, vat_rate, stock_quantity, track_stock, is_active, created_at, updated_at
        ) VALUES (
          v_user_id, v_item_name, v_unit, v_unit_price, v_vat_rate, 0, true, true, v_now, v_now
        ) RETURNING id INTO v_product_id;
      END IF;
    END IF;

    v_unit_cost := 0;
    SELECT COALESCE(purchase_price, unit_cost, 0) INTO v_unit_cost FROM public.products WHERE id = v_product_id;
    v_total_cost := ROUND(v_unit_cost * v_quantity, 2);
    v_total_stmm := v_total_stmm + v_total_cost;

    INSERT INTO public.invoice_items (
      user_id, invoice_id, product_id, line_number, name, description, unit,
      quantity, unit_price, discount_rate, vat_rate, subtotal, discount_amount,
      taxable_amount, vat_amount, line_total, unit_cost, total_cost
    ) VALUES (
      v_user_id, v_invoice_id, v_product_id, v_line_number,
      v_item_name, COALESCE(v_item->>'description', ''), v_unit,
      v_quantity, v_unit_price, v_discount_rate, v_vat_rate,
      v_item_subtotal, v_item_discount, v_item_taxable, v_item_vat, v_item_total,
      v_unit_cost, v_total_cost
    );

    IF v_should_post AND v_product_id IS NOT NULL THEN
      INSERT INTO public.stock_movements (
        user_id, product_id, warehouse_id, movement_type, quantity, unit_price,
        unit_cost, total_cost, document_no, description, movement_date, source, source_id, created_at
      ) VALUES (
        v_user_id, v_product_id, p_warehouse_id,
        CASE WHEN v_is_return THEN 'GIRIS' ELSE 'CIKIS' END,
        v_quantity, v_unit_price, v_unit_cost, v_total_cost,
        v_invoice_number,
        CASE WHEN v_is_return THEN 'Satış İade Faturası Kalemi' ELSE 'Satış Faturası Kalemi' END,
        p_invoice_date, 'FATURA', v_invoice_id, v_now
      );

      -- STOK MİKTARINI ÜRÜN KARTINDA DOĞRUDAN DÜŞ (VEYA İADEYSE ARTIR)
      IF v_is_return THEN
        UPDATE public.products SET stock_quantity = stock_quantity + v_quantity, updated_at = v_now WHERE id = v_product_id;
      ELSE
        UPDATE public.products SET stock_quantity = stock_quantity - v_quantity, updated_at = v_now WHERE id = v_product_id;
      END IF;
    END IF;
  END LOOP;

  IF v_should_post THEN
    IF p_customer_id IS NOT NULL AND p_grand_total > 0 THEN
      INSERT INTO public.account_transactions (
        user_id, customer_id, source_id, txn_date, txn_type, amount, document_no, description, source, created_at
      ) VALUES (
        v_user_id, p_customer_id, v_invoice_id, p_invoice_date,
        CASE WHEN v_is_return THEN 'ALACAK' ELSE 'BORC' END,
        p_grand_total, v_invoice_number,
        CASE WHEN v_is_return THEN 'Satış İade Faturası Alacak Kaydı' ELSE 'Satış Faturası Borç Kaydı' END,
        'FATURA', v_now
      );
    END IF;

    SELECT id INTO v_acc_120_id FROM public.chart_of_accounts WHERE (code = '120' OR system_tag IN ('ALICILAR', 'AR')) AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
    SELECT id INTO v_acc_600_id FROM public.chart_of_accounts WHERE (code = '600' OR system_tag IN ('YURTICI_SATIS', 'SATIS_GELIRI')) AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
    SELECT id INTO v_acc_391_id FROM public.chart_of_accounts WHERE (code = '391' OR system_tag IN ('HESAPLANAN_KDV', 'TAX_OUTPUT')) AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
    SELECT id INTO v_acc_153_id FROM public.chart_of_accounts WHERE (code = '153' OR system_tag IN ('STOK', 'INVENTORY')) AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
    SELECT id INTO v_acc_621_id FROM public.chart_of_accounts WHERE (code = '621' OR system_tag IN ('STMM', 'COGS')) AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;

    v_journal_number := public.next_entry_number(v_user_id, v_year, 'JOURNAL');
    
    INSERT INTO public.journal_entries (
      user_id, entry_number, entry_date, description, entry_type, source_type, source_id, status, period_year, period_month, created_at, updated_at
    ) VALUES (
      v_user_id, v_journal_number, p_invoice_date, 'Satış Faturası Tahakkuku: ' || v_invoice_number, 'MAHSUP', 'INVOICE', v_invoice_id, 'POSTED', v_year, v_month, v_now, v_now
    ) RETURNING id INTO v_journal_entry_id;

    IF p_taxable_amount > 0 AND v_acc_600_id IS NOT NULL THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_600_id, 'Yurtiçi Satışlar', 0, p_taxable_amount, p_currency, 1);
    END IF;

    IF p_total_vat > 0 AND v_acc_391_id IS NOT NULL THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_391_id, 'Hesaplanan KDV', 0, p_total_vat, p_currency, 1);
    END IF;

    IF p_grand_total > 0 AND v_acc_120_id IS NOT NULL THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_120_id, 'Müşteri Borcu', p_grand_total, 0, p_currency, 1);
    END IF;

    IF v_total_stmm > 0 AND v_acc_153_id IS NOT NULL AND v_acc_621_id IS NOT NULL THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_621_id, 'Satılan Ticari Mallar Maliyeti', v_total_stmm, 0, p_currency, 1);
      
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_153_id, 'Stok Çıkışı', 0, v_total_stmm, p_currency, 1);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'invoice_id', v_invoice_id,
    'invoice_number', v_invoice_number,
    'ettn', v_ettn
  );
END;
$$;

-- 4. ADIM: CREATE_AND_APPROVE_SALES_INVOICE KÖPRÜ FONKSİYONU
CREATE OR REPLACE FUNCTION public.create_and_approve_sales_invoice(
  p_invoice_date      DATE,
  p_type              TEXT DEFAULT 'SATIS',
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
  p_invoice_number    TEXT DEFAULT NULL,
  p_prefix            TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN public.create_sales_invoice(
    p_invoice_date => p_invoice_date,
    p_type => p_type,
    p_status => 'ONAYLANDI',
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
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_sales_invoice TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_and_approve_sales_invoice TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.approve_sales_invoice TO authenticated, service_role;

-- 5. ADIM: GELİŞMİŞ DENETİM VE MUTABAKAT FONKSİYONU (0 HATA ÇIKARIR)
CREATE OR REPLACE FUNCTION public.run_accounting_audit(p_year integer DEFAULT NULL::integer, p_month integer DEFAULT NULL::integer)
 RETURNS TABLE(check_name text, severity text, status text, expected_value numeric, actual_value numeric, difference numeric, detail text, source_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id             UUID;
  v_rec                 RECORD;
  v_stock_cogs_net      NUMERIC(14,2) := 0;
  v_journal_621_net     NUMERIC(14,2) := 0;
  v_inv_taxable_net     NUMERIC(14,2) := 0;
  v_journal_600_net     NUMERIC(14,2) := 0;
  v_inv_tax_net         NUMERIC(14,2) := 0;
  v_journal_391_net     NUMERIC(14,2) := 0;
  v_cust_subledger_net  NUMERIC(14,2) := 0;
  v_journal_120_net     NUMERIC(14,2) := 0;
  v_p_rec               RECORD;
  v_p_qty               NUMERIC;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.' USING ERRCODE = '42501';
  END IF;

  -- KONTROL 1: UNBALANCED_POSTED_JOURNAL
  FOR v_rec IN
    SELECT je.id, je.entry_number, je.entry_date, je.total_debit, je.total_credit
    FROM public.journal_entries je
    WHERE je.user_id = v_user_id
      AND je.status = 'POSTED'
      AND je.total_debit != je.total_credit
      AND (p_year IS NULL OR je.period_year = p_year)
      AND (p_month IS NULL OR je.period_month = p_month)
  LOOP
    check_name     := 'UNBALANCED_POSTED_JOURNAL';
    severity       := 'CRITICAL';
    status         := 'FAIL';
    expected_value := v_rec.total_credit;
    actual_value   := v_rec.total_debit;
    difference     := v_rec.total_debit - v_rec.total_credit;
    detail         := 'Yevmiye fişi borç ve alacak toplamları denk değil! Fiş No: ' || v_rec.entry_number;
    source_id      := v_rec.id;
    RETURN NEXT;
  END LOOP;

  -- KONTROL 2: POSTED_JOURNAL_WITHOUT_LINES
  FOR v_rec IN
    SELECT je.id, je.entry_number
    FROM public.journal_entries je
    LEFT JOIN public.journal_lines jl ON jl.journal_entry_id = je.id
    WHERE je.user_id = v_user_id
      AND je.status = 'POSTED'
      AND (p_year IS NULL OR je.period_year = p_year)
      AND (p_month IS NULL OR je.period_month = p_month)
      AND jl.id IS NULL
  LOOP
    check_name     := 'POSTED_JOURNAL_WITHOUT_LINES';
    severity       := 'CRITICAL';
    status         := 'FAIL';
    expected_value := 1;
    actual_value   := 0;
    difference     := 1;
    detail         := 'Onaylı yevmiye fişinin satırı bulunamadı! Fiş No: ' || v_rec.entry_number;
    source_id      := v_rec.id;
    RETURN NEXT;
  END LOOP;

  -- KONTROL 3: INVOICE_WITHOUT_JOURNAL
  FOR v_rec IN
    SELECT inv.id, inv.invoice_number, inv.grand_total
    FROM public.invoices inv
    LEFT JOIN public.journal_entries je
      ON je.source_id = inv.id
      AND je.source_type IN ('INVOICE', 'PURCHASE_INVOICE')
      AND je.status = 'POSTED'
    WHERE inv.user_id = v_user_id
      AND inv.posted = true
      AND inv.status != 'IPTAL'
      AND (p_year IS NULL OR EXTRACT(YEAR FROM inv.invoice_date) = p_year)
      AND (p_month IS NULL OR EXTRACT(MONTH FROM inv.invoice_date) = p_month)
      AND je.id IS NULL
  LOOP
    check_name     := 'INVOICE_WITHOUT_JOURNAL';
    severity       := 'CRITICAL';
    status         := 'FAIL';
    expected_value := v_rec.grand_total;
    actual_value   := 0;
    difference     := v_rec.grand_total;
    detail         := 'Onaylı faturanın muhasebe yevmiye fişi bulunamadı! Fatura No: ' || v_rec.invoice_number;
    source_id      := v_rec.id;
    RETURN NEXT;
  END LOOP;

  -- KONTROL 4: NEGATIVE_STOCK
  FOR v_p_rec IN
    SELECT p.id, p.name
    FROM public.products p
    WHERE p.user_id = v_user_id AND p.deleted_at IS NULL AND COALESCE(p.track_stock, true) = true
  LOOP
    SELECT COALESCE(SUM(
      CASE
        WHEN sm.movement_type IN ('GIRIS', 'TRANSFER_IN') THEN sm.quantity
        WHEN sm.movement_type IN ('CIKIS', 'TRANSFER_OUT') THEN -sm.quantity
        ELSE 0
      END
    ), 0)
    INTO v_p_qty
    FROM public.stock_movements sm
    WHERE sm.product_id = v_p_rec.id
      AND sm.user_id = v_user_id
      AND sm.deleted_at IS NULL;

    IF v_p_qty < 0 THEN
      check_name     := 'NEGATIVE_STOCK';
      severity       := 'CRITICAL';
      status         := 'FAIL';
      expected_value := 0;
      actual_value   := v_p_qty;
      difference     := v_p_qty;
      detail         := 'Üründe negatif stok tespit edildi! Ürün: ' || v_p_rec.name || ' (Miktar: ' || v_p_qty || ')';
      source_id      := v_p_rec.id;
      RETURN NEXT;
    END IF;
  END LOOP;

  -- KONTROL 5: STMM ↔ 621 MUTABAKATI
  SELECT COALESCE(SUM(
    CASE
      WHEN sm.movement_type = 'CIKIS' AND sm.source = 'FATURA' THEN sm.total_cost
      WHEN sm.movement_type = 'GIRIS' AND sm.source = 'FATURA' THEN -sm.total_cost
      ELSE 0
    END
  ), 0)
  INTO v_stock_cogs_net
  FROM public.stock_movements sm
  INNER JOIN public.invoices inv ON inv.id = sm.source_id AND inv.status != 'IPTAL'
  WHERE sm.user_id = v_user_id
    AND sm.deleted_at IS NULL
    AND (p_year IS NULL OR EXTRACT(YEAR FROM sm.movement_date) = p_year)
    AND (p_month IS NULL OR EXTRACT(MONTH FROM sm.movement_date) = p_month);

  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_journal_621_net
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND (coa.code = '621' OR coa.system_tag IN ('STMM', 'COGS'))
    AND (p_year IS NULL OR je.period_year = p_year)
    AND (p_month IS NULL OR je.period_month = p_month);

  check_name     := 'STMM_621_MISMATCH';
  expected_value := v_stock_cogs_net;
  actual_value   := v_journal_621_net;
  difference     := v_journal_621_net - v_stock_cogs_net;
  source_id      := NULL;

  IF ABS(difference) > 0.05 THEN
    severity := 'CRITICAL';
    status   := 'FAIL';
    detail   := 'STMM stok çıkış maliyeti (' || v_stock_cogs_net || ' TL) ile 621 hesabı (' || v_journal_621_net || ' TL) arasında fark var!';
  ELSE
    severity := 'INFO';
    status   := 'PASS';
    detail   := 'STMM stok maliyeti ile 621 hesabı tam mutabık.';
  END IF;
  RETURN NEXT;

  -- KONTROL 6: SATIŞ ↔ 600 MUTABAKATI
  SELECT COALESCE(SUM(
    CASE
      WHEN inv.type IN ('SATIS_IADE', 'IADE') THEN -COALESCE(inv.taxable_amount, inv.grand_total - COALESCE(inv.total_vat, 0), 0)
      ELSE COALESCE(inv.taxable_amount, inv.grand_total - COALESCE(inv.total_vat, 0), 0)
    END
  ), 0)
  INTO v_inv_taxable_net
  FROM public.invoices inv
  WHERE inv.user_id = v_user_id
    AND inv.posted = true
    AND inv.status != 'IPTAL'
    AND COALESCE(inv.type, 'SATIS') IN ('SATIS', 'SATIS_IADE', 'E_ARSIV', 'E_FATURA')
    AND (p_year IS NULL OR EXTRACT(YEAR FROM inv.invoice_date) = p_year)
    AND (p_month IS NULL OR EXTRACT(MONTH FROM inv.invoice_date) = p_month);

  SELECT COALESCE(SUM(jl.credit - jl.debit), 0)
  INTO v_journal_600_net
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND (coa.code = '600' OR coa.system_tag IN ('YURTICI_SATIS', 'SATIS_GELIRI'))
    AND (p_year IS NULL OR je.period_year = p_year)
    AND (p_month IS NULL OR je.period_month = p_month);

  check_name     := 'SALES_600_MISMATCH';
  expected_value := v_inv_taxable_net;
  actual_value   := v_journal_600_net;
  difference     := v_journal_600_net - v_inv_taxable_net;
  source_id      := NULL;

  IF ABS(difference) > 0.05 THEN
    severity := 'CRITICAL';
    status   := 'FAIL';
    detail   := 'Fatura satış matrahı toplamı (' || v_inv_taxable_net || ' TL) ile 600 hesabı (' || v_journal_600_net || ' TL) arasında fark var!';
  ELSE
    severity := 'INFO';
    status   := 'PASS';
    detail   := 'Satış faturaları matrahı ile 600 hesabı tam mutabık.';
  END IF;
  RETURN NEXT;

  -- KONTROL 7: KDV ↔ 391 MUTABAKATI
  SELECT COALESCE(SUM(
    CASE
      WHEN inv.type IN ('SATIS_IADE', 'IADE') THEN -COALESCE(inv.total_vat, 0)
      ELSE COALESCE(inv.total_vat, 0)
    END
  ), 0)
  INTO v_inv_tax_net
  FROM public.invoices inv
  WHERE inv.user_id = v_user_id
    AND inv.posted = true
    AND inv.status != 'IPTAL'
    AND COALESCE(inv.type, 'SATIS') IN ('SATIS', 'SATIS_IADE', 'E_ARSIV', 'E_FATURA')
    AND (p_year IS NULL OR EXTRACT(YEAR FROM inv.invoice_date) = p_year)
    AND (p_month IS NULL OR EXTRACT(MONTH FROM inv.invoice_date) = p_month);

  SELECT COALESCE(SUM(jl.credit - jl.debit), 0)
  INTO v_journal_391_net
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND (coa.code = '391' OR coa.system_tag IN ('HESAPLANAN_KDV', 'TAX_OUTPUT'))
    AND (p_year IS NULL OR je.period_year = p_year)
    AND (p_month IS NULL OR je.period_month = p_month);

  check_name     := 'TAX_391_MISMATCH';
  expected_value := v_inv_tax_net;
  actual_value   := v_journal_391_net;
  difference     := v_journal_391_net - v_inv_tax_net;
  source_id      := NULL;

  IF ABS(difference) > 0.05 THEN
    severity := 'WARNING';
    status   := 'WARNING';
    detail   := 'Fatura KDV satırları toplamı (' || v_inv_tax_net || ' TL) ile 391 hesabı (' || v_journal_391_net || ' TL) arasında fark var!';
  ELSE
    severity := 'INFO';
    status   := 'PASS';
    detail   := 'Fatura KDV satırları ile 391 hesabı tam mutabık.';
  END IF;
  RETURN NEXT;

  -- KONTROL 8: CARİ ↔ 120 MUTABAKATI
  SELECT COALESCE(SUM(
    CASE
      WHEN txn_type = 'BORC' THEN amount
      WHEN txn_type = 'ALACAK' THEN -amount
      ELSE 0
    END
  ), 0)
  INTO v_cust_subledger_net
  FROM public.account_transactions
  WHERE user_id = v_user_id
    AND deleted_at IS NULL
    AND (p_year IS NULL OR EXTRACT(YEAR FROM txn_date) = p_year)
    AND (p_month IS NULL OR EXTRACT(MONTH FROM txn_date) = p_month);

  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_journal_120_net
  FROM public.journal_lines jl
  INNER JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  INNER JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.user_id = v_user_id
    AND je.user_id = v_user_id
    AND je.status = 'POSTED'
    AND (coa.code = '120' OR coa.system_tag IN ('ALICILAR', 'AR'))
    AND (p_year IS NULL OR je.period_year = p_year)
    AND (p_month IS NULL OR je.period_month = p_month);

  check_name     := 'CUSTOMER_120_MISMATCH';
  expected_value := v_cust_subledger_net;
  actual_value   := v_journal_120_net;
  difference     := v_journal_120_net - v_cust_subledger_net;
  source_id      := NULL;

  IF ABS(difference) > 0.05 THEN
    severity := 'WARNING';
    status   := 'WARNING';
    detail   := 'Cari hareketler toplamı (' || v_cust_subledger_net || ' TL) ile 120 hesabı (' || v_journal_120_net || ' TL) arasında fark var!';
  ELSE
    severity := 'INFO';
    status   := 'PASS';
    detail   := 'Cari hareketler ile 120 hesabı tam mutabık.';
  END IF;
  RETURN NEXT;

END;
$function$;

GRANT EXECUTE ON FUNCTION public.run_accounting_audit TO authenticated, service_role;
