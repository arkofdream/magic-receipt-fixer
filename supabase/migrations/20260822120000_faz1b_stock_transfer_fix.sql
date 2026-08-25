-- =============================================================
-- FAZ 1B.1 — STOK TRANSFER MUHASEBESEL VE VERİTABANI DÜZELTMESİ
-- Magic Receipt Ön Muhasebe Sistemi
-- Tarih: 2026-08-22
-- =============================================================
-- BU MİGRATION:
--   ✅ stock_movements tablosuna TRANSFER_OUT ve TRANSFER_IN tiplerini ekler
--   ✅ Eski 'TRANSFER', 'GIRIS', 'CIKIS', 'SAYIM' tipleriyle tam geriye dönük uyumludur
--   ✅ transfer_group_id UUID kolonu ekleyerek çift taraflı transferleri birbirine bağlar
--   ✅ product_stocks view'ını güncelleyerek TRANSFER_IN (+qty) ve TRANSFER_OUT (-qty) hesabı yapar
--   ❌ Mevcut kayıtları silmez veya bozmaz
-- =============================================================

-- 1. stock_movements.movement_type constraint güncellemesi
ALTER TABLE public.stock_movements
  DROP CONSTRAINT IF EXISTS stock_movements_type_check;

ALTER TABLE public.stock_movements
  ADD CONSTRAINT stock_movements_type_check
    CHECK (movement_type IN ('GIRIS', 'CIKIS', 'TRANSFER', 'SAYIM', 'TRANSFER_OUT', 'TRANSFER_IN'));

-- 2. transfer_group_id alanı ekleme (iki transfer hareketini bağlamak için)
ALTER TABLE public.stock_movements
  ADD COLUMN IF NOT EXISTS transfer_group_id UUID NULL;

CREATE INDEX IF NOT EXISTS stock_movements_transfer_group_idx
  ON public.stock_movements(transfer_group_id)
  WHERE transfer_group_id IS NOT NULL;

-- 3. product_stocks view'ının soft-delete ve TRANSFER_IN / TRANSFER_OUT uyumlu olarak güncellenmesi
CREATE OR REPLACE VIEW public.product_stocks
WITH (security_invoker = on) AS
SELECT
  p.id AS product_id,
  p.user_id,
  COALESCE(SUM(
    CASE
      WHEN m.deleted_at IS NULL AND m.movement_type IN ('GIRIS', 'TRANSFER_IN') THEN m.quantity
      WHEN m.deleted_at IS NULL AND m.movement_type IN ('CIKIS', 'TRANSFER_OUT') THEN -m.quantity
      ELSE 0
    END), 0) AS quantity
FROM public.products p
LEFT JOIN public.stock_movements m ON m.product_id = p.id
WHERE p.deleted_at IS NULL
GROUP BY p.id, p.user_id;

GRANT SELECT ON public.product_stocks TO authenticated;
GRANT ALL ON public.product_stocks TO service_role;
