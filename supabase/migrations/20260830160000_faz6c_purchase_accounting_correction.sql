-- ==============================================================================
-- FAZ 6C: PURCHASE ACCOUNTING CORRECTION & REVERSAL
-- ==============================================================================
-- Bu migration, Faz 5 (Alış Faturası) tarafındaki kritik muhasebe hatalarını düzeltir:
-- 1. Ürün vs Hizmet ayrımı (153 vs 770) track_stock üzerinden yapılır.
-- 2. cancel_purchase_invoice (İptal ve ters kayıt) fonksiyonu eklenir.
-- 3. Frontend RPC contract uyumsuzlukları giderilir.
-- ==============================================================================

BEGIN;

-- ------------------------------------------------------------------------------
-- 1. create_purchase_invoice
-- ------------------------------------------------------------------------------
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
  p_status            TEXT DEFAULT 'TASLAK'
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
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Yetkilendirme hatası.' USING ERRCODE = '42501'; END IF;

  v_invoice_number := trim(p_invoice_number);
  v_ettn := COALESCE(NULLIF(trim(p_ettn), ''), UPPER(gen_random_uuid()::TEXT));

  PERFORM public.assert_accounting_period_open(v_user_id, p_invoice_date);

  IF EXISTS (
    SELECT 1 FROM public.invoices
    WHERE user_id = v_user_id AND customer_id = p_supplier_id AND invoice_number = v_invoice_number AND type IN ('ALIS', 'GELEN_FATURA', 'GELEN_E_ARSIV') AND status != 'IPTAL'
  ) THEN
    RAISE EXCEPTION 'Bu tedarikçiye ait bu fatura numarası ile kayıtlı bir alış faturası zaten mevcuttur.';
  END IF;

  INSERT INTO public.invoices (
    user_id, customer_id, warehouse_id, posted, ettn, invoice_number, type, status,
    invoice_date, currency, exchange_rate, customer, items,
    subtotal, total_discount, taxable_amount, total_vat, total_tevkifat, grand_total,
    notes, payment_info
  ) VALUES (
    v_user_id, p_supplier_id, p_warehouse_id, false, v_ettn, v_invoice_number,
    'ALIS', p_status,
    p_invoice_date, p_currency, COALESCE(p_exchange_rate, 1), p_supplier_info, p_items,
    p_subtotal, p_total_discount, p_taxable_amount, p_total_vat, COALESCE(p_total_tevkifat, 0),
    p_grand_total, COALESCE(p_notes, ''), COALESCE(p_payment_info, '')
  ) RETURNING id INTO v_invoice_id;

  RETURN jsonb_build_object('success', true, 'invoice_id', v_invoice_id, 'invoice_number', v_invoice_number, 'ettn', v_ettn);
END;
$$;

-- ------------------------------------------------------------------------------
-- 2. update_purchase_invoice
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_purchase_invoice(
  p_invoice_id        UUID,
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
  p_status            TEXT DEFAULT 'TASLAK'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
  v_inv RECORD;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Yetkilendirme hatası.' USING ERRCODE = '42501'; END IF;

  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id AND user_id = v_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fatura bulunamadı.'; END IF;

  IF v_inv.status IN ('ONAYLANDI', 'SENT', 'IPTAL') THEN
    RAISE EXCEPTION 'Sadece taslak faturalar güncellenebilir.';
  END IF;

  PERFORM public.assert_accounting_period_open(v_user_id, p_invoice_date);

  UPDATE public.invoices SET
    invoice_date = p_invoice_date,
    customer_id = p_supplier_id,
    invoice_number = trim(p_invoice_number),
    warehouse_id = p_warehouse_id,
    customer = p_supplier_info,
    items = p_items,
    subtotal = p_subtotal,
    total_discount = p_total_discount,
    taxable_amount = p_taxable_amount,
    total_vat = p_total_vat,
    total_tevkifat = COALESCE(p_total_tevkifat, 0),
    grand_total = p_grand_total,
    currency = p_currency,
    exchange_rate = COALESCE(p_exchange_rate, 1),
    notes = COALESCE(p_notes, ''),
    payment_info = COALESCE(p_payment_info, ''),
    status = p_status,
    updated_at = now()
  WHERE id = p_invoice_id;

  RETURN jsonb_build_object('success', true, 'invoice_id', p_invoice_id);
END;
$$;

-- ------------------------------------------------------------------------------
-- 3. approve_purchase_invoice
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.approve_purchase_invoice(p_invoice_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id           UUID;
  v_inv               RECORD;
  v_item              JSONB;
  v_product_id        UUID;
  v_quantity          NUMERIC;
  v_unit_price        NUMERIC;
  v_discount_rate     NUMERIC;
  v_item_subtotal     NUMERIC;
  v_item_discount     NUMERIC;
  v_item_taxable      NUMERIC;
  v_is_product        BOOLEAN;
  v_total_153         NUMERIC := 0;
  v_total_770         NUMERIC := 0;
  v_year              INTEGER;
  v_month             INTEGER;
  v_now               TIMESTAMPTZ := now();
  v_journal_entry_id  UUID;
  v_journal_number    TEXT;
  v_acc_153_id        UUID;
  v_acc_770_id        UUID;
  v_acc_191_id        UUID;
  v_acc_320_id        UUID;
  v_product_ids       UUID[];
  v_locked_product    RECORD;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Yetkilendirme hatası.'; END IF;

  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id AND user_id = v_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fatura bulunamadı.'; END IF;

  IF v_inv.status IN ('ONAYLANDI', 'SENT') THEN
    RETURN jsonb_build_object('success', true, 'message', 'Fatura zaten onaylı.');
  END IF;
  IF v_inv.status = 'IPTAL' THEN RAISE EXCEPTION 'İptal edilmiş fatura onaylanamaz.'; END IF;

  PERFORM public.assert_accounting_period_open(v_user_id, v_inv.invoice_date);

  v_year := EXTRACT(YEAR FROM v_inv.invoice_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM v_inv.invoice_date)::INTEGER;

  -- Deterministik satır kilitleme (Deadlock koruması)
  SELECT array_agg(DISTINCT (item->>'productId')::UUID ORDER BY (item->>'productId')::UUID)
  INTO v_product_ids
  FROM jsonb_array_elements(v_inv.items) AS item
  WHERE (item->>'productId') IS NOT NULL AND trim(item->>'productId') != '';

  IF v_product_ids IS NOT NULL AND array_length(v_product_ids, 1) > 0 THEN
    FOR v_locked_product IN
      SELECT id FROM public.products WHERE id = ANY(v_product_ids) AND user_id = v_user_id AND deleted_at IS NULL ORDER BY id ASC FOR UPDATE
    LOOP NULL; END LOOP;
  END IF;

  -- Fatura kalemlerini dön (153 vs 770 hesabı) ve Stok hareketi oluştur
  FOR v_item IN SELECT * FROM jsonb_array_elements(v_inv.items)
  LOOP
    v_product_id := NULLIF(trim(v_item->>'productId'), '')::UUID;
    v_quantity := GREATEST(0, COALESCE((v_item->>'quantity')::NUMERIC, 0));
    v_unit_price := ROUND(COALESCE((v_item->>'unitPrice')::NUMERIC, 0), 2);
    v_discount_rate := COALESCE((v_item->>'discountRate')::NUMERIC, 0);
    
    v_item_subtotal := v_quantity * v_unit_price;
    v_item_discount := ROUND(v_item_subtotal * (v_discount_rate / 100.0), 2);
    v_item_taxable := v_item_subtotal - v_item_discount;

    v_is_product := false;
    IF v_product_id IS NOT NULL THEN
      SELECT COALESCE(track_stock, true) INTO v_is_product FROM public.products WHERE id = v_product_id;
    END IF;

    IF v_is_product THEN
      v_total_153 := v_total_153 + v_item_taxable;
      IF v_quantity > 0 THEN
        INSERT INTO public.stock_movements (
          user_id, product_id, warehouse_id, movement_type, quantity, unit_price, unit_cost, total_cost, movement_date, document_no, description, source, source_id, created_at
        ) VALUES (
          v_user_id, v_product_id, v_inv.warehouse_id, 'GIRIS', v_quantity, v_unit_price, v_unit_price, v_item_taxable, v_inv.invoice_date, v_inv.invoice_number, 'Alış Faturası Stok Girişi', 'ALIS_FATURASI', p_invoice_id, v_now
        );
        -- Satışta maliyetin doğru hesaplanması için unit_cost da güncellenmeli. (Ortalama maliyeti tetikler).
        UPDATE public.products SET stock_quantity = stock_quantity + v_quantity, unit_cost = v_unit_price, updated_at = v_now WHERE id = v_product_id;
      END IF;
    ELSE
      v_total_770 := v_total_770 + v_item_taxable;
    END IF;
  END LOOP;

  -- Hesap Planı Sorgusu
  SELECT id INTO v_acc_320_id FROM public.chart_of_accounts WHERE (code = '320' OR system_tag = 'AP') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
  SELECT id INTO v_acc_191_id FROM public.chart_of_accounts WHERE (code = '191' OR system_tag = 'VAT_IN') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
  
  IF v_total_153 > 0 THEN
    SELECT id INTO v_acc_153_id FROM public.chart_of_accounts WHERE (code = '153' OR system_tag = 'INVENTORY') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
    IF v_acc_153_id IS NULL THEN RAISE EXCEPTION 'Ticari Mallar (153) hesabı bulunamadı.'; END IF;
  END IF;
  
  IF v_total_770 > 0 THEN
    SELECT id INTO v_acc_770_id FROM public.chart_of_accounts WHERE (code = '770' OR system_tag = 'GENERAL_EXPENSE') AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
    IF v_acc_770_id IS NULL THEN RAISE EXCEPTION 'Genel Yönetim Giderleri (770) hesabı bulunamadı.'; END IF;
  END IF;
  
  IF v_acc_320_id IS NULL OR v_acc_191_id IS NULL THEN RAISE EXCEPTION 'Satıcılar (320) veya İndirilecek KDV (191) hesabı bulunamadı.'; END IF;

  UPDATE public.invoices SET status = 'ONAYLANDI', posted = true, updated_at = v_now WHERE id = p_invoice_id;

  IF v_inv.customer_id IS NOT NULL AND v_inv.grand_total > 0 THEN
    INSERT INTO public.account_transactions (
      user_id, customer_id, source_id, txn_date, txn_type, amount, document_no, description, source, period_year, period_month, created_at
    ) VALUES (
      v_user_id, v_inv.customer_id, p_invoice_id, v_inv.invoice_date, 'ALACAK', v_inv.grand_total, v_inv.invoice_number, 'Alış Faturası Alacak Kaydı', 'ALIS_FATURASI', v_year, v_month, v_now
    ) ON CONFLICT (source, source_id) DO NOTHING;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.journal_entries WHERE source_type = 'PURCHASE_INVOICE' AND source_id = p_invoice_id) THEN
    v_journal_number := public.next_entry_number(v_user_id, v_year, 'JOURNAL');
    
    INSERT INTO public.journal_entries (
      user_id, entry_number, entry_date, description, entry_type, source_type, source_id, status, period_year, period_month, created_at, updated_at
    ) VALUES (
      v_user_id, v_journal_number, v_inv.invoice_date, 'Alış Faturası Tahakkuku: ' || v_inv.invoice_number, 'MAHSUP', 'PURCHASE_INVOICE', p_invoice_id, 'DRAFT', v_year, v_month, v_now, v_now
    ) RETURNING id INTO v_journal_entry_id;

    IF v_total_153 > 0 THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_153_id, 'Ticari Mallar', v_total_153, 0, COALESCE(v_inv.currency, 'TRY'), 1);
    END IF;

    IF v_total_770 > 0 THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_770_id, 'Hizmet / Gider Girişi', v_total_770, 0, COALESCE(v_inv.currency, 'TRY'), 1);
    END IF;

    IF v_inv.total_vat > 0 THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_191_id, 'İndirilecek KDV', v_inv.total_vat, 0, COALESCE(v_inv.currency, 'TRY'), 1);
    END IF;

    IF v_inv.grand_total > 0 THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_320_id, 'Satıcılar Alacak', 0, v_inv.grand_total, COALESCE(v_inv.currency, 'TRY'), 1);
    END IF;
    
    UPDATE public.journal_entries SET status = 'POSTED', updated_at = v_now WHERE id = v_journal_entry_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'invoice_id', p_invoice_id, 'message', 'Alış faturası başarıyla onaylandı.');
END;
$$;

-- ------------------------------------------------------------------------------
-- 4. create_and_approve_purchase_invoice
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_and_approve_purchase_invoice(
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
  p_ettn              TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_res JSONB;
BEGIN
  v_res := public.create_purchase_invoice(p_invoice_date, p_supplier_id, p_invoice_number, p_warehouse_id, p_supplier_info, p_items, p_subtotal, p_total_discount, p_taxable_amount, p_total_vat, p_total_tevkifat, p_grand_total, p_currency, p_exchange_rate, p_notes, p_payment_info, p_ettn, 'TASLAK');
  RETURN public.approve_purchase_invoice((v_res->>'invoice_id')::UUID);
END;
$$;

-- ------------------------------------------------------------------------------
-- 5. update_and_approve_purchase_invoice
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_and_approve_purchase_invoice(
  p_invoice_id        UUID,
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
  p_payment_info      TEXT DEFAULT ''
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.update_purchase_invoice(p_invoice_id, p_invoice_date, p_supplier_id, p_invoice_number, p_warehouse_id, p_supplier_info, p_items, p_subtotal, p_total_discount, p_taxable_amount, p_total_vat, p_total_tevkifat, p_grand_total, p_currency, p_exchange_rate, p_notes, p_payment_info, 'TASLAK');
  RETURN public.approve_purchase_invoice(p_invoice_id);
END;
$$;

-- ------------------------------------------------------------------------------
-- 6. cancel_purchase_invoice (REVERSAL ENGINE)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_purchase_invoice(
  p_invoice_id UUID,
  p_cancel_reason TEXT DEFAULT 'Kullanıcı tarafından iptal edildi'
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id           UUID;
  v_inv               RECORD;
  v_journal_id        UUID;
  v_new_journal_id    UUID;
  v_journal_number    TEXT;
  v_sm                RECORD;
  v_now               TIMESTAMPTZ := now();
  v_year              INTEGER;
  v_month             INTEGER;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Yetkilendirme hatası.'; END IF;

  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id AND user_id = v_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fatura bulunamadı.'; END IF;

  IF v_inv.status = 'IPTAL' THEN
    RETURN jsonb_build_object('success', true, 'message', 'Fatura zaten iptal edilmiş.');
  END IF;

  PERFORM public.assert_accounting_period_open(v_user_id, v_inv.invoice_date);

  v_year := EXTRACT(YEAR FROM v_inv.invoice_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM v_inv.invoice_date)::INTEGER;

  -- 1. Fatura durumunu güncelle
  UPDATE public.invoices SET status = 'IPTAL', notes = COALESCE(notes, '') || ' [İPTAL: ' || p_cancel_reason || ']', updated_at = v_now WHERE id = p_invoice_id;

  -- 2. Cari ters kayıt (320 Borçlandır)
  IF v_inv.customer_id IS NOT NULL AND v_inv.grand_total > 0 THEN
    INSERT INTO public.account_transactions (
      user_id, customer_id, source_id, txn_date, txn_type, amount, document_no, description, source, period_year, period_month, created_at
    ) VALUES (
      v_user_id, v_inv.customer_id, p_invoice_id, v_inv.invoice_date, 'BORC', v_inv.grand_total, v_inv.invoice_number, 'Alış Faturası İptal (Ters Kayıt)', 'ALIS_FATURASI_IPTAL', v_year, v_month, v_now
    );
  END IF;

  -- 3. Stok Ters Kayıt (CIKIS)
  FOR v_sm IN SELECT * FROM public.stock_movements WHERE source_id = p_invoice_id AND source = 'ALIS_FATURASI' AND movement_type = 'GIRIS'
  LOOP
    INSERT INTO public.stock_movements (
      user_id, product_id, warehouse_id, movement_type, quantity, unit_price, unit_cost, total_cost, movement_date, document_no, description, source, source_id, created_at
    ) VALUES (
      v_user_id, v_sm.product_id, v_sm.warehouse_id, 'CIKIS', v_sm.quantity, v_sm.unit_price, v_sm.unit_cost, v_sm.total_cost, v_inv.invoice_date, v_inv.invoice_number, 'Alış Faturası İptali (Stok Çıkışı)', 'ALIS_FATURASI_IPTAL', p_invoice_id, v_now
    );
    -- Stoğu geri düş
    UPDATE public.products SET stock_quantity = stock_quantity - v_sm.quantity, updated_at = v_now WHERE id = v_sm.product_id;
  END LOOP;

  -- 4. Yevmiye Ters Kayıt (Reversal Journal)
  SELECT id INTO v_journal_id FROM public.journal_entries WHERE source_type = 'PURCHASE_INVOICE' AND source_id = p_invoice_id LIMIT 1;
  IF v_journal_id IS NOT NULL THEN
    -- Ters yevmiye oluştur
    v_journal_number := public.next_entry_number(v_user_id, v_year, 'JOURNAL');
    INSERT INTO public.journal_entries (
      user_id, entry_number, entry_date, description, entry_type, source_type, source_id, status, period_year, period_month, created_at, updated_at
    ) VALUES (
      v_user_id, v_journal_number, v_inv.invoice_date, 'İptal Yevmiyesi: ' || v_inv.invoice_number, 'MAHSUP', 'PURCHASE_INVOICE_CANCEL', p_invoice_id, 'DRAFT', v_year, v_month, v_now, v_now
    ) RETURNING id INTO v_new_journal_id;

    -- Eski yevmiye satırlarını ters çevirerek (Borç <-> Alacak) kopyala
    INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
    SELECT v_new_journal_id, user_id, account_id, description || ' (İptal)', credit, debit, currency, exchange_rate
    FROM public.journal_lines
    WHERE journal_entry_id = v_journal_id;
    
    UPDATE public.journal_entries SET status = 'POSTED', updated_at = v_now WHERE id = v_new_journal_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'invoice_id', p_invoice_id, 'message', 'Fatura ve finansal kayıtlar başarıyla iptal edildi.');
END;
$$;

COMMIT;
