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

const DEFAULT_EDM_LIVE_URL = "https://portal2.edmbilisim.com.tr/EFaturaEDM/EFaturaEDM.svc";

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
 * Resolves EDM live production credentials.
 * Accepts dynamic credentials or falls back to environment variables.
 */
export function resolveEdmConfig(customCredentials?: {
  username?: string;
  password?: string;
  serviceUrl?: string;
}): { username: string; password: string; serviceUrl: string } {
  const username = (customCredentials?.username || process.env.EDM_PROD_USERNAME || "").trim();
  const password = (customCredentials?.password || process.env.EDM_PROD_PASSWORD || "").trim();
  const serviceUrl = (customCredentials?.serviceUrl || process.env.EDM_PROD_SERVICE_URL || DEFAULT_EDM_LIVE_URL).trim();

  if (!username || !password) {
    throw new Error("EDM Bilişim yetkilendirme hatası: Müşteri kullanıcı adı veya şifresi girilmelidir.");
  }

  return { username, password, serviceUrl };
}

/**
 * Performs EDM Login on server-side and returns the raw SESSION_ID string.
 * Internal server helper.
 */
export async function getEdmSessionId(customCredentials?: {
  username?: string;
  password?: string;
  serviceUrl?: string;
}): Promise<{ sessionId: string; serviceUrl: string }> {
  const { username, password, serviceUrl } = resolveEdmConfig(customCredentials);

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

  return { sessionId, serviceUrl };
}

/**
 * Performs EDM Login test on the server-side for EDM Live service.
 */
export async function testEdmConnection(customCredentials?: {
  username?: string;
  password?: string;
  serviceUrl?: string;
}): Promise<EdmConnectionTestResult> {
  try {
    const { sessionId } = await getEdmSessionId(customCredentials);
    return {
      success: true,
      message: "EDM Bilişim canlı bağlantısı başarılı.",
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

/**
 * Validates, constructs UBL-TR XML, authenticates via EDM Web Service,
 * and sends an e-Invoice to the EDM production environment.
 */
export async function sendInvoiceToEdm(
  rawInvoiceData: UblInvoiceData,
  customCredentials?: {
    username?: string;
    password?: string;
    serviceUrl?: string;
  }
): Promise<EdmSendInvoiceResult> {
  try {
    // 1. Validate data & calculate totals
    const validatedData = validateAndCalculateInvoice(rawInvoiceData);

    // 2. Generate UBL-TR 2.1 XML
    const ublXml = createUblTrInvoice(validatedData);
    const base64UblContent = Buffer.from(ublXml, "utf-8").toString("base64");

    // 3. Login to EDM Web Service and get SESSION_ID
    const { sessionId, serviceUrl } = await getEdmSessionId(customCredentials);

    // 4. Build SendInvoiceRequest SOAP XML payload
    const nowIso = new Date().toISOString();
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
      </REQUEST_HEADER>
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

    // 5. Send SOAP Request to EDM Web Service
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
      message: "Fatura EDM canlı servisine başarıyla gönderildi.",
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
export async function getInvoiceStatusFromEdm(
  uuid: string,
  customCredentials?: {
    username?: string;
    password?: string;
    serviceUrl?: string;
  }
): Promise<EdmInvoiceStatusResult> {
  try {
    if (!uuid || !uuid.trim()) {
      throw new Error("Durum sorgulaması için geçerli bir UUID/ETTN gereklidir.");
    }

    const cleanUuid = uuid.trim().toLowerCase();
    const { sessionId, serviceUrl } = await getEdmSessionId(customCredentials);
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
  cancelReason = "Müşteri talebi ve fatura iptali",
  customCredentials?: {
    username?: string;
    password?: string;
    serviceUrl?: string;
  }
): Promise<EdmCancelResult> {
  try {
    if (!uuid || !uuid.trim()) {
      throw new Error("İptal işlemi için geçerli bir UUID/ETTN gereklidir.");
    }

    const cleanUuid = uuid.trim().toLowerCase();
    const { sessionId, serviceUrl } = await getEdmSessionId(customCredentials);
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
        invoiceNumber,
        errorCode: code,
        returnMessage: errorLongDes || errorShortDes || faultString,
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
