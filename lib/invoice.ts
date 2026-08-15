export type InvoiceItem = {
  id: string;
  productId?: string;
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

export const INVOICE_STATUSES: Record<
  string,
  { label: string; tone: "draft" | "sent" | "cancel" }
> = {
  TASLAK: { label: "Taslak", tone: "draft" },
  ONAYLANDI: { label: "GİB'e İletildi", tone: "sent" },
  IPTAL: { label: "İptal", tone: "cancel" },
};

export const TEVKIFAT_RATES = [
  { value: "0", label: "Tevkifatsız (%0)" },
  { value: "20", label: "2/10 (%20)" },
  { value: "30", label: "3/10 (%30)" },
  { value: "40", label: "4/10 (%40)" },
  { value: "50", label: "5/10 (%50)" },
  { value: "70", label: "7/10 (%70)" },
  { value: "90", label: "9/10 (%90)" },
  { value: "100", label: "Tam Tevkifat (%100)" },
] as const;

export const CURRENCY_OPTIONS = [
  { code: "TRY", symbol: "₺", label: "Türk Lirası (TRY)" },
  { code: "USD", symbol: "$", label: "Amerikan Doları (USD)" },
  { code: "EUR", symbol: "€", label: "Euro (EUR)" },
  { code: "GBP", symbol: "£", label: "İngiliz Sterlini (GBP)" },
] as const;

/** Hassas kuruş/ondalık yuvarlama (Banker's/Commercial precision rounding). */
export function roundDecimals(value: number, decimals = 2): number {
  if (!Number.isFinite(value)) return 0;
  const factor = Math.pow(10, decimals);
  return Math.round((value + Number.EPSILON) * factor) / factor;
}

export function roundMoney(amount: number): number {
  return roundDecimals(amount, 2);
}

export function newItem(): InvoiceItem {
  return {
    id: crypto.randomUUID(),
    productId: "",
    name: "",
    unit: "Adet",
    quantity: 1,
    unitPrice: 0,
    discountRate: 0,
    vatRate: 20,
  };
}

export function itemTotals(item: InvoiceItem) {
  const qty = Math.max(0, Number(item.quantity) || 0);
  const price = Math.max(0, Number(item.unitPrice) || 0);
  const discountRate = Math.min(100, Math.max(0, Number(item.discountRate) || 0));
  const vatRate = Math.max(0, Number(item.vatRate) || 0);

  const gross = roundMoney(qty * price);
  const discount = roundMoney((gross * discountRate) / 100);
  const taxable = roundMoney(gross - discount);
  const vat = roundMoney((taxable * vatRate) / 100);
  const total = roundMoney(taxable + vat);

  return { gross, discount, taxable, vat, total };
}

export function invoiceTotals(items: InvoiceItem[], tevkifatRate = 0) {
  let subtotal = 0;
  let totalDiscount = 0;
  let taxableAmount = 0;
  let totalVat = 0;

  for (const item of items) {
    const t = itemTotals(item);
    subtotal = roundMoney(subtotal + t.gross);
    totalDiscount = roundMoney(totalDiscount + t.discount);
    taxableAmount = roundMoney(taxableAmount + t.taxable);
    totalVat = roundMoney(totalVat + t.vat);
  }

  const validTevkifatRate = Math.min(100, Math.max(0, Number(tevkifatRate) || 0));
  const totalTevkifat = roundMoney((totalVat * validTevkifatRate) / 100);
  const grandTotal = roundMoney(taxableAmount + totalVat - totalTevkifat);

  return {
    subtotal,
    totalDiscount,
    taxableAmount,
    totalVat,
    totalTevkifat,
    grandTotal,
  };
}

export function formatMoney(value: number, currency = "TRY") {
  const safeVal = Number.isFinite(value) ? value : 0;
  try {
    return new Intl.NumberFormat("tr-TR", {
      style: "currency",
      currency: currency || "TRY",
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    }).format(safeVal);
  } catch {
    return `${safeVal.toFixed(2)} ${currency || "TRY"}`;
  }
}

export function formatDate(value: string | null | undefined) {
  if (!value) return "-";
  try {
    const date = new Date(value);
    if (isNaN(date.getTime())) return "-";
    return new Intl.DateTimeFormat("tr-TR").format(date);
  } catch {
    return String(value);
  }
}

export function generateEttn() {
  return crypto.randomUUID().toUpperCase();
}

export function generateInvoiceNumber(count: number, prefix = "GIB") {
  const year = new Date().getFullYear();
  const safePrefix = (prefix || "GIB").trim().slice(0, 3).toUpperCase();
  return `${safePrefix}${year}${String(Math.max(1, count + 1)).padStart(9, "0")}`;
}

/** Türkiye VKN (Vergi Kimlik Numarası) 10 hane algoritma kontrolü */
export function isValidVKN(vkn: string): boolean {
  const clean = vkn.replace(/\D/g, "");
  if (clean.length !== 10) return false;
  const digits = clean.split("").map(Number);
  const lastDigit = digits[9];
  let sum = 0;
  for (let i = 0; i < 9; i++) {
    const d = digits[i];
    const c1 = (d + (9 - i)) % 10;
    const c2 = (c1 * Math.pow(2, 9 - i)) % 9;
    const c3 = c1 !== 0 && c2 === 0 ? 9 : c2;
    sum += c3;
  }
  const check = (10 - (sum % 10)) % 10;
  return check === lastDigit;
}

/** Türkiye TCKN (T.C. Kimlik Numarası) 11 hane algoritma kontrolü */
export function isValidTCKN(tckn: string): boolean {
  const clean = tckn.replace(/\D/g, "");
  if (clean.length !== 11 || clean.startsWith("0")) return false;
  const digits = clean.split("").map(Number);
  const d10 =
    ((digits[0] + digits[2] + digits[4] + digits[6] + digits[8]) * 7 -
      (digits[1] + digits[3] + digits[5] + digits[7])) %
    10;
  const positiveD10 = (d10 + 10) % 10;
  if (digits[9] !== positiveD10) return false;
  const sum10 = digits.slice(0, 10).reduce((acc, curr) => acc + curr, 0);
  return digits[10] === sum10 % 10;
}

export function isValidVknTckn(val: string): boolean {
  const clean = val.replace(/\D/g, "");
  if (clean.length === 10) return isValidVKN(clean);
  if (clean.length === 11) return isValidTCKN(clean);
  return false;
}
