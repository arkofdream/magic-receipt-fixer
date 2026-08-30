-- Migration: 20260830150000_faz6a_financial_immutability_hardening.sql
-- FAZ 6A - Security Hardening (Immutability) for Financial Records
-- 
-- Bu migration tablolardaki mevcut RLS politikalarini daha guvenli hale getirir:
-- 1. journal_entries, journal_lines, account_transactions, stock_movements tablolari 
--    sadece READ-ONLY (SELECT) hale getirilir. INSERT/UPDATE/DELETE sadece RPC (service_role) uzerinden yapilabilir.
-- 2. invoices tablosu icin UPDATE ve DELETE islemleri yalnizca status = 'TASLAK' ise gecerli olur.

-- ==============================================================================
-- 1. journal_entries
-- ==============================================================================
DROP POLICY IF EXISTS "je_all_own" ON public.journal_entries;
-- Yeni politika sadece okumaya (SELECT) izin verir.
CREATE POLICY "je_select_own" ON public.journal_entries 
  FOR SELECT TO authenticated 
  USING (user_id = auth.uid());

-- ==============================================================================
-- 2. journal_lines
-- ==============================================================================
DROP POLICY IF EXISTS "jl_all_own" ON public.journal_lines;
CREATE POLICY "jl_select_own" ON public.journal_lines 
  FOR SELECT TO authenticated 
  USING (user_id = auth.uid());

-- ==============================================================================
-- 3. account_transactions
-- ==============================================================================
DROP POLICY IF EXISTS "Users manage own account transactions" ON public.account_transactions;
CREATE POLICY "Users read own account transactions" ON public.account_transactions 
  FOR SELECT TO authenticated 
  USING (user_id = auth.uid());

-- ==============================================================================
-- 4. stock_movements
-- ==============================================================================
DROP POLICY IF EXISTS "Users manage own stock movements" ON public.stock_movements;
CREATE POLICY "Users read own stock movements" ON public.stock_movements 
  FOR SELECT TO authenticated 
  USING (user_id = auth.uid());

-- ==============================================================================
-- 5. invoices
-- ==============================================================================
-- CREATE policy (INSERT) zaten kontrol altindaydi, aynen koruyoruz.
-- Sadece UPDATE ve DELETE kisitliyoruz.

DROP POLICY IF EXISTS "Users update own invoices" ON public.invoices;
CREATE POLICY "Users update own invoices" ON public.invoices 
  FOR UPDATE TO authenticated 
  -- Sadece 'TASLAK' asamasindaki faturalarin dogrudan API uzerinden guncellenmesine izin veriyoruz.
  USING (auth.uid() = user_id AND status = 'TASLAK') 
  WITH CHECK (auth.uid() = user_id AND status = 'TASLAK');

DROP POLICY IF EXISTS "Users delete own invoices" ON public.invoices;
CREATE POLICY "Users delete own invoices" ON public.invoices 
  FOR DELETE TO authenticated 
  -- Sadece 'TASLAK' asamasindaki faturalarin dogrudan API uzerinden silinmesine izin veriyoruz.
  USING (auth.uid() = user_id AND status = 'TASLAK');
