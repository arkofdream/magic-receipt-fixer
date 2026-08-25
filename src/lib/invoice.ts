import { validateTCKN, validateVKN, validateVknTckn } from "./validation.ts";

export type InvoiceItem = {
  id: string;
  productId?: string;
  code?: string;
  name: string;
  unit: string;
  quantity: number;
  unitPrice: number;
  discountRate: number;
  vatRate: number;
  tevkifatCode?: string;
  tevkifatRate?: number;
  description?: string;
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
  customPrefix?: string;
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
  customPrefix: "",
};

export const INVOICE_TYPES = [
  { value: "SATIS",              label: "Satış" },
  { value: "E_ARSIV",            label: "E-Arşiv Fatura" },
  { value: "GENEL_IADE",         label: "Genel İade" },
  { value: "TEVKIFAT",           label: "Tevkifat" },
  { value: "TEVKIFAT_IADE",      label: "Tevkifat İade" },
  { value: "ISTISNA",            label: "İstisna" },
  { value: "OZEL_MATRAH",        label: "Özel Matrah" },
  { value: "IHRAC_KAYITLI",      label: "İhraç Kayıtlı" },
  { value: "KONAKLAMA_VERGISI",  label: "Konaklama Vergisi" },
  { value: "YATIRIM_TESVIK",     label: "Yatırım Teşvik Satış" },
  { value: "GELEN_FATURA",       label: "Gelen Fatura (Alış e-Faturası)" },
  { value: "GELEN_E_ARSIV",      label: "Gelen E-Arşiv (Alış e-Arşivi)" },
] as const;

export type InvoiceTypeKey = (typeof INVOICE_TYPES)[number]["value"];

export const INVOICE_TYPE_DETAILS: Record<
  string,
  {
    title: string;
    description: string;
    badge: string;
    features: string[];
    defaultVat?: number;
  }
> = {
  SATIS: {
    title: "Satış Faturası",
    description: "Mal ve hizmet satışlarınız için düzenlenen genel e-Fatura veya e-Arşiv faturası.",
    badge: "Satış",
    features: [
      "Stok ve cari bakiyelerine otomatik işlenir",
      "KDV oranları %0, %1, %10 ve %20 uygulanabilir",
      "GİB e-Fatura mükelleflerine sistem üzerinden iletilir",
      "600 Yurtiçi Satışlar hesabına, 391 Hesaplanan KDV hesabına yansır",
    ],
  },
  E_ARSIV: {
    title: "E-Arşiv Fatura",
    description: "e-Fatura kullanıcısı olmayan nihai tüketicilere veya firmalara kesilen resmi e-Arşiv faturası.",
    badge: "E-Arşiv",
    features: [
      "Nihai tüketiciye veya e-faturaya kayıtlı olmayan kurumlara kesilir",
      "Resmi e-Arşiv formatında PDF ve e-posta ile iletilir",
      "İnternet satış bilgisi ve ödeme şekli eklenebilir",
      "5.000 TL üzeri e-Arşiv internet satışlarında zorunludur",
    ],
  },
  GENEL_IADE: {
    title: "Genel İade Faturası",
    description: "Satış veya e-Arşiv faturasına istinaden düzenlenen genel iade faturası (KDV iadesi dahil).",
    badge: "Genel İade",
    features: [
      "İade edilen faturanın numarası ve tarihine referans verilir",
      "Cari hesaba alacak/borç ters kaydı yapılır",
      "KDV tutarı 191 İndirilecek KDV hesabına iade işlenir",
      "İade malları depoya geri alır (stok düzeltmesi)",
      "İade faturasında senaryo: EARSIVFATURA, fatura tipi: IADE",
    ],
  },
  TEVKIFAT: {
    title: "Tevkifatlı Fatura",
    description: "KDV'nin bir kısmının alıcı tarafından doğrudan devlete ödendiği KDV Genel Tebliği kapsamındaki fatura.",
    badge: "Tevkifat",
    features: [
      "GİB Tevkifat Kodları 601'den 616'ya kadar resmi kod seçimi",
      "Tevkifat oranları: 2/10, 3/10, 4/10, 5/10, 7/10, 9/10 veya Tam (10/10)",
      "Hesaplanan KDV ile alıcıya yansıyan net KDV tutarı ayrı gösterilir",
      "Tevkifat kodu ve gerekçesi PDF çıktısında yasal olarak yer alır",
      "391 Hesaplanan KDV hesabına tevkifat düşümü yapılır",
    ],
  },
  TEVKIFAT_IADE: {
    title: "Tevkifat İade Faturası",
    description: "Daha önce kesilen tevkifatlı satış faturasına istinaden düzenlenen iade faturası.",
    badge: "Tevkifat İade",
    features: [
      "İade edilen tevkifatlı faturanın numarasına referans verilir",
      "Tevkifat tutarı ve kodu iade faturasında da ayrıca gösterilir",
      "KDV iadesi ile tevkifat iadesi aynı belgede birlikte işlenir",
      "191 İndirilecek KDV ve 320 Satıcılar hesabına ters kayıt yapılır",
    ],
  },
  ISTISNA: {
    title: "İstisna Faturası (KDV %0)",
    description: "KDV Kanunu kapsamında KDV'den istisna tutulan işlemler için düzenlenen fatura (İhracat, serbest bölge, Ar-Ge vb.).",
    badge: "İstisna",
    features: [
      "Tüm kalemlerde KDV %0 olarak uygulanır",
      "GİB KDV Muafiyet/İstisna Kodu (301 Mal İhracatı, 302 Hizmet İhracatı, 353 Teknokent vb.) seçilir",
      "İstisna gerekçesi ve KDV Kanunu maddesi PDF çıktısında resmi olarak yer alır",
      "İhracat, serbest bölge, diplomatik istisna ve Ar-Ge/Teknokent yazılımlarında kullanılır",
    ],
    defaultVat: 0,
  },
  OZEL_MATRAH: {
    title: "Özel Matrah Faturası",
    description: "Altın, gümüş, mücevher ve ikinci el araç/konut gibi özel matrah uygulamasına tabi mallarda düzenlenen fatura.",
    badge: "Özel Matrah",
    features: [
      "Altın, gümüş, mücevher teslimleri için KDV matrahı sadece işçilik üzerinden hesaplanır",
      "İkinci el motorlu taşıt ve konut teslimlerinde kâr marjı üzerinden KDV uygulanır",
      "Özel matrah tutarı ve KDV'ye tabi matrah faturada ayrı gösterilir",
      "KDV Kanunu 23. ve 24. maddelerine uygun şekil şartlarını taşır",
      "Hazır giyim, tekstil ve tütün ürünlerinde de uygulanabilir",
    ],
  },
  IHRAC_KAYITLI: {
    title: "İhraç Kayıtlı Teslim Faturası",
    description: "KDV Kanunu 11/1-c maddesi kapsamında ihracatçıya ihraç kaydıyla yapılan teslim faturası. KDV tahsil edilmez, ihracatçı gümrükten iade alır.",
    badge: "İhraç Kayıtlı",
    features: [
      "Üretici firmadan ihracatçıya yapılan ihraç kayıtlı teslimlerde kesilir",
      "Faturada KDV hesaplanır ancak ihracatçıdan tahsil edilmez",
      "KDV Kanunu 11/1-c ibaresi ve 'Tahsil Edilmemiş KDV' bilgisi PDF'de yer alır",
      "İhracatçı gümrük beyannamesi ile bu KDV'yi Hazine'den talep eder",
      "Tecil-Terkin yöntemi: KDV önce tecil edilir, ihracat gerçekleşince terkin yapılır",
    ],
  },
  KONAKLAMA_VERGISI: {
    title: "Konaklama Vergisi Faturası",
    description: "Otel, motel, pansiyon, tatil köyü ve konaklama tesislerinde geceleme hizmetleri için düzenlenen özel vergi faturası. KDV'ye ek olarak Konaklama Vergisi (%2) uygulanır.",
    badge: "Konaklama Vergisi",
    features: [
      "Geceleme, kahvaltı, yarım pansiyon ve tam pansiyon hizmetlerini kapsar",
      "KDV oranı %10, üzerine ek Konaklama Vergisi %2 ayrıca hesaplanır",
      "Konaklama Vergisi matrahı ve tutarı faturada ayrı bir satırda gösterilir",
      "7194 sayılı Kanun ve Konaklama Vergisi Genel Tebliği hükümlerine uygun düzenlenir",
      "SPA, havuz, spor ve eğlence hizmetleri konaklama paketine dahilse vergiye tabidir",
      "Belediye vergi kodları ve tesis kodu faturaya işlenebilir",
    ],
  },
  YATIRIM_TESVIK: {
    title: "Yatırım Teşvik Satış Faturası",
    description: "Yatırım Teşvik Belgesi (YTB) kapsamındaki makine, teçhizat ve yazılım alımlarında KDV istisnası uygulanan fatura.",
    badge: "Yatırım Teşvik",
    features: [
      "Yatırım Teşvik Belgesi (YTB) numarası ve tarihi faturaya işlenir",
      "KDV Kanunu 13/d maddesi kapsamında KDV %0 uygulanır",
      "Alıcının YTB belgesi kontrolü yapılarak istisna onayı alınır",
      "Makine, teçhizat, taşıt, yazılım ve lisans alımlarında kullanılabilir",
      "İstisna belgesi ve onay kodu PDF çıktısında resmi olarak yer alır",
      "Satıcı firmada KDV iadesi talebine konu olabilir (KDV Kanunu 32. madde)",
    ],
    defaultVat: 0,
  },
  GELEN_FATURA: {
    title: "Gelen Fatura (Alış / Tedarikçi)",
    description: "Tedarikçilerinizden firmanıza gelen alış e-faturalarının kaydı.",
    badge: "Gelen Alış",
    features: [
      "Tedarikçi cari hesabına alacak borç kaydı işler",
      "Giriş deposuna otomatik stok girişi yapar",
      "191 İndirilecek KDV hesabına yansır",
    ],
  },
  GELEN_E_ARSIV: {
    title: "Gelen E-Arşiv Fatura",
    description: "Firmanıza kesilen ve e-Arşiv portalından indirilen alış faturalarının arşivi.",
    badge: "Gelen e-Arşiv",
    features: [
      "Masraf ve alım faturalarını ön muhasebeye dahil eder",
      "KDV matrahı ve indirim kalemlerini kaydeder",
      "Gider hesaplarına otomatik aktarılır",
    ],
  },
  // Geriye dönük uyumluluk
  IADE: {
    title: "İade Faturası",
    description: "Daha önce satın alınan veya satılan malların iadesi için düzenlenen fatura.",
    badge: "İade",
    features: [
      "Cari hesaba ters hareket (alacak/borç dengeleme) kaydeder",
      "Stok miktarlarını depoya geri alır",
      "İade edilen faturanın numara ve tarih bilgisi belirtilebilir",
    ],
  },
};

export const INVOICE_STATUSES: Record<
  string,
  { label: string; tone: "draft" | "sent" | "cancel" }
> = {
  TASLAK: { label: "Taslak", tone: "draft" },
  DRAFT: { label: "Taslak", tone: "draft" },
  PENDING: { label: "Gönderim Bekliyor", tone: "draft" },
  PROCESSING: { label: "İşleniyor", tone: "draft" },
  SENT: { label: "Entegratöre Gönderildi", tone: "sent" },
  ACCEPTED: { label: "Kabul Edildi", tone: "sent" },
  ONAYLANDI: { label: "Onaylandı", tone: "sent" },
  REJECTED: { label: "Reddedildi", tone: "cancel" },
  FAILED: { label: "Hatalı", tone: "cancel" },
  IPTAL: { label: "İptal Edildi", tone: "cancel" },
  CANCELLED: { label: "İptal Edildi", tone: "cancel" },
  UNKNOWN: { label: "Durum Bilinmiyor", tone: "draft" },
};

/**
 * Normalizes raw status string from EDM SOAP into standard application status.
 */
export function mapEdmStatusToInvoiceStatus(edmStatus: string): string {
  if (!edmStatus) return "UNKNOWN";
  const upper = edmStatus.toUpperCase().trim();

  if (
    upper.includes("SUCCEED") ||
    upper.includes("ACCEPTED") ||
    upper.includes("COMPLETED") ||
    upper.includes("ONAYLANDI") ||
    upper.includes("SUCCESS") ||
    upper.includes("APPROVED")
  ) {
    return "ACCEPTED";
  }

  if (
    upper.includes("SEND") ||
    upper.includes("PROCESSING") ||
    upper.includes("PACKAGE") ||
    upper.includes("ISLENDI")
  ) {
    return "SENT";
  }

  if (upper.includes("REJECT") || upper.includes("REDDEDILDI")) {
    return "REJECTED";
  }

  if (
    upper.includes("FAIL") ||
    upper.includes("ERROR") ||
    upper.includes("HATA") ||
    upper.includes("BASARISIZ")
  ) {
    return "FAILED";
  }

  if (upper.includes("CANCEL") || upper.includes("IPTAL")) {
    return "CANCELLED";
  }

  return "UNKNOWN";
}

/** Standart Türkiye KDV Dilimleri */
export const VAT_RATES = [0, 1, 10, 20] as const;

/** Resmi GİB KDV Tevkifat Kodları ve Oranları */
export const TEVKIFAT_CODES = [
  { code: "601", name: "Yapım İşleri ile Bu İşlerle Birlikte İfa Edilen Mühendislik-Mimarlık ve Etüt-Proje Hizmetleri", rate: 40, label: "601 - Yapım İşleri (4/10)" },
  { code: "602", name: "Temizlik Hizmeti", rate: 90, label: "602 - Temizlik Hizmeti (9/10)" },
  { code: "603", name: "Özel Güvenlik Hizmeti", rate: 90, label: "603 - Özel Güvenlik Hizmeti (9/10)" },
  { code: "604", name: "Makine, Teçhizat, Demirbaş ve Taşıtlara Ait Tadilat, Bakım ve Onarım Hizmetleri", rate: 70, label: "604 - Bakım ve Onarım Hizmetleri (7/10)" },
  { code: "605", name: "Yemek Servis ve Organizasyon Hizmetleri", rate: 50, label: "605 - Yemek Servis ve Organizasyon (5/10)" },
  { code: "606", name: "İşgücü Temin Hizmetleri", rate: 90, label: "606 - İşgücü Temin Hizmetleri (9/10)" },
  { code: "607", name: "Yapı Denetim Hizmetleri", rate: 90, label: "607 - Yapı Denetim Hizmetleri (9/10)" },
  { code: "608", name: "Fason Olarak Yaptırılan Tekstil ve Konfeksiyon İşleri", rate: 70, label: "608 - Fason Tekstil ve Konfeksiyon (7/10)" },
  { code: "609", name: "Turistik Mağazalara Verilen Müşteri Bulma / Götürme Hizmetleri", rate: 90, label: "609 - Turistik Müşteri Hizmetleri (9/10)" },
  { code: "610", name: "Spor Kulüplerinin Yayın, Reklam ve İsim Hakkı Gelirleri", rate: 70, label: "610 - Spor Kulüpleri Yayın/Reklam (7/10)" },
  { code: "611", name: "Servis Taşımacılığı Hizmeti / Diğer Hizmetler", rate: 50, label: "611 - Servis Taşımacılığı / Diğer (5/10)" },
  { code: "612", name: "Hurda ve Atık Teslimi", rate: 100, label: "612 - Hurda ve Atık Teslimi (%100 Tam Tevkifat)" },
  { code: "613", name: "Metal, Plastik, Lastik, Kauçuk, Kağıt, Cam Hurda ve Atıkları Teslimi", rate: 70, label: "613 - Hurda Metal/Plastik/Kağıt (7/10)" },
  { code: "614", name: "Pamuk, Tiftik, Yün ve Yapağı ile Ham Post ve Deri Teslimleri", rate: 90, label: "614 - Deri, Pamuk ve Yün Teslimleri (9/10)" },
  { code: "615", name: "Ağaç ve Orman Ürünleri Teslimi", rate: 90, label: "615 - Ağaç ve Orman Ürünleri (9/10)" },
  { code: "616", name: "Demir-Çelik Ürünlerinin Teslimi", rate: 50, label: "616 - Demir-Çelik Ürünleri Teslimi (5/10)" },
] as const;

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

/** Resmi GİB KDV Muafiyet / İstisna Kodları */
export const EXEMPTION_CODES = [
  { code: "301", name: "11/1-a Mal İhracatı", label: "301 - 11/1-a Mal İhracatı" },
  { code: "302", name: "11/1-a Hizmet İhracatı", label: "302 - 11/1-a Hizmet İhracatı" },
  { code: "303", name: "11/1-a Ro-Ro ve Konteyner Taşımacılığı", label: "303 - 11/1-a Ro-Ro ve Konteyner" },
  { code: "304", name: "11/1-a Serbest Bölgelerdeki Müşteriler İçin Fason Hizmetler", label: "304 - Serbest Bölge Fason Hizmet" },
  { code: "311", name: "13/a Deniz, Hava ve Demiryolu Taşıma Araçları Teslimi", label: "311 - Taşıma Araçları İmal ve Teslimi" },
  { code: "315", name: "13/d Yatırım Teşvik Belgesi Kapsamında Makine ve Teçhizat Teslimi", label: "315 - Yatırım Teşvik Kapsamı" },
  { code: "317", name: "13/f Ar-Ge ve Tasarım Faaliyetlerinde Kullanılan Makine-Teçhizat Teslimi", label: "317 - Ar-Ge ve Tasarım Faaliyetleri" },
  { code: "350", name: "17/4-g Külçe Altın, Külçe Gümüş ve Kıymetli Taşların Teslimi", label: "350 - Külçe Altın/Gümüş Teslimi" },
  { code: "351", name: "17/4-g Metal, Plastik, Lastik, Kağıt, Cam Hurda ve Atık Teslimi", label: "351 - Hurda ve Atık Teslimi" },
  { code: "352", name: "17/4-y Serbest Bölgelerde İfa Edilen Hizmetler", label: "352 - Serbest Bölge İçi Hizmetler" },
  { code: "353", name: "17/4-z Teknoloji Geliştirme Bölgesinde (Teknokent) Üretilen Yazılım Teslimleri", label: "353 - Teknokent / Yazılım Teslimi" },
  { code: "250", name: "Diğer KDV İstisnaları ve Muafiyetler", label: "250 - Diğer KDV İstisnaları" },
] as const;

export const CURRENCY_OPTIONS = [
  { code: "TRY", symbol: "₺", label: "Türk Lirası (TRY)" },
  { code: "USD", symbol: "$", label: "Amerikan Doları (USD)" },
  { code: "EUR", symbol: "€", label: "Euro (EUR)" },
  { code: "GBP", symbol: "£", label: "İngiliz Sterlini (GBP)" },
] as const;

export const UNIT_OPTIONS = [
  "Adet",
  "Kg",
  "Gram",
  "Metre",
  "m² (Metrekare)",
  "m³ (Metreküp)",
  "Litre",
  "Paket",
  "Koli",
  "Kutu",
  "Takım",
  "Saat",
  "Gün",
  "Ay",
  "Hizmet",
  "Ton",
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
    code: "",
    name: "",
    unit: "Adet",
    quantity: 1,
    unitPrice: 0,
    discountRate: 0,
    vatRate: 20,
    description: "",
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

  const vatBreakdown: Record<number, { taxable: number; vat: number }> = {
    0: { taxable: 0, vat: 0 },
    1: { taxable: 0, vat: 0 },
    10: { taxable: 0, vat: 0 },
    20: { taxable: 0, vat: 0 },
  };

  for (const item of items) {
    const t = itemTotals(item);
    subtotal = roundMoney(subtotal + t.gross);
    totalDiscount = roundMoney(totalDiscount + t.discount);
    taxableAmount = roundMoney(taxableAmount + t.taxable);
    totalVat = roundMoney(totalVat + t.vat);

    const vRate = Number(item.vatRate) || 0;
    if (!vatBreakdown[vRate]) {
      vatBreakdown[vRate] = { taxable: 0, vat: 0 };
    }
    vatBreakdown[vRate].taxable = roundMoney(vatBreakdown[vRate].taxable + t.taxable);
    vatBreakdown[vRate].vat = roundMoney(vatBreakdown[vRate].vat + t.vat);
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
    vatBreakdown,
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

export function generateEttn(): string {
  return crypto.randomUUID().toLowerCase();
}

/**
 * Müşteriye özel seri ön eki ile fatura numarası üretimi (ör. EAR2026000000001, ABC2026000000001)
 * Not: GİB öneki sadece Gelir İdaresi Portalına aittir, entegratör/özel programlarda firmaya özel veya EAR kullanılır.
 */
export function generateInvoiceNumber(count: number, prefix = "EAR") {
  const year = new Date().getFullYear();
  let cleanPrefix = (prefix || "EAR").replace(/[^a-zA-Z0-9]/g, "").toUpperCase();
  if (cleanPrefix === "GIB") cleanPrefix = "EAR";
  const safePrefix = (cleanPrefix.length >= 3 ? cleanPrefix.slice(0, 3) : cleanPrefix.padEnd(3, "E"));
  return `${safePrefix}${year}${String(Math.max(1, count + 1)).padStart(9, "0")}`;
}

/**
 * Sayısal tutarı resmi fatura standardında Türkçe metne ("YAZI İLE: ...") çevirir.
 * Örnek: 1450.50 => "Yalnız Bin Dört Yüz Elli Türk Lirası Elli Kuruş"
 */
export function numberToTurkishWords(amount: number, currency = "TRY"): string {
  const safe = Math.abs(Number(amount) || 0);
  const lira = Math.floor(safe);
  const kurus = Math.round((safe - lira) * 100);

  const ones = ["", "Bir", "İki", "Üç", "Dört", "Beş", "Altı", "Yedi", "Sekiz", "Dokuz"];
  const tens = ["", "On", "Yirmi", "Otuz", "Kırk", "Elli", "Altmış", "Yetmiş", "Seksen", "Doksan"];

  function convertGroup(num: number): string {
    const h = Math.floor(num / 100);
    const t = Math.floor((num % 100) / 10);
    const o = num % 10;
    let res = "";
    if (h > 1) res += ones[h] + " Yüz ";
    else if (h === 1) res += "Yüz ";
    if (t > 0) res += tens[t] + " ";
    if (o > 0) res += ones[o] + " ";
    return res.trim();
  }

  function numberToWordsInt(num: number): string {
    if (num === 0) return "Sıfır";
    const billions = Math.floor(num / 1_000_000_000);
    const millions = Math.floor((num % 1_000_000_000) / 1_000_000);
    const thousands = Math.floor((num % 1_000_000) / 1_000);
    const remainder = num % 1_000;

    let text = "";
    if (billions > 0) text += (billions === 1 ? "Bir Milyar " : convertGroup(billions) + " Milyar ");
    if (millions > 0) text += (millions === 1 ? "Bir Milyon " : convertGroup(millions) + " Milyon ");
    if (thousands > 0) text += (thousands === 1 ? "Bin " : convertGroup(thousands) + " Bin ");
    if (remainder > 0) text += convertGroup(remainder);

    return text.trim();
  }

  const currencyNames: Record<string, { main: string; sub: string }> = {
    TRY: { main: "Türk Lirası", sub: "Kuruş" },
    USD: { main: "Amerikan Doları", sub: "Cent" },
    EUR: { main: "Euro", sub: "Cent" },
    GBP: { main: "İngiliz Sterlini", sub: "Pence" },
  };

  const curr = currencyNames[currency] || { main: currency, sub: "Kuruş" };
  const liraText = numberToWordsInt(lira);
  let result = `Yalnız ${liraText} ${curr.main}`;

  if (kurus > 0) {
    const kurusText = numberToWordsInt(kurus);
    result += ` ${kurusText} ${curr.sub}`;
  }

  return result.replace(/\s+/g, " ").trim();
}

/** Türkiye VKN (Vergi Kimlik Numarası) 10 hane algoritma kontrolü */
export function isValidVKN(vkn: string): boolean {
  return validateVKN(vkn.replace(/\D/g, "")).isValid;
}

/** Türkiye TCKN (T.C. Kimlik Numarası) 11 hane algoritma kontrolü */
export function isValidTCKN(tckn: string): boolean {
  return validateTCKN(tckn.replace(/\D/g, "")).isValid;
}

export function isValidVknTckn(val: string): boolean {
  return validateVknTckn(val.replace(/\D/g, "")).isValid;
}

