export type InvoiceItem = {
  id: string;
  name: string;
  unit: string;
  quantity: number;
  unitPrice: number;
  discountRate: number;
  vatRate: number;
};

export type InvoiceCustomer = {
  vknTckn: string;
  title: string;
  taxOffice: string;
  address: string;
  city: string;
  district: string;
  neighborhood: string;
  email: string;
  phone: string;
};

export const emptyCustomer: InvoiceCustomer = {
  vknTckn: "",
  title: "",
  taxOffice: "",
  address: "",
  city: "",
  district: "",
  neighborhood: "",
  email: "",
  phone: "",
};

export const INVOICE_TYPES = [
  { value: "SATIS", label: "Satış Faturası" },
  { value: "IADE", label: "İade Faturası" },
  { value: "TEVKIFAT", label: "Tevkifatlı Fatura" },
  { value: "ISTISNA", label: "İstisna Faturası" },
] as const;

export const INVOICE_STATUSES: Record<string, { label: string; tone: "draft" | "sent" | "cancel" }> = {
  TASLAK: { label: "Taslak", tone: "draft" },
  ONAYLANDI: { label: "GİB'e İletildi", tone: "sent" },
  IPTAL: { label: "İptal", tone: "cancel" },
};

export function newItem(): InvoiceItem {
  return {
    id: crypto.randomUUID(),
    name: "",
    unit: "Adet",
    quantity: 1,
    unitPrice: 0,
    discountRate: 0,
    vatRate: 20,
  };
}

export function itemTotals(item: InvoiceItem) {
  const gross = item.quantity * item.unitPrice;
  const discount = (gross * item.discountRate) / 100;
  const taxable = gross - discount;
  const vat = (taxable * item.vatRate) / 100;
  return { gross, discount, taxable, vat, total: taxable + vat };
}

export function invoiceTotals(items: InvoiceItem[]) {
  return items.reduce(
    (acc, item) => {
      const t = itemTotals(item);
      acc.subtotal += t.gross;
      acc.totalDiscount += t.discount;
      acc.taxableAmount += t.taxable;
      acc.totalVat += t.vat;
      acc.grandTotal += t.total;
      return acc;
    },
    { subtotal: 0, totalDiscount: 0, taxableAmount: 0, totalVat: 0, grandTotal: 0 },
  );
}

export function formatMoney(value: number, currency = "TRY") {
  return new Intl.NumberFormat("tr-TR", {
    style: "currency",
    currency,
    minimumFractionDigits: 2,
  }).format(Number.isFinite(value) ? value : 0);
}

export function formatDate(value: string) {
  if (!value) return "-";
  return new Intl.DateTimeFormat("tr-TR").format(new Date(value));
}

export function generateEttn() {
  return crypto.randomUUID().toUpperCase();
}

export function generateInvoiceNumber(count: number) {
  const year = new Date().getFullYear();
  return `GIB${year}${String(count + 1).padStart(9, "0")}`;
}
