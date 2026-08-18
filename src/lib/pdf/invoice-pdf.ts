import {
  formatDate,
  formatMoney,
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
    styles: { font: FONT, fontStyle: "normal", fontSize: 7.5, cellPadding: 3.5 },
    headStyles: { font: FONT, fontStyle: "normal", fillColor: [241, 245, 249], textColor: [15, 23, 42] },
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
  SATIS:              "e-Arşiv Fatura",
  E_ARSIV:            "e-Arşiv Fatura",
  GENEL_IADE:         "İade Faturası (Genel İade)",
  TEVKIFAT:           "e-Arşiv Fatura (Tevkifat)",
  TEVKIFAT_IADE:      "İade Faturası (Tevkifat İade)",
  ISTISNA:            "e-Arşiv Fatura (İstisna / KDV %0)",
  OZEL_MATRAH:        "e-Arşiv Fatura (Özel Matrah)",
  IHRAC_KAYITLI:      "e-Arşiv Fatura (İhraç Kayıtlı)",
  KONAKLAMA_VERGISI:  "e-Arşiv Fatura (Konaklama Vergisi)",
  YATIRIM_TESVIK:     "e-Arşiv Fatura (Yatırım Teşvik)",
  IADE:               "İade Faturası",
  GELEN_FATURA:       "Gelen Alış Faturası",
  GELEN_E_ARSIV:      "Gelen e-Arşiv Fatura",
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
  doc.setFontSize(10.5);
  doc.setTextColor(15, 23, 42);
  const sellerTitle = seller.companyTitle || "FİRMA UNVANI BELİRTİLMEDİ";
  doc.text(doc.splitTextToSize(sellerTitle, 190), margin, 38);

  doc.setFontSize(7.5);
  doc.setTextColor(71, 85, 105);
  let sY = 56;
  const sellerDetails = [
    seller.address ? `Adres: ${seller.address}` : "",
    seller.phone ? `Tel: ${seller.phone}` : "",
    seller.email ? `E-Posta: ${seller.email}` : "",
    seller.taxOffice ? `Vergi Dairesi: ${seller.taxOffice}` : "",
    seller.vknTckn ? `VKN/TCKN: ${seller.vknTckn}` : "",
  ].filter(Boolean);

  for (const line of sellerDetails) {
    doc.text(doc.splitTextToSize(line, 190), margin, sY);
    sY += 10;
  }

  // ORTA: GİB Logo & e-Arşiv / e-Fatura Başlığı
  const midX = pageWidth / 2;

  // GİB Hilal Kırmızı Amblem Çizimi
  doc.setFillColor(220, 38, 38); // Kırmızı
  doc.circle(midX, 42, 13, "F");
  doc.setFillColor(255, 255, 255);
  doc.circle(midX + 3.5, 42, 10.5, "F");
  doc.setFillColor(220, 38, 38);
  doc.rect(midX - 2.5, 34, 5, 16, "F");

  doc.setFontSize(6);
  doc.setTextColor(100, 116, 139);
  doc.text("T.C. Hazine ve Maliye Bakanlığı", midX, 62, { align: "center" });
  doc.text("Gelir İdaresi Başkanlığı", midX, 69, { align: "center" });

  doc.setFontSize(11);
  doc.setTextColor(15, 23, 42);
  const mainTitle = TYPE_TITLE[invoice.type] || "e-Arşiv Fatura";
  doc.text(mainTitle, midX, 83, { align: "center" });

  doc.setFontSize(6.5);
  doc.setTextColor(100, 116, 139);
  doc.text("GİB ONAYLI ELEKTRONİK BELGE", midX, 93, { align: "center" });
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
    // Fallback kare kutu
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
  doc.setFontSize(9.5);
  doc.setTextColor(15, 23, 42);
  doc.text("SAYIN", margin, subY);

  doc.setFontSize(8.5);
  doc.text(customer.title || "NİHAİ TÜKETİCİ", margin, subY + 12);

  doc.setFontSize(7.5);
  doc.setTextColor(71, 85, 105);
  let cY = subY + 23;
  const customerDetails = [
    [customer.address, customer.neighborhood, customer.district, customer.city].filter(Boolean).join(", "),
    customer.email ? `E-Posta: ${customer.email}` : "",
    customer.phone ? `Tel: ${customer.phone}` : "",
    customer.taxOffice ? `Vergi Dairesi: ${customer.taxOffice}` : "",
    customer.vknTckn ? `VKN/TCKN: ${customer.vknTckn}` : "VKN/TCKN: 11111111111",
  ].filter(Boolean);

  for (const line of customerDetails) {
    doc.text(doc.splitTextToSize(line, 260), margin, cY);
    cY += 9.5;
  }

  // SAĞ: Çerçeveli Fatura Metadata Tablosu
  const metaTableX = pageWidth - margin - 170;
  const invoiceTime = invoice.created_at ? new Date(invoice.created_at).toLocaleTimeString("tr-TR") : "10:00:00";
  const scenario = SCENARIO_TITLE[invoice.type] || "EARSIVFATURA";

  await autoTable(doc, {
    startY: subY - 4,
    margin: { left: metaTableX, right: margin },
    tableWidth: 170,
    theme: "grid",
    body: [
      ["Özelleştirme No:", "TR1.2"],
      ["Senaryo:", scenario],
      ["Fatura Tipi:", invoice.type],
      ["Fatura No:", invoice.invoice_number],
      ["Fatura Tarihi:", formatDate(invoice.invoice_date)],
      ["Fatura Saati:", invoiceTime],
    ],
    styles: { fontSize: 7, cellPadding: 2.2, textColor: [15, 23, 42] },
    columnStyles: {
      0: { cellWidth: 70, fontStyle: "normal", textColor: [100, 116, 139] },
      1: { cellWidth: 100, fontStyle: "normal" },
    },
  });

  // ORTA: ETTN Numarası
  const afterMetaY = Math.max(cY + 6, lastY(doc, subY + 70) + 12);
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
      it.name || "Mal / Hizmet",
      `${Number(it.quantity)} ${it.unit || "Adet"}`,
      formatMoney(Number(it.unitPrice), currency),
      discRate > 0 ? `%${discRate}` : "-",
      discRate > 0 ? formatMoney(discAmount, currency) : "0,00",
      `%${Number(it.vatRate)}`,
      formatMoney(t.vatAmount, currency),
      formatMoney(t.lineTotal, currency),
    ];
  });

  await autoTable(doc, {
    startY: afterMetaY + 8,
    margin: { left: margin, right: margin },
    theme: "grid",
    head: [[
      "Sıra\nNo",
      "Mal / Hizmet",
      "Miktar",
      "Birim Fiyat",
      "İskonto\nOranı",
      "İskonto\nTutarı",
      "KDV\nOranı",
      "KDV Tutarı",
      "Mal Hizmet Tutarı",
    ]],
    body: tableRows.length > 0 ? tableRows : [["1", "Mal / Hizmet Teslimi", "1 Adet", "0,00", "-", "0,00", "%20", "0,00", "0,00"]],
    headStyles: {
      fillColor: [241, 245, 249],
      textColor: [15, 23, 42],
      fontSize: 7,
      fontStyle: "normal",
      halign: "center",
      cellPadding: 3,
    },
    styles: { fontSize: 7, cellPadding: 3.5, textColor: [30, 41, 59] },
    columnStyles: {
      0: { cellWidth: 24, halign: "center" },
      1: { cellWidth: "auto" },
      2: { cellWidth: 44, halign: "center" },
      3: { cellWidth: 54, halign: "right" },
      4: { cellWidth: 38, halign: "center" },
      5: { cellWidth: 44, halign: "right" },
      6: { cellWidth: 36, halign: "center" },
      7: { cellWidth: 50, halign: "right" },
      8: { cellWidth: 62, halign: "right" },
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
    cur.taxable += t.taxableAmount;
    cur.vat += t.vatAmount;
    vatBreakdownMap.set(r, cur);
  }

  const vatBreakdownRows: (string | number)[][] = [];
  vatBreakdownMap.forEach((val, rate) => {
    vatBreakdownRows.push([`%${rate}`, formatMoney(val.taxable, currency), formatMoney(val.vat, currency)]);
  });
  if (vatBreakdownRows.length === 0) {
    vatBreakdownRows.push(["%20", formatMoney(taxable, currency), formatMoney(vat, currency)]);
  }

  await autoTable(doc, {
    startY: currentY,
    margin: { left: margin, right: pageWidth - margin - 180 },
    tableWidth: 180,
    theme: "grid",
    head: [["KDV Oranı", "KDV Matrahı", "Hesaplanan KDV"]],
    body: vatBreakdownRows,
    headStyles: { fillColor: [241, 245, 249], textColor: [15, 23, 42], fontSize: 6.5, fontStyle: "normal" },
    styles: { fontSize: 6.5, cellPadding: 2.5 },
    columnStyles: {
      0: { cellWidth: 45, halign: "center" },
      1: { cellWidth: 65, halign: "right" },
      2: { cellWidth: 70, halign: "right" },
    },
  });

  // Sağ Alt: Toplamlar Tablosu
  const totalBoxRows = [
    ["Mal Hizmet Toplam Tutarı", formatMoney(subtotal, currency)],
    discount > 0 ? ["Toplam İskonto (-)", formatMoney(discount, currency)] : null,
    ["KDV Matrahı", formatMoney(taxable, currency)],
    ["Hesaplanan KDV", formatMoney(vat, currency)],
    tevkifat > 0 ? ["Tevkifat Kesintisi (-)", formatMoney(tevkifat, currency)] : null,
    ["Vergiler Dahil Toplam Tutar", formatMoney(grand + tevkifat, currency)],
    ["ÖDENECEK TUTAR", formatMoney(grand, currency)],
  ].filter(Boolean) as string[][];

  await autoTable(doc, {
    startY: currentY,
    margin: { left: pageWidth - margin - 200, right: margin },
    tableWidth: 200,
    theme: "grid",
    body: totalBoxRows,
    styles: { fontSize: 7, cellPadding: 2.8, textColor: [15, 23, 42] },
    columnStyles: {
      0: { cellWidth: 110, fontStyle: "normal", textColor: [71, 85, 105] },
      1: { cellWidth: 90, halign: "right", fontStyle: "normal" },
    },
  });

  const totalsEndY = Math.max(lastY(doc, currentY + 70), currentY + 70);

  // ==========================================
  // 6. YAZI İLE TUTAR KUTUSU (# YAZI İLE: ... #)
  // ==========================================
  const wordsY = totalsEndY + 12;
  const wordsText = `# YAZI İLE: ${numberToTurkishWords(grand, currency)} #`;

  doc.setDrawColor(203, 213, 225);
  doc.setFillColor(248, 250, 252);
  doc.roundedRect(margin, wordsY, printWidth, 18, 2, 2, "FD");

  doc.setFontSize(7.5);
  doc.setTextColor(15, 23, 42);
  doc.text(wordsText, margin + 8, wordsY + 12);

  // ==========================================
  // 7. DİPNOTLAR & YASAL UYARI
  // ==========================================
  let footerY = wordsY + 26;
  const extraNotes: string[] = [];

  if (invoice.type === "TEVKIFAT" || tevkifat > 0) {
    extraNotes.push(`TEVKİFAT BİLGİSİ: Bu faturada KDV Tevkifatı uygulanmıştır (Tevkifat Tutarı: ${formatMoney(tevkifat, currency)}).`);
  }
  if (invoice.tevkifat_code) {
    extraNotes.push(`Tevkifat Kodu: ${invoice.tevkifat_code}`);
  }
  if (invoice.notes) extraNotes.push(`Fatura Notu: ${invoice.notes}`);
  if (invoice.payment_info) extraNotes.push(`Ödeme / Banka: ${invoice.payment_info}`);

  if (extraNotes.length > 0) {
    doc.setFontSize(7);
    doc.setTextColor(71, 85, 105);
    for (const n of extraNotes) {
      const split = doc.splitTextToSize(n, printWidth);
      doc.text(split, margin, Math.min(footerY, 780));
      footerY += split.length * 9 + 2;
    }
  }

  doc.setFontSize(6.5);
  doc.setTextColor(100, 116, 139);
  doc.text(
    "Bu belge 213 sayılı Vergi Usul Kanunu hükümlerine göre Gelir İdaresi Başkanlığı e-Arşiv / e-Fatura standartlarına uygun olarak düzenlenmiştir.",
    pageWidth / 2,
    814,
    { align: "center" },
  );
}

/** Seçili faturaları TEK bir PDF dosyası olarak indirir. */
export async function downloadInvoicesPdf(
  invoices: InvoiceRecord[],
  seller: SellerInfo,
  filename?: string,
) {
  if (invoices.length === 0) throw new Error("İndirilecek fatura seçilmedi.");
  const doc = await createDoc();
  for (let i = 0; i < invoices.length; i += 1) {
    if (i > 0) doc.addPage();
    await renderInvoice(doc, invoices[i]!, seller);
  }
  const total = doc.getNumberOfPages();
  for (let page = 1; page <= total; page += 1) {
    doc.setPage(page);
    doc.setFont(FONT, "normal");
    doc.setFontSize(7.5);
    doc.text(`Sayfa ${page} / ${total}`, 555, 825, { align: "right" });
  }
  doc.save(filename ?? `fatura-${new Date().toISOString().slice(0, 10)}.pdf`);
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
    body: data.vatBreakdown.map((row) => [
      `%${row.rate}`,
      formatMoney(row.taxable),
      formatMoney(row.vat),
    ]),
    theme: "grid",
    columnStyles: { 1: { halign: "right" }, 2: { halign: "right" } },
  });

  doc.save(`z-raporu-${data.date}.pdf`);
}

