import { createFileRoute, useNavigate, Link } from "@tanstack/react-router";
import { useState, useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import { ArrowLeft, Plus, Trash2, Send, Save, CheckCircle2, AlertTriangle, FileText } from "lucide-react";
import { toast } from "sonner";

import { AppShell } from "@/components/AppShell";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Badge } from "@/components/ui/badge";
import { supabase } from "@/integrations/supabase/client";
import { validateVknTckn } from "@/lib/validation";
import { roundDecimal } from "@/lib/ubl";

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
  vatRate: number;
}

function NewInvoicePage() {
  const navigate = useNavigate();

  // 1. Seller state
  const { data: profile } = useQuery({
    queryKey: ["profile"],
    queryFn: async () => {
      const { data } = await supabase.from("profiles").select("*").maybeSingle();
      return data;
    },
  });

  const [sellerName, setSellerName] = useState("");
  const [sellerTaxNumber, setSellerTaxNumber] = useState("");

  // Sync profile when loaded
  useMemo(() => {
    if (profile) {
      if (!sellerName && profile.company_title) setSellerName(profile.company_title);
      if (!sellerTaxNumber && profile.vkn_tckn) setSellerTaxNumber(profile.vkn_tckn);
    }
  }, [profile]);

  // 2. Buyer state
  const [buyerType, setBuyerType] = useState<"FIRMA" | "SAHIS">("FIRMA");
  const [buyerTaxNumber, setBuyerTaxNumber] = useState("2222222222"); // Default test VKN
  const [buyerName, setBuyerName] = useState("Demo Alıcı A.Ş.");
  const [buyerTaxOffice, setBuyerTaxOffice] = useState("Kadıköy");
  const [buyerAddress, setBuyerAddress] = useState("Atatürk Cad. No: 123");
  const [buyerCity, setBuyerCity] = useState("İstanbul");
  const [buyerDistrict, setBuyerDistrict] = useState("Kadıköy");
  const [buyerEmail, setBuyerEmail] = useState("alici@demo.com");
  const [buyerPhone, setBuyerPhone] = useState("05551112233");

  // 3. Invoice Header state
  const [invoiceTypeCode, setInvoiceTypeCode] = useState<"SATIS" | "IADE" | "TEVKIFAT" | "ISTISNA">("SATIS");
  const [profileId, setProfileId] = useState<"EARSIVFATURA" | "TICARIFATURA" | "TEMELFATURA">("EARSIVFATURA");
  const [currency, setCurrency] = useState("TRY");
  const [issueDate, setIssueDate] = useState(new Date().toISOString().slice(0, 10));
  const [issueTime, setIssueTime] = useState(new Date().toTimeString().slice(0, 8));
  const [customInvoiceNumber, setCustomInvoiceNumber] = useState(
    "MRF2026" + String(Date.now()).slice(-9)
  );
  const [note, setNote] = useState("e-Fatura TEST gönderimidir.");

  // 4. Lines state
  const [lines, setLines] = useState<FormLine[]>([
    {
      id: "1",
      name: "Yazılım Danışmanlık Hizmeti",
      description: "Aylık e-Fatura entegrasyon desteği",
      quantity: 1,
      unit: "ADET",
      unitPrice: 1000,
      vatRate: 20,
    },
  ]);

  const [submitting, setSubmitting] = useState(false);

  // Line Calculations
  const calculatedLines = useMemo(() => {
    return lines.map((line) => {
      const qty = Math.max(0, Number(line.quantity) || 0);
      const price = Math.max(0, Number(line.unitPrice) || 0);
      const lineSubtotal = roundDecimal(qty * price, 2);
      const vatAmount = roundDecimal((lineSubtotal * (Number(line.vatRate) || 0)) / 100, 2);
      const lineTotal = roundDecimal(lineSubtotal + vatAmount, 2);
      return {
        ...line,
        lineSubtotal,
        vatAmount,
        lineTotal,
      };
    });
  }, [lines]);

  const subTotal = useMemo(
    () => roundDecimal(calculatedLines.reduce((acc, l) => acc + l.lineSubtotal, 0), 2),
    [calculatedLines]
  );

  const vatTotal = useMemo(
    () => roundDecimal(calculatedLines.reduce((acc, l) => acc + l.vatAmount, 0), 2),
    [calculatedLines]
  );

  const grandTotal = useMemo(() => roundDecimal(subTotal + vatTotal, 2), [subTotal, vatTotal]);

  const vatBreakdown = useMemo(() => {
    const map = new Map<number, { taxable: number; vat: number }>();
    for (const l of calculatedLines) {
      const rate = l.vatRate;
      const cur = map.get(rate) || { taxable: 0, vat: 0 };
      map.set(rate, {
        taxable: roundDecimal(cur.taxable + l.lineSubtotal, 2),
        vat: roundDecimal(cur.vat + l.vatAmount, 2),
      });
    }
    return Array.from(map.entries()).sort((a, b) => a[0] - b[0]);
  }, [calculatedLines]);

  function handleAddLine() {
    setLines((prev) => [
      ...prev,
      {
        id: String(Date.now()),
        name: "",
        description: "",
        quantity: 1,
        unit: "ADET",
        unitPrice: 0,
        vatRate: 20,
      },
    ]);
  }

  function handleRemoveLine(id: string) {
    if (lines.length <= 1) {
      toast.error("Faturada en az 1 satır olmalıdır.");
      return;
    }
    setLines((prev) => prev.filter((l) => l.id !== id));
  }

  function handleLineChange(id: string, field: keyof FormLine, value: any) {
    setLines((prev) =>
      prev.map((l) => (l.id === id ? { ...l, [field]: value } : l))
    );
  }

  function validateForm(): boolean {
    const cleanSellerVkn = sellerTaxNumber.trim() || "3230512384";
    const cleanBuyerVkn = buyerTaxNumber.trim();

    if (!cleanBuyerVkn || !validateVknTckn(cleanBuyerVkn).isValid) {
      toast.error("Lütfen geçerli bir Alıcı VKN (10 hane) veya TCKN (11 hane) girin.");
      return false;
    }

    if (!buyerName.trim()) {
      toast.error("Alıcı unvanı/adı boş bırakılamaz.");
      return false;
    }

    if (lines.length === 0) {
      toast.error("En az bir ürün/hizmet satırı eklemelisiniz.");
      return false;
    }

    for (const line of lines) {
      if (!line.name.trim()) {
        toast.error("Tüm satırların Ürün/Hizmet Adı dolu olmalıdır.");
        return false;
      }
      if (line.quantity <= 0) {
        toast.error("Miktar 0'dan büyük olmalıdır.");
        return false;
      }
      if (line.unitPrice < 0) {
        toast.error("Birim fiyat negatif olamaz.");
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
          vatRate: l.vatRate,
        })),
        note,
      };

      const res = await fetch("/api/invoices/draft", {
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
      "Bu işlem e-Faturayı EDM entegratör sistemine iletecektir. Devam etmek istiyor musunuz?"
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
          vatRate: l.vatRate,
        })),
        note,
      };

      const res = await fetch("/api/edm/invoice", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });

      const json = await res.json();
      if (!res.ok || !json.success) {
        throw new Error(json.message || "EDM gönderim hatası.");
      }

      toast.success(
        `Fatura EDM TEST ortamına başarıyla gönderildi!\nFatura No: ${json.invoiceNumber}\nEDM Ref: ${json.edmReference || "TRXID Alındı"}`
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
      title="Yeni e-Fatura Oluştur"
      subtitle="EDM TEST Web Service entegrasyonu ile e-Fatura kesme ve taslak yönetimi"
      actions={
        <Button variant="outline" asChild>
          <Link to="/faturalar">
            <ArrowLeft className="mr-1 size-4" /> Faturalara Dön
          </Link>
        </Button>
      }
    >
      <div className="space-y-6">
        {/* Üst Bilgilendirme */}
        <Card className="border-primary/20 bg-primary/5">
          <CardContent className="py-3 flex flex-wrap items-center justify-between gap-3 text-xs">
            <div className="flex items-center gap-2">
              <Badge variant="secondary">EDM TEST ORTAMI</Badge>
              <span className="text-muted-foreground">
                Bu ekranda oluşturulan faturalar <strong>EDM TEST Web Service</strong> ortamına iletilir. Canlı sisteme yük verilmez.
              </span>
            </div>
          </CardContent>
        </Card>

        {/* 1. Satıcı & Alıcı Bilgileri */}
        <div className="grid gap-6 md:grid-cols-2">
          {/* Satıcı */}
          <Card>
            <CardHeader className="py-4">
              <CardTitle className="text-base font-semibold">Satıcı Bilgileri (Düzenleyen)</CardTitle>
              <CardDescription>Faturayı kesen firma veya şahıs bilgileri</CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
              <div className="space-y-1">
                <Label className="text-xs">Firma Unvanı</Label>
                <Input
                  className="h-9 text-xs"
                  value={sellerName}
                  onChange={(e) => setSellerName(e.target.value)}
                  placeholder="Fuat Ekiz Teknoloji A.Ş."
                />
              </div>
              <div className="space-y-1">
                <Label className="text-xs">Satıcı VKN / TCKN</Label>
                <Input
                  className="h-9 text-xs font-mono"
                  value={sellerTaxNumber}
                  onChange={(e) => setSellerTaxNumber(e.target.value)}
                  placeholder="3230512384"
                />
              </div>
            </CardContent>
          </Card>

          {/* Alıcı */}
          <Card>
            <CardHeader className="py-4">
              <CardTitle className="text-base font-semibold flex items-center justify-between">
                <span>Alıcı Müşteri Bilgileri</span>
                <Select value={buyerType} onValueChange={(v: any) => setBuyerType(v)}>
                  <SelectTrigger className="w-28 h-7 text-xs">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="FIRMA">Firma (VKN)</SelectItem>
                    <SelectItem value="SAHIS">Şahıs (TCKN)</SelectItem>
                  </SelectContent>
                </Select>
              </CardTitle>
              <CardDescription>Faturanın kesileceği alıcı bilgileri</CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
              <div className="grid grid-cols-2 gap-3">
                <div className="space-y-1">
                  <Label className="text-xs">Alıcı VKN / TCKN *</Label>
                  <Input
                    className="h-9 text-xs font-mono"
                    value={buyerTaxNumber}
                    onChange={(e) => setBuyerTaxNumber(e.target.value)}
                    placeholder="2222222222"
                  />
                </div>
                <div className="space-y-1">
                  <Label className="text-xs">Vergi Dairesi</Label>
                  <Input
                    className="h-9 text-xs"
                    value={buyerTaxOffice}
                    onChange={(e) => setBuyerTaxOffice(e.target.value)}
                    placeholder="Kadıköy"
                  />
                </div>
              </div>

              <div className="space-y-1">
                <Label className="text-xs">Alıcı Unvanı / Adı Soyadı *</Label>
                <Input
                  className="h-9 text-xs"
                  value={buyerName}
                  onChange={(e) => setBuyerName(e.target.value)}
                  placeholder="Demo Alıcı A.Ş."
                />
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div className="space-y-1">
                  <Label className="text-xs">İl</Label>
                  <Input
                    className="h-9 text-xs"
                    value={buyerCity}
                    onChange={(e) => setBuyerCity(e.target.value)}
                    placeholder="İstanbul"
                  />
                </div>
                <div className="space-y-1">
                  <Label className="text-xs">İlçe</Label>
                  <Input
                    className="h-9 text-xs"
                    value={buyerDistrict}
                    onChange={(e) => setBuyerDistrict(e.target.value)}
                    placeholder="Kadıköy"
                  />
                </div>
              </div>

              <div className="space-y-1">
                <Label className="text-xs">Adres</Label>
                <Input
                  className="h-9 text-xs"
                  value={buyerAddress}
                  onChange={(e) => setBuyerAddress(e.target.value)}
                  placeholder="Atatürk Cad. No: 123"
                />
              </div>
            </CardContent>
          </Card>
        </div>

        {/* 2. Fatura Başlık Bilgileri */}
        <Card>
          <CardHeader className="py-4">
            <CardTitle className="text-base font-semibold">Fatura Başlık Bilgileri</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
              <div className="space-y-1">
                <Label className="text-xs">Fatura Tipi</Label>
                <Select value={invoiceTypeCode} onValueChange={(v: any) => setInvoiceTypeCode(v)}>
                  <SelectTrigger className="h-9 text-xs">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="SATIS">SATIS - Satış Faturası</SelectItem>
                    <SelectItem value="IADE">IADE - İade Faturası</SelectItem>
                    <SelectItem value="TEVKIFAT">TEVKIFAT - Tevkifatlı Fatura</SelectItem>
                    <SelectItem value="ISTISNA">ISTISNA - İstisna Faturası (%0)</SelectItem>
                  </SelectContent>
                </Select>
              </div>

              <div className="space-y-1">
                <Label className="text-xs">Fatura Profili</Label>
                <Select value={profileId} onValueChange={(v: any) => setProfileId(v)}>
                  <SelectTrigger className="h-9 text-xs">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="EARSIVFATURA">EARSIVFATURA - e-Arşiv</SelectItem>
                    <SelectItem value="TICARIFATURA">TICARIFATURA - Ticari e-Fatura</SelectItem>
                    <SelectItem value="TEMELFATURA">TEMELFATURA - Temel e-Fatura</SelectItem>
                  </SelectContent>
                </Select>
              </div>

              <div className="space-y-1">
                <Label className="text-xs">Para Birimi</Label>
                <Select value={currency} onValueChange={setCurrency}>
                  <SelectTrigger className="h-9 text-xs font-mono">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="TRY">TRY (Türk Lirası)</SelectItem>
                    <SelectItem value="USD">USD (Amerikan Doları)</SelectItem>
                    <SelectItem value="EUR">EUR (Euro)</SelectItem>
                  </SelectContent>
                </Select>
              </div>

              <div className="space-y-1">
                <Label className="text-xs">Fatura Numarası (16 Hane)</Label>
                <Input
                  className="h-9 text-xs font-mono"
                  value={customInvoiceNumber}
                  onChange={(e) => setCustomInvoiceNumber(e.target.value)}
                />
              </div>
            </div>
          </CardContent>
        </Card>

        {/* 3. Ürün / Hizmet Satırları */}
        <Card>
          <CardHeader className="py-4 flex flex-row items-center justify-between">
            <div>
              <CardTitle className="text-base font-semibold">Ürün / Hizmet Satırları</CardTitle>
              <CardDescription>Faturaya dahil edilen ürün ve hizmet kalemleri</CardDescription>
            </div>
            <Button size="sm" variant="outline" className="gap-1 text-xs" onClick={handleAddLine}>
              <Plus className="size-3.5" /> Satır Ekle
            </Button>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="overflow-x-auto">
              <table className="w-full text-xs">
                <thead>
                  <tr className="border-b border-border text-left uppercase text-muted-foreground">
                    <th className="py-2 pr-2">Ürün / Hizmet Adı</th>
                    <th className="py-2 pr-2 w-24">Miktar</th>
                    <th className="py-2 pr-2 w-28">Birim</th>
                    <th className="py-2 pr-2 w-28">Birim Fiyat</th>
                    <th className="py-2 pr-2 w-24">KDV Oranı</th>
                    <th className="py-2 pr-2 w-28 text-right">Satır Toplamı</th>
                    <th className="py-2 w-10"></th>
                  </tr>
                </thead>
                <tbody>
                  {calculatedLines.map((line) => (
                    <tr key={line.id} className="border-b border-border/50">
                      <td className="py-2 pr-2">
                        <Input
                          className="h-8 text-xs"
                          placeholder="Ürün/Hizmet Adı"
                          value={line.name}
                          onChange={(e) => handleLineChange(line.id, "name", e.target.value)}
                        />
                      </td>
                      <td className="py-2 pr-2">
                        <Input
                          type="number"
                          step="0.01"
                          className="h-8 text-xs font-mono"
                          value={line.quantity}
                          onChange={(e) => handleLineChange(line.id, "quantity", parseFloat(e.target.value) || 0)}
                        />
                      </td>
                      <td className="py-2 pr-2">
                        <Select value={line.unit} onValueChange={(v) => handleLineChange(line.id, "unit", v)}>
                          <SelectTrigger className="h-8 text-xs">
                            <SelectValue />
                          </SelectTrigger>
                          <SelectContent>
                            <SelectItem value="ADET">ADET</SelectItem>
                            <SelectItem value="KG">KG</SelectItem>
                            <SelectItem value="LT">LT</SelectItem>
                            <SelectItem value="SAAT">SAAT</SelectItem>
                            <SelectItem value="PAKET">PAKET</SelectItem>
                            <SelectItem value="METRE">METRE</SelectItem>
                            <SelectItem value="DIGER">DİĞER</SelectItem>
                          </SelectContent>
                        </Select>
                      </td>
                      <td className="py-2 pr-2">
                        <Input
                          type="number"
                          step="0.01"
                          className="h-8 text-xs font-mono"
                          value={line.unitPrice}
                          onChange={(e) => handleLineChange(line.id, "unitPrice", parseFloat(e.target.value) || 0)}
                        />
                      </td>
                      <td className="py-2 pr-2">
                        <Select
                          value={String(line.vatRate)}
                          onValueChange={(v) => handleLineChange(line.id, "vatRate", parseInt(v, 10))}
                        >
                          <SelectTrigger className="h-8 text-xs font-mono">
                            <SelectValue />
                          </SelectTrigger>
                          <SelectContent>
                            <SelectItem value="0">%0</SelectItem>
                            <SelectItem value="1">%1</SelectItem>
                            <SelectItem value="10">%10</SelectItem>
                            <SelectItem value="20">%20</SelectItem>
                          </SelectContent>
                        </Select>
                      </td>
                      <td className="py-2 pr-2 text-right font-medium font-mono">
                        {line.lineTotal.toLocaleString("tr-TR", { minimumFractionDigits: 2 })} {currency}
                      </td>
                      <td className="py-2 text-right">
                        <Button
                          size="icon"
                          variant="ghost"
                          className="size-7 text-destructive"
                          onClick={() => handleRemoveLine(line.id)}
                        >
                          <Trash2 className="size-3.5" />
                        </Button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            {/* Hesaplama Özeti */}
            <div className="flex flex-col md:flex-row justify-between items-start gap-4 pt-4 border-t">
              <div className="w-full md:w-1/2 space-y-2">
                <Label className="text-xs">Fatura Notu</Label>
                <Textarea
                  className="text-xs h-20"
                  value={note}
                  onChange={(e) => setNote(e.target.value)}
                  placeholder="İrsaliye ve ödeme notları..."
                />
              </div>

              <div className="w-full md:w-80 space-y-2 text-xs border rounded-lg p-3 bg-muted/20">
                <div className="flex justify-between py-1 border-b border-border/50">
                  <span className="text-muted-foreground">Ara Toplam:</span>
                  <span className="font-mono font-medium">{subTotal.toLocaleString("tr-TR", { minimumFractionDigits: 2 })} {currency}</span>
                </div>

                {vatBreakdown.map(([rate, data]) => (
                  <div key={rate} className="flex justify-between py-0.5 text-muted-foreground">
                    <span>% {rate} KDV ({data.taxable.toLocaleString("tr-TR")} {currency}):</span>
                    <span className="font-mono">{data.vat.toLocaleString("tr-TR", { minimumFractionDigits: 2 })} {currency}</span>
                  </div>
                ))}

                <div className="flex justify-between py-1 border-b border-border/50">
                  <span className="text-muted-foreground">Toplam KDV:</span>
                  <span className="font-mono font-medium">{vatTotal.toLocaleString("tr-TR", { minimumFractionDigits: 2 })} {currency}</span>
                </div>

                <div className="flex justify-between py-1 text-sm font-bold text-primary">
                  <span>Genel Toplam:</span>
                  <span className="font-mono">{grandTotal.toLocaleString("tr-TR", { minimumFractionDigits: 2 })} {currency}</span>
                </div>
              </div>
            </div>
          </CardContent>
        </Card>

        {/* Aksiyon Butonları */}
        <div className="flex flex-wrap items-center justify-end gap-3 pt-2">
          <Button
            variant="outline"
            className="gap-2"
            disabled={submitting}
            onClick={handleSaveDraft}
          >
            <Save className="size-4" />
            {submitting ? "Kaydediliyor..." : "Faturayı Taslak Olarak Kaydet"}
          </Button>

          <Button
            className="gap-2"
            disabled={submitting}
            onClick={handleSendToEdm}
          >
            <Send className="size-4" />
            {submitting ? "EDM'ye İletiliyor..." : "EDM TEST'e Gönder"}
          </Button>
        </div>
      </div>
    </AppShell>
  );
}
