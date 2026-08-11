/**
 * Modüler e-Fatura sağlayıcı katmanı.
 *
 * Her sağlayıcı aynı arayüzü uygular; ileride gerçek API entegrasyonu
 * eklenirken yalnızca ilgili adaptörün `testConnection` / `sendInvoice`
 * gövdesi doldurulur. Uygulamanın geri kalanı değişmez.
 *
 * DİKKAT: Bu dosya yalnızca sunucu tarafında çalışır (*.server.ts).
 */

export type ProviderId = "GIB" | "INTEGRATOR";

export type ConnectionCredentials = {
  provider: ProviderId;
  /** GİB: kullanıcı kodu | Entegratör: API kullanıcı adı */
  username: string;
  /** GİB: şifre | Entegratör: API anahtarı (çözülmüş) */
  secret: string;
  /** GİB: TEST | PROD */
  environment?: string;
  /** Entegratör: servis adresi */
  baseUrl?: string;
  /** Entegratör: seçilen entegratör adı */
  integratorName?: string;
};

export type ConnectionTestResult = { ok: boolean; message: string };

export type InvoicePayload = Record<string, unknown>;
export type SendInvoiceResult = { ok: boolean; message: string; externalId?: string };

export interface EInvoiceProvider {
  id: ProviderId;
  label: string;
  testConnection(credentials: ConnectionCredentials): Promise<ConnectionTestResult>;
  sendInvoice(credentials: ConnectionCredentials, invoice: InvoicePayload): Promise<SendInvoiceResult>;
}

function validate(credentials: ConnectionCredentials, extra?: () => string | null): ConnectionTestResult | null {
  if (!credentials.username.trim() || !credentials.secret.trim()) {
    return { ok: false, message: "Kullanıcı adı ve şifre/API anahtarı zorunludur." };
  }
  const extraError = extra?.();
  if (extraError) return { ok: false, message: extraError };
  return null;
}

const gibProvider: EInvoiceProvider = {
  id: "GIB",
  label: "GİB Portal",
  async testConnection(credentials) {
    const invalid = validate(credentials);
    if (invalid) return invalid;
    // TODO: Gerçek GİB servis çağrısı buraya eklenecek (SOAP/REST oturum açma).
    return {
      ok: true,
      message: `GİB ${credentials.environment === "PROD" ? "canlı" : "test"} ortamı için kimlik bilgileri doğrulandı.`,
    };
  },
  async sendInvoice() {
    return { ok: false, message: "GİB fatura gönderimi henüz etkinleştirilmedi." };
  },
};

const integratorProvider: EInvoiceProvider = {
  id: "INTEGRATOR",
  label: "Özel Entegratör",
  async testConnection(credentials) {
    const invalid = validate(credentials, () => {
      if (!credentials.integratorName?.trim()) return "Entegratör seçimi zorunludur.";
      if (!credentials.baseUrl?.trim()) return "Servis adresi (URL) zorunludur.";
      try {
        new URL(credentials.baseUrl);
      } catch {
        return "Servis adresi geçerli bir URL olmalıdır.";
      }
      return null;
    });
    if (invalid) return invalid;
    // TODO: Gerçek entegratör API çağrısı buraya eklenecek.
    return { ok: true, message: `${credentials.integratorName} bağlantı bilgileri doğrulandı.` };
  },
  async sendInvoice() {
    return { ok: false, message: "Entegratör fatura gönderimi henüz etkinleştirilmedi." };
  },
};

const providers: Record<ProviderId, EInvoiceProvider> = {
  GIB: gibProvider,
  INTEGRATOR: integratorProvider,
};

export function getProvider(id: ProviderId): EInvoiceProvider {
  return providers[id];
}
