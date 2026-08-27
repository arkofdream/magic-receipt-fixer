-- ============================================================================
-- ADD MISSING INTEGRATOR_SENDER_ALIAS COLUMN TO EFATURA_CONNECTION_SETTINGS
-- ============================================================================

ALTER TABLE public.efatura_connection_settings
ADD COLUMN IF NOT EXISTS integrator_sender_alias TEXT NULL;

-- Reload PostgREST schema cache
NOTIFY pgrst, 'reload schema';
