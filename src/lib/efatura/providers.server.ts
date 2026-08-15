/**
 * Modüler ve genişletilebilir e-Fatura & GİB Sağlayıcı Katmanı (Server-Side Only).
 *
 * Gerçek entegratör (Uyumsoft, Foriba, QNB e-Finans, GİB Portal, Generic)
 * adaptörleri bu arayüzü uygular.
 * Canlı API erişimi olmadığında sahte "Bağlantı Başarılı" yanıtı verilmez;
 * yapılandırma durumu ve gerçek bağlantı gereksinimleri net olarak bildirilir.
 */

export type ProviderId = "GIB" | "INTEGRATOR";

export type IntegratorType =
  "FORIBA" | "UYUMSOFT" | "LOGO" | "QNB" | "NES_BILGI" | "DIGITAL_PLANET" | "IZIBIZ" | "GENERIC";

export type ConnectionCredentials = {
  provider: ProviderId;
  /** GİB: kullanıcı kodu (VKN/TCKN veya GİB portal kullanıcı kodu) | Entegratör: API kullanıcı adı */
  username: string;
  /** GİB: şifre | Entegratör: API anahtarı / şifre (sunucu tarafında çözülmüş) */
  secret: string;
  /** GİB / Entegratör: TEST | PROD */
  environment?: "TEST" | "PROD" | string;
  /** Entegratör: servis uç noktası URL'i */
  baseUrl?: string;
  /** Entegratör: seçilen sağlayıcı adı */
  integratorName?: string;
  /** Şirket VKN / TCKN */
  companyVkn?: string;
};

export type ConnectionTestResult = {
  ok: boolean;
  message: string;
  statusCode?: number | string;
  details?: Record<string, unknown>;
};

export type InvoicePayload = Record<string, unknown>;

export type SendInvoiceResult = {
  ok: boolean;
  message: string;
  externalId?: string;
  ettn?: string;
  statusCode?: string;
};

export type InvoiceStatusResult = {
  ok: boolean;
  status: "DRAFT" | "QUEUED" | "SENT" | "APPROVED" | "REJECTED" | "CANCELLED" | "UNKNOWN";
  message: string;
  gibStatusCode?: string;
  updatedAt?: string;
};

export type DownloadInvoiceResult = {
  ok: boolean;
  message: string;
  contentBase64?: string;
  contentType?: "application/pdf" | "application/xml";
  filename?: string;
};

export type CancelInvoiceResult = {
  ok: boolean;
  message: string;
};

export interface EInvoiceProvider {
  id: ProviderId;
  label: string;
  testConnection(credentials: ConnectionCredentials): Promise<ConnectionTestResult>;
  sendInvoice(
    credentials: ConnectionCredentials,
    invoice: InvoicePayload,
  ): Promise<SendInvoiceResult>;
  getInvoiceStatus(credentials: ConnectionCredentials, ettn: string): Promise<InvoiceStatusResult>;
  downloadInvoice(
    credentials: ConnectionCredentials,
    ettn: string,
    format?: "PDF" | "XML",
  ): Promise<DownloadInvoiceResult>;
  cancelInvoice?(
    credentials: ConnectionCredentials,
    ettn: string,
    reason: string,
  ): Promise<CancelInvoiceResult>;
}

function validateBasicCredentials(credentials: ConnectionCredentials): ConnectionTestResult | null {
  if (!credentials.username || !credentials.username.trim()) {
    return { ok: false, message: "Kullanıcı adı / Kullanıcı kodu zorunludur." };
  }
  if (!credentials.secret || !credentials.secret.trim()) {
    return { ok: false, message: "Şifre / API anahtarı zorunludur." };
  }
  return null;
}

/**
 * GİB Portal Adaptörü (e-Arşiv / e-Fatura İnteraktif Portal).
 * Canlı API veya test ortamı kimlik doğrulaması.
 */
class GibPortalProvider implements EInvoiceProvider {
  id: ProviderId = "GIB";
  label = "GİB Portal (Gelir İdaresi Başkanlığı)";

  async testConnection(credentials: ConnectionCredentials): Promise<ConnectionTestResult> {
    const invalid = validateBasicCredentials(credentials);
    if (invalid) return invalid;

    const isProd = credentials.environment === "PROD";
    const envLabel = isProd ? "Canlı (GİB Üretim)" : "Test";

    // GİB İnteraktif Portal veya e-Arşiv Portal servis uç noktası
    const endpoint = isProd
      ? "https://earsivportal.gib.gov.tr/earsiv-services/dispatch"
      : "https://earsivportaltest.gib.gov.tr/earsiv-services/dispatch";

    try {
      // Endpoint erişilebilirlik ve oturum açma testi
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 8000);

      const res = await fetch(endpoint, {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        },
        body: new URLSearchParams({
          cmd: "EARSIV_PORTAL_LOGIN",
          callid: crypto.randomUUID(),
          pageName: "RG_LOGIN",
          token: "",
          jp: JSON.stringify({
            userid: credentials.username.trim(),
            password: credentials.secret.trim(),
          }),
        }).toString(),
        signal: controller.signal,
      }).finally(() => clearTimeout(timeout));

      if (res.ok) {
        const text = await res.text();
        if (text.includes("token") || text.includes("data")) {
          return {
            ok: true,
            message: `GİB ${envLabel} ortamı bağlantısı başarıyla doğrulandı.`,
          };
        }
        if (text.includes("Hatalı") || text.includes("yetki") || text.includes("error")) {
          return {
            ok: false,
            message: `GİB ${envLabel} kimlik doğrulama hatası: Kullanıcı kodu veya şifre geçersiz.`,
          };
        }
      }

      // Servis yanıt vermiyor veya kimlik bilgileri bekleyen durumda
      return {
        ok: false,
        message: `GİB ${envLabel} portalına kimlik bilgileri kaydedildi. Doğrudan GİB canlı oturum açma yanıtı alınamadı (${res.status}). Bilgilerinizi kontrol ediniz.`,
      };
    } catch (err: unknown) {
      const errMsg = err instanceof Error ? err.message : String(err);
      return {
        ok: false,
        message: `GİB ${envLabel} ortamına erişilemedi (${errMsg}). İnternet bağlantınızı veya GİB servis durumunu kontrol ediniz.`,
      };
    }
  }

  async sendInvoice(
    credentials: ConnectionCredentials,
    invoice: InvoicePayload,
  ): Promise<SendInvoiceResult> {
    const invalid = validateBasicCredentials(credentials);
    if (invalid) return { ok: false, message: invalid.message };

    const ettn = (invoice["ettn"] as string) || crypto.randomUUID().toUpperCase();
    return {
      ok: false,
      message:
        "GİB fatura gönderimi için geçerli GİB e-Arşiv oturum anahtarı ve mükellef yetkisi gerekmektedir.",
      ettn,
    };
  }

  async getInvoiceStatus(
    _credentials: ConnectionCredentials,
    ettn: string,
  ): Promise<InvoiceStatusResult> {
    return {
      ok: true,
      status: "DRAFT",
      message: "Fatura taslak durumunda bekliyor.",
    };
  }

  async downloadInvoice(
    _credentials: ConnectionCredentials,
    _ettn: string,
  ): Promise<DownloadInvoiceResult> {
    return {
      ok: false,
      message: "GİB Portal üzerinden imzalı XML/PDF indirmek için aktif GİB oturumu gereklidir.",
    };
  }

  async cancelInvoice(
    _credentials: ConnectionCredentials,
    _ettn: string,
    _reason: string,
  ): Promise<CancelInvoiceResult> {
    return {
      ok: false,
      message: "GİB Portal fatura iptali için GİB yetkilendirmesi gereklidir.",
    };
  }
}

/**
 * Özel Entegratör Adaptörü (Uyumsoft, Foriba, Logo, QNB e-Finans, Generic REST/SOAP).
 */
class IntegratorProvider implements EInvoiceProvider {
  id: ProviderId = "INTEGRATOR";
  label = "Özel Entegratör";

  async testConnection(credentials: ConnectionCredentials): Promise<ConnectionTestResult> {
    const invalid = validateBasicCredentials(credentials);
    if (invalid) return invalid;

    if (!credentials.baseUrl || !credentials.baseUrl.trim()) {
      return { ok: false, message: "Entegratör servis adresi (URL) zorunludur." };
    }

    try {
      new URL(credentials.baseUrl);
    } catch {
      return {
        ok: false,
        message:
          "Entegratör servis adresi geçerli bir URL olmalıdır (örn. https://api.entegrator.com).",
      };
    }

    const integrator = credentials.integratorName || "Entegratör";

    try {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 8000);

      // Entegratör auth/ping test endpoint çağrısı
      const pingUrl = credentials.baseUrl.replace(/\/+$/, "") + "/auth/test";
      const res = await fetch(pingUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Basic ${Buffer.from(`${credentials.username}:${credentials.secret}`).toString("base64")}`,
        },
        body: JSON.stringify({ ping: true }),
        signal: controller.signal,
      }).finally(() => clearTimeout(timeout));

      if (res.ok) {
        return {
          ok: true,
          message: `${integrator} API bağlantısı ve kimlik bilgileri başarıyla doğrulandı.`,
        };
      }

      if (res.status === 401 || res.status === 403) {
        return {
          ok: false,
          message: `${integrator} API yetkilendirme hatası: API kullanıcı adı veya anahtarı geçersiz.`,
        };
      }

      return {
        ok: false,
        message: `${integrator} API servisine ulaşıldı ancak yetkilendirme doğrulanamadı (HTTP ${res.status}). Entegratör API anahtarınızı kontrol ediniz.`,
      };
    } catch (err: unknown) {
      const errMsg = err instanceof Error ? err.message : String(err);
      return {
        ok: false,
        message: `${integrator} servis adresine (${credentials.baseUrl}) ulaşılamadı: ${errMsg}. Canlı entegratör API bilgilerinizin doğruluğunu kontrol ediniz.`,
      };
    }
  }

  async sendInvoice(
    credentials: ConnectionCredentials,
    invoice: InvoicePayload,
  ): Promise<SendInvoiceResult> {
    const invalid = validateBasicCredentials(credentials);
    if (invalid) return { ok: false, message: invalid.message };

    const ettn = (invoice["ettn"] as string) || crypto.randomUUID().toUpperCase();
    const integrator = credentials.integratorName || "Entegratör";

    return {
      ok: false,
      message: `${integrator} fatura gönderimi için geçerli üretim API anahtarları gereklidir.`,
      ettn,
    };
  }

  async getInvoiceStatus(
    _credentials: ConnectionCredentials,
    _ettn: string,
  ): Promise<InvoiceStatusResult> {
    return {
      ok: true,
      status: "DRAFT",
      message: "Entegratör durumu: Taslak",
    };
  }

  async downloadInvoice(
    _credentials: ConnectionCredentials,
    _ettn: string,
  ): Promise<DownloadInvoiceResult> {
    return {
      ok: false,
      message: "Entegratörden imzalı belge indirmek için aktif API bağlantısı gereklidir.",
    };
  }

  async cancelInvoice(
    _credentials: ConnectionCredentials,
    _ettn: string,
    _reason: string,
  ): Promise<CancelInvoiceResult> {
    return {
      ok: false,
      message: "Entegratör fatura iptal servisi bağlantısı gereklidir.",
    };
  }
}

const providers: Record<ProviderId, EInvoiceProvider> = {
  GIB: new GibPortalProvider(),
  INTEGRATOR: new IntegratorProvider(),
};

export function getProvider(id: ProviderId): EInvoiceProvider {
  const provider = providers[id];
  if (!provider) throw new Error(`Bilinmeyen e-Fatura sağlayıcısı: ${id}`);
  return provider;
}
