/**
 * e-Fatura & Entegratör Bağlantı Ayarları (Server-side).
 * Supabase `efatura_connection_settings` tablosundan ayarları okur/yazar.
 * Hassas şifreler / API anahtarları AES-256-GCM ile şifrelenir.
 */

import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/integrations/supabase/types";
import { decryptSecret, encryptSecret } from "./crypto.server";
import {
  getProvider,
  type ConnectionCredentials,
  type ProviderId,
} from "./providers.server";

export type ActiveProvider = "NONE" | "GIB" | "INTEGRATOR";

export type EfaturaConnectionSettingsRow =
  Database["public"]["Tables"]["efatura_connection_settings"]["Row"];

export type ConnectionSettingsView = {
  activeProvider: ActiveProvider;
  gib: {
    enabled: boolean;
    environment: "TEST" | "PROD";
    username: string;
    hasPassword: boolean;
    status: string;
    lastTestedAt: string | null;
    lastError: string | null;
  };
  integrator: {
    enabled: boolean;
    provider: string;
    baseUrl: string;
    apiUsername: string;
    hasApiKey: boolean;
    status: string;
    lastTestedAt: string | null;
    lastError: string | null;
  };
};

type Patch = Partial<Database["public"]["Tables"]["efatura_connection_settings"]["Insert"]>;

export async function loadSettings(
  userId: string,
  client?: SupabaseClient<Database>,
): Promise<EfaturaConnectionSettingsRow> {
  if (!client) {
    throw new Error("Supabase istemcisi yüklenemedi.");
  }
  const { data, error } = await client
    .from("efatura_connection_settings")
    .select("*")
    .eq("user_id", userId)
    .maybeSingle();

  if (error) {
    throw new Error(`Bağlantı ayarları yüklenemedi: ${error.message}`);
  }

  if (!data) {
    const { data: created, error: createError } = await client
      .from("efatura_connection_settings")
      .insert({ user_id: userId })
      .select("*")
      .single();

    if (createError) {
      throw new Error(`Varsayılan ayarlar oluşturulamadı: ${createError.message}`);
    }
    return created;
  }

  return data;
}

export function toView(row: EfaturaConnectionSettingsRow): ConnectionSettingsView {
  return {
    activeProvider: (row.active_provider as ActiveProvider) || "NONE",
    gib: {
      enabled: row.gib_enabled,
      environment: (row.gib_environment as "TEST" | "PROD") || "TEST",
      username: row.gib_username || "",
      hasPassword: Boolean(row.gib_password_encrypted),
      status: row.gib_status || "NOT_CONFIGURED",
      lastTestedAt: row.gib_last_tested_at,
      lastError: row.gib_last_error,
    },
    integrator: {
      enabled: row.integrator_enabled,
      provider: row.integrator_provider || "NES Bilgi",
      baseUrl: row.integrator_base_url || "https://apitest.nes.com.tr",
      apiUsername: row.integrator_api_username || "",
      hasApiKey: Boolean(row.integrator_api_key_encrypted),
      status: row.integrator_status || "NOT_CONFIGURED",
      lastTestedAt: row.integrator_last_tested_at,
      lastError: row.integrator_last_error,
    },
  };
}

export async function update(
  userId: string,
  patch: Patch,
  client?: SupabaseClient<Database>,
): Promise<EfaturaConnectionSettingsRow> {
  if (!client) {
    throw new Error("Supabase istemcisi yüklenemedi.");
  }
  const { data, error } = await client
    .from("efatura_connection_settings")
    .update({ ...patch, updated_at: new Date().toISOString() })
    .eq("user_id", userId)
    .select("*")
    .single();

  if (error) {
    throw new Error(`Ayarlar güncellenemedi: ${error.message}`);
  }
  return data;
}

export async function saveGib(
  userId: string,
  input: {
    enabled: boolean;
    environment: "TEST" | "PROD";
    username: string;
    password?: string | undefined;
  },
  client?: SupabaseClient<Database>,
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
  if (input.enabled) {
    patch["active_provider"] = "GIB";
  }
  return toView(await update(userId, patch, client));
}

export async function saveIntegrator(
  userId: string,
  input: {
    enabled: boolean;
    provider: string;
    baseUrl: string;
    apiUsername: string;
    apiKey?: string | undefined;
  },
  client?: SupabaseClient<Database>,
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
  if (input.enabled) {
    patch["active_provider"] = "INTEGRATOR";
  }
  return toView(await update(userId, patch, client));
}

export async function setActive(
  userId: string,
  activeProvider: ActiveProvider,
  client?: SupabaseClient<Database>,
): Promise<ConnectionSettingsView> {
  const patch: Patch = { active_provider: activeProvider };
  if (activeProvider === "GIB") {
    patch["gib_enabled"] = true;
    patch["integrator_enabled"] = false;
  } else if (activeProvider === "INTEGRATOR") {
    patch["integrator_enabled"] = true;
    patch["gib_enabled"] = false;
  }
  return toView(await update(userId, patch, client));
}

export function resolveActiveCredentials(
  row: EfaturaConnectionSettingsRow,
): ConnectionCredentials | null {
  if (row.active_provider === "GIB") {
    return {
      provider: "GIB" as ProviderId,
      username: row.gib_username,
      secret: row.gib_password_encrypted ? decryptSecret(row.gib_password_encrypted) : "",
      environment: row.gib_environment,
    };
  }
  if (row.active_provider === "INTEGRATOR" || (row.integrator_enabled && row.integrator_api_key_encrypted)) {
    return {
      provider: "INTEGRATOR" as ProviderId,
      username: row.integrator_api_username || "",
      secret: row.integrator_api_key_encrypted
        ? decryptSecret(row.integrator_api_key_encrypted)
        : "",
      baseUrl: row.integrator_base_url || "https://apitest.nes.com.tr",
      integratorName: row.integrator_provider || "NES Bilgi",
    };
  }
  return null;
}

export async function runConnectionTest(
  userId: string,
  provider: ProviderId,
  client?: SupabaseClient<Database>,
  overrides?: {
    apiKey?: string;
    baseUrl?: string;
    apiUsername?: string;
    integratorName?: string;
  },
) {
  const row = await loadSettings(userId, client);

  const rawSecret =
    overrides?.apiKey && overrides.apiKey.trim().length > 0
      ? overrides.apiKey
      : row.integrator_api_key_encrypted
        ? decryptSecret(row.integrator_api_key_encrypted)
        : "";

  const baseUrl =
    overrides?.baseUrl && overrides.baseUrl.trim().length > 0
      ? overrides.baseUrl.trim()
      : row.integrator_base_url || "https://apitest.nes.com.tr";

  const username =
    overrides?.apiUsername !== undefined
      ? overrides.apiUsername.trim()
      : row.integrator_api_username || "";

  const integratorName = overrides?.integratorName || row.integrator_provider || "NES Bilgi";

  const credentials =
    provider === "GIB"
      ? {
          provider,
          username: row.gib_username,
          secret: row.gib_password_encrypted ? decryptSecret(row.gib_password_encrypted).trim() : "",
          environment: row.gib_environment,
        }
      : {
          provider,
          username,
          secret: rawSecret.trim(),
          baseUrl,
          integratorName,
        };

  let result = { ok: false, message: "Bağlantı test edilemedi." };
  try {
    result = await getProvider(provider).testConnection(credentials);
  } catch (error) {
    result = { ok: false, message: error instanceof Error ? error.message : "Bilinmeyen hata." };
  }

  // If test was successful AND overrides were provided, automatically save working settings!
  if (result.ok && provider === "INTEGRATOR" && overrides?.apiKey && overrides.apiKey.trim().length > 0) {
    const autoSavePatch: Patch = {
      active_provider: "INTEGRATOR",
      integrator_enabled: true,
      integrator_provider: integratorName,
      integrator_base_url: baseUrl,
      integrator_api_username: username,
      integrator_api_key_encrypted: encryptSecret(rawSecret.trim()),
    };
    await update(userId, autoSavePatch, client);
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
          active_provider: result.ok ? "INTEGRATOR" : row.active_provider,
          integrator_enabled: result.ok ? true : row.integrator_enabled,
          integrator_status: result.ok ? "CONNECTED" : "FAILED",
          integrator_last_tested_at: now,
          integrator_last_error: result.ok ? "" : result.message,
        };

  const settings = toView(await update(userId, patch, client));
  return { ...result, settings };
}

export async function sendInvoiceToActiveProvider(
  userId: string,
  invoiceData: Record<string, unknown>,
  client?: SupabaseClient<Database>,
) {
  const row = await loadSettings(userId, client);
  const credentials = resolveActiveCredentials(row);

  if (!credentials) {
    return {
      ok: false,
      message: "Aktif bir e-Fatura entegratör / GİB bağlantısı bulunamadı. Lütfen Ayarlar sayfasından entegratör ayarlarınızı kaydedip aktif hale getirin.",
    };
  }

  const provider = getProvider(credentials.provider);
  return provider.sendInvoice(credentials, invoiceData);
}
