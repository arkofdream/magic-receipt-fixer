import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/integrations/supabase/types";
import { decryptSecret } from "./crypto.server";
import type { EdmCredentials } from "@/lib/edm";

export class EInvoiceCredentialsError extends Error {
  code = "EINVOICE_NOT_CONFIGURED";
  constructor(message: string) {
    super(message);
    this.name = "EInvoiceCredentialsError";
  }
}

const NOT_CONFIGURED =
  "e-Fatura bağlantısı tanımlanmamış. Lütfen Ayarlar > e-Fatura bölümünden entegratör kullanıcı adı, şifre/anahtar ve servis adresini kaydedin.";

/**
 * Oturum açmış kullanıcının entegratör kimlik bilgilerini veritabanından okur ve çözer.
 * Kod tabanında gömülü kullanıcı adı/şifre/servis adresi bulunmaz.
 */
export async function loadUserEInvoiceCredentials(
  userId: string,
  supabase: SupabaseClient<Database>,
): Promise<EdmCredentials> {
  const { data, error } = await supabase
    .from("efatura_connection_settings")
    .select(
      "active_provider, integrator_enabled, integrator_base_url, integrator_api_username, integrator_api_key_encrypted",
    )
    .eq("user_id", userId)
    .maybeSingle();

  if (error) throw new EInvoiceCredentialsError(`${NOT_CONFIGURED} (${error.message})`);
  if (!data) throw new EInvoiceCredentialsError(NOT_CONFIGURED);

  if (!data.integrator_enabled || data.active_provider === "NONE") {
    throw new EInvoiceCredentialsError(NOT_CONFIGURED);
  }

  const username = (data.integrator_api_username || "").trim();
  const serviceUrl = (data.integrator_base_url || "").trim();
  const password = data.integrator_api_key_encrypted
    ? decryptSecret(data.integrator_api_key_encrypted)
    : "";

  if (!username || !password || !serviceUrl) {
    throw new EInvoiceCredentialsError(NOT_CONFIGURED);
  }

  return { username, password, serviceUrl };
}

/** Kimlik bilgisi hatalarını 400'lük tek biçimli bir JSON yanıta çevirir. */
export function credentialsErrorResponse(error: unknown): Response | null {
  if (error instanceof EInvoiceCredentialsError) {
    return Response.json(
      {
        success: false,
        message: error.message,
        data: null,
        error: { code: error.code, message: error.message },
      },
      { status: 400 },
    );
  }
  return null;
}
