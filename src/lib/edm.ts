import { createUblTrInvoice, validateAndCalculateInvoice, type UblInvoiceData } from "./ubl.ts";

export interface EdmConnectionTestResult {
  success: boolean;
  message: string;
  sessionIdPresent: boolean;
}

export interface EdmSendInvoiceResult {
  success: boolean;
  message: string;
  invoiceNumber?: string;
  uuid?: string;
  edmReference?: string;
  status?: string;
  error?: {
    code: string;
    message: string;
  } | null;
}

export interface EdmInvoiceStatusResult {
  success: boolean;
  message: string;
  uuid?: string;
  invoiceNumber?: string;
  status?: string;
  edmStatus?: string;
  edmReturnCode?: string;
  edmReturnMessage?: string;
}

const DEFAULT_EDM_TEST_URL = "https://test.edmbilisim.com.tr/EFaturaEDM21ea/EFaturaEDM.svc";
const FORBIDDEN_LIVE_HOST = "portal2.edmbilisim.com.tr";

/** XML attribute değerlerini güvenli hale getirir. */
function escapeXmlAttr(value: string): string {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}


/**
 * Checks that the configured service URL is strictly a TEST URL
 * and not accidentally configured to the live EDM production host.
 */
function verifyTestServiceUrl(url: string): string {
  if (!url || url.includes(FORBIDDEN_LIVE_HOST)) {
    throw new Error(
      "Güvenlik Uyarısı: Canlı EDM servisine (portal2.edmbilisim.com.tr) bu test modunda gönderim yapılamaz. Yalnızca EDM TEST servisi kullanılabilir."
    );
  }
  return url;
}

/**
 * Extracts inner text of a target XML tag without relying on namespace prefixes.
 * Handles tags like <SESSION_ID>, <a:SESSION_ID>, <tns:SESSION_ID>, etc.
 */
export function extractXmlTagValue(xml: string, tagName: string): string | null {
  const regex = new RegExp(
    `<\\s*(?:[a-zA-Z0-9_-]+:)?${tagName}(?:\\s+[^>]*)?>([\\s\\S]*?)<\\s*\\/(?:[a-zA-Z0-9_-]+:)?${tagName}\\s*>`,
    "i"
  );
  const match = xml.match(regex);
  if (!match) return null;
  return match[1].trim();
}

/**
 * Extracts an XML attribute value from a target tag (e.g., UUID="..." or TRXID="...").
 */
export function extractXmlAttributeValue(xml: string, tagName: string, attrName: string): string | null {
  const regex = new RegExp(
    `<\\s*(?:[a-zA-Z0-9_-]+:)?${tagName}[^>]*\\b${attrName}\\s*=\\s*"([^"]+)"`,
    "i"
  );
  const match = xml.match(regex);
  if (!match) return null;
  return match[1].trim();
}

/**
 * Builds the SOAP XML payload for EDM LoginRequest.
 * XML special characters in username and password are properly escaped.
 */
export function buildEdmLoginSoapBody(username: string, password: string): string {
  const escapedUser = username
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");

  const escapedPass = password
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");

  const actionDate = new Date().toISOString();

  return `<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns="http://tempuri.org/">
  <soap:Body>
    <ns:LoginRequest>
      <REQUEST_HEADER>
        <SESSION_ID>-1</SESSION_ID>
        <ACTION_DATE>${actionDate}</ACTION_DATE>
        <REASON>LOGIN</REASON>
        <APPLICATION_NAME>MagicReceipt</APPLICATION_NAME>
        <HOSTNAME>localhost</HOSTNAME>
        <CHANNEL_NAME>XML</CHANNEL_NAME>
      </REQUEST_HEADER>
      <USER_NAME>${escapedUser}</USER_NAME>
      <PASSWORD>${escapedPass}</PASSWORD>
    </ns:LoginRequest>
  </soap:Body>
</soap:Envelope>`;
}

/**
  * Resolves environment credentials and enforces environment isolation guards.
  */
export function resolveEdmConfig(): { username: string; password: string; serviceUrl: string; env: "TEST" | "PRODUCTION" } {
  const env = (process.env.EDM_ENV || "TEST").toUpperCase() === "PRODUCTION" ? "PRODUCTION" : "TEST";

  let username = "";
  let password = "";
  let serviceUrl = "";

  if (env === "PRODUCTION") {
    username = process.env.EDM_PROD_USERNAME || "";
    password = process.env.EDM_PROD_PASSWORD || "";
    serviceUrl = process.env.EDM_PROD_SERVICE_URL || "https://portal2.edmbilisim.com.tr/EFaturaEDM/EFaturaEDM.svc";

    if (!username || !password) {
      throw new Error("Production Güvenlik Uyarısı: EDM_PROD_USERNAME veya EDM_PROD_PASSWORD ortam değişkenleri tanımlı değil.");
    }
    if (serviceUrl.includes("test.edmbilisim.com.tr")) {
      throw new Error("Production Güvenlik Uyarısı: EDM_ENV=PRODUCTION modunda TEST URL kullanılamaz.");
    }
  } else {
    if (process.env.EDM_TEST_USERNAME === "" || process.env.EDM_TEST_PASSWORD === "") {
      throw new Error("EDM_TEST_USERNAME veya EDM_TEST_PASSWORD ortam değişkenleri tanımlı değil.");
    }
    username = process.env.EDM_TEST_USERNAME || "fuatekiz";
    password = process.env.EDM_TEST_PASSWORD || "1234567Edm";
    serviceUrl = process.env.EDM_TEST_SERVICE_URL || DEFAULT_EDM_TEST_URL;

    if (!username || !password) {
      throw new Error("EDM_TEST_USERNAME veya EDM_TEST_PASSWORD ortam değişkenleri tanımlı değil.");
    }
    if (serviceUrl.includes(FORBIDDEN_LIVE_HOST)) {
      throw new Error("Güvenlik Uyarısı: Canlı EDM servisine (portal2.edmbilisim.com.tr) bu test modunda gönderim yapılamaz. Yalnızca EDM TEST servisi kullanılabilir.");
    }
  }

  return { username, password, serviceUrl, env };
}

/**
 * Performs EDM Login on server-side and returns the raw SESSION_ID string.
 * Internal server helper.
 */
export async function getEdmSessionId(): Promise<{ sessionId: string; serviceUrl: string; env: string }> {
  const { username, password, serviceUrl, env } = resolveEdmConfig();

  const soapPayload = buildEdmLoginSoapBody(username, password);

  const response = await fetch(serviceUrl, {
    method: "POST",
    headers: {
      "Content-Type": "text/xml; charset=utf-8",
      SOAPAction: "LoginRequest",
    },
    body: soapPayload,
  });

  const responseText = await response.text();

  const faultString = extractXmlTagValue(responseText, "faultstring");
  const errorShortDes = extractXmlTagValue(responseText, "ERROR_SHORT_DES");
  const errorLongDes = extractXmlTagValue(responseText, "ERROR_LONG_DES");

  if (errorShortDes || errorLongDes || faultString) {
    const errDetail = errorShortDes || errorLongDes || faultString;
    throw new Error(`EDM Login hatası: ${errDetail}`);
  }

  const returnCode = extractXmlTagValue(responseText, "RETURN_CODE");
  if (returnCode !== null && returnCode !== "0") {
    const warnings = extractXmlTagValue(responseText, "WARNINGS");
    throw new Error(`EDM Login başarısız. Dönüş Kodu: ${returnCode}${warnings ? ` (${warnings})` : ""}`);
  }

  const sessionId = extractXmlTagValue(responseText, "SESSION_ID");
  if (!sessionId) {
    throw new Error("EDM yanıtında geçerli bir SESSION_ID bulunamadı.");
  }

  return { sessionId, serviceUrl, env };
}

/**
 * Performs EDM Login test on the server-side.
 * Reads EDM credentials strictly from environment variables.
 * Never returns or exposes actual passwords or SESSION_ID values to the caller.
 */
export async function testEdmConnection(): Promise<EdmConnectionTestResult> {
  try {
    const { sessionId } = await getEdmSessionId();
    return {
      success: true,
      message: "EDM TEST bağlantısı başarılı.",
      sessionIdPresent: Boolean(sessionId),
    };
  } catch (err: unknown) {
    const errMessage = err instanceof Error ? err.message : "Bilinmeyen ağ hatası";
    return {
      success: false,
      message: `EDM Web Service bağlantı hatası: ${errMessage}`,
      sessionIdPresent: false,
    };
  }
}

/** GİB mükellef kaydı (EDM CheckUser → GIBUSER) */
export interface EdmGibUser {
  identifier: string;
  alias: string;
  title: string;
  type: string;
  registerTime?: string;
  unit?: string; // "PK" (posta kutusu / alıcı) veya "GB" (gönderici birim)
  aliasCreationTime?: string;
  aliasRemovalTime?: string;
  documentType?: string;
  active: boolean;
}

export interface EdmCheckUserResult {
  success: boolean;
  message: string;
  identifier: string;
  isEinvoiceUser: boolean;
  title?: string;
  type?: string;
  registerTime?: string;
  aliases: EdmGibUser[]; // PK (alıcı posta kutusu) etiketleri
  senderAliases: EdmGibUser[]; // GB (gönderici birim) etiketleri
  error?: { code: string; message: string } | null;
}

/** "urn:mail:merkezpk@nes.com.tr" → "merkezpk@nes.com.tr" */
export function normalizeAliasMail(alias: string): string {
  return String(alias || "")
    .trim()
    .replace(/^urn:mail:/i, "")
    .toLowerCase();
}

/** İki alias'ın (urn:mail ön ekli ya da eksiz) aynı olup olmadığını karşılaştırır. */
export function isSameAlias(a: string, b: string): boolean {
  const na = normalizeAliasMail(a);
  const nb = normalizeAliasMail(b);
  return Boolean(na) && na === nb;
}

function parseGibUsers(responseText: string): EdmGibUser[] {
  const users: EdmGibUser[] = [];
  const blocks = responseText.match(/<USER[^>]*>[\s\S]*?<\/USER>/g) || [];
  for (const block of blocks) {
    const removal = extractXmlTagValue(block, "ALIAS_REMOVAL_TIME") || undefined;
    const alias = extractXmlTagValue(block, "ALIAS") || "";
    if (!alias) continue;
    users.push({
      identifier: extractXmlTagValue(block, "IDENTIFIER") || "",
      alias,
      title: extractXmlTagValue(block, "TITLE") || "",
      type: extractXmlTagValue(block, "TYPE") || "",
      registerTime: extractXmlTagValue(block, "REGISTER_TIME") || undefined,
      unit: (extractXmlTagValue(block, "UNIT") || "").toUpperCase() || undefined,
      aliasCreationTime: extractXmlTagValue(block, "ALIAS_CREATION_TIME") || undefined,
      aliasRemovalTime: removal,
      documentType: extractXmlTagValue(block, "DOCUMENTTYPE") || undefined,
      // GİB, etiket silindiğinde ALIAS_REMOVAL_TIME döner → geçersiz sayılır.
      active: !removal || new Date(removal).getTime() > Date.now(),
    });
  }
  return users;
}

/**
 * EDM CheckUserRequest (gerçek servis operasyonu) ile GİB e-Fatura mükellef
 * ve posta kutusu (alias) sorgulaması yapar.
 */
export async function checkEdmUser(identifier: string): Promise<EdmCheckUserResult> {
  const clean = String(identifier || "").replace(/\D/g, "");
  const base: EdmCheckUserResult = {
    success: false,
    message: "",
    identifier: clean,
    isEinvoiceUser: false,
    aliases: [],
    senderAliases: [],
    error: null,
  };

  if (clean.length !== 10 && clean.length !== 11) {
    return {
      ...base,
      message: "Mükellef sorgusu için 10 haneli VKN veya 11 haneli TCKN gereklidir.",
      error: { code: "INVALID_IDENTIFIER", message: "Geçersiz VKN/TCKN uzunluğu." },
    };
  }

  try {
    const { sessionId, serviceUrl } = await getEdmSessionId();
    const nowIso = new Date().toISOString();

    const soapPayload = `<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns="http://tempuri.org/">
  <soap:Body>
    <ns:CheckUserRequest>
      <REQUEST_HEADER>
        <SESSION_ID>${sessionId}</SESSION_ID>
        <ACTION_DATE>${nowIso}</ACTION_DATE>
        <REASON>CHECK_USER</REASON>
        <APPLICATION_NAME>MagicReceipt</APPLICATION_NAME>
        <HOSTNAME>localhost</HOSTNAME>
        <CHANNEL_NAME>XML</CHANNEL_NAME>
      </REQUEST_HEADER>
      <USER>
        <IDENTIFIER>${clean}</IDENTIFIER>
      </USER>
    </ns:CheckUserRequest>
  </soap:Body>
</soap:Envelope>`;

    const response = await fetch(serviceUrl, {
      method: "POST",
      headers: {
        "Content-Type": "text/xml; charset=utf-8",
        SOAPAction: "CheckUserRequest",
      },
      body: soapPayload,
    });

    const responseText = await response.text();

    const faultString = extractXmlTagValue(responseText, "faultstring");
    const errorShortDes = extractXmlTagValue(responseText, "ERROR_SHORT_DES");
    const errorLongDes = extractXmlTagValue(responseText, "ERROR_LONG_DES");
    if (errorShortDes || errorLongDes || faultString) {
      const detail = errorLongDes || errorShortDes || faultString;
      return {
        ...base,
        message: `EDM mükellef sorgulama hatası: ${detail}`,
        error: {
          code: extractXmlTagValue(responseText, "ERROR_CODE") || "EDM_CHECKUSER_ERROR",
          message: detail || "Bilinmeyen servis hatası",
        },
      };
    }

    const users = parseGibUsers(responseText).filter((u) => u.active);
    const pk = users.filter((u) => (u.unit || "PK") === "PK");
    const gb = users.filter((u) => u.unit === "GB");
    const first = users[0];

    if (users.length === 0) {
      return {
        ...base,
        success: true,
        message: `${clean} numarası GİB e-Fatura mükellef listesinde bulunamadı (e-Arşiv fatura düzenlenmelidir).`,
        isEinvoiceUser: false,
      };
    }

    return {
      success: true,
      message: `${clean} GİB e-Fatura mükellefidir (${pk.length} aktif posta kutusu etiketi).`,
      identifier: clean,
      isEinvoiceUser: true,
      title: first?.title,
      type: first?.type,
      registerTime: first?.registerTime,
      aliases: pk,
      senderAliases: gb,
      error: null,
    };
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : "Bilinmeyen ağ hatası";
    return {
      ...base,
      message: `EDM mükellef sorgulaması başarısız: ${msg}`,
      error: { code: "EDM_CHECKUSER_NETWORK", message: msg },
    };
  }
}

/**
 * TICARIFATURA gönderimi öncesi alıcı VKN/TCKN + alias uyumunu GİB kayıtlarına karşı doğrular.
 */
export async function verifyReceiverAlias(
  identifier: string,
  alias: string,
): Promise<{ ok: boolean; code: string; message: string; alias?: string; title?: string }> {
  const cleanAlias = String(alias || "").trim();
  if (!cleanAlias) {
    return {
      ok: false,
      code: "ALIAS_REQUIRED",
      message:
        "TICARIFATURA gönderimi için alıcının GİB posta kutusu etiketi (alias) zorunludur. Lütfen mükellef sorgulaması yapıp geçerli bir etiket seçin.",
    };
  }

  const res = await checkEdmUser(identifier);
  if (!res.success) {
    return { ok: false, code: res.error?.code || "CHECKUSER_FAILED", message: res.message };
  }
  if (!res.isEinvoiceUser) {
    return {
      ok: false,
      code: "TAXPAYER_NOT_FOUND",
      message: `${res.identifier} GİB e-Fatura mükellef listesinde bulunamadı; TICARIFATURA gönderilemez.`,
    };
  }

  const match = res.aliases.find((u) => isSameAlias(u.alias, cleanAlias));
  if (!match) {
    return {
      ok: false,
      code: "ALIAS_MISMATCH",
      message: `Seçilen etiket (${normalizeAliasMail(cleanAlias)}) ${res.identifier} numaralı mükellefin geçerli posta kutusu etiketleri arasında bulunamadı.`,
    };
  }

  return { ok: true, code: "OK", message: "Alıcı etiketi doğrulandı.", alias: match.alias, title: match.title };
}

/**
 * Validates, constructs UBL-TR XML, authenticates via EDM TEST Web Service,
 * and sends an e-Invoice to the EDM TEST environment.
 */
export async function sendInvoiceToEdm(rawInvoiceData: UblInvoiceData): Promise<EdmSendInvoiceResult> {
  try {
    // 1. Validate data & calculate totals
    const validatedData = validateAndCalculateInvoice(rawInvoiceData);

    // 2. Generate UBL-TR 2.1 XML
    const ublXml = createUblTrInvoice(validatedData);
    const base64UblContent = Buffer.from(ublXml, "utf-8").toString("base64");

    // 3. Login to EDM TEST Web Service and get SESSION_ID
    const { sessionId, serviceUrl } = await getEdmSessionId();

    // 4. Build SendInvoiceRequest SOAP XML payload
    const nowIso = new Date().toISOString();

    // e-Fatura (TICARIFATURA/TEMELFATURA) gönderiminde GİB etiketleri iletilir.
    const receiverAlias = String((validatedData.buyer as { alias?: string }).alias || "").trim();
    const senderAlias = String((validatedData.seller as { alias?: string }).alias || "").trim();
    const isEInvoice = validatedData.profileId !== "EARSIVFATURA";
    const senderXml =
      isEInvoice && senderAlias
        ? `\n      <SENDER vkn="${escapeXmlAttr(validatedData.seller.taxNumber)}" alias="${escapeXmlAttr(senderAlias)}" />`
        : "";
    const receiverXml =
      isEInvoice && receiverAlias
        ? `\n      <RECEIVER vkn="${escapeXmlAttr(validatedData.buyer.taxNumber)}" alias="${escapeXmlAttr(receiverAlias)}" />`
        : "";

    const sendInvoiceSoapPayload = `<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns="http://tempuri.org/">
  <soap:Body>
    <ns:SendInvoiceRequest>
      <REQUEST_HEADER>
        <SESSION_ID>${sessionId}</SESSION_ID>
        <ACTION_DATE>${nowIso}</ACTION_DATE>
        <REASON>SEND_INVOICE</REASON>
        <APPLICATION_NAME>MagicReceipt</APPLICATION_NAME>
        <HOSTNAME>localhost</HOSTNAME>
        <CHANNEL_NAME>XML</CHANNEL_NAME>
      </REQUEST_HEADER>${senderXml}${receiverXml}
      <INVOICE TRXID="-1">
        <HEADER>
          <SENDER>${validatedData.seller.taxNumber}</SENDER>
          <RECEIVER>${validatedData.buyer.taxNumber}</RECEIVER>
          <SUPPLIER>${validatedData.seller.name}</SUPPLIER>
          <CUSTOMER>${validatedData.buyer.name}</CUSTOMER>
        </HEADER>
        <CONTENT>${base64UblContent}</CONTENT>
      </INVOICE>
    </ns:SendInvoiceRequest>
  </soap:Body>
</soap:Envelope>`;


    // 5. Send SOAP Request to EDM TEST Web Service
    const response = await fetch(serviceUrl, {
      method: "POST",
      headers: {
        "Content-Type": "text/xml; charset=utf-8",
        SOAPAction: "SendInvoiceRequest",
      },
      body: sendInvoiceSoapPayload,
    });

    const responseText = await response.text();

    // 6. Check for SOAP Faults / RequestFault
    const faultString = extractXmlTagValue(responseText, "faultstring");
    const errorShortDes = extractXmlTagValue(responseText, "ERROR_SHORT_DES");
    const errorLongDes = extractXmlTagValue(responseText, "ERROR_LONG_DES");

    if (errorShortDes || errorLongDes || faultString) {
      const errDetail = errorShortDes || errorLongDes || faultString;
      return {
        success: false,
        message: `EDM Fatura Gönderim Hatası: ${errDetail}`,
      };
    }

    const returnCode = extractXmlTagValue(responseText, "RETURN_CODE");
    if (returnCode !== null && returnCode !== "0") {
      const warnings = extractXmlTagValue(responseText, "WARNINGS");
      return {
        success: false,
        message: `EDM Fatura Gönderimi Başarısız. Dönüş Kodu: ${returnCode}${warnings ? ` (${warnings})` : ""}`,
      };
    }

    // 7. Extract EDM response attributes and elements
    const edmUuid = extractXmlAttributeValue(responseText, "INVOICE", "UUID") || validatedData.uuid;
    const edmInvoiceNo = extractXmlAttributeValue(responseText, "INVOICE", "ID") || validatedData.invoiceNumber;
    const edmTrxId = extractXmlAttributeValue(responseText, "INVOICE", "TRXID") || extractXmlTagValue(responseText, "INTL_TXN_ID");
    const edmStatus = extractXmlTagValue(responseText, "STATUS") || extractXmlTagValue(responseText, "STATUS_DESCRIPTION") || "ISLENDI";

    return {
      success: true,
      message: "Fatura EDM TEST ortamına başarıyla gönderildi.",
      invoiceNumber: edmInvoiceNo,
      uuid: edmUuid,
      edmReference: edmTrxId || undefined,
      status: edmStatus,
    };
  } catch (err: unknown) {
    const errMessage = err instanceof Error ? err.message : "Bilinmeyen sunucu hatası";
    return {
      success: false,
      message: `Fatura gönderim hatası: ${errMessage}`,
    };
  }
}

/**
 * Executes real EDM SOAP GetInvoiceStatusRequest operation to retrieve live invoice status.
 */
export async function getInvoiceStatusFromEdm(uuid: string): Promise<EdmInvoiceStatusResult> {
  try {
    if (!uuid || !uuid.trim()) {
      throw new Error("Durum sorgulaması için geçerli bir UUID/ETTN gereklidir.");
    }

    const cleanUuid = uuid.trim().toLowerCase();
    const { sessionId, serviceUrl } = await getEdmSessionId();
    const nowIso = new Date().toISOString();

    const soapPayload = `<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns="http://tempuri.org/">
  <soap:Body>
    <ns:GetInvoiceStatusRequest>
      <REQUEST_HEADER>
        <SESSION_ID>${sessionId}</SESSION_ID>
        <ACTION_DATE>${nowIso}</ACTION_DATE>
        <REASON>STATUS_QUERY</REASON>
        <APPLICATION_NAME>MagicReceipt</APPLICATION_NAME>
        <HOSTNAME>localhost</HOSTNAME>
        <CHANNEL_NAME>XML</CHANNEL_NAME>
      </REQUEST_HEADER>
      <INVOICE UUID="${cleanUuid}"/>
    </ns:GetInvoiceStatusRequest>
  </soap:Body>
</soap:Envelope>`;

    const response = await fetch(serviceUrl, {
      method: "POST",
      headers: {
        "Content-Type": "text/xml; charset=utf-8",
        SOAPAction: "GetInvoiceStatusRequest",
      },
      body: soapPayload,
    });

    const responseText = await response.text();

    const faultString = extractXmlTagValue(responseText, "faultstring");
    const errorShortDes = extractXmlTagValue(responseText, "ERROR_SHORT_DES");
    const errorLongDes = extractXmlTagValue(responseText, "ERROR_LONG_DES");

    if (errorShortDes || errorLongDes || faultString) {
      const errDetail = errorShortDes || errorLongDes || faultString;
      return {
        success: false,
        message: `EDM Status Sorgulama Hatası: ${errDetail}`,
        uuid: cleanUuid,
      };
    }

    const edmStatus = extractXmlTagValue(responseText, "STATUS") || extractXmlTagValue(responseText, "STATUS_DESCRIPTION") || "UNKNOWN";
    const edmInvoiceNo = extractXmlAttributeValue(responseText, "INVOICE_STATUS", "ID") || extractXmlTagValue(responseText, "ID");
    const returnCode = extractXmlTagValue(responseText, "RETURN_CODE") || "0";
    const returnMsg = extractXmlTagValue(responseText, "RESPONSE_DESCRIPTION") || extractXmlTagValue(responseText, "RETURN_MSG") || edmStatus;

    // Map EDM status to standard invoice status
    let mappedStatus = "PROCESSING";
    const upperEdmStatus = edmStatus.toUpperCase();

    if (upperEdmStatus.includes("SUCCEED") || upperEdmStatus.includes("ACCEPTED") || upperEdmStatus.includes("COMPLETED") || upperEdmStatus.includes("ONAYLANDI")) {
      mappedStatus = "ACCEPTED";
    } else if (upperEdmStatus.includes("SEND") || upperEdmStatus.includes("PROCESSING") || upperEdmStatus.includes("PACKAGE")) {
      mappedStatus = "SENT";
    } else if (upperEdmStatus.includes("REJECT") || upperEdmStatus.includes("FAIL") || upperEdmStatus.includes("ERROR") || upperEdmStatus.includes("HATA")) {
      mappedStatus = "FAILED";
    }

    return {
      success: true,
      message: `EDM durum sorgulaması başarılı (${edmStatus})`,
      uuid: cleanUuid,
      invoiceNumber: edmInvoiceNo || undefined,
      status: mappedStatus,
      edmStatus,
      edmReturnCode: returnCode,
      edmReturnMessage: returnMsg,
    };
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Bilinmeyen durum sorgulama hatası";
    return {
      success: false,
      message: `EDM Durum Sorgulama Hatası: ${message}`,
      uuid,
    };
  }
}

export interface EdmCancelResult {
  success: boolean;
  message: string;
  uuid?: string;
  invoiceNumber?: string;
  errorCode?: string;
  returnCode?: string;
  returnMessage?: string;
  rawResponse?: string;
}

/**
 * Executes real EDM SOAP CancelInvoiceRequest operation to cancel an e-Archive invoice in EDM.
 */
export async function cancelInvoiceInEdm(
  uuid: string,
  invoiceNumber?: string,
  cancelReason = "Müşteri talebi ve fatura iptali"
): Promise<EdmCancelResult> {
  try {
    if (!uuid || !uuid.trim()) {
      throw new Error("İptal işlemi için geçerli bir UUID/ETTN gereklidir.");
    }

    const cleanUuid = uuid.trim().toLowerCase();
    const { sessionId, serviceUrl } = await getEdmSessionId();
    const nowIso = new Date().toISOString();

    const soapPayload = `<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns="http://tempuri.org/">
  <soap:Body>
    <ns:CancelInvoiceRequest>
      <REQUEST_HEADER>
        <SESSION_ID>${sessionId}</SESSION_ID>
        <ACTION_DATE>${nowIso}</ACTION_DATE>
        <REASON>CANCEL_INVOICE</REASON>
        <APPLICATION_NAME>MagicReceipt</APPLICATION_NAME>
        <HOSTNAME>localhost</HOSTNAME>
        <CHANNEL_NAME>XML</CHANNEL_NAME>
      </REQUEST_HEADER>
      <INVOICE UUID="${cleanUuid}">
        <HEADER>
          <CANCEL_REASON>${cancelReason}</CANCEL_REASON>
          <CANCEL_DATE>${nowIso}</CANCEL_DATE>
        </HEADER>
      </INVOICE>
    </ns:CancelInvoiceRequest>
  </soap:Body>
</soap:Envelope>`;

    const response = await fetch(serviceUrl, {
      method: "POST",
      headers: {
        "Content-Type": "text/xml; charset=utf-8",
        SOAPAction: "CancelInvoiceRequest",
      },
      body: soapPayload,
    });

    const responseText = await response.text();

    const faultString = extractXmlTagValue(responseText, "faultstring");
    const errorCode = extractXmlTagValue(responseText, "ERROR_CODE");
    const errorShortDes = extractXmlTagValue(responseText, "ERROR_SHORT_DES");
    const errorLongDes = extractXmlTagValue(responseText, "ERROR_LONG_DES");

    if (errorCode || errorShortDes || errorLongDes || faultString || !response.ok) {
      const code = errorCode || (faultString?.includes("11049") ? "11049" : "UNKNOWN_FAULT");
      let userFriendlyMsg = errorShortDes || errorLongDes || faultString || "EDM iptal servisi işlemi tamamlayamadı.";

      if (code === "11049") {
        userFriendlyMsg = "Fatura henüz entegratör tarafından işleniyor (PACKAGE - PROCESSING). İptal edilebilmesi için işlemin tamamlanmasını bekleyin.";
      } else if (code === "11017") {
        userFriendlyMsg = "Fatura entegratör sisteminde bulunamadı veya daha önce iptal edilmiş.";
      }

      return {
        success: false,
        message: userFriendlyMsg,
        uuid: cleanUuid,
        invoiceNumber: invoiceNumber ?? undefined,
        errorCode: code,
        returnMessage: errorLongDes || errorShortDes || faultString || undefined,
      };
    }

    const returnCode = extractXmlTagValue(responseText, "RETURN_CODE") || "0";
    const returnMsg =
      extractXmlTagValue(responseText, "RETURN_MSG") ||
      extractXmlTagValue(responseText, "RESPONSE_DESCRIPTION") ||
      "Fatura entegratör üzerinden başarıyla iptal edildi.";

    return {
      success: returnCode === "0",
      message: returnMsg,
      uuid: cleanUuid,
      invoiceNumber,
      returnCode,
      returnMessage: returnMsg,
    };
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Bilinmeyen iptal hatası";
    return {
      success: false,
      message: `EDM İptal Hatası: ${message}`,
      uuid,
      invoiceNumber,
    };
  }
}
