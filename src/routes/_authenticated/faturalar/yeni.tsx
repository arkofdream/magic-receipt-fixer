import { createFileRoute, useNavigate, Link } from "@tanstack/react-router";
import { useState, useMemo } from "react";
import { ArrowLeft, Plus, Trash2, Send, Save, FileText } from "lucide-react";
import { toast } from "sonner";

import { AppShell } from "@/components/AppShell";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Badge } from "@/components/ui/badge";
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

  // Form State
  const [profileId, setProfileId] = useState<"EARSIVFATURA" | "TICARIFATURA" | "TEMELFATURA">("EARSIVFATURA");
  const [invoiceTypeCode, setInvoiceTypeCode] = useState<"SATIS" | "IADE" | "TEVKIFAT" | "ISTISNA">("SATIS");
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
      vatRate: 20,
    },
  ]);

  const [submitting, setSubmitting] = useState(false);

  // VKN / TCKN Validation State
  const taxValidation = useMemo(() => {
    if (!buyerTaxNumber.trim()) return null;
    return validateVknTckn(buyerTaxNumber.trim());
  }, [buyerTaxNumber]);

  // Hesaplamalar
  const totals = useMemo(() => {
    let subTotal = 0;
    let taxTotal = 0;
    const vatGroupsMap = new Map<number, { taxable: number; tax: number }>();

    for (const l of lines) {
      const q = Math.max(0, l.quantity || 0);
      const p = Math.max(0, l.unitPrice || 0);
      const lineExt = roundDecimal(q * p, 2);
      const lineVat = roundDecimal(lineExt * ((l.vatRate || 0) / 100), 2);

      subTotal += lineExt;
      taxTotal += lineVat;

      const group = vatGroupsMap.get(l.vatRate) || { taxable: 0, tax: 0 };
      vatGroupsMap.set(l.vatRate, {
        taxable: roundDecimal(group.taxable + lineExt, 2),
        tax: roundDecimal(group.tax + lineVat, 2),
      });
    }

    subTotal = roundDecimal(subTotal, 2);
    taxTotal = roundDecimal(taxTotal, 2);
    const grandTotal = roundDecimal(subTotal + taxTotal, 2);

    return {
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
    setLines((prev) =>
      prev.map((l) => (l.id === id ? { ...l, [field]: value } : l))
    );
  }

  function validateForm(): boolean {
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
      title="Yeni e-Fatura Oluştur (EDM TEST)"
      subtitle="UBL-TR 2.1 standardında resmî e-Fatura hazırlama ve EDM Bilişim entegrasyonu"
      actions={
        <div className="flex gap-2">
          <Button variant="outline" onClick={() => navigate({ to: "/faturalar" })}>
            <ArrowLeft className="mr-1 size-4" /> Faturalara Dön
          </Button>
          <Button variant="secondary" disabled={submitting} onClick={handleSaveDraft}>
            <Save className="mr-1 size-4" /> Taslak Kaydet
          </Button>
          <Button disabled={submitting} onClick={handleSendToEdm} className="bg-primary text-primary-foreground">
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
                <Input value={sellerTaxNumber} onChange={(e) => setSellerTaxNumber(e.target.value)} />
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
                  <Input
                    placeholder="Örn: Kadıköy V.D."
                    value={buyerTaxOffice}
                    onChange={(e) => setBuyerTaxOffice(e.target.value)}
                  />
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
                  <Input placeholder="Örn: İstanbul" value={buyerCity} onChange={(e) => setBuyerCity(e.target.value)} />
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
              <div key={line.id} className="grid grid-cols-12 gap-2 items-center border p-3 rounded-md bg-card">
                <div className="col-span-1 text-center font-bold text-xs text-muted-foreground">
                  #{idx + 1}
                </div>
                <div className="col-span-4">
                  <Input
                    placeholder="Ürün / Hizmet Adı *"
                    value={line.name}
                    onChange={(e) => updateLine(line.id, "name", e.target.value)}
                  />
                </div>
                <div className="col-span-2">
                  <Input
                    type="number"
                    min="1"
                    placeholder="Miktar"
                    value={line.quantity}
                    onChange={(e) => updateLine(line.id, "quantity", parseFloat(e.target.value) || 0)}
                  />
                </div>
                <div className="col-span-2">
                  <Input
                    type="number"
                    step="0.01"
                    placeholder="Birim Fiyat (TL)"
                    value={line.unitPrice}
                    onChange={(e) => updateLine(line.id, "unitPrice", parseFloat(e.target.value) || 0)}
                  />
                </div>
                <div className="col-span-2">
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
                <div className="col-span-1 text-right">
                  <Button size="icon" variant="ghost" className="text-destructive" onClick={() => removeLine(line.id)}>
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
                <span className="text-muted-foreground">Ara Toplam:</span>
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
    </AppShell>
  );
}
