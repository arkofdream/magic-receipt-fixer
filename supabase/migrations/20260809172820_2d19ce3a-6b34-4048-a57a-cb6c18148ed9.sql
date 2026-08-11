CREATE TABLE public.efatura_connection_settings (
  user_id UUID NOT NULL PRIMARY KEY,
  active_provider TEXT NOT NULL DEFAULT 'NONE',
  gib_enabled BOOLEAN NOT NULL DEFAULT false,
  gib_environment TEXT NOT NULL DEFAULT 'TEST',
  gib_username TEXT NOT NULL DEFAULT '',
  gib_password_encrypted TEXT,
  gib_status TEXT NOT NULL DEFAULT 'NOT_CONFIGURED',
  gib_last_tested_at TIMESTAMPTZ,
  gib_last_error TEXT NOT NULL DEFAULT '',
  integrator_enabled BOOLEAN NOT NULL DEFAULT false,
  integrator_provider TEXT NOT NULL DEFAULT '',
  integrator_base_url TEXT NOT NULL DEFAULT '',
  integrator_api_username TEXT NOT NULL DEFAULT '',
  integrator_api_key_encrypted TEXT,
  integrator_status TEXT NOT NULL DEFAULT 'NOT_CONFIGURED',
  integrator_last_tested_at TIMESTAMPTZ,
  integrator_last_error TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

GRANT ALL ON public.efatura_connection_settings TO service_role;
ALTER TABLE public.efatura_connection_settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "No direct client access to connection settings"
  ON public.efatura_connection_settings
  FOR SELECT TO authenticated, anon
  USING (false);

CREATE TRIGGER update_efatura_connection_settings_updated_at
BEFORE UPDATE ON public.efatura_connection_settings
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();