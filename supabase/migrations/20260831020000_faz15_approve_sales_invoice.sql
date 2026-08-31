-- ==============================================================================
-- FAZ 15: approve_sales_invoice RPC + due_date DESTEĞI
-- ==============================================================================
-- Bu migration:
-- 1. approve_sales_invoice(p_invoice_id UUID) fonksiyonunu oluşturur
--    (faturalar.tsx listesinden taslak satış faturalarını onaylama)
-- 2. Onaylama sırasında cari harekete due_date yazar (vade takip için)
-- ==============================================================================

-- 1. approve_sales_invoice — Taslak satış faturasını onaylar ve muhasebeleştirir
CREATE OR REPLACE FUNCTION public.approve_sales_invoice(p_invoice_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id           UUID;
  v_inv               RECORD;
  v_item              JSONB;
  v_item_name         TEXT;
  v_product_id        UUID;
  v_quantity          NUMERIC;
  v_unit_price        NUMERIC;
  v_discount_rate     NUMERIC;
  v_vat_rate          NUMERIC;
  v_unit              TEXT;
  v_item_subtotal     NUMERIC;
  v_item_discount     NUMERIC;
  v_item_taxable      NUMERIC;
  v_unit_cost         NUMERIC;
  v_total_cost        NUMERIC;
  v_total_stmm        NUMERIC := 0;
  v_is_return         BOOLEAN;
  v_year              INTEGER;
  v_month             INTEGER;
  v_now               TIMESTAMPTZ := now();
  v_line_number       INTEGER := 0;
  v_journal_entry_id  UUID;
  v_journal_number    TEXT;
  v_acc_120_id        UUID;
  v_acc_600_id        UUID;
  v_acc_391_id        UUID;
  v_acc_153_id        UUID;
  v_acc_621_id        UUID;
  v_product_ids       UUID[];
  v_locked_product    RECORD;
  v_due_date          DATE;
  v_payment_term_days INTEGER;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.' USING ERRCODE = '42501';
  END IF;

  -- Faturayı kilitle ve oku
  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id AND user_id = v_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fatura bulunamadı.'; END IF;

  -- Zaten onaylıysa geç
  IF v_inv.status IN ('ONAYLANDI', 'SENT') THEN
    RETURN jsonb_build_object('success', true, 'message', 'Fatura zaten onaylı.');
  END IF;
  IF v_inv.status = 'IPTAL' THEN RAISE EXCEPTION 'İptal edilmiş fatura onaylanamaz.'; END IF;

  -- Kalemsiz fatura kontrolü
  IF v_inv.items IS NULL OR jsonb_array_length(v_inv.items) = 0 THEN
    RAISE EXCEPTION 'Fatura en az bir kalem içermelidir.';
  END IF;

  PERFORM public.assert_accounting_period_open(v_user_id, v_inv.invoice_date);

  v_year := EXTRACT(YEAR FROM v_inv.invoice_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM v_inv.invoice_date)::INTEGER;
  v_is_return := (v_inv.type IN ('SATIS_IADE', 'IADE'));

  -- Vade tarihini hesapla (müşteri payment_term_days varsa kullan, yoksa +30 gün)
  v_payment_term_days := 30;
  IF v_inv.customer_id IS NOT NULL THEN
    SELECT COALESCE(c.payment_term_days, 30) INTO v_payment_term_days
    FROM public.customers c WHERE c.id = v_inv.customer_id;
  END IF;
  v_due_date := v_inv.invoice_date + v_payment_term_days;

  -- Deterministik satır kilitleme (Deadlock koruması)
  SELECT array_agg(DISTINCT pid ORDER BY pid)
  INTO v_product_ids
  FROM (
    SELECT COALESCE(
      NULLIF(trim(item->>'productId'), ''),
      NULLIF(trim(item->>'product_id'), '')
    )::UUID AS pid
    FROM jsonb_array_elements(v_inv.items) AS item
    WHERE COALESCE(NULLIF(trim(item->>'productId'), ''), NULLIF(trim(item->>'product_id'), '')) IS NOT NULL
  ) sub;

  IF v_product_ids IS NOT NULL AND array_length(v_product_ids, 1) > 0 THEN
    FOR v_locked_product IN
      SELECT id FROM public.products WHERE id = ANY(v_product_ids) AND user_id = v_user_id AND deleted_at IS NULL ORDER BY id ASC FOR UPDATE
    LOOP NULL; END LOOP;
  END IF;

  -- Fatura kalemlerini işle: stok hareketi + invoice_items + maliyet hesabı
  FOR v_item IN SELECT * FROM jsonb_array_elements(v_inv.items)
  LOOP
    v_line_number := v_line_number + 1;
    v_item_name   := COALESCE(NULLIF(trim(v_item->>'name'), ''), 'Genel Kalem');
    v_product_id  := COALESCE(NULLIF(v_item->>'productId', ''), NULLIF(v_item->>'product_id', ''))::UUID;
    v_quantity    := COALESCE((v_item->>'quantity')::NUMERIC, 1);
    v_unit_price  := COALESCE((v_item->>'unitPrice')::NUMERIC, (v_item->>'unit_price')::NUMERIC, 0);
    v_discount_rate := COALESCE((v_item->>'discountRate')::NUMERIC, (v_item->>'discount_rate')::NUMERIC, 0);
    v_vat_rate    := COALESCE((v_item->>'vatRate')::NUMERIC, (v_item->>'vat_rate')::NUMERIC, 20);
    v_unit        := COALESCE(v_item->>'unit', 'Adet');

    v_item_subtotal := ROUND(v_quantity * v_unit_price, 2);
    v_item_discount := ROUND(v_item_subtotal * (v_discount_rate / 100.0), 2);
    v_item_taxable  := v_item_subtotal - v_item_discount;

    -- Eğer ürün veritabanında yoksa veya product_id boş geldiyse: Adından ara ya da yeni ürün oluştur
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

    -- Maliyet hesapla
    v_unit_cost := 0;
    SELECT COALESCE(purchase_price, unit_cost, 0) INTO v_unit_cost FROM public.products WHERE id = v_product_id;
    v_total_cost := ROUND(v_unit_cost * v_quantity, 2);
    v_total_stmm := v_total_stmm + v_total_cost;

    -- invoice_items'a kayıt (eğer tablo kullanılıyorsa)
    INSERT INTO public.invoice_items (
      user_id, invoice_id, product_id, line_number, name, description, unit,
      quantity, unit_price, discount_rate, vat_rate, subtotal, discount_amount,
      taxable_amount, vat_amount, line_total, unit_cost, total_cost
    ) VALUES (
      v_user_id, p_invoice_id, v_product_id, v_line_number,
      v_item_name, COALESCE(v_item->>'description', ''), v_unit,
      v_quantity, v_unit_price, v_discount_rate, v_vat_rate,
      v_item_subtotal, v_item_discount, v_item_taxable,
      ROUND(v_item_taxable * (v_vat_rate / 100.0), 2),
      v_item_taxable + ROUND(v_item_taxable * (v_vat_rate / 100.0), 2),
      v_unit_cost, v_total_cost
    ) ON CONFLICT DO NOTHING;

    -- Stok hareketi oluştur
    IF v_product_id IS NOT NULL THEN
      INSERT INTO public.stock_movements (
        user_id, product_id, warehouse_id, movement_type, quantity, unit_price,
        unit_cost, total_cost, document_no, description, movement_date, source, source_id, created_at
      ) VALUES (
        v_user_id, v_product_id, v_inv.warehouse_id,
        CASE WHEN v_is_return THEN 'GIRIS' ELSE 'CIKIS' END,
        v_quantity, v_unit_price, v_unit_cost, v_total_cost,
        v_inv.invoice_number,
        CASE WHEN v_is_return THEN 'Satış İade Faturası Kalemi' ELSE 'Satış Faturası Kalemi' END,
        v_inv.invoice_date, 'FATURA', p_invoice_id, v_now
      );

      -- Stok miktarını güncelle
      IF v_is_return THEN
        UPDATE public.products SET updated_at = v_now WHERE id = v_product_id;
      ELSE
        UPDATE public.products SET updated_at = v_now WHERE id = v_product_id;
      END IF;
    END IF;
  END LOOP;

  -- Fatura durumunu güncelle
  UPDATE public.invoices
  SET status = 'ONAYLANDI', posted = true, gib_approval_date = v_now, updated_at = v_now
  WHERE id = p_invoice_id;

  -- Cari hareket kaydı (due_date ile birlikte)
  IF v_inv.customer_id IS NOT NULL AND v_inv.grand_total > 0 THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.account_transactions
      WHERE source = 'FATURA' AND source_id = p_invoice_id AND user_id = v_user_id
    ) THEN
      INSERT INTO public.account_transactions (
        user_id, customer_id, source_id, txn_date, due_date, txn_type, amount, document_no, description, source, created_at
      ) VALUES (
        v_user_id, v_inv.customer_id, p_invoice_id, v_inv.invoice_date, v_due_date,
        CASE WHEN v_is_return THEN 'ALACAK' ELSE 'BORC' END,
        v_inv.grand_total, v_inv.invoice_number,
        CASE WHEN v_is_return THEN 'Satış İade Faturası Alacak Kaydı' ELSE 'Satış Faturası Borç Kaydı' END,
        'FATURA', v_now
      );
    END IF;
  END IF;

  -- Yevmiye Fişi Oluştur (120/600/391/621/153)
  IF NOT EXISTS (SELECT 1 FROM public.journal_entries WHERE source_type = 'INVOICE' AND source_id = p_invoice_id AND status = 'POSTED') THEN
    -- Varsa önceki DRAFT fişi temizle
    DELETE FROM public.journal_entries WHERE source_type = 'INVOICE' AND source_id = p_invoice_id AND status = 'DRAFT';

    SELECT id INTO v_acc_120_id FROM public.chart_of_accounts WHERE (code = '120' OR system_tag IN ('ALICILAR', 'AR')) AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
    SELECT id INTO v_acc_600_id FROM public.chart_of_accounts WHERE (code = '600' OR system_tag IN ('YURTICI_SATIS', 'SATIS_GELIRI')) AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
    SELECT id INTO v_acc_391_id FROM public.chart_of_accounts WHERE (code = '391' OR system_tag IN ('HESAPLANAN_KDV', 'TAX_OUTPUT')) AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
    SELECT id INTO v_acc_153_id FROM public.chart_of_accounts WHERE (code = '153' OR system_tag IN ('STOK', 'INVENTORY')) AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;
    SELECT id INTO v_acc_621_id FROM public.chart_of_accounts WHERE (code = '621' OR system_tag IN ('STMM', 'COGS')) AND (user_id = v_user_id OR user_id IS NULL) AND is_active = true ORDER BY user_id NULLS LAST LIMIT 1;

    v_journal_number := public.next_entry_number(v_user_id, v_year, 'JOURNAL');

    INSERT INTO public.journal_entries (
      user_id, entry_number, entry_date, description, entry_type, source_type, source_id, status, period_year, period_month, created_at, updated_at
    ) VALUES (
      v_user_id, v_journal_number, v_inv.invoice_date, 'Satış Faturası Tahakkuku: ' || v_inv.invoice_number, 'MAHSUP', 'INVOICE', p_invoice_id, 'DRAFT', v_year, v_month, v_now, v_now
    ) RETURNING id INTO v_journal_entry_id;

    -- 600 Yurtiçi Satışlar (Alacak)
    IF COALESCE(v_inv.taxable_amount, 0) > 0 AND v_acc_600_id IS NOT NULL THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_600_id, 'Yurtiçi Satışlar', 0, v_inv.taxable_amount, COALESCE(v_inv.currency, 'TRY'), 1);
    END IF;

    -- 391 Hesaplanan KDV (Alacak)
    IF COALESCE(v_inv.total_vat, 0) > 0 AND v_acc_391_id IS NOT NULL THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_391_id, 'Hesaplanan KDV', 0, v_inv.total_vat, COALESCE(v_inv.currency, 'TRY'), 1);
    END IF;

    -- 120 Alıcılar (Borç)
    IF COALESCE(v_inv.grand_total, 0) > 0 AND v_acc_120_id IS NOT NULL THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_120_id, 'Müşteri Borcu', v_inv.grand_total, 0, COALESCE(v_inv.currency, 'TRY'), 1);
    END IF;

    -- 621 STMM (Borç) + 153 Stok Çıkışı (Alacak)
    IF v_total_stmm > 0 AND v_acc_153_id IS NOT NULL AND v_acc_621_id IS NOT NULL THEN
      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_621_id, 'Satılan Ticari Mallar Maliyeti', v_total_stmm, 0, COALESCE(v_inv.currency, 'TRY'), 1);

      INSERT INTO public.journal_lines (journal_entry_id, user_id, account_id, description, debit, credit, currency, exchange_rate)
      VALUES (v_journal_entry_id, v_user_id, v_acc_153_id, 'Stok Çıkışı', 0, v_total_stmm, COALESCE(v_inv.currency, 'TRY'), 1);
    END IF;

    UPDATE public.journal_entries SET status = 'POSTED', updated_at = v_now WHERE id = v_journal_entry_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'invoice_id', p_invoice_id, 'message', 'Satış faturası başarıyla onaylandı ve muhasebeleşti.');
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_sales_invoice TO authenticated, service_role;

-- 2. create_sales_invoice'a due_date desteği eklenmesi
-- Mevcut create_sales_invoice RPC'deki account_transactions INSERT'ine due_date eklenir
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
  v_due_date          DATE;
  v_payment_term_days INTEGER;
  
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

  -- Vade tarihini hesapla
  v_payment_term_days := 30;
  IF p_customer_id IS NOT NULL THEN
    SELECT COALESCE(c.payment_term_days, 30) INTO v_payment_term_days
    FROM public.customers c WHERE c.id = p_customer_id;
  END IF;
  v_due_date := p_invoice_date + v_payment_term_days;

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

      IF v_is_return THEN
        UPDATE public.products SET updated_at = v_now WHERE id = v_product_id;
      ELSE
        UPDATE public.products SET updated_at = v_now WHERE id = v_product_id;
      END IF;
    END IF;
  END LOOP;

  IF v_should_post THEN
    -- Cari hareket kaydı (due_date ile)
    IF p_customer_id IS NOT NULL AND p_grand_total > 0 THEN
      INSERT INTO public.account_transactions (
        user_id, customer_id, source_id, txn_date, due_date, txn_type, amount, document_no, description, source, created_at
      ) VALUES (
        v_user_id, p_customer_id, v_invoice_id, p_invoice_date, v_due_date,
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

-- Köprü fonksiyonu güncelle
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
