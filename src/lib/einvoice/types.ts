/**
 * Domain-agnostic e-Invoice Abstraction Layer Types
 * Allows supporting EDM Bilişim, API Key, and OAuth e-Invoice providers seamlessly.
 */

export interface EInvoiceParty {
  taxNumber: string; // VKN (10 digits) or TCKN (11 digits)
  name: string;
  taxOffice?: string;
  address?: string;
  district?: string;
  city?: string;
}

export interface EInvoiceLine {
  name: string;
  quantity: number;
  unitPrice: number;
  vatRate: number; // e.g. 0, 1, 10, 20
  unitCode?: string; // e.g. "C62" (adet), "KGM" (kg)
}

export interface EInvoiceData {
  uuid?: string;
  invoiceNumber?: string;
  issueDate?: string; // YYYY-MM-DD
  issueTime?: string; // HH:mm:ss
  currency?: string; // default "TRY"
  profileId?: "EARSIVFATURA" | "TICARIFATURA" | "TEMELFATURA";
  invoiceTypeCode?: "SATIS" | "IADE" | "TEVKIFAT" | "ISTISNA";
  seller: EInvoiceParty;
  buyer: EInvoiceParty;
  lines: EInvoiceLine[];
  note?: string;
}

export interface EInvoiceResult {
  success: boolean;
  message: string;
  invoiceNumber?: string;
  uuid?: string;
  providerReference?: string;
  status?: string;
  data?: Record<string, any> | null;
  error?: { code: string; message: string } | null;
}

export interface IEInvoiceProvider {
  readonly providerId: string;
  readonly providerName: string;
  testConnection(): Promise<{ success: boolean; message: string }>;
  sendInvoice(data: EInvoiceData): Promise<EInvoiceResult>;
  getInvoiceStatus(uuid: string): Promise<EInvoiceResult>;
}
