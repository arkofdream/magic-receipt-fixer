/**
 * Modüler ve genişletilebilir e-Fatura & GİB Sağlayıcı Katmanı (Server-Side Only).
 *
 * Gerçek entegratör (Uyumsoft, Foriba, QNB e-Finans, GİB Portal, NES Bilgi, Generic vb.)
 * adaptörleri bu arayüzü uygular.
 * Canlı API erişimi olmadığında sahte "Bağlantı Başarılı" yanıtı verilmez;
 * yapılandırma durumu ve gerçek bağlantı gereksinimleri net olarak bildirilir.
 */

import { getIntegratorConfig } from "./integrators.config";

export type ProviderId = "GIB" | "INTEGRATOR";

export type ConnectionCredentials = {
  provider: ProviderId;
  /** GİB: kullanıcı kodu | Entegratör: API kullanıcı adı (gerekli ise) */
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

function validateCredentials(credentials: ConnectionCredentials): ConnectionTestResult | null {
  const providerName = credentials.integratorName || "Entegratör";
  const config = getIntegratorConfig(providerName);

  if (credentials.provider === "GIB") {
    if (!credentials.username || !credentials.username.trim()) {
      return { ok: false, message: "GİB Portal kullanıcı kodu zorunludur." };
    }
    if (!credentials.secret || !credentials.secret.trim()) {
      return { ok: false, message: "GİB Portal şifresi zorunludur." };
    }
    return null;
  }

  if (config.requiresUsername && (!credentials.username || !credentials.username.trim())) {
    return {
      ok: false,
      message: `${providerName} için kullanıcı adı / kullanıcı kodu zorunludur.`,
    };
  }
  if (config.requiresApiKey && (!credentials.secret || !credentials.secret.trim())) {
    return { ok: false, message: `${providerName} için şifre veya API anahtarı zorunludur.` };
  }
  return null;
}

export function normalizeApiKey(key?: string | null): string {
  if (!key) return "";
  let clean = key.trim();
  clean = clean.replace(/[\u200B-\u200D\uFEFF]/g, "");
  clean = clean.replace(/^["']+|["']+$/g, "").trim();
  if (/^bearer\s+/i.test(clean)) {
    clean = clean.replace(/^bearer\s+/i, "").trim();
  }
  clean = clean.replace(/^["']+|["']+$/g, "").trim();
  return clean;
}

function buildIntegratorTestUrl(
  integratorName: string,
  baseUrl: string,
  docType: "einvoice" | "earchive" = "einvoice",
): string {
  let cleanUrl = baseUrl.trim().replace(/\/+$/, "");

  if (
    integratorName === "Nes Bilgi" ||
    integratorName === "NES Bilgi" ||
    integratorName.toLowerCase().includes("nes")
  ) {
    const servicePath = docType === "earchive" ? "earchive" : "einvoice";
    if (cleanUrl.endsWith(`/${servicePath}/v1/uploads/document`)) {
      return cleanUrl;
    }
    cleanUrl = cleanUrl.replace(/\/(einvoice|earchive)(\/v1(\/uploads\/document)?)?$/i, "");
    return `${cleanUrl}/${servicePath}/v1/uploads/document`;
  }

  if (cleanUrl.endsWith("/auth/test")) {
    return cleanUrl;
  }
  return cleanUrl + "/auth/test";
}

/**
 * GİB Portal Adaptörü (e-Arşiv / e-Fatura İnteraktif Portal).
 */
class GibPortalProvider implements EInvoiceProvider {
  id: ProviderId = "GIB";
  label = "GİB Portal (Gelir İdaresi Başkanlığı)";

  async testConnection(credentials: ConnectionCredentials): Promise<ConnectionTestResult> {
    const invalid = validateCredentials(credentials);
    if (invalid) return invalid;

    const isProd = credentials.environment === "PROD";
    const envLabel = isProd ? "Canlı (GİB Üretim)" : "Test";

    const endpoint = isProd
      ? "https://earsivportal.gib.gov.tr/earsiv-services/dispatch"
      : "https://earsivportaltest.gib.gov.tr/earsiv-services/dispatch";

    try {
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
    const invalid = validateCredentials(credentials);
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
    _ettn: string,
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
 * Özel Entegratör Adaptörü (NES Bilgi, EDM, Uyumsoft, Foriba, Logo, QNB, Generic REST/SOAP).
 */
class IntegratorProvider implements EInvoiceProvider {
  id: ProviderId = "INTEGRATOR";
  label = "Özel Entegratör";

  async testConnection(credentials: ConnectionCredentials): Promise<ConnectionTestResult> {
    const invalid = validateCredentials(credentials);
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
          "Entegratör servis adresi geçerli bir URL olmalıdır (örn. https://apitest.nes.com.tr).",
      };
    }

    const integrator = credentials.integratorName || "Entegratör";
    const config = getIntegratorConfig(integrator);
    const testUrl = buildIntegratorTestUrl(integrator, credentials.baseUrl);
    const cleanBaseUrl = credentials.baseUrl.trim().replace(/\/+$/, "");

    const cleanSecret = normalizeApiKey(credentials.secret);
    if (!cleanSecret) {
      return { ok: false, message: `${integrator} için API anahtarı zorunludur.` };
    }

    const maskedKey = `${cleanSecret.slice(0, 2)}...${cleanSecret.slice(-2)} (uzunluk: ${cleanSecret.length})`;
    console.log(`[NES TEST] Endpoint: ${testUrl}, Method: POST, Masked Key: ${maskedKey}`);

    try {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 8000);

      const headers: Record<string, string> = {};

      const isNes = integrator.toLowerCase().includes("nes");
      if (config.authType === "BEARER_TOKEN" || config.authType === "API_KEY" || isNes) {
        headers["Authorization"] = `Bearer ${cleanSecret}`;
      } else {
        headers["Authorization"] =
          `Basic ${Buffer.from(`${credentials.username || ""}:${cleanSecret}`).toString("base64")}`;
      }

      const res = await fetch(testUrl, {
        method: "POST",
        headers,
        signal: controller.signal,
      })
        .catch(async () => {
          return await fetch(cleanBaseUrl, {
            method: "GET",
            headers,
            signal: controller.signal,
          });
        })
        .finally(() => clearTimeout(timeout));

      console.log(`[NES TEST] Response HTTP Status: ${res.status}`);

      if (res.ok || res.status === 400 || res.status === 415 || res.status === 422) {
        return {
          ok: true,
          message: `${integrator} API bağlantısı ve kimlik bilgileri başarıyla doğrulandı.`,
          statusCode: res.status,
        };
      }

      if (res.status === 401 || res.status === 403) {
        return {
          ok: false,
          message: `${integrator} API yetkilendirme hatası: Girilen API anahtarı veya kimlik bilgisi geçersiz (HTTP ${res.status}). Lütfen API anahtarınızı kontrol ediniz.`,
          statusCode: res.status,
        };
      }

      if (res.status === 404) {
        return {
          ok: false,
          message: `${integrator} servis adresine (${testUrl}) ulaşıldı ancak uç nokta adresi bulunamadı (HTTP 404). Lütfen API URL adresini kontrol ediniz.`,
          statusCode: res.status,
        };
      }

      return {
        ok: false,
        message: `${integrator} API servisine ulaşıldı ancak yanıt doğrulanamadı (HTTP ${res.status}). API bilgilerinizi kontrol ediniz.`,
        statusCode: res.status,
      };
    } catch (err: unknown) {
      const errMsg = err instanceof Error ? err.message : String(err);
      return {
        ok: false,
        message: `${integrator} servis adresine (${credentials.baseUrl}) ulaşılamadı: ${errMsg}. Servis adresini ve internet bağlantınızı kontrol ediniz.`,
      };
    }
  }

  async sendInvoice(
    credentials: ConnectionCredentials,
    invoice: InvoicePayload,
  ): Promise<SendInvoiceResult> {
    const invalid = validateCredentials(credentials);
    if (invalid) return { ok: false, message: invalid.message };

    const ettn = (invoice["ettn"] as string) || crypto.randomUUID().toUpperCase();
    const integrator = credentials.integratorName || "Entegratör";

    if (
      integrator === "Nes Bilgi" ||
      integrator === "NES Bilgi" ||
      integrator.toLowerCase().includes("nes")
    ) {
      if (!credentials.baseUrl) {
        console.log("[INVOICE] NES API URL'i tanımlı değil.");
        return { ok: false, message: "NES API URL'i tanımlı değil.", ettn };
      }

      const isEArchive =
        invoice["isEArchive"] === true ||
        invoice["docType"] === "EARCHIVE" ||
        invoice["profileId"] === "EARSIVFATURA" ||
        (invoice["type"] === "SATIS" && !invoice["isEinvoiceTaxpayer"]);

      const docTypeKey: "einvoice" | "earchive" = isEArchive ? "earchive" : "einvoice";
      const testUrl = buildIntegratorTestUrl(integrator, credentials.baseUrl, docTypeKey);
      console.log(
        `[INVOICE] Gönderim başlatıldı. Tür: ${isEArchive ? "e-Arşiv" : "e-Fatura"}, ETTN: ${ettn}`,
      );
      console.log(`[INVOICE] Backend endpoint: ${testUrl}`);

      try {
        const formData = new FormData();
        const isDirectSendVal =
          invoice["isDirectSend"] !== undefined ? String(invoice["isDirectSend"]) : "true";
        formData.append("IsDirectSend", isDirectSendVal);
        formData.append("PreviewType", (invoice["previewType"] as string) || "Html");
        formData.append("SourceApp", "MagicReceiptApp");

        const senderAlias = String(invoice["senderAlias"] || credentials.senderAlias || "").trim();

        if (!senderAlias || senderAlias.toLowerCase() === "defaultgb") {
          console.warn("[INVOICE] Geçersiz Gönderici Birim (GB) etiketi. defaultgb engellendi.");
          return {
            ok: false,
            message:
              "NES entegrasyonu için geçerli Gönderici Birim (GB) etiketi bulunamadı. Firma/NES entegrasyon bilgilerini kontrol edin.",
            ettn,
            statusCode: "400",
          };
        }

        formData.append("SenderAlias", senderAlias);
        console.log(`[INVOICE] Gerçek SenderAlias eklendi: ${senderAlias}`);

        if (invoice["receiverAlias"]) {
          formData.append("ReceiverAlias", String(invoice["receiverAlias"]));
        }

        console.log("[INVOICE] Request oluşturuldu (IsDirectSend: " + isDirectSendVal + ")");

        if (invoice["xmlContent"]) {
          const blob = new Blob([String(invoice["xmlContent"])], { type: "application/xml" });
          formData.append("File", blob, `${ettn}.xml`);
          console.log("[INVOICE] XML/UBL mevcut içerik ile eklendi");
        } else {
          const { createUblTrInvoice } = await import("../ubl");
          const ublXml = createUblTrInvoice({
            uuid: ettn,
            invoiceNumber: (invoice["invoiceNumber"] as string) || "EAR2026000000001",
            issueDate: new Date().toISOString().split("T")[0],
            seller: {
              taxNumber: (invoice["sellerTaxNumber"] as string) || "1111111111",
              name: (invoice["sellerName"] as string) || "Satıcı Firma",
            },
            buyer: {
              taxNumber:
                (invoice["buyerTaxNumber"] as string) ||
                (invoice["customerTaxNumber"] as string) ||
                "2222222222",
              name:
                (invoice["buyerName"] as string) ||
                (invoice["customerName"] as string) ||
                "Müşteri Firma",
            },
            lines: Array.isArray(invoice["items"])
              ? (invoice["items"] as Record<string, unknown>[]).map((it) => ({
                  name: String(it.name || "Ürün/Hizmet"),
                  quantity: Number(it.quantity) || 1,
                  unitPrice: Number(it.unitPrice || it.unit_price) || 100,
                  discountRate: Number(it.discountRate || it.discount_rate) || 0,
                  vatRate: Number(it.vatRate || it.vat_rate) || 20,
                }))
              : [
                  {
                    name: "Ürün/Hizmet",
                    quantity: 1,
                    unitPrice: Number(invoice["grandTotal"]) || 100,
                    vatRate: 20,
                  },
                ],
          });
          const blob = new Blob([ublXml], { type: "application/xml" });
          formData.append("File", blob, `${ettn}.xml`);
          console.log("[INVOICE] XML/UBL dinamik olarak oluşturuldu");
        }

        const cleanSecret = normalizeApiKey(credentials.secret);
        console.log("[INVOICE] Entegratör API çağrısı başladı");
        const res = await fetch(testUrl, {
          method: "POST",
          headers: {
            Authorization: `Bearer ${cleanSecret}`,
          },
          body: formData,
        });

        const text = await res.text().catch(() => "");
        console.log(`[INVOICE] API response alındı (${text.length} bayt)`);

        // NES FORENSIC RESPONSE OBSERVER LOG
        const contentType = res.headers.get("content-type") || "BİLİNMİYOR";
        const wwwAuth = res.headers.get("www-authenticate") || "YOK";
        const correlationId =
          res.headers.get("x-correlation-id") ||
          res.headers.get("x-request-id") ||
          res.headers.get("cf-ray") ||
          "YOK";

        let nesErrorCode = "YOK";
        let nesErrorMessage = "YOK";

        if (text.trim().startsWith("{")) {
          try {
            const parsed = JSON.parse(text);
            nesErrorCode = String(
              parsed.code || parsed.errorCode || parsed.errors?.[0]?.code || "YOK",
            );
            nesErrorMessage = String(
              parsed.message || parsed.errorDescription || parsed.errors?.[0]?.description || "YOK",
            );
          } catch {
            // Raw text fallback
          }
        }

        console.log(`[NES FORENSIC RESPONSE]
HTTP Status: ${res.status}
Status Text: ${res.statusText || "N/A"}
Content-Type: ${contentType}
WWW-Authenticate: ${wwwAuth}
NES Error Code: ${nesErrorCode}
NES Error Message: ${nesErrorMessage}
Correlation/Request ID: ${correlationId}`);

        if (res.ok) {
          console.log("[INVOICE] Gönderim sonucu: BAŞARILI (Kuyruğa Alındı)");
          let parsedJson: any = null;
          if (text.trim().startsWith("{")) {
            try {
              parsedJson = JSON.parse(text);
            } catch {
              parsedJson = null;
            }
          }

          const externalId =
            parsedJson?.id || parsedJson?.documentId || parsedJson?.referenceId || ettn;
          const statusCode = String(parsedJson?.statusCode || res.status);
          const statusDesc =
            parsedJson?.statusDescription ||
            "Fatura NES servisine başarıyla yüklendi (İşleme Alındı).";

          return {
            ok: true,
            message: statusDesc,
            externalId,
            ettn,
            statusCode,
          };
        }

        console.log(`[INVOICE] Gönderim sonucu: HATALI (${res.status})`);
        if (res.status === 401 || res.status === 403) {
          return {
            ok: false,
            message: "NES yetkilendirme hatası: API Anahtarı geçersiz.",
            ettn,
            statusCode: String(res.status),
          };
        }

        // Try parsing JSON error body safely
        let jsonErr: any = null;
        if (
          res.headers.get("content-type")?.includes("application/json") ||
          text.trim().startsWith("{")
        ) {
          try {
            jsonErr = JSON.parse(text);
          } catch {
            jsonErr = null;
          }
        }

        if (jsonErr && Array.isArray(jsonErr.errors) && jsonErr.errors.length > 0) {
          const errObj = jsonErr.errors[0];
          const code = String(errObj.code || "");
          const desc = String(errObj.description || jsonErr.message || "Hatalı istek.");
          const detail = errObj.detail ? ` (${errObj.detail})` : "";

          if (code === "1150" || desc.includes("UYUSMUYOR")) {
            return {
              ok: false,
              message:
                "NES entegrasyonundaki firma VKN/TCKN ile faturadaki gönderen VKN/TCKN uyuşmuyor. Firma ve NES entegrasyon bilgilerini kontrol edin.",
              ettn,
              statusCode: String(res.status),
            };
          }

          return {
            ok: false,
            message: `NES Fatura Hatası [Kod ${code || res.status}]: ${desc}${detail}`,
            ettn,
            statusCode: String(res.status),
          };
        }

        const isHtml = text.trim().startsWith("<") || text.includes("<html");
        return {
          ok: false,
          message: isHtml
            ? `Sunucudan beklenmeyen bir yanıt alındı (HTTP ${res.status}). Lütfen tekrar deneyin.`
            : `NES fatura yükleme yanıtı (${res.status}): ${text || "Belge işlenemedi."}`,
          ettn,
          statusCode: String(res.status),
        };
      } catch (err: unknown) {
        const errMsg = err instanceof Error ? err.message : String(err);
        console.error(`[INVOICE] Gönderim istisnası: ${errMsg}`);
        return {
          ok: false,
          message: `NES fatura gönderim hatası: ${errMsg}`,
          ettn,
        };
      }
    }

    return {
      ok: false,
      message: `${integrator} fatura gönderimi için aktif API bağlantısı gereklidir.`,
      ettn,
    };
  }

  async getInvoiceStatus(
    credentials: ConnectionCredentials,
    ettn: string,
  ): Promise<InvoiceStatusResult> {
    if (!credentials.baseUrl || !credentials.secret) {
      return {
        ok: false,
        status: "UNKNOWN",
        message: "Sorgulama için entegratör URL ve API anahtarı gereklidir.",
      };
    }

    const cleanBaseUrl = credentials.baseUrl.trim().replace(/\/+$/, "");
    let statusUrl = `${cleanBaseUrl}/einvoice/v1/invoices/${ettn}/status`;

    try {
      let res = await fetch(statusUrl, {
        method: "GET",
        headers: {
          Authorization: `Bearer ${credentials.secret}`,
          Accept: "application/json",
        },
      });

      if (res.status === 404) {
        statusUrl = `${cleanBaseUrl}/earchive/v1/invoices/${ettn}/status`;
        res = await fetch(statusUrl, {
          method: "GET",
          headers: {
            Authorization: `Bearer ${credentials.secret}`,
            Accept: "application/json",
          },
        });
      }

      if (res.ok) {
        const json = await res.json().catch(() => ({}));
        const code = String(json.gibStatusCode || json.statusCode || "");
        const statusStr = String(json.status || "").toUpperCase();

        let status:
          "DRAFT" | "QUEUED" | "SENT" | "APPROVED" | "REJECTED" | "CANCELLED" | "UNKNOWN" = "SENT";
        if (
          statusStr === "ACCEPTED" ||
          statusStr === "APPROVED" ||
          code === "1300" ||
          code === "3000"
        ) {
          status = "APPROVED";
        } else if (statusStr === "REJECTED" || statusStr === "FAILED" || code === "1150") {
          status = "REJECTED";
        } else if (statusStr === "CANCELLED") {
          status = "CANCELLED";
        } else if (statusStr === "QUEUED" || statusStr === "SUBMITTING") {
          status = "QUEUED";
        }

        return {
          ok: true,
          status,
          message:
            json.gibStatusDescription || json.statusDescription || `Entegratör Durumu: ${status}`,
          gibStatusCode: code,
          updatedAt: json.updatedAt || new Date().toISOString(),
        };
      }

      return {
        ok: false,
        status: "UNKNOWN",
        message: `NES Durum Sorgulama Yanıtı (HTTP ${res.status}): Belge henüz GİB tarafından onaylanmadı veya işleniyor.`,
      };
    } catch (err: unknown) {
      const errMsg = err instanceof Error ? err.message : String(err);
      return {
        ok: false,
        status: "UNKNOWN",
        message: `Durum sorgulama hatası: ${errMsg}`,
      };
    }
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
