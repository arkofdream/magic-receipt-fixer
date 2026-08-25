import { randomUUID } from "node:crypto";

export interface UblParty {
  taxNumber: string; // VKN (10 digits) or TCKN (11 digits)
  name: string;
  taxOffice?: string;
  address?: string;
  district?: string;
  city?: string;
}

export interface UblInvoiceLine {
  name: string;
  quantity: number;
  unitPrice: number;
  vatRate: number; // e.g. 0, 1, 10, 20
  unitCode?: string; // e.g. "C62" for adet, "KGM" for kg
}

export interface UblInvoiceData {
  uuid?: string;
  invoiceNumber?: string;
  issueDate?: string; // YYYY-MM-DD
  issueTime?: string; // HH:mm:ss
  currency?: string; // default "TRY"
  profileId?: "EARSIVFATURA" | "TICARIFATURA" | "TEMELFATURA";
  invoiceTypeCode?: "SATIS" | "IADE" | "TEVKIFAT" | "ISTISNA";
  seller: UblParty;
  buyer: UblParty;
  lines: UblInvoiceLine[];
  note?: string;
}

export interface VatGroupSummary {
  vatRate: number;
  taxableAmount: number;
  taxAmount: number;
}

export interface ValidatedUblData {
  uuid: string;
  invoiceNumber: string;
  issueDate: string;
  issueTime: string;
  currency: string;
  profileId: string;
  invoiceTypeCode: string;
  seller: UblParty;
  buyer: UblParty;
  lines: UblInvoiceLine[];
  vatGroups: VatGroupSummary[];
  subTotal: number;
  taxTotal: number;
  grandTotal: number;
  note?: string;
}

const UUID_V4_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/**
 * Decimal rounding helper to prevent JavaScript floating-point errors.
 * e.g., roundDecimal(33.333333, 2) -> 33.33
 */
export function roundDecimal(value: number, decimals: number = 2): number {
  if (isNaN(value) || !isFinite(value)) return 0;
  const factor = Math.pow(10, decimals);
  return Math.round((value + Number.EPSILON) * factor) / factor;
}

/**
 * Validates tax numbers (VKN 10 digits, TCKN 11 digits).
 */
export function validateTaxNumberFormat(taxNumber: string, partyLabel: string): { taxNumber: string; schemeId: "VKN" | "TCKN" } {
  if (!taxNumber || typeof taxNumber !== "string" || !taxNumber.trim()) {
    throw new Error(`Fatura doğrulaması başarısız: ${partyLabel} VKN/TCKN alanı boş olamaz.`);
  }

  const clean = taxNumber.trim();

  if (!/^\d+$/.test(clean)) {
    throw new Error(`Fatura doğrulaması başarısız: ${partyLabel} VKN/TCKN yalnızca rakamlardan oluşmalıdır ("${clean}").`);
  }

  if (clean.length === 10) {
    return { taxNumber: clean, schemeId: "VKN" };
  } else if (clean.length === 11) {
    return { taxNumber: clean, schemeId: "TCKN" };
  } else {
    throw new Error(`Fatura doğrulaması başarısız: ${partyLabel} VKN 10 hane veya TCKN 11 hane olmalıdır (Girilen: ${clean.length} hane).`);
  }
}

/**
 * Validates invoice payload, calculates accurate tax totals grouped by VAT rate,
 * and handles precise decimal rounding.
 */
export function validateAndCalculateInvoice(data: UblInvoiceData): ValidatedUblData {
  if (!data.seller) {
    throw new Error("Fatura doğrulaması başarısız: Satıcı bilgileri eksik.");
  }
  if (!data.seller.name || !data.seller.name.trim()) {
    throw new Error("Fatura doğrulaması başarısız: Satıcı unvanı boş olamaz.");
  }
  validateTaxNumberFormat(data.seller.taxNumber, "Satıcı");

  if (!data.buyer) {
    throw new Error("Fatura doğrulaması başarısız: Alıcı bilgileri eksik.");
  }
  if (!data.buyer.name || !data.buyer.name.trim()) {
    throw new Error("Fatura doğrulaması başarısız: Alıcı unvanı boş olamaz.");
  }
  validateTaxNumberFormat(data.buyer.taxNumber, "Alıcı");

  if (!data.lines || !Array.isArray(data.lines) || data.lines.length === 0) {
    throw new Error("Fatura doğrulaması başarısız: En az 1 fatura kalemi (ürün/hizmet) girmelisiniz.");
  }

  const vatMap = new Map<number, { taxableAmount: number; taxAmount: number }>();
  let subTotal = 0;
  let taxTotal = 0;

  for (let i = 0; i < data.lines.length; i++) {
    const line = data.lines[i];
    if (!line.name || !line.name.trim()) {
      throw new Error(`Fatura doğrulaması başarısız: Kalem #${i + 1} için ürün/hizmet adı boş olamaz.`);
    }
    if (typeof line.quantity !== "number" || isNaN(line.quantity) || line.quantity <= 0) {
      throw new Error(`Fatura doğrulaması başarısız: Kalem #${i + 1} ("${line.name}") miktarı 0'dan büyük olmalıdır.`);
    }
    if (typeof line.unitPrice !== "number" || isNaN(line.unitPrice) || line.unitPrice < 0) {
      throw new Error(`Fatura doğrulaması başarısız: Kalem #${i + 1} ("${line.name}") birim fiyatı 0 veya daha büyük olmalıdır.`);
    }
    if (typeof line.vatRate !== "number" || isNaN(line.vatRate) || line.vatRate < 0 || line.vatRate > 100) {
      throw new Error(`Fatura doğrulaması başarısız: Kalem #${i + 1} ("${line.name}") KDV oranı %0 ile %100 arasında olmalıdır.`);
    }

    const lineExtension = roundDecimal(line.quantity * line.unitPrice, 2);
    const lineVat = roundDecimal(lineExtension * (line.vatRate / 100), 2);

    subTotal += lineExtension;
    taxTotal += lineVat;

    const existingGroup = vatMap.get(line.vatRate) || { taxableAmount: 0, taxAmount: 0 };
    vatMap.set(line.vatRate, {
      taxableAmount: roundDecimal(existingGroup.taxableAmount + lineExtension, 2),
      taxAmount: roundDecimal(existingGroup.taxAmount + lineVat, 2),
    });
  }

  subTotal = roundDecimal(subTotal, 2);
  taxTotal = roundDecimal(taxTotal, 2);
  const grandTotal = roundDecimal(subTotal + taxTotal, 2);

  const vatGroups: VatGroupSummary[] = Array.from(vatMap.entries()).map(([vatRate, group]) => ({
    vatRate,
    taxableAmount: group.taxableAmount,
    taxAmount: group.taxAmount,
  }));

  const now = new Date();

  let uuid = data.uuid ? data.uuid.trim().toLowerCase() : "";
  if (uuid) {
    if (!UUID_V4_REGEX.test(uuid)) {
      throw new Error(`Fatura doğrulaması başarısız: Geçersiz UUID formatı ("${uuid}").`);
    }
  } else {
    uuid = randomUUID().toLowerCase();
  }

  let invoiceNumber = (data.invoiceNumber || "").trim();
  if (invoiceNumber) {
    const INVOICE_NUMBER_REGEX = /^[A-Za-z0-9]{3}(?:19|20)\d{2}\d{9}$/;
    if (!INVOICE_NUMBER_REGEX.test(invoiceNumber)) {
      throw new Error(
        `Fatura doğrulaması başarısız: Geçersiz fatura numarası formatı ("${invoiceNumber}"). Fatura numarası 3 hane seri ön eki, 4 hane yıl ve 9 hane sıra numarasından (toplam 16 karakter) oluşmalıdır (Örn: EAR2026000000001).`
      );
    }
  } else {
    invoiceNumber = "MRF" + now.getFullYear() + String(Date.now()).slice(-9);
  }

  const issueDate = data.issueDate || now.toISOString().slice(0, 10);
  const issueTime = data.issueTime || now.toISOString().slice(11, 19);

  return {
    uuid,
    invoiceNumber,
    issueDate,
    issueTime,
    currency: (data.currency || "TRY").toUpperCase(),
    profileId: data.profileId || "EARSIVFATURA",
    invoiceTypeCode: data.invoiceTypeCode || "SATIS",
    seller: {
      ...data.seller,
      taxNumber: data.seller.taxNumber.trim(),
    },
    buyer: {
      ...data.buyer,
      taxNumber: data.buyer.taxNumber.trim(),
    },
    lines: data.lines,
    vatGroups,
    subTotal,
    taxTotal,
    grandTotal,
    note: data.note,
  };
}

/**
 * Generates GİB UBL-TR 2.1 compliant XML content.
 */
export function createUblTrInvoice(data: UblInvoiceData): string {
  const validated = validateAndCalculateInvoice(data);

  const sellerSchemeId = validated.seller.taxNumber.length === 11 ? "TCKN" : "VKN";
  const buyerSchemeId = validated.buyer.taxNumber.length === 11 ? "TCKN" : "VKN";

  const noteXml = validated.note
    ? `<cbc:Note>${escapeXml(validated.note)}</cbc:Note>`
    : "";

  const vatSubtotalsXml = validated.vatGroups
    .map(
      (group) => `
    <cac:TaxSubtotal>
      <cbc:TaxableAmount currencyID="${validated.currency}">${group.taxableAmount.toFixed(2)}</cbc:TaxableAmount>
      <cbc:TaxAmount currencyID="${validated.currency}">${group.taxAmount.toFixed(2)}</cbc:TaxAmount>
      <cbc:Percent>${group.vatRate}</cbc:Percent>
      <cac:TaxCategory>
        <cac:TaxScheme>
          <cbc:Name>KDV</cbc:Name>
          <cbc:TaxTypeCode>0015</cbc:TaxTypeCode>
        </cac:TaxScheme>
      </cac:TaxCategory>
    </cac:TaxSubtotal>`
    )
    .join("");

  return `<?xml version="1.0" encoding="UTF-8"?>
<Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"
         xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
         xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2"
         xmlns:ext="urn:oasis:names:specification:ubl:schema:xsd:CommonExtensionComponents-2">
  <cbc:UBLVersionID>2.1</cbc:UBLVersionID>
  <cbc:CustomizationID>TR1.2</cbc:CustomizationID>
  <cbc:ProfileID>${validated.profileId}</cbc:ProfileID>
  <cbc:ID>${validated.invoiceNumber}</cbc:ID>
  <cbc:CopyIndicator>false</cbc:CopyIndicator>
  <cbc:UUID>${validated.uuid}</cbc:UUID>
  <cbc:IssueDate>${validated.issueDate}</cbc:IssueDate>
  <cbc:IssueTime>${validated.issueTime}</cbc:IssueTime>
  <cbc:InvoiceTypeCode>${validated.invoiceTypeCode}</cbc:InvoiceTypeCode>
  ${noteXml}
  <cbc:DocumentCurrencyCode>${validated.currency}</cbc:DocumentCurrencyCode>
  <cbc:LineCountNumeric>${validated.lines.length}</cbc:LineCountNumeric>

  <cac:AccountingSupplierParty>
    <cac:Party>
      <cac:PartyIdentification>
        <cbc:ID schemeID="${sellerSchemeId}">${validated.seller.taxNumber}</cbc:ID>
      </cac:PartyIdentification>
      <cac:PartyName>
        <cbc:Name>${escapeXml(validated.seller.name)}</cbc:Name>
      </cac:PartyName>
      <cac:PostalAddress>
        <cbc:StreetName>${escapeXml(validated.seller.address || "Adres Belirtilmedi")}</cbc:StreetName>
        <cbc:CitySubdivisionName>${escapeXml(validated.seller.district || "Merkez")}</cbc:CitySubdivisionName>
        <cbc:CityName>${escapeXml(validated.seller.city || "İstanbul")}</cbc:CityName>
        <cac:Country>
          <cbc:Name>Türkiye</cbc:Name>
        </cac:Country>
      </cac:PostalAddress>
      ${validated.seller.taxOffice ? `<cac:PartyTaxScheme><cac:TaxScheme><cbc:Name>${escapeXml(validated.seller.taxOffice)}</cbc:Name></cac:TaxScheme></cac:PartyTaxScheme>` : ""}
    </cac:Party>
  </cac:AccountingSupplierParty>

  <cac:AccountingCustomerParty>
    <cac:Party>
      <cac:PartyIdentification>
        <cbc:ID schemeID="${buyerSchemeId}">${validated.buyer.taxNumber}</cbc:ID>
      </cac:PartyIdentification>
      <cac:PartyName>
        <cbc:Name>${escapeXml(validated.buyer.name)}</cbc:Name>
      </cac:PartyName>
      <cac:PostalAddress>
        <cbc:StreetName>${escapeXml(validated.buyer.address || "Adres Belirtilmedi")}</cbc:StreetName>
        <cbc:CitySubdivisionName>${escapeXml(validated.buyer.district || "Merkez")}</cbc:CitySubdivisionName>
        <cbc:CityName>${escapeXml(validated.buyer.city || "Ankara")}</cbc:CityName>
        <cac:Country>
          <cbc:Name>Türkiye</cbc:Name>
        </cac:Country>
      </cac:PostalAddress>
      ${validated.buyer.taxOffice ? `<cac:PartyTaxScheme><cac:TaxScheme><cbc:Name>${escapeXml(validated.buyer.taxOffice)}</cbc:Name></cac:TaxScheme></cac:PartyTaxScheme>` : ""}
    </cac:Party>
  </cac:AccountingCustomerParty>

  <cac:TaxTotal>
    <cbc:TaxAmount currencyID="${validated.currency}">${validated.taxTotal.toFixed(2)}</cbc:TaxAmount>${vatSubtotalsXml}
  </cac:TaxTotal>

  <cac:LegalMonetaryTotal>
    <cbc:LineExtensionAmount currencyID="${validated.currency}">${validated.subTotal.toFixed(2)}</cbc:LineExtensionAmount>
    <cbc:TaxExclusiveAmount currencyID="${validated.currency}">${validated.subTotal.toFixed(2)}</cbc:TaxExclusiveAmount>
    <cbc:TaxInclusiveAmount currencyID="${validated.currency}">${validated.grandTotal.toFixed(2)}</cbc:TaxInclusiveAmount>
    <cbc:AllowanceTotalAmount currencyID="${validated.currency}">0.00</cbc:AllowanceTotalAmount>
    <cbc:PayableAmount currencyID="${validated.currency}">${validated.grandTotal.toFixed(2)}</cbc:PayableAmount>
  </cac:LegalMonetaryTotal>

  ${validated.lines
    .map((line, idx) => {
      const lineExtension = roundDecimal(line.quantity * line.unitPrice, 2);
      const lineVat = roundDecimal(lineExtension * (line.vatRate / 100), 2);
      const unitCode = line.unitCode || "C62";
      return `
  <cac:InvoiceLine>
    <cbc:ID>${idx + 1}</cbc:ID>
    <cbc:InvoicedQuantity unitCode="${unitCode}">${line.quantity}</cbc:InvoicedQuantity>
    <cbc:LineExtensionAmount currencyID="${validated.currency}">${lineExtension.toFixed(2)}</cbc:LineExtensionAmount>
    <cac:TaxTotal>
      <cbc:TaxAmount currencyID="${validated.currency}">${lineVat.toFixed(2)}</cbc:TaxAmount>
      <cac:TaxSubtotal>
        <cbc:TaxableAmount currencyID="${validated.currency}">${lineExtension.toFixed(2)}</cbc:TaxableAmount>
        <cbc:TaxAmount currencyID="${validated.currency}">${lineVat.toFixed(2)}</cbc:TaxAmount>
        <cbc:Percent>${line.vatRate}</cbc:Percent>
        <cac:TaxCategory>
          <cac:TaxScheme>
            <cbc:Name>KDV</cbc:Name>
            <cbc:TaxTypeCode>0015</cbc:TaxTypeCode>
          </cac:TaxScheme>
        </cac:TaxCategory>
      </cac:TaxSubtotal>
    </cac:TaxTotal>
    <cac:Item>
      <cbc:Name>${escapeXml(line.name)}</cbc:Name>
    </cac:Item>
    <cac:Price>
      <cbc:PriceAmount currencyID="${validated.currency}">${line.unitPrice.toFixed(2)}</cbc:PriceAmount>
    </cac:Price>
  </cac:InvoiceLine>`;
    })
    .join("")}
</Invoice>`;
}

function escapeXml(str: string): string {
  if (!str) return "";
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}
