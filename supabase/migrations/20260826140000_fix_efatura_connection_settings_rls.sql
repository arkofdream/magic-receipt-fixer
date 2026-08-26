-- Fix RLS Policies and Permissions for efatura_connection_settings

-- 1. Grant table permissions to authenticated users
GRANT SELECT, INSERT, UPDATE, DELETE ON public.efatura_connection_settings TO authenticated;

-- 2. Drop legacy restrictive RLS policy if exists
DROP POLICY IF EXISTS "No direct client access to connection settings" ON public.efatura_connection_settings;
DROP POLICY IF EXISTS "Users read own connection settings" ON public.efatura_connection_settings;
DROP POLICY IF EXISTS "Users insert own connection settings" ON public.efatura_connection_settings;
DROP POLICY IF EXISTS "Users update own connection settings" ON public.efatura_connection_settings;

-- 3. Ensure Row Level Security is enabled
ALTER TABLE public.efatura_connection_settings ENABLE ROW LEVEL SECURITY;

-- 4. Policy for SELECT: Users can read only their own settings
CREATE POLICY "Users read own connection settings"
  ON public.efatura_connection_settings
  FOR SELECT TO authenticated
  USING (auth.uid() = user_id);

-- 5. Policy for INSERT: Users can insert only their own settings
CREATE POLICY "Users insert own connection settings"
  ON public.efatura_connection_settings
  FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = user_id);

-- 6. Policy for UPDATE: Users can update only their own settings
CREATE POLICY "Users update own connection settings"
  ON public.efatura_connection_settings
  FOR UPDATE TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);
