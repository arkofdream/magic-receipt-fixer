-- =============================================================
-- FAZ 1B.4 — ATOMİK FATURA İPTALİ VE REVERSAL (TERS KAYIT) RPC
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-22
-- =============================================================
-- BU MİGRATION:
--   ✅ cancel_sales_invoice RPC fonksiyonunu oluşturur
--   ✅ Orijinal cari ve stok kayıtlarını silmeden/soft-delete etmeden korur
--   ✅ İptal anında ters yönde dengeleyici (reversal) cari ve stok kayıtları oluşturur
--   ✅ SELECT ... FOR UPDATE ile aynı faturaya eşzamanlı çift iptali engeller
--   ✅ auth.uid() doğrulaması ile tam kullanıcı izolasyonu sağlar
--   ✅ Herhangi bir adım başarısız olursa TÜM işlemi ROLLBACK eder
-- =============================================================

CREATE OR REPLACE FUNCTION public.cancel_sales_invoice(
  p_invoice_id    UUID,
  p_cancel_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id         UUID;
  v_invoice         RECORD;
  v_is_return       BOOLEAN;
  v_item            JSONB;
  v_product_id      UUID;
  v_quantity        NUMERIC;
  v_unit_price      NUMERIC;
  v_now             TIMESTAMPTZ := now();
  v_cancel_date_str TEXT;
  v_journal         RECORD;
  v_reversal_je_id  UUID;
  v_line            RECORD;
BEGIN
  -- 1. Yetkilendirme Kontrolü
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Yetkilendirme hatası: Oturum açmış kullanıcı bulunamadı.'
      USING ERRCODE = '42501';
  END IF;

  IF p_invoice_id IS NULL THEN
    RAISE EXCEPTION 'Fatura ID zorunludur.';
  END IF;

  -- 2. Faturayı Satır Kilitlemeli Olarak Oku (Concurrency / Çift İptal Koruması)
  SELECT *
  INTO v_invoice
  FROM public.invoices
  WHERE id = p_invoice_id AND user_id = v_user_id AND deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fatura bulunamadı veya bu işlem için yetkiniz yok. Fatura ID: %', p_invoice_id;
  END IF;

  -- 3. Durum Kontrolü
  IF v_invoice.status = 'IPTAL' THEN
    RAISE EXCEPTION 'Bu fatura zaten iptal edilmiştir. Fatura No: %', v_invoice.invoice_number;
  END IF;

  v_is_return := (v_invoice.type = 'IADE');
  v_cancel_date_str := to_char(v_now, 'YYYY-MM-DD');

  -- 4. Fatura Başlığını İptal Durumuna Güncelle (Orijinal Kayıt Korunur)
  UPDATE public.invoices
  SET
    status = 'IPTAL',
    cancel_date = v_now,
    notes = CASE
      WHEN p_cancel_reason IS NOT NULL AND trim(p_cancel_reason) != '' THEN
        CASE
          WHEN notes IS NULL OR trim(notes) = '' THEN 'İptal Nedeni: ' || trim(p_cancel_reason)
          ELSE notes || ' | İptal Nedeni: ' || trim(p_cancel_reason)
        END
      ELSE notes
    END,
    updated_at = v_now
  WHERE id = p_invoice_id;

  -- 5. Onaylı (POSTED) Fatura ise Muhasebesel Ters Kayıtları Oluştur
  IF v_invoice.posted = true THEN

    -- A) Cari Reversal (Ters Cari Kaydı: SATIS ise ALACAK, IADE ise BORC)
    IF v_invoice.customer_id IS NOT NULL AND v_invoice.grand_total > 0 THEN
      INSERT INTO public.account_transactions (
        user_id,
        customer_id,
        txn_date,
        txn_type,
        amount,
        document_no,
        description,
        source,
        source_id
      ) VALUES (
        v_user_id,
        v_invoice.customer_id,
        v_now::date,
        CASE WHEN v_is_return THEN 'BORC' ELSE 'ALACAK' END,
        v_invoice.grand_total,
        v_invoice.invoice_number,
        CASE
          WHEN v_is_return THEN 'İade Faturası İptali (Borç Düzeltme) - ' || v_invoice.invoice_number
          ELSE 'Satış Faturası İptali (Alacak Düzeltme) - ' || v_invoice.invoice_number
        END,
        'FATURA_IPTAL',
        p_invoice_id
      );
    END IF;

    -- B) Stok Reversal (Ters Stok Kaydı: SATIS ise GIRIS, IADE ise CIKIS)
    IF v_invoice.items IS NOT NULL AND jsonb_typeof(v_invoice.items) = 'array' THEN
      FOR v_item IN SELECT * FROM jsonb_array_elements(v_invoice.items)
      LOOP
        IF (v_item->>'productId') IS NOT NULL AND trim(v_item->>'productId') != '' THEN
          v_product_id := (v_item->>'productId')::UUID;
          v_quantity   := GREATEST(0, COALESCE((v_item->>'quantity')::NUMERIC, 0));
          v_unit_price := ROUND(COALESCE((v_item->>'unitPrice')::NUMERIC, 0), 2);

          IF v_quantity > 0 THEN
            INSERT INTO public.stock_movements (
              user_id,
              product_id,
              warehouse_id,
              customer_id,
              movement_date,
              movement_type,
              quantity,
              unit_price,
              document_no,
              description,
              source,
              source_id
            ) VALUES (
              v_user_id,
              v_product_id,
              v_invoice.warehouse_id,
              v_invoice.customer_id,
              v_now::date,
              CASE WHEN v_is_return THEN 'CIKIS' ELSE 'GIRIS' END,
              v_quantity,
              v_unit_price,
              v_invoice.invoice_number,
              CASE
                WHEN v_is_return THEN 'İade Faturası İptali (Stok Çıkışı) - ' || v_invoice.invoice_number
                ELSE 'Satış Faturası İptali (Stok Girişi) - ' || v_invoice.invoice_number
              END,
              'FATURA_IPTAL',
              p_invoice_id
            );
          END IF;
        END IF;
      END LOOP;
    END IF;

    -- C) Varsa KDV Reversal (invoice_tax_lines)
    IF EXISTS (
      SELECT 1 FROM public.invoice_tax_lines
      WHERE invoice_id = p_invoice_id AND is_reversal = false
    ) THEN
      INSERT INTO public.invoice_tax_lines (
        invoice_id,
        user_id,
        direction,
        vat_rate,
        taxable_amount,
        tax_amount,
        withholding_rate,
        withholding_amount,
        is_exempt,
        exemption_code,
        is_cancelled,
        is_reversal,
        reversal_of,
        currency,
        exchange_rate,
        taxable_amount_try,
        tax_amount_try,
        period_year,
        period_month
      )
      SELECT
        invoice_id,
        user_id,
        direction,
        vat_rate,
        taxable_amount,
        tax_amount,
        withholding_rate,
        withholding_amount,
        is_exempt,
        exemption_code,
        true,
        true,
        id,
        currency,
        exchange_rate,
        taxable_amount_try,
        tax_amount_try,
        EXTRACT(YEAR FROM v_now)::INTEGER,
        EXTRACT(MONTH FROM v_now)::INTEGER
      FROM public.invoice_tax_lines
      WHERE invoice_id = p_invoice_id AND is_reversal = false;
    END IF;

    -- D) Varsa Yevmiye Fişi Reversal (journal_entries)
    SELECT * INTO v_journal
    FROM public.journal_entries
    WHERE source_type = 'INVOICE' AND source_id = p_invoice_id AND status = 'POSTED'
    LIMIT 1;

    IF FOUND THEN
      -- Yeni Ters Yevmiye Fişi Başlığı
      INSERT INTO public.journal_entries (
        user_id,
        entry_number,
        entry_date,
        description,
        entry_type,
        source_type,
        source_id,
        status,
        period_year,
        period_month
      ) VALUES (
        v_user_id,
        public.next_entry_number(v_user_id, EXTRACT(YEAR FROM v_now)::INTEGER, 'JOURNAL'),
        v_now::date,
        'Fatura İptal Yevmiye Fişi - ' || v_invoice.invoice_number,
        'MAHSUP',
        'INVOICE_CANCEL',
        p_invoice_id,
        'DRAFT',
        EXTRACT(YEAR FROM v_now)::INTEGER,
        EXTRACT(MONTH FROM v_now)::INTEGER
      )
      RETURNING id INTO v_reversal_je_id;

      -- Orijinal Fiş Satırlarını Ters Yönle (Borç ➔ Alacak, Alacak ➔ Borç) Ekle
      FOR v_line IN
        SELECT * FROM public.journal_lines WHERE journal_entry_id = v_journal.id
      LOOP
        INSERT INTO public.journal_lines (
          journal_entry_id,
          user_id,
          account_id,
          description,
          debit,
          credit,
          currency,
          foreign_amount,
          exchange_rate
        ) VALUES (
          v_reversal_je_id,
          v_user_id,
          v_line.account_id,
          'İptal Ters Kaydı: ' || COALESCE(v_line.description, ''),
          v_line.credit, -- Orijinal alacak burada borç olur
          v_line.debit,  -- Orijinal borç burada alacak olur
          v_line.currency,
          v_line.foreign_amount,
          v_line.exchange_rate
        );
      END LOOP;

      -- Fişi Onaylı (POSTED) Durumuna Getir (Trigger toplamları otomatik hesaplar)
      UPDATE public.journal_entries
      SET status = 'POSTED'
      WHERE id = v_reversal_je_id;
    END IF;

  END IF;

  -- 6. Yanıt Dönüşü
  RETURN jsonb_build_object(
    'success', true,
    'id', p_invoice_id,
    'invoice_number', v_invoice.invoice_number,
    'status', 'IPTAL',
    'cancel_date', v_now
  );
END;
$$;

-- Yetkilendirme
REVOKE ALL ON FUNCTION public.cancel_sales_invoice FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_sales_invoice TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_sales_invoice TO service_role;
