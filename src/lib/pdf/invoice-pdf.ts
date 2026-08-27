import {
  formatDate,
  itemTotals,
  numberToTurkishWords,
  type InvoiceItem,
} from "@/lib/invoice";

export type SellerInfo = {
  companyTitle: string;
  vknTckn: string;
  taxOffice: string;
  address: string;
  phone: string;
  email: string;
};

export type InvoiceRecord = {
  id?: string;
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
  tevkifat_code?: string | null;
  created_at?: string;
};

type JsPdf = import("jspdf").jsPDF;

const FONT = "helvetica";

function cleanPdfText(str: string | null | undefined): string {
  if (!str) return "";
  return String(str)
    .replace(/₺/g, "TL")
    .replace(/İ/g, "I")
    .replace(/ı/g, "i")
    .replace(/Ş/g, "S")
    .replace(/ş/g, "s")
    .replace(/Ğ/g, "G")
    .replace(/ğ/g, "g")
    .replace(/Ç/g, "C")
    .replace(/ç/g, "c")
    .replace(/Ö/g, "O")
    .replace(/ö/g, "o")
    .replace(/Ü/g, "U")
    .replace(/ü/g, "u");
}

function formatMoneyPdf(value: number | string | null | undefined, currency = "TL"): string {
  const num = Number(value) || 0;
  const formatted = num.toLocaleString("tr-TR", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const cleanCurr = (currency || "TL").replace("TRY", "TL").trim();
  return `${formatted} ${cleanCurr}`;
}

async function createDoc(): Promise<JsPdf> {
  const { jsPDF } = await import("jspdf");
  const doc = new jsPDF({ unit: "pt", format: "a4" });
  doc.setFont(FONT, "normal");
  return doc;
}

async function autoTable(doc: JsPdf, options: Record<string, unknown>) {
  const mod = await import("jspdf-autotable");
  (mod.default as unknown as (d: JsPdf, o: Record<string, unknown>) => void)(doc, {
    styles: { font: FONT, fontStyle: "normal", fontSize: 7.5, cellPadding: 3.5 },
    headStyles: { font: FONT, fontStyle: "bold", fillColor: [241, 245, 249], textColor: [15, 23, 42] },
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

const TYPE_TITLE: Record<string, string> = {
  SATIS:              "e-Arsiv Fatura",
  E_ARSIV:            "e-Arsiv Fatura",
  GENEL_IADE:         "Iade Faturasi (Genel Iade)",
  TEVKIFAT:           "e-Arsiv Fatura (Tevkifat)",
  TEVKIFAT_IADE:      "Iade Faturasi (Tevkifat Iade)",
  ISTISNA:            "e-Arsiv Fatura (Istisna / KDV %0)",
  OZEL_MATRAH:        "e-Arsiv Fatura (Ozel Matrah)",
  IHRAC_KAYITLI:      "e-Arsiv Fatura (Ihrac Kayitli)",
  KONAKLAMA_VERGISI:  "e-Arsiv Fatura (Konaklama Vergisi)",
  YATIRIM_TESVIK:     "e-Arsiv Fatura (Yatirim Tesvik)",
  IADE:               "Iade Faturasi",
  GELEN_FATURA:       "Gelen Alis Faturasi",
  GELEN_E_ARSIV:      "Gelen e-Arsiv Fatura",
};

const SCENARIO_TITLE: Record<string, string> = {
  SATIS:              "EARSIVFATURA",
  E_ARSIV:            "EARSIVFATURA",
  GENEL_IADE:         "IADE",
  TEVKIFAT:           "TEVKIFAT",
  TEVKIFAT_IADE:      "TEVKIFATIADE",
  ISTISNA:            "ISTISNA",
  OZEL_MATRAH:        "OZELMATRAH",
  IHRAC_KAYITLI:      "IHRACKAYITLI",
  KONAKLAMA_VERGISI:  "KONAKLAMAVERGISI",
  YATIRIM_TESVIK:     "YATIRIMTESVIK",
  IADE:               "IADE",
  GELEN_FATURA:       "TICARIFATURA",
  GELEN_E_ARSIV:      "EARSIVFATURA",
};

async function renderInvoice(doc: JsPdf, invoice: InvoiceRecord, seller: SellerInfo) {
  const currency = invoice.currency || "TRY";
  const customer = asCustomer(invoice.customer);
  const items = asItems(invoice.items);
  const margin = 28;
  const pageWidth = 595.28; // A4 width in pt
  const printWidth = pageWidth - margin * 2;

  doc.setFont(FONT, "normal");

  // ==========================================
  // 1. ÜST BÖLÜM (SOL: SATICI | ORTA: GİB LOGO & BAŞLIK | SAĞ: KAREKOD/QR)
  // ==========================================

  // SOL: Satıcı Firma Bilgileri
  doc.setFont(FONT, "bold");
  doc.setFontSize(10);
  doc.setTextColor(15, 23, 42);
  const sellerTitle = cleanPdfText(seller.companyTitle || "FIRMA UNVANI BELIRTILMEDI");
  const sellerTitleLines = doc.splitTextToSize(sellerTitle, 190);
  doc.text(sellerTitleLines, margin, 38);

  doc.setFont(FONT, "normal");
  doc.setFontSize(7.5);
  doc.setTextColor(71, 85, 105);
  let sY = 38 + (Array.isArray(sellerTitleLines) ? sellerTitleLines.length : 1) * 11 + 2;

  const sellerDetails = [
    seller.address ? `Adres: ${cleanPdfText(seller.address)}` : "",
    seller.phone ? `Tel: ${cleanPdfText(seller.phone)}` : "",
    seller.email ? `E-Posta: ${seller.email}` : "",
    seller.taxOffice ? `Vergi Dairesi: ${cleanPdfText(seller.taxOffice)}` : "",
    seller.vknTckn ? `VKN/TCKN: ${seller.vknTckn}` : "",
  ].filter(Boolean);

  for (const line of sellerDetails) {
    const lines = doc.splitTextToSize(line, 190);
    doc.text(lines, margin, sY);
    const lineCount = Array.isArray(lines) ? lines.length : 1;
    sY += lineCount * 9.5;
  }

  // ORTA: GİB Logo & e-Arşiv / e-Fatura Başlığı
  const midX = pageWidth / 2;

  // GİB Hilal Kırmızı Amblem Çizimi
  doc.setFillColor(220, 38, 38);
  doc.circle(midX, 42, 13, "F");
  doc.setFillColor(255, 255, 255);
  doc.circle(midX + 3.5, 42, 10.5, "F");
  doc.setFillColor(220, 38, 38);
  doc.rect(midX - 2.5, 34, 5, 16, "F");

  doc.setFont(FONT, "normal");
  doc.setFontSize(6);
  doc.setTextColor(100, 116, 139);
  doc.text("T.C. Hazine ve Maliye Bakanligi", midX, 62, { align: "center" });
  doc.text("Gelir Idaresi Baskanligi", midX, 69, { align: "center" });

  doc.setFont(FONT, "bold");
  doc.setFontSize(11);
  doc.setTextColor(15, 23, 42);
  const mainTitle = TYPE_TITLE[invoice.type] || "e-Arsiv Fatura";
  doc.text(mainTitle, midX, 83, { align: "center" });

  doc.setFont(FONT, "normal");
  doc.setFontSize(6.5);
  doc.setTextColor(100, 116, 139);
  doc.text("GIB ONAYLI ELEKTRONIK BELGE", midX, 93, { align: "center" });
  doc.text("www.gib.gov.tr", midX, 100, { align: "center" });

  // SAĞ ÜST: Büyük ve Net Resmi GİB Karekod (QR Code)
  const qrSize = 82;
  const qrX = pageWidth - margin - qrSize;
  const qrY = 24;

  try {
    const QRCode = await import("qrcode");
    const qrPayload = [
      `VKN:${seller.vknTckn || ""}`,
      `AVKN:${customer.vknTckn || ""}`,
      `FNo:${invoice.invoice_number}`,
      `Trh:${invoice.invoice_date}`,
      `Ttr:${invoice.grand_total}`,
      `ETTN:${invoice.ettn}`,
    ].join("|");

    const qrDataUrl = await QRCode.toDataURL(qrPayload, {
      margin: 1,
      width: 200,
      color: { dark: "#000000", light: "#ffffff" },
    });

    doc.addImage(qrDataUrl, "PNG", qrX, qrY, qrSize, qrSize);
  } catch {
    doc.setDrawColor(0, 0, 0);
    doc.rect(qrX, qrY, qrSize, qrSize);
    doc.setFontSize(7);
    doc.text("KAREKOD", qrX + qrSize / 2, qrY + qrSize / 2, { align: "center" });
  }

  // ==========================================
  // 2. YATAY AYIRICI ÇİZGİ
  // ==========================================
  const lineY = 114;
  doc.setDrawColor(15, 23, 42);
  doc.setLineWidth(1.5);
  doc.line(margin, lineY, pageWidth - margin, lineY);

  // ==========================================
  // 3. ORTA BÖLÜM (SOL: SAYIN / ALICI | SAĞ: RESMİ METADATA TABLOSU)
  // ==========================================
  const subY = lineY + 14;

  // SOL: SAYIN (ALICI BİLGİLERİ)
  doc.setFont(FONT, "bold");
  doc.setFontSize(9);
  doc.setTextColor(15, 23, 42);
  doc.text("SAYIN", margin, subY);

  doc.setFontSize(8.5);
  const custTitle = cleanPdfText(customer.title || "NIHAI TUKETICI");
  const custTitleLines = doc.splitTextToSize(custTitle, 260);
  doc.text(custTitleLines, margin, subY + 12);

  doc.setFont(FONT, "normal");
  doc.setFontSize(7.5);
  doc.setTextColor(71, 85, 105);
  let cY = subY + 12 + (Array.isArray(custTitleLines) ? custTitleLines.length : 1) * 10 + 2;
  const customerDetails = [
    cleanPdfText([customer.address, customer.neighborhood, customer.district, customer.city].filter(Boolean).join(", ")),
    customer.email ? `E-Posta: ${customer.email}` : "",
    customer.phone ? `Tel: ${customer.phone}` : "",
    customer.taxOffice ? `Vergi Dairesi: ${cleanPdfText(customer.taxOffice)}` : "",
    customer.vknTckn ? `VKN/TCKN: ${customer.vknTckn}` : "VKN/TCKN: 11111111111",
  ].filter(Boolean);

  for (const line of customerDetails) {
    const lines = doc.splitTextToSize(line, 260);
    doc.text(lines, margin, cY);
    const lineCount = Array.isArray(lines) ? lines.length : 1;
    cY += lineCount * 9.5;
  }

  // SAĞ: Çerçeveli Fatura Metadata Tablosu
  const metaTableX = pageWidth - margin - 180;
  const invoiceTime = invoice.created_at ? new Date(invoice.created_at).toLocaleTimeString("tr-TR") : "10:00:00";
  const scenario = SCENARIO_TITLE[invoice.type] || "EARSIVFATURA";

  await autoTable(doc, {
    startY: subY - 4,
    margin: { left: metaTableX, right: margin },
    tableWidth: 180,
    theme: "grid",
    body: [
      ["Ozellestirme No:", "TR1.2"],
      ["Senaryo:", scenario],
      ["Fatura Tipi:", cleanPdfText(invoice.type)],
      ["Fatura No:", invoice.invoice_number],
      ["Fatura Tarihi:", formatDate(invoice.invoice_date)],
      ["Fatura Saati:", invoiceTime],
    ],
    styles: { font: FONT, fontSize: 7, cellPadding: 2.2, textColor: [15, 23, 42] },
    columnStyles: {
      0: { cellWidth: 75, fontStyle: "normal", textColor: [100, 116, 139] },
      1: { cellWidth: 105, fontStyle: "normal" },
    },
  });

  // ORTA: ETTN Numarası
  const afterMetaY = Math.max(cY + 6, lastY(doc, subY + 70) + 12);
  doc.setFont(FONT, "bold");
  doc.setFontSize(7.5);
  doc.setTextColor(15, 23, 42);
  doc.text(`ETTN: ${invoice.ettn || "-"}`, margin, afterMetaY);

  // ==========================================
  // 4. MAL / HİZMET TABLOSU (RESMİ ÇERÇEVELİ ÇİZELGE)
  // ==========================================
  const tableRows = items.map((it, idx) => {
    const t = itemTotals(it);
    const discRate = Number(it.discountRate) || 0;
    const discAmount = (Number(it.quantity) * Number(it.unitPrice) * discRate) / 100;
    return [
      idx + 1,
      cleanPdfText(it.name || "Mal / Hizmet"),
      `${Number(it.quantity)} ${cleanPdfText(it.unit || "Adet")}`,
      formatMoneyPdf(Number(it.unitPrice), currency),
      discRate > 0 ? `%${discRate}` : "-",
      discRate > 0 ? formatMoneyPdf(discAmount, currency) : "0,00 TL",
      `%${Number(it.vatRate)}`,
      formatMoneyPdf(t.vat, currency),
      formatMoneyPdf(t.total, currency),
    ];
  });

  await autoTable(doc, {
    startY: afterMetaY + 8,
    margin: { left: margin, right: margin },
    theme: "grid",
    head: [[
      "Sira\nNo",
      "Mal / Hizmet",
      "Miktar",
      "Birim Fiyat",
      "Iskonto\nOrani",
      "Iskonto\nTutari",
      "KDV\nOrani",
      "KDV Tutari",
      "Mal Hizmet Tutari",
    ]],
    body: tableRows.length > 0 ? tableRows : [["1", "Mal / Hizmet Teslimi", "1 Adet", "0,00 TL", "-", "0,00 TL", "%20", "0,00 TL", "0,00 TL"]],
    headStyles: {
      font: FONT,
      fillColor: [241, 245, 249],
      textColor: [15, 23, 42],
      fontSize: 7,
      fontStyle: "bold",
      halign: "center",
      cellPadding: 3,
    },
    styles: { font: FONT, fontSize: 7, cellPadding: 3.5, textColor: [30, 41, 59] },
    columnStyles: {
      0: { cellWidth: 24, halign: "center" },
      1: { cellWidth: 155 },
      2: { cellWidth: 46, halign: "center" },
      3: { cellWidth: 54, halign: "right" },
      4: { cellWidth: 44, halign: "center" },
      5: { cellWidth: 48, halign: "right" },
      6: { cellWidth: 40, halign: "center" },
      7: { cellWidth: 56, halign: "right" },
      8: { cellWidth: 72, halign: "right" },
    },
  });

  let currentY = lastY(doc, afterMetaY + 100) + 10;

  // ==========================================
  // 5. KDV KIRILIMI (SOL) VE TOPLAMLAR (SAĞ)
  // ==========================================
  const subtotal = toNumber(invoice.subtotal);
  const discount = toNumber(invoice.total_discount);
  const taxable = toNumber(invoice.taxable_amount || subtotal - discount);
  const vat = toNumber(invoice.total_vat);
  const tevkifat = toNumber(invoice.total_tevkifat);
  const grand = toNumber(invoice.grand_total);

  // Sol Alt: KDV Oranları Kırılımı Tablosu
  const vatBreakdownMap = new Map<number, { taxable: number; vat: number }>();
  for (const it of items) {
    const t = itemTotals(it);
    const r = Number(it.vatRate) || 0;
    const cur = vatBreakdownMap.get(r) || { taxable: 0, vat: 0 };
    cur.taxable += t.taxable;
    cur.vat += t.vat;
    vatBreakdownMap.set(r, cur);
  }

  const vatBreakdownRows: (string | number)[][] = [];
  vatBreakdownMap.forEach((val, rate) => {
    vatBreakdownRows.push([`%${rate}`, formatMoneyPdf(val.taxable, currency), formatMoneyPdf(val.vat, currency)]);
  });
  if (vatBreakdownRows.length === 0) {
    vatBreakdownRows.push(["%20", formatMoneyPdf(taxable, currency), formatMoneyPdf(vat, currency)]);
  }

  await autoTable(doc, {
    startY: currentY,
    margin: { left: margin, right: pageWidth - margin - 200 },
    tableWidth: 200,
    theme: "grid",
    head: [["KDV Orani", "KDV Matrahi", "Hesaplanan KDV"]],
    headStyles: { font: FONT, fillColor: [241, 245, 249], textColor: [15, 23, 42], fontSize: 6.5, fontStyle: "bold" },
    styles: { font: FONT, fontSize: 6.5, cellPadding: 2.5 },
    columnStyles: {
      0: { cellWidth: 50, halign: "center" },
      1: { cellWidth: 75, halign: "right" },
      2: { cellWidth: 75, halign: "right" },
    },
  });

  // Sağ Alt: Toplamlar Tablosu
  const totalBoxRows = [
    ["Mal Hizmet Toplam Tutari", formatMoneyPdf(subtotal, currency)],
    discount > 0 ? ["Toplam Iskonto (-)", formatMoneyPdf(discount, currency)] : null,
    ["KDV Matrahi", formatMoneyPdf(taxable, currency)],
    ["Hesaplanan KDV", formatMoneyPdf(vat, currency)],
    tevkifat > 0 ? ["Tevkifat Kesintisi (-)", formatMoneyPdf(tevkifat, currency)] : null,
    ["Vergiler Dahil Toplam Tutar", formatMoneyPdf(grand + tevkifat, currency)],
    ["ODENECEK TUTAR", formatMoneyPdf(grand, currency)],
  ].filter(Boolean) as string[][];

  await autoTable(doc, {
    startY: currentY,
    margin: { left: pageWidth - margin - 220, right: margin },
    tableWidth: 220,
    theme: "grid",
    body: totalBoxRows,
    styles: { font: FONT, fontSize: 7, cellPadding: 2.8, textColor: [15, 23, 42] },
    columnStyles: {
      0: { cellWidth: 125, fontStyle: "normal", textColor: [71, 85, 105] },
      1: { cellWidth: 95, halign: "right", fontStyle: "bold" },
    },
  });

  const totalsEndY = Math.max(lastY(doc, currentY + 70), currentY + 70);

  // ==========================================
  // 6. YAZI İLE TUTAR KUTUSU (# YAZI ILE: ... #)
  // ==========================================
  const wordsY = totalsEndY + 12;
  const rawWords = numberToTurkishWords(grand, currency);
  const wordsText = `# YAZI ILE: ${cleanPdfText(rawWords)} #`;

  doc.setDrawColor(203, 213, 225);
  doc.setFillColor(248, 250, 252);
  doc.roundedRect(margin, wordsY, printWidth, 18, 2, 2, "FD");

  doc.setFont(FONT, "bold");
  doc.setFontSize(7.5);
  doc.setTextColor(15, 23, 42);
  doc.text(wordsText, margin + 8, wordsY + 12);

  // ==========================================
  // 7. DİPNOTLAR & YASAL UYARI
  // ==========================================
  let footerY = wordsY + 26;
  const extraNotes: string[] = [];

  if (invoice.type === "TEVKIFAT" || tevkifat > 0) {
    extraNotes.push(`TEVKIFAT BILGISI: Bu faturada KDV Tevkifati uygulanmistir (Tevkifat Tutari: ${formatMoneyPdf(tevkifat, currency)}).`);
  }
  if (invoice.tevkifat_code) {
    extraNotes.push(`Tevkifat Kodu: ${invoice.tevkifat_code}`);
  }
  if (invoice.notes) extraNotes.push(`Fatura Notu: ${cleanPdfText(invoice.notes)}`);
  if (invoice.payment_info) extraNotes.push(`Odeme / Banka: ${cleanPdfText(invoice.payment_info)}`);

  if (extraNotes.length > 0) {
    doc.setFont(FONT, "normal");
    doc.setFontSize(7);
    doc.setTextColor(71, 85, 105);
    for (const n of extraNotes) {
      const split = doc.splitTextToSize(n, printWidth);
      doc.text(split, margin, Math.min(footerY, 780));
      footerY += split.length * 9;
    }
  }

  // EN ALT: Resmi Yasal Dipnot
  doc.setFont(FONT, "normal");
  doc.setFontSize(6.5);
  doc.setTextColor(148, 163, 184);
  const bottomLegalY = Math.min(Math.max(footerY + 12, 790), 815);
  doc.text(
    "Bu belge 213 sayili V.U.K. hukumlerine gore e-Arsiv Fatura olarak elektronik ortamda duzenlenmistir.",
    pageWidth / 2,
    bottomLegalY,
    { align: "center" }
  );
}

/**
 * Tek bir faturayı veya seçilen birden fazla faturayı PDF olarak indirir.
 */
export async function downloadInvoicesPdf(
  invoices: InvoiceRecord[],
  seller: SellerInfo,
  fileName?: string,
): Promise<void> {
  if (!invoices || invoices.length === 0) {
    throw new Error("Indirilecek fatura kaydi bulunamadi.");
  }

  const doc = await createDoc();

  for (let i = 0; i < invoices.length; i++) {
    if (i > 0) {
      doc.addPage("a4", "portrait");
    }
    await renderInvoice(doc, invoices[i], seller);
  }

  const outputName =
    fileName ||
    (invoices.length === 1
      ? `fatura-${invoices[0].invoice_number || "e-arsiv"}.pdf`
      : `toplu-faturalar-${new Date().toISOString().slice(0, 10)}.pdf`);

  doc.save(outputName);
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

export async function downloadZReportPdf(
  report: ZReportData,
  seller: SellerInfo,
): Promise<void> {
  const doc = await createDoc();
  const margin = 28;
  const pageWidth = 595.28;

  // Header
  doc.setFont(FONT, "bold");
  doc.setFontSize(14);
  doc.setTextColor(15, 23, 42);
  doc.text("GUNLUK Z RAPORU / KDV VE SATIS DOKUMU", pageWidth / 2, 45, { align: "center" });

  doc.setFont(FONT, "normal");
  doc.setFontSize(9);
  doc.setTextColor(71, 85, 105);
  doc.text(`Rapor Tarihi: ${formatDate(report.date)}`, pageWidth / 2, 60, { align: "center" });
  doc.text(`Firma: ${cleanPdfText(seller.companyTitle || "-")} (VKN: ${seller.vknTckn || "-"})`, pageWidth / 2, 72, { align: "center" });

  // Summary Table
  const summaryRows = [
    ["Fatura Adedi", String(report.invoiceCount)],
    ["Iptal Edilen Fatura Adedi", String(report.cancelledCount)],
    ["Mal / Hizmet Toplam Tutari", formatMoneyPdf(report.subtotal)],
    ["Toplam Iskonto", formatMoneyPdf(report.discount)],
    ["Toplam KDV Matrahi", formatMoneyPdf(report.taxable)],
    ["Toplam Hesaplanan KDV", formatMoneyPdf(report.vat)],
    ["Toplam Tevkifat", formatMoneyPdf(report.tevkifat)],
    ["Fatura Genel Toplami", formatMoneyPdf(report.grandTotal)],
    ...(report.posTotal !== undefined ? [["Yazarkasa / POS Toplami", formatMoneyPdf(report.posTotal)]] : []),
  ];

  await autoTable(doc, {
    startY: 90,
    margin: { left: margin, right: margin },
    theme: "grid",
    head: [["Ozet Kalemi", "Tutar / Deger"]],
    body: summaryRows,
    headStyles: { font: FONT, fontStyle: "bold", fillColor: [241, 245, 249], textColor: [15, 23, 42], fontSize: 8 },
    styles: { font: FONT, fontSize: 8, cellPadding: 3.5 },
    columnStyles: {
      0: { cellWidth: 260 },
      1: { cellWidth: 279, halign: "right", fontStyle: "bold" },
    },
  });

  const nextY = lastY(doc, 250) + 16;

  // VAT Breakdown Table
  const vatRows = (report.vatBreakdown || []).map((v) => [
    `%${v.rate}`,
    formatMoneyPdf(v.taxable),
    formatMoneyPdf(v.vat),
  ]);

  if (vatRows.length > 0) {
    await autoTable(doc, {
      startY: nextY,
      margin: { left: margin, right: margin },
      theme: "grid",
      head: [["KDV Orani", "KDV Matrahi", "KDV Tutari"]],
      body: vatRows,
      headStyles: { font: FONT, fontStyle: "bold", fillColor: [241, 245, 249], textColor: [15, 23, 42], fontSize: 8 },
      styles: { font: FONT, fontSize: 8, cellPadding: 3.5 },
      columnStyles: {
        0: { cellWidth: 100, halign: "center" },
        1: { cellWidth: 219, halign: "right" },
        2: { cellWidth: 220, halign: "right" },
      },
    });
  }

  doc.save(`z-raporu-${report.date}.pdf`);
}
