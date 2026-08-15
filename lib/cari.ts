export type PartnerType = "MUSTERI" | "TEDARIKCI";

export type TxnType = "BORC" | "ALACAK" | "TAHSILAT" | "ODEME" | "VIRMAN";

export const PARTNER_LABELS: Record<PartnerType, string> = {
  MUSTERI: "Müşteri",
  TEDARIKCI: "Tedarikçi",
};

/** Borç tarafını artıran hareketler view ile birebir aynıdır. */
export const DEBIT_TYPES: TxnType[] = ["BORC", "ODEME"];

export const TXN_LABELS: Record<TxnType, string> = {
  BORC: "Borç Kaydı",
  ALACAK: "Alacak Kaydı",
  TAHSILAT: "Tahsilat",
  ODEME: "Ödeme",
  VIRMAN: "Virman",
};

export const TXN_OPTIONS: { value: TxnType; label: string; hint: string }[] = [
  { value: "BORC", label: "Borç Kaydı", hint: "Cariye borç yazar (satış, fatura vb.)" },
  { value: "ALACAK", label: "Alacak Kaydı", hint: "Cariye alacak yazar (iade, indirim vb.)" },
  { value: "TAHSILAT", label: "Tahsilat", hint: "Müşteriden para tahsil edildi" },
  { value: "ODEME", label: "Ödeme", hint: "Tedarikçiye ödeme yapıldı" },
];

export function isDebit(type: string) {
  return DEBIT_TYPES.includes(type as TxnType);
}

export function balanceLabel(balance: number) {
  if (Math.abs(balance) < 0.005) return "Bakiye yok";
  return balance > 0 ? "Borçlu" : "Alacaklı";
}

export type StockMovementType = "GIRIS" | "CIKIS" | "TRANSFER" | "SAYIM";

export const STOCK_LABELS: Record<StockMovementType, string> = {
  GIRIS: "Stok Girişi",
  CIKIS: "Stok Çıkışı",
  TRANSFER: "Depo Transferi",
  SAYIM: "Sayım / Düzeltme",
};

export function today() {
  return new Date().toISOString().slice(0, 10);
}

export function addDaysISO(iso: string, days: number) {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}
