import { createFileRoute, useNavigate, Link } from "@tanstack/react-router";
import { useState, useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import { ArrowLeft, Plus, Trash2, Send, Save, FileText, UserCheck, FileCode, Copy, Download } from "lucide-react";
import { toast } from "sonner";

import { AppShell } from "@/components/AppShell";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogFooter,
} from "@/components/ui/dialog";
import { Badge } from "@/components/ui/badge";
import { supabase } from "@/integrations/supabase/client";
import { apiFetch } from "@/lib/api-client";
import { validateVknTckn } from "@/lib/validation";
import { createUblTrInvoice, parseUblXmlForensic, roundDecimal } from "@/lib/ubl";
import { formatMoney } from "@/lib/invoice";
import { generateUUID } from "@/lib/uuid";
import { getMyCompanyProfile } from "@/lib/profile.functions";

const POPULAR_TAX_OFFICES = [
  "Kadıköy V.D.",
  "Beşiktaş V.D.",
  "Şişli V.D.",
  "Ümraniye V.D.",
  "Kızılay V.D.",
  "Çankaya V.D.",
  "Karşıyaka V.D.",
  "Nilüfer V.D.",
  "Meram V.D.",
  "Seyhan V.D.",
  "Bornova V.D.",
  "Konak V.D.",
  "Büyük Mükellefler V.D.",
];

const TURKEY_CITIES = [
  "Adana",
  "Adıyaman",
  "Afyonkarahisar",
  "Ağrı",
  "Amasya",
  "Ankara",
  "Antalya",
  "Artvin",
  "Aydın",
  "Balıkesir",
  "Bilecik",
  "Bingöl",
  "Bitlis",
  "Bolu",
  "Burdur",
  "Bursa",
  "Çanakkale",
  "Çankırı",
  "Çorum",
  "Denizli",
  "Diyarbakır",
  "Edirne",
  "Elazığ",
  "Erzincan",
  "Erzurum",
  "Eskişehir",
  "Gaziantep",
  "Giresun",
  "Gümüşhane",
  "Hakkari",
  "Hatay",
  "Isparta",
  "Mersin",
  "İstanbul",
  "İzmir",
  "Kars",
  "Kastamonu",
  "Kayseri",
  "Kırklareli",
  "Kırşehir",
  "Kocaeli",
  "Konya",
  "Kütahya",
  "Malatya",
  "Manisa",
  "Kahramanmaraş",
  "Mardin",
  "Muğla",
  "Muş",
  "Nevşehir",
  "Niğde",
  "Ordu",
  "Rize",
  "Sakarya",
  "Samsun",
  "Siirt",
  "Sinop",
  "Sivas",
  "Tekirdağ",
  "Tokat",
  "Trabzon",
  "Tunceli",
  "Şanlıurfa",
  "Uşak",
  "Van",
  "Yozgat",
  "Zonguldak",
  "Aksaray",
  "Bayburt",
  "Karaman",
  "Kırıkkale",
  "Batman",
  "Şırnak",
  "Bartın",
  "Ardahan",
  "Iğdır",
  "Yalova",
  "Karabük",
  "Kilis",
  "Osmaniye",
  "Düzce",
];

export const Route = createFileRoute("/_authenticated/faturalar/yeni")({
  component: NewInvoicePage,
});

interface FormLine {
  id: string;
  name: string;
  description: string;
  quantity: number;
  unit: string;
  unitPrice: number;
  discountRate: number;
  vatRate: number;
}

function NewInvoicePage() {
  const navigate = useNavigate();

  // Kayıtlı Müşterileri Çek
  const { data: customers = [] } = useQuery({
    queryKey: ["customers-dropdown"],
    queryFn: async () => {
      const { data, error } = await supabase.from("customers").select("*").order("title");
      if (error) {
        console.error("Müşteri hatası:", error);
        return [];
      }
      return data || [];
    },
  });

  // Form State
  const [profileId, setProfileId] = useState<"EARSIVFATURA" | "TICARIFATURA" | "TEMELFATURA">(
    "EARSIVFATURA",
  );
  const [invoiceTypeCode, setInvoiceTypeCode] = useState<"SATIS" | "IADE" | "TEVKIFAT" | "ISTISNA">(
    "SATIS",
  );
  const [currency, setCurrency] = useState("TRY");
  const [customInvoiceNumber, setCustomInvoiceNumber] = useState("");
  const [issueDate, setIssueDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [issueTime, setIssueTime] = useState(() => new Date().toISOString().slice(11, 19));

  // Satıcı Bilgileri
  const [sellerName, setSellerName] = useState("Fuat Ekiz Teknoloji A.Ş.");
  const [sellerTaxNumber, setSellerTaxNumber] = useState("3230512384");

  // Alıcı Bilgileri
  const [buyerName, setBuyerName] = useState("");
  const [buyerTaxNumber, setBuyerTaxNumber] = useState("");
  const [buyerTaxOffice, setBuyerTaxOffice] = useState("");
  const [buyerAddress, setBuyerAddress] = useState("");
  const [buyerCity, setBuyerCity] = useState("");
  const [buyerDistrict, setBuyerDistrict] = useState("");

  const [note, setNote] = useState("");
  const [lines, setLines] = useState<FormLine[]>([
    {
      id: "1",
      name: "Yazılım ve Danışmanlık Hizmeti",
      description: "",
      quantity: 1,
      unit: "C62",
      unitPrice: 1000,
      discountRate: 0,
      vatRate: 20,
    },
  ]);

  const [submitting, setSubmitting] = useState(false);

  // XML Forensic Modal State
  const [showXmlModal, setShowXmlModal] = useState(false);
  const [previewXmlString, setPreviewXmlString] = useState("");

  // Firma Profili (Satıcı VKN)
  const { data: companyProfile } = useQuery({
    queryKey: ["company-profile"],
    queryFn: () => getMyCompanyProfile(),
  });

  function handlePreviewXml() {
    try {
      const ettn = generateUUID();
      const ublXml = createUblTrInvoice({
        uuid: ettn,
        invoiceNumber: customInvoiceNumber.trim() || `EAR${new Date().getFullYear()}000000001`,
        issueDate,
        issueTime,
        currency,
        profileId,
        invoiceTypeCode,
        seller: {
          taxNumber: companyProfile?.vknTckn || sellerTaxNumber.trim() || "1234567801",
          name: companyProfile?.companyTitle || sellerName.trim() || "Satıcı Firma",
          taxOffice: companyProfile?.taxOffice || "",
          address: companyProfile?.address || "",
        },
        buyer: {
          taxNumber: buyerTaxNumber.trim() || "11111111111",
          name: buyerName.trim() || "Alıcı Müşteri",
          taxOffice: buyerTaxOffice.trim(),
          address: buyerAddress.trim(),
          city: buyerCity.trim(),
          district: buyerDistrict.trim(),
        },
        lines: lines.map((l) => ({
          name: l.name || "Ürün/Hizmet",
          quantity: Number(l.quantity) || 1,
          unitPrice: Number(l.unitPrice) || 0,
          discountRate: Number(l.discountRate) || 0,
          vatRate: Number(l.vatRate) || 20,
        })),
        note: note.trim(),
      });

      setPreviewXmlString(ublXml);
      setShowXmlModal(true);

      const forensic = parseUblXmlForensic(ublXml);
      console.log("[NES XML FORENSIC]", {
        supplierVkn: forensic.supplierVkn,
        customerVkn: forensic.customerVkn,
        supplierEndpointId: forensic.supplierEndpointId,
        customerEndpointId: forensic.customerEndpointId,
        xmlLength: forensic.xmlLength,
      });
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : "XML önizleme oluşturulamadı.");
    }
  }

  // VKN / TCKN Validation State
  const taxValidation = useMemo(() => {
    if (!buyerTaxNumber.trim()) return null;
    return validateVknTckn(buyerTaxNumber.trim());
  }, [buyerTaxNumber]);

  // Hesaplamalar
  const totals = useMemo(() => {
    let grossTotal = 0;
    let totalDiscount = 0;
    let subTotal = 0;
    let taxTotal = 0;
    const vatGroupsMap = new Map<number, { taxable: number; tax: number }>();

    for (const l of lines) {
      const q = Math.max(0, l.quantity || 0);
      const p = Math.max(0, l.unitPrice || 0);
      const discRate = Math.min(100, Math.max(0, l.discountRate || 0));
      const gross = roundDecimal(q * p, 2);
      const discAmt = roundDecimal((gross * discRate) / 100, 2);
      const lineExt = roundDecimal(gross - discAmt, 2);
      const lineVat = roundDecimal(lineExt * ((l.vatRate || 0) / 100), 2);

      grossTotal += gross;
      totalDiscount += discAmt;
      subTotal += lineExt;
      taxTotal += lineVat;

      const group = vatGroupsMap.get(l.vatRate) || { taxable: 0, tax: 0 };
      vatGroupsMap.set(l.vatRate, {
        taxable: roundDecimal(group.taxable + lineExt, 2),
        tax: roundDecimal(group.tax + lineVat, 2),
      });
    }

    grossTotal = roundDecimal(grossTotal, 2);
    totalDiscount = roundDecimal(totalDiscount, 2);
    subTotal = roundDecimal(subTotal, 2);
    taxTotal = roundDecimal(taxTotal, 2);
    const grandTotal = roundDecimal(subTotal + taxTotal, 2);

    return {
      grossTotal,
      totalDiscount,
      subTotal,
      taxTotal,
      grandTotal,
      vatGroups: Array.from(vatGroupsMap.entries()).map(([rate, val]) => ({
        rate,
        taxable: val.taxable,
        tax: val.tax,
      })),
    };
  }, [lines]);

  function addLine() {
    setLines((prev) => [
      ...prev,
      {
        id: String(Date.now()),
        name: "",
        description: "",
        quantity: 1,
        unit: "C62",
        unitPrice: 0,
        discountRate: 0,
        vatRate: 20,
      },
    ]);
  }

  function removeLine(id: string) {
    if (lines.length <= 1) {
      toast.error("Faturada en az 1 satır kalem olmalıdır.");
      return;
    }
    setLines((prev) => prev.filter((l) => l.id !== id));
  }

  function updateLine(id: string, field: keyof FormLine, value: any) {
    setLines((prev) => prev.map((l) => (l.id === id ? { ...l, [field]: value } : l)));
  }

  function validateForm(): boolean {
    if (customInvoiceNumber.trim()) {
      const INVOICE_NUMBER_REGEX = /^[A-Za-z0-9]{3}(?:19|20)\d{2}\d{9}$/;
      if (!INVOICE_NUMBER_REGEX.test(customInvoiceNumber.trim())) {
        toast.error(
          "Geçersiz Fatura Numarası: 3 hane seri ön eki, 4 hane yıl ve 9 hane sıra numarasından (toplam 16 karakter) oluşmalıdır (Örn: EAR2026000000001).",
        );
        return false;
      }
    }
    if (!buyerName.trim()) {
      toast.error("Lütfen alıcı unvanını/adını giriniz.");
      return false;
    }
    if (!buyerTaxNumber.trim()) {
      toast.error("Lütfen alıcı VKN veya TCKN numarasını giriniz.");
      return false;
    }
    if (taxValidation && !taxValidation.isValid) {
      toast.error(`Geçersiz VKN/TCKN: ${taxValidation.message}`);
      return false;
    }
    if (lines.length === 0) {
      toast.error("En az 1 fatura kalemi girmelisiniz.");
      return false;
    }
    for (let i = 0; i < lines.length; i++) {
      if (!lines[i].name.trim()) {
        toast.error(`Satır #${i + 1} için ürün/hizmet adı boş olamaz.`);
        return false;
      }
    }
    return true;
  }

  async function handleSaveDraft() {
    if (!validateForm()) return;
    setSubmitting(true);

    try {
      const payload = {
        invoiceNumber: customInvoiceNumber.trim(),
        issueDate,
        issueTime,
        currency,
        profileId,
        invoiceTypeCode,
        seller: {
          taxNumber: sellerTaxNumber.trim() || "3230512384",
          name: sellerName.trim() || "Fuat Ekiz Teknoloji A.Ş.",
        },
        buyer: {
          taxNumber: buyerTaxNumber.trim(),
          name: buyerName.trim(),
          taxOffice: buyerTaxOffice.trim(),
          address: buyerAddress.trim(),
          city: buyerCity.trim(),
          district: buyerDistrict.trim(),
        },
        lines: lines.map((l) => ({
          name: l.name,
          quantity: l.quantity,
          unitPrice: l.unitPrice,
          discountRate: l.discountRate || 0,
          vatRate: l.vatRate,
        })),
        note,
      };

      const res = await apiFetch("/api/invoices/draft", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });

      const json = await res.json();
      if (!res.ok || !json.success) {
        throw new Error(json.message || "Taslak kaydı başarısız.");
      }

      toast.success(`Fatura taslak olarak kaydedildi (No: ${json.invoiceNumber}).`);
      navigate({ to: "/faturalar" });
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : "Taslak kaydı sırasında hata oluştu.");
    } finally {
      setSubmitting(false);
    }
  }

  async function handleSendToEdm() {
    if (!validateForm()) return;

    const confirmed = window.confirm(
      "Bu işlem e-Faturayı EDM entegratör sistemine iletecektir. Devam etmek istiyor musunuz?",
    );
    if (!confirmed) return;

    setSubmitting(true);

    try {
      const payload = {
        invoiceNumber: customInvoiceNumber.trim(),
        issueDate,
        issueTime,
        currency,
        profileId,
        invoiceTypeCode,
        seller: {
          taxNumber: sellerTaxNumber.trim() || "3230512384",
          name: sellerName.trim() || "Fuat Ekiz Teknoloji A.Ş.",
        },
        buyer: {
          taxNumber: buyerTaxNumber.trim(),
          name: buyerName.trim(),
          taxOffice: buyerTaxOffice.trim(),
          address: buyerAddress.trim(),
          city: buyerCity.trim(),
          district: buyerDistrict.trim(),
        },
        lines: lines.map((l) => ({
          name: l.name,
          quantity: l.quantity,
          unitPrice: l.unitPrice,
          discountRate: l.discountRate || 0,
          vatRate: l.vatRate,
        })),
        note,
      };

      const res = await apiFetch("/api/edm/invoice", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });

      const json = await res.json();
      if (!res.ok || !json.success) {
        throw new Error(json.message || "EDM gönderim hatası.");
      }

      toast.success(
        `Fatura EDM TEST ortamına başarıyla gönderildi!\nFatura No: ${json.invoiceNumber}\nEDM Ref: ${json.edmReference || "TRXID Alındı"}`,
      );

      navigate({ to: "/faturalar" });
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : "Fatura gönderiminde bir hata oluştu.");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <AppShell
      title="Yeni e-Fatura Oluştur (EDM TEST)"
      subtitle="UBL-TR 2.1 standardında resmî e-Fatura hazırlama ve EDM Bilişim entegrasyonu"
      actions={
        <div className="flex gap-2">
          <Button variant="outline" onClick={() => navigate({ to: "/faturalar" })}>
            <ArrowLeft className="mr-1 size-4" /> Faturalara Dön
          </Button>
          <Button
            variant="outline"
            onClick={handlePreviewXml}
            className="gap-1.5 border-indigo-500/40 text-indigo-600 dark:text-indigo-400 hover:bg-indigo-50 dark:hover:bg-indigo-950/40"
          >
            <FileCode className="size-4" /> XML'i Görüntüle
          </Button>
          <Button variant="secondary" disabled={submitting} onClick={handleSaveDraft}>
            <Save className="mr-1 size-4" /> Taslak Kaydet
          </Button>
          <Button
            disabled={submitting}
            onClick={handleSendToEdm}
            className="bg-primary text-primary-foreground"
          >
            <Send className="mr-1 size-4" /> {submitting ? "İletiliyor..." : "EDM TEST'e Gönder"}
          </Button>
        </div>
      }
    >
      <div className="space-y-6">
        {/* Üst Bilgi Kartı */}
        <Card>
          <CardHeader className="py-4">
            <CardTitle className="text-base flex items-center gap-2">
              <FileText className="size-5 text-primary" /> Fatura Başlık & Profil Ayarları
            </CardTitle>
          </CardHeader>
          <CardContent className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-4 gap-4">
            <div className="space-y-2">
              <Label>Fatura Senaryosu (Profil)</Label>
              <Select value={profileId} onValueChange={(v: any) => setProfileId(v)}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="EARSIVFATURA">e-Arşiv Fatura</SelectItem>
                  <SelectItem value="TICARIFATURA">Ticari Fatura (GİB)</SelectItem>
                  <SelectItem value="TEMELFATURA">Temel Fatura (GİB)</SelectItem>
                </SelectContent>
              </Select>
            </div>

            <div className="space-y-2">
              <Label>Fatura Tipi</Label>
              <Select value={invoiceTypeCode} onValueChange={(v: any) => setInvoiceTypeCode(v)}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="SATIS">Satış Faturası</SelectItem>
                  <SelectItem value="IADE">İade Faturası</SelectItem>
                  <SelectItem value="TEVKIFAT">Tevkifatlı Fatura</SelectItem>
                  <SelectItem value="ISTISNA">İstisna (%0 KDV)</SelectItem>
                </SelectContent>
              </Select>
            </div>

            <div className="space-y-2">
              <Label>Özel Fatura No (Opsiyonel)</Label>
              <Input
                placeholder="Örn: MRF2026000000001"
                value={customInvoiceNumber}
                onChange={(e) => setCustomInvoiceNumber(e.target.value)}
              />
            </div>

            <div className="space-y-2">
              <Label>Fatura Tarihi</Label>
              <Input type="date" value={issueDate} onChange={(e) => setIssueDate(e.target.value)} />
            </div>
          </CardContent>
        </Card>

        {/* Satıcı ve Alıcı Kartları */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
          {/* Satıcı (Biz) */}
          <Card>
            <CardHeader className="py-4 bg-muted/30">
              <CardTitle className="text-sm font-semibold">Satıcı Bilgileri (Düzenleyen)</CardTitle>
            </CardHeader>
            <CardContent className="space-y-3 pt-4 text-xs">
              <div>
                <Label className="text-xs">Firma Unvanı</Label>
                <Input value={sellerName} onChange={(e) => setSellerName(e.target.value)} />
              </div>
              <div>
                <Label className="text-xs">VKN / TCKN</Label>
                <Input
                  value={sellerTaxNumber}
                  onChange={(e) => setSellerTaxNumber(e.target.value)}
                />
              </div>
            </CardContent>
          </Card>

          {/* Alıcı (Müşteri) */}
          <Card>
            <CardHeader className="py-4 bg-muted/30">
              <CardTitle className="text-sm font-semibold flex items-center justify-between">
                <span>Alıcı Müşteri Bilgileri</span>
                {taxValidation && (
                  <Badge variant={taxValidation.isValid ? "secondary" : "destructive"}>
                    {taxValidation.type} - {taxValidation.isValid ? "Geçerli" : "Hatalı"}
                  </Badge>
                )}
              </CardTitle>
            </CardHeader>
            <CardContent className="space-y-3 pt-4 text-xs">
              {/* Kayıtlı Müşterilerden Seç (Hızlı Doldur) */}
              {customers.length > 0 && (
                <div className="space-y-1 bg-primary/5 p-2 rounded border border-primary/20">
                  <Label className="text-xs font-semibold text-primary">
                    Kayıtlı Müşteri / Cari Seç (Hızlı Doldur)
                  </Label>
                  <Select
                    onValueChange={(custId) => {
                      const c = customers.find((item: any) => item.id === custId);
                      if (c) {
                        setBuyerName(c.title || "");
                        setBuyerTaxNumber(c.vkn_tckn || "");
                        setBuyerTaxOffice(c.tax_office || "");
                        setBuyerAddress(c.address || "");
                        setBuyerCity(c.city || "");
                        setBuyerDistrict(c.district || "");
                        toast.success(`${c.title} bilgileri forma aktarıldı.`);
                      }
                    }}
                  >
                    <SelectTrigger className="bg-background">
                      <SelectValue placeholder="-- Kayıtlı Müşterilerinizden Seçin --" />
                    </SelectTrigger>
                    <SelectContent>
                      {customers.map((c: any) => (
                        <SelectItem key={c.id} value={c.id}>
                          {c.title || c.name} ({c.vkn_tckn || c.tax_number || c.tckn || "No VKN"})
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
              )}

              <div>
                <Label className="text-xs">Müşteri Unvanı / Adı Soyadı *</Label>
                <Input
                  placeholder="Örn: Demo Müşteri Ticaret Ltd. Şti."
                  value={buyerName}
                  onChange={(e) => setBuyerName(e.target.value)}
                />
              </div>
              <div className="grid grid-cols-2 gap-2">
                <div>
                  <Label className="text-xs">VKN (10) / TCKN (11) *</Label>
                  <Input
                    placeholder="VKN veya TCKN"
                    value={buyerTaxNumber}
                    onChange={(e) => setBuyerTaxNumber(e.target.value)}
                  />
                </div>
                <div>
                  <Label className="text-xs">Vergi Dairesi</Label>
                  <div className="space-y-1">
                    <Input
                      placeholder="Örn: Kadıköy V.D."
                      value={buyerTaxOffice}
                      onChange={(e) => setBuyerTaxOffice(e.target.value)}
                    />
                    <Select onValueChange={(v) => setBuyerTaxOffice(v)}>
                      <SelectTrigger className="h-7 text-[11px]">
                        <SelectValue placeholder="Listeden seçin (Opsiyonel)" />
                      </SelectTrigger>
                      <SelectContent>
                        {POPULAR_TAX_OFFICES.map((vd) => (
                          <SelectItem key={vd} value={vd}>
                            {vd}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  </div>
                </div>
              </div>
              <div>
                <Label className="text-xs">Adres</Label>
                <Input
                  placeholder="Cadde, sokak, bina no"
                  value={buyerAddress}
                  onChange={(e) => setBuyerAddress(e.target.value)}
                />
              </div>
              <div className="grid grid-cols-2 gap-2">
                <div>
                  <Label className="text-xs">İl</Label>
                  <div className="space-y-1">
                    <Input
                      placeholder="Örn: İstanbul"
                      value={buyerCity}
                      onChange={(e) => setBuyerCity(e.target.value)}
                    />
                    <Select onValueChange={(v) => setBuyerCity(v)}>
                      <SelectTrigger className="h-7 text-[11px]">
                        <SelectValue placeholder="İl seçin" />
                      </SelectTrigger>
                      <SelectContent className="max-h-56">
                        {TURKEY_CITIES.map((city) => (
                          <SelectItem key={city} value={city}>
                            {city}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  </div>
                </div>
                <div>
                  <Label className="text-xs">İlçe</Label>
                  <Input
                    placeholder="Örn: Kadıköy"
                    value={buyerDistrict}
                    onChange={(e) => setBuyerDistrict(e.target.value)}
                  />
                </div>
              </div>
            </CardContent>
          </Card>
        </div>

        {/* Satır Kalemleri */}
        <Card>
          <CardHeader className="py-4 flex flex-row items-center justify-between">
            <CardTitle className="text-base">Fatura Satır Kalemleri</CardTitle>
            <Button size="sm" variant="outline" onClick={addLine}>
              <Plus className="mr-1 size-4" /> Satır Ekle
            </Button>
          </CardHeader>
          <CardContent className="space-y-3">
            {lines.map((line, idx) => (
              <div
                key={line.id}
                className="grid grid-cols-1 sm:grid-cols-12 gap-2 sm:items-center border p-3 rounded-md bg-card"
              >
                <div className="sm:col-span-1 font-bold text-xs text-muted-foreground flex justify-between sm:justify-center">
                  <span>Satır</span>
                  <span>#{idx + 1}</span>
                </div>
                <div className="sm:col-span-3">
                  <Input
                    placeholder="Ürün / Hizmet Adı *"
                    value={line.name}
                    onChange={(e) => updateLine(line.id, "name", e.target.value)}
                  />
                </div>
                <div className="sm:col-span-2">
                  <Input
                    type="number"
                    min="0.0001"
                    step="any"
                    placeholder="Miktar"
                    defaultValue={line.quantity === 0 ? "" : line.quantity}
                    onBlur={(e) => {
                      const val = e.target.value.replace(",", ".");
                      updateLine(line.id, "quantity", val === "" ? 0 : Number(val));
                    }}
                  />
                </div>
                <div className="sm:col-span-2">
                  <Input
                    type="number"
                    step="any"
                    placeholder="Birim Fiyat (TL)"
                    defaultValue={line.unitPrice === 0 ? "" : line.unitPrice}
                    onBlur={(e) => {
                      const val = e.target.value.replace(",", ".");
                      updateLine(line.id, "unitPrice", val === "" ? 0 : Number(val));
                    }}
                  />
                </div>
                <div className="sm:col-span-2">
                  <Input
                    type="number"
                    min="0"
                    max="100"
                    step="any"
                    placeholder="İsk. %"
                    defaultValue={line.discountRate === 0 ? "" : line.discountRate}
                    onBlur={(e) => {
                      const val = e.target.value.replace(",", ".");
                      updateLine(line.id, "discountRate", val === "" ? 0 : Number(val));
                    }}
                  />
                </div>
                <div className="sm:col-span-1">
                  <Select
                    value={String(line.vatRate)}
                    onValueChange={(v) => updateLine(line.id, "vatRate", parseInt(v, 10))}
                  >
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="0">%0 KDV</SelectItem>
                      <SelectItem value="1">%1 KDV</SelectItem>
                      <SelectItem value="10">%10 KDV</SelectItem>
                      <SelectItem value="20">%20 KDV</SelectItem>
                    </SelectContent>
                  </Select>
                </div>
                <div className="sm:col-span-1 text-right">
                  <Button
                    size="icon"
                    variant="ghost"
                    className="text-destructive"
                    onClick={() => removeLine(line.id)}
                  >
                    <Trash2 className="size-4" />
                  </Button>
                </div>
              </div>
            ))}
          </CardContent>
        </Card>

        {/* Dip Not ve Toplamlar */}
        <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
          <Card className="md:col-span-2">
            <CardHeader className="py-3">
              <CardTitle className="text-sm font-semibold">Fatura Notu</CardTitle>
            </CardHeader>
            <CardContent>
              <Textarea
                placeholder="Fatura alt notu (Örn: Banka IBAN bilgileri, ödeme şartları...)"
                rows={3}
                value={note}
                onChange={(e) => setNote(e.target.value)}
              />
            </CardContent>
          </Card>

          <Card className="bg-muted/20">
            <CardHeader className="py-3">
              <CardTitle className="text-sm font-semibold">Hesaplanan Toplamlar</CardTitle>
            </CardHeader>
            <CardContent className="space-y-2 text-xs">
              <div className="flex justify-between py-1 border-b">
                <span className="text-muted-foreground">Brüt Tutar:</span>
                <span className="font-mono font-semibold">{totals.grossTotal.toFixed(2)} TL</span>
              </div>
              {totals.totalDiscount > 0 && (
                <div className="flex justify-between py-1 border-b text-amber-600 dark:text-amber-400">
                  <span>İskonto Toplamı:</span>
                  <span className="font-mono font-semibold">
                    -{totals.totalDiscount.toFixed(2)} TL
                  </span>
                </div>
              )}
              <div className="flex justify-between py-1 border-b">
                <span className="text-muted-foreground">Net Matrah:</span>
                <span className="font-mono font-semibold">{totals.subTotal.toFixed(2)} TL</span>
              </div>
              {totals.vatGroups.map((g) => (
                <div key={g.rate} className="flex justify-between text-muted-foreground py-0.5">
                  <span>KDV (%{g.rate}):</span>
                  <span className="font-mono">{g.tax.toFixed(2)} TL</span>
                </div>
              ))}
              <div className="flex justify-between py-1 border-b font-semibold">
                <span className="text-muted-foreground">Toplam KDV:</span>
                <span className="font-mono text-primary">{totals.taxTotal.toFixed(2)} TL</span>
              </div>
              <div className="flex justify-between py-2 text-sm font-bold text-foreground">
                <span>Genel Toplam:</span>
                <span className="font-mono text-lg text-emerald-600 dark:text-emerald-400">
                  {totals.grandTotal.toFixed(2)} TL
                </span>
              </div>
            </CardContent>
          </Card>
        </div>
      </div>

      {/* NES UBL-TR 2.1 XML FORENSIC MODAL */}
      <Dialog open={showXmlModal} onOpenChange={setShowXmlModal}>
        <DialogContent className="max-w-4xl max-h-[85vh] flex flex-col">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2 text-base font-bold">
              <FileCode className="size-5 text-indigo-600 dark:text-indigo-400" /> NES UBL-TR 2.1 XML Forensic Önizleme
            </DialogTitle>
            <DialogDescription className="text-xs">
              NES API sunucusuna iletilmek üzere oluşturulan ham UBL-TR 2.1 XML belgesi ve doğrulanmış parti metadataları.
            </DialogDescription>
          </DialogHeader>

          {(() => {
            const metadata = parseUblXmlForensic(previewXmlString);
            return (
              <div className="space-y-4 overflow-y-auto pr-1 flex-1">
                {/* FORENSIC METADATA CARDS */}
                <div className="grid grid-cols-2 md:grid-cols-4 gap-3 bg-muted/40 p-3 rounded-lg border border-border/60 text-xs">
                  <div className="space-y-1">
                    <span className="text-muted-foreground text-[11px] block font-medium">Gönderici VKN / TCKN</span>
                    <span className="font-mono font-bold text-indigo-600 dark:text-indigo-400 block">{metadata.supplierVkn}</span>
                  </div>
                  <div className="space-y-1">
                    <span className="text-muted-foreground text-[11px] block font-medium">Alıcı VKN / TCKN</span>
                    <span className="font-mono font-bold text-emerald-600 dark:text-emerald-400 block">{metadata.customerVkn}</span>
                  </div>
                  <div className="space-y-1">
                    <span className="text-muted-foreground text-[11px] block font-medium">Gönderici EndpointID</span>
                    <span className="font-mono text-[11px] text-foreground truncate block" title={metadata.supplierEndpointId}>{metadata.supplierEndpointId}</span>
                  </div>
                  <div className="space-y-1">
                    <span className="text-muted-foreground text-[11px] block font-medium">Alıcı EndpointID</span>
                    <span className="font-mono text-[11px] text-foreground truncate block" title={metadata.customerEndpointId}>{metadata.customerEndpointId}</span>
                  </div>
                </div>

                {/* XML CODE DISPLAY AREA */}
                <div className="relative rounded-md border border-border/80 bg-slate-950 text-slate-100 p-4 font-mono text-xs overflow-x-auto max-h-[350px]">
                  <pre className="whitespace-pre">{previewXmlString}</pre>
                </div>
              </div>
            );
          })()}

          <DialogFooter className="flex items-center justify-between sm:justify-between pt-2 border-t">
            <span className="text-xs text-muted-foreground font-mono">
              Uzunluk: {previewXmlString.length} bayt
            </span>
            <div className="flex gap-2">
              <Button
                variant="outline"
                size="sm"
                onClick={() => {
                  navigator.clipboard.writeText(previewXmlString);
                  toast.success("UBL XML kopyalandı!");
                }}
                className="gap-1.5"
              >
                <Copy className="size-3.5" /> Kopyala
              </Button>
              <Button
                variant="default"
                size="sm"
                onClick={() => {
                  const blob = new Blob([previewXmlString], { type: "application/xml" });
                  const url = URL.createObjectURL(blob);
                  const a = document.createElement("a");
                  a.href = url;
                  a.download = `UBL-TR-${parseUblXmlForensic(previewXmlString).uuid}.xml`;
                  a.click();
                  URL.revokeObjectURL(url);
                  toast.success("UBL XML dosyası indirildi!");
                }}
                className="gap-1.5 bg-indigo-600 hover:bg-indigo-700 text-white"
              >
                <Download className="size-3.5" /> XML'i İndir
              </Button>
              <Button variant="ghost" size="sm" onClick={() => setShowXmlModal(false)}>
                Kapat
              </Button>
            </div>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </AppShell>
  );
}
