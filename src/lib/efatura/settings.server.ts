import type { Database } from "@/integrations/supabase/types";
import { decryptSecret, encryptSecret } from "./crypto.server";
import { getProvider, type ProviderId } from "./providers.server";
import type { ActiveProvider, ConnectionSettingsView, ConnectionStatus } from "@/lib/efatura-settings.functions";

type Row = Database["public"]["Tables"]["efatura_connection_settings"]["Row"];
type Patch = Database["public"]["Tables"]["efatura_connection_settings"]["Update"];

async function admin() {
  const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
  return supabaseAdmin;
}

export async function loadSettings(userId: string): Promise<Row> {
  const db = await admin();
  const { data, error } = await db
    .from("efatura_connection_settings")
    .select("*")
    .eq("user_id", userId)
    .maybeSingle();
  if (error) throw error;
  if (data) return data as Row;

  const { data: created, error: insertError } = await db
    .from("efatura_connection_settings")
    .insert({ user_id: userId })
    .select("*")
    .single();
  if (insertError) throw insertError;
  return created as Row;
}

async function update(userId: string, patch: Patch): Promise<Row> {
  const db = await admin();
  await loadSettings(userId);
  const { data, error } = await db
    .from("efatura_connection_settings")
    .update(patch)
    .eq("user_id", userId)
    .select("*")
    .single();
  if (error) throw error;
  return data as Row;
}

export function toView(row: Row): ConnectionSettingsView {
  return {
    activeProvider: row.active_provider as ActiveProvider,
    gib: {
      enabled: row.gib_enabled,
      environment: row.gib_environment,
      username: row.gib_username,
      hasPassword: Boolean(row.gib_password_encrypted),
      status: row.gib_status as ConnectionStatus,
      lastTestedAt: row.gib_last_tested_at,
      lastError: row.gib_last_error,
    },
    integrator: {
      enabled: row.integrator_enabled,
      provider: row.integrator_provider,
      baseUrl: row.integrator_base_url,
      apiUsername: row.integrator_api_username,
      hasApiKey: Boolean(row.integrator_api_key_encrypted),
      status: row.integrator_status as ConnectionStatus,
      lastTestedAt: row.integrator_last_tested_at,
      lastError: row.integrator_last_error,
    },
  };
}

export async function saveGib(
  userId: string,
  input: { enabled: boolean; environment: string; username: string; password?: string | undefined },
): Promise<ConnectionSettingsView> {
  const patch: Patch = {
    gib_enabled: input.enabled,
    gib_environment: input.environment,
    gib_username: input.username,
    gib_status: "NOT_CONFIGURED",
    gib_last_error: "",
  };
  if (input.password && input.password.length > 0) {
    patch["gib_password_encrypted"] = encryptSecret(input.password);
  }
  return toView(await update(userId, patch));
}

export async function saveIntegrator(
  userId: string,
  input: { enabled: boolean; provider: string; baseUrl: string; apiUsername: string; apiKey?: string | undefined },
): Promise<ConnectionSettingsView> {
  const patch: Patch = {
    integrator_enabled: input.enabled,
    integrator_provider: input.provider,
    integrator_base_url: input.baseUrl,
    integrator_api_username: input.apiUsername,
    integrator_status: "NOT_CONFIGURED",
    integrator_last_error: "",
  };
  if (input.apiKey && input.apiKey.length > 0) {
    patch["integrator_api_key_encrypted"] = encryptSecret(input.apiKey);
  }
  return toView(await update(userId, patch));
}

export async function setActive(userId: string, activeProvider: ActiveProvider): Promise<ConnectionSettingsView> {
  const patch: Patch = { active_provider: activeProvider };
  if (activeProvider === "GIB") {
    patch["gib_enabled"] = true;
    patch["integrator_enabled"] = false;
  } else if (activeProvider === "INTEGRATOR") {
    patch["integrator_enabled"] = true;
    patch["gib_enabled"] = false;
  }
  return toView(await update(userId, patch));
}

/** Aktif bağlantının çözülmüş kimlik bilgileri — yalnızca sunucu tarafı kullanır. */
export async function getActiveConnection(userId: string) {
  const row = await loadSettings(userId);
  if (row.active_provider === "GIB") {
    return {
      provider: "GIB" as ProviderId,
      username: row.gib_username,
      secret: row.gib_password_encrypted ? decryptSecret(row.gib_password_encrypted) : "",
      environment: row.gib_environment,
    };
  }
  if (row.active_provider === "INTEGRATOR") {
    return {
      provider: "INTEGRATOR" as ProviderId,
      username: row.integrator_api_username,
      secret: row.integrator_api_key_encrypted ? decryptSecret(row.integrator_api_key_encrypted) : "",
      baseUrl: row.integrator_base_url,
      integratorName: row.integrator_provider,
    };
  }
  return null;
}

export async function runConnectionTest(userId: string, provider: ProviderId) {
  const row = await loadSettings(userId);
  const credentials =
    provider === "GIB"
      ? {
          provider,
          username: row.gib_username,
          secret: row.gib_password_encrypted ? decryptSecret(row.gib_password_encrypted) : "",
          environment: row.gib_environment,
        }
      : {
          provider,
          username: row.integrator_api_username,
          secret: row.integrator_api_key_encrypted ? decryptSecret(row.integrator_api_key_encrypted) : "",
          baseUrl: row.integrator_base_url,
          integratorName: row.integrator_provider,
        };

  let result = { ok: false, message: "Bağlantı test edilemedi." };
  try {
    result = await getProvider(provider).testConnection(credentials);
  } catch (error) {
    result = { ok: false, message: error instanceof Error ? error.message : "Bilinmeyen hata." };
  }

  const now = new Date().toISOString();
  const patch: Patch =
    provider === "GIB"
      ? {
          gib_status: result.ok ? "CONNECTED" : "FAILED",
          gib_last_tested_at: now,
          gib_last_error: result.ok ? "" : result.message,
        }
      : {
          integrator_status: result.ok ? "CONNECTED" : "FAILED",
          integrator_last_tested_at: now,
          integrator_last_error: result.ok ? "" : result.message,
        };

  const settings = toView(await update(userId, patch));
  return { ...result, settings };
}
