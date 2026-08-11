import { formatDate, formatMoney, itemTotals, type InvoiceItem } from "@/lib/invoice";

export type SellerInfo = {
  companyTitle: string;
  vknTckn: string;
  taxOffice: string;
  address: string;
  phone: string;
  email: string;
};

export type InvoiceRecord = {
  invoice_number: string;
  ettn: string;
  invoice_date: string;
  type: string;
  status: string;
  currency: string;
  customer: unknown;
  items: unknown;
  subtotal: number | string;
  total_discount: number | string;
  taxable_amount: number | string;
  total_vat: number | string;
  total_tevkifat: number | string;
  grand_total: number | string;
  notes?: string | null;
  payment_info?: string | null;
};

type JsPdf = import("jspdf").jsPDF;

const FONT = "RobotoTR";

async function createDoc(): Promise<JsPdf> {
  const [{ jsPDF }, { ROBOTO_TR_BASE64 }] = await Promise.all([
    import("jspdf"),
    import("./roboto-tr-font"),
  ]);
  const doc = new jsPDF({ unit: "pt", format: "a4" });
  doc.addFileToVFS("RobotoTR.ttf", ROBOTO_TR_BASE64);
  doc.addFont("RobotoTR.ttf", FONT, "normal");
  doc.setFont(FONT, "normal");
  return doc;
}

async function autoTable(doc: JsPdf, options: Record<string, unknown>) {
  const mod = await import("jspdf-autotable");
  (mod.default as unknown as (d: JsPdf, o: Record<string, unknown>) => void)(doc, {
    styles: { font: FONT, fontStyle: "normal", fontSize: 8, cellPadding: 4 },
    headStyles: { font: FONT, fontStyle: "normal", fillColor: [30, 41, 59], textColor: 255 },
    ...options,
  });
}

function lastY(doc: JsPdf, fallback: number) {
  const y = (doc as unknown as { lastAutoTable?: { finalY?: number } }).lastAutoTable?.finalY;
  return typeof y === "number" ? y : fallback;
}

function toNumber(value: number | string | null | undefined) {
  return Number(value ?? 0) || 0;
}

function asItems(value: unknown): InvoiceItem[] {
  return Array.isArray(value) ? (value as InvoiceItem[]) : [];
}

function asCustomer(value: unknown) {
  return (value ?? {}) as Partial<{
    title: string;
    vknTckn: string;
    taxOffice: string;
    address: string;
    city: string;
    district: string;
    neighborhood: string;
    email: string;
    phone: string;
  }>;
}

const STATUS_LABEL: Record<string, string> = {
  TASLAK: "Taslak",
  ONAYLANDI: "GİB'e İletildi",
  IPTAL: "İptal",
};

async function renderInvoice(doc: JsPdf, invoice: InvoiceRecord, seller: SellerInfo) {
  const currency = invoice.currency || "TRY";
  const customer = asCustomer(invoice.customer);
  const items = asItems(invoice.items);
  const margin = 40;

  doc.setFont(FONT, "normal");
  doc.setFontSize(16);
  doc.text(seller.companyTitle || "e-Fatura", margin, 50);
  doc.setFontSize(9);
  const sellerLines = [
    seller.vknTckn ? `VKN/TCKN: ${seller.vknTckn}` : "",
    seller.taxOffice ? `Vergi Dairesi: ${seller.taxOffice}` : "",
    seller.address,
    [seller.phone, seller.email].filter(Boolean).join(" · "),
  ].filter(Boolean);
  doc.text(sellerLines, margin, 66);

  doc.setFontSize(13);
  doc.text("FATURA", 555, 50, { align: "right" });
  doc.setFontSize(9);
  doc.text(
    [
      `Fatura No: ${invoice.invoice_number}`,
      `Tarih: ${formatDate(invoice.invoice_date)}`,
      `ETTN: ${invoice.ettn}`,
      `Durum: ${STATUS_LABEL[invoice.status] ?? invoice.status}`,
    ],
    555,
    66,
    { align: "right" },
  );

  const headerBottom = Math.max(66 + sellerLines.length * 12, 120);

  await autoTable(doc, {
    startY: headerBottom + 8,
    head: [["ALICI BİLGİLERİ", ""]],
    body: [
      ["Unvan / Ad Soyad", customer.title ?? "-"],
      ["VKN / TCKN", customer.vknTckn ?? "-"],
      ["Vergi Dairesi", customer.taxOffice ?? "-"],
      [
        "Adres",
        [customer.address, customer.neighborhood, customer.district, customer.city].filter(Boolean).join(", ") || "-",
      ],
      ["İletişim", [customer.email, customer.phone].filter(Boolean).join(" · ") || "-"],
    ],
    theme: "grid",
    columnStyles: { 0: { cellWidth: 130 } },
  });

  await autoTable(doc, {
    startY: lastY(doc, headerBottom) + 14,
    head: [["Açıklama", "Miktar", "Birim", "Birim Fiyat", "İsk. %", "KDV %", "Tutar"]],
    body: items.map((item) => {
      const t = itemTotals(item);
      return [
        item.name,
        String(item.quantity),
        item.unit,
        formatMoney(item.unitPrice, currency),
        `%${item.discountRate}`,
        `%${item.vatRate}`,
        formatMoney(t.total, currency),
      ];
    }),
    theme: "striped",
    columnStyles: {
      1: { halign: "right" },
      3: { halign: "right" },
      4: { halign: "right" },
      5: { halign: "right" },
      6: { halign: "right" },
    },
  });

  await autoTable(doc, {
    startY: lastY(doc, headerBottom) + 12,
    body: [
      ["Ara Toplam", formatMoney(toNumber(invoice.subtotal), currency)],
      ["İskonto", formatMoney(toNumber(invoice.total_discount), currency)],
      ["KDV Matrahı", formatMoney(toNumber(invoice.taxable_amount), currency)],
      ["Toplam KDV", formatMoney(toNumber(invoice.total_vat), currency)],
      ["Tevkifat", formatMoney(toNumber(invoice.total_tevkifat), currency)],
      ["ÖDENECEK TUTAR", formatMoney(toNumber(invoice.grand_total), currency)],
    ],
    theme: "plain",
    margin: { left: 330 },
    tableWidth: 225,
    columnStyles: { 0: { cellWidth: 120 }, 1: { halign: "right" } },
  });

  const notes = [invoice.notes, invoice.payment_info].filter(Boolean).join("\n");
  if (notes) {
    doc.setFontSize(8);
    doc.text(doc.splitTextToSize(notes, 480), margin, Math.min(lastY(doc, 700) + 24, 780));
  }
}

/** Seçili faturaları TEK bir PDF dosyası olarak indirir (zip yok, her fatura ayrı sayfa). */
export async function downloadInvoicesPdf(invoices: InvoiceRecord[], seller: SellerInfo, filename?: string) {
  if (invoices.length === 0) throw new Error("İndirilecek fatura seçilmedi.");
  const doc = await createDoc();
  for (let i = 0; i < invoices.length; i += 1) {
    if (i > 0) doc.addPage();
    // eslint-disable-next-line no-await-in-loop
    await renderInvoice(doc, invoices[i]!, seller);
  }
  const total = doc.getNumberOfPages();
  for (let page = 1; page <= total; page += 1) {
    doc.setPage(page);
    doc.setFont(FONT, "normal");
    doc.setFontSize(8);
    doc.text(`Sayfa ${page} / ${total}`, 555, 820, { align: "right" });
  }
  doc.save(filename ?? `faturalar-${new Date().toISOString().slice(0, 10)}.pdf`);
}

export type ZReportData = {
  date: string;
  invoiceCount: number;
  cancelledCount: number;
  subtotal: number;
  discount: number;
  taxable: number;
  vat: number;
  tevkifat: number;
  grandTotal: number;
  vatBreakdown: { rate: number; taxable: number; vat: number }[];
  posTotal?: number;
};

/** Günlük Z raporunu PDF olarak indirir. */
export async function downloadZReportPdf(data: ZReportData, seller: SellerInfo) {
  const doc = await createDoc();
  doc.setFontSize(16);
  doc.text("GÜNLÜK Z RAPORU", 40, 50);
  doc.setFontSize(10);
  doc.text(
    [
      seller.companyTitle || "-",
      seller.vknTckn ? `VKN/TCKN: ${seller.vknTckn}` : "",
      `Rapor Tarihi: ${formatDate(data.date)}`,
      `Oluşturulma: ${new Date().toLocaleString("tr-TR")}`,
    ].filter(Boolean),
    40,
    70,
  );

  await autoTable(doc, {
    startY: 130,
    head: [["ÖZET", "DEĞER"]],
    body: [
      ["Fatura Adedi", String(data.invoiceCount)],
      ["İptal Edilen", String(data.cancelledCount)],
      ["Ara Toplam", formatMoney(data.subtotal)],
      ["İskonto", formatMoney(data.discount)],
      ["KDV Matrahı", formatMoney(data.taxable)],
      ["Toplam KDV", formatMoney(data.vat)],
      ["Tevkifat", formatMoney(data.tevkifat)],
      ["GÜNLÜK TOPLAM", formatMoney(data.grandTotal)],
    ],
    theme: "grid",
    columnStyles: { 1: { halign: "right" } },
  });

  await autoTable(doc, {
    startY: lastY(doc, 300) + 16,
    head: [["KDV Oranı", "Matrah", "KDV Tutarı"]],
    body: data.vatBreakdown.map((row) => [`%${row.rate}`, formatMoney(row.taxable), formatMoney(row.vat)]),
    theme: "grid",
    columnStyles: { 1: { halign: "right" }, 2: { halign: "right" } },
  });

  doc.save(`z-raporu-${data.date}.pdf`);
}
