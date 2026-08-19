import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { Trash2, AlertCircle, Info, Check, Edit, PlusCircle, ArrowLeft } from "lucide-react";
import { toast } from "sonner";

import { AppShell } from "@/components/AppShell";
import { AddressSelect } from "@/components/AddressSelect";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { supabase } from "@/integrations/supabase/client";
import {
  emptyCustomer,
  formatMoney,
  generateEttn,
  generateInvoiceNumber,
  INVOICE_TYPES,
  INVOICE_TYPE_DETAILS,
  TEVKIFAT_CODES,
  TEVKIFAT_RATES,
  EXEMPTION_CODES,
  CURRENCY_OPTIONS,
  UNIT_OPTIONS,
  VAT_RATES,
  invoiceTotals,
  itemTotals,
  newItem,
  numberToTurkishWords,
  roundMoney,
  isValidVknTckn,
  type InvoiceCustomer,
  type InvoiceItem,
} from "@/lib/invoice";

type SearchParams = {
  editId?: string | undefined;
};

export const Route = createFileRoute("/_authenticated/fatura-kes")({
  validateSearch: (search: Record<string, unknown>): SearchParams => {
    const editId = search["editId"];
    return {
      editId: typeof editId === "string" ? editId : undefined,
    };
  },
  head: () => ({
    meta: [
      { title: "Fatura Kes & Düzenle | e-Fatura Portalı" },
      {
        name: "description",
        content:
          "Alıcı bilgileri ve kalemlerle e-arşiv/e-fatura hazırlayın, KDV (%0, %1, %10, %20) ve tevkifatı otomatik hesaplayın.",
      },
      { property: "og:title", content: "Fatura Kes & Düzenle | e-Fatura Portalı" },
      { property: "og:description", content: "Yeni e-arşiv veya e-fatura oluşturun." },
    ],
  }),
  component: NewInvoicePage,
});

function NewInvoicePage() {
  const navigate = useNavigate();
  const searchParams = Route.useSearch();
  const editId = searchParams.editId;
  const queryClient = useQueryClient();

  const [type, setType] = useState("SATIS");
  const [currency, setCurrency] = useState("TRY");
  const [date, setDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [customer, setCustomer] = useState<InvoiceCustomer>(emptyCustomer);
  const [customerId, setCustomerId] = useState<string>("");
  const [warehouseId, setWarehouseId] = useState<string>("");
  const [serialPrefix, setSerialPrefix] = useState("EAR");
  const [items, setItems] = useState<InvoiceItem[]>([newItem()]);
  const [selectedTevkifatCode, setSelectedTevkifatCode] = useState<string>("");
  const [selectedExemptionCode, setSelectedExemptionCode] = useState<string>("301");
  const [tevkifatRate, setTevkifatRate] = useState("0");
  const [notes, setNotes] = useState("");
  const [paymentInfo, setPaymentInfo] = useState("");

  const { data: customers = [] } = useQuery({
    queryKey: ["customers"],
    queryFn: async () => {
      const { data, error } = await supabase.from("customers").select("*").order("title");
      if (error) throw error;
      return data ?? [];
    },
  });

  const {
    data: products = [],
    isLoading: productsLoading,
    error: productsError,
  } = useQuery({
    queryKey: ["products", "catalog"],
    queryFn: async () => {
      const { data, error } = await supabase.from("products").select("*").order("name");
      if (error) throw error;
      return data ?? [];
    },
    staleTime: 0,
    refetchOnMount: "always",
  });

  const { data: warehouses = [] } = useQuery({
    queryKey: ["warehouses"],
    queryFn: async () => {
      const { data, error } = await supabase.from("warehouses").select("*").order("name");
      if (error) throw error;
      return data ?? [];
    },
  });

  const { data: invoiceCount = 0 } = useQuery({
    queryKey: ["invoice-count"],
    queryFn: async () => {
      const { count, error } = await supabase
        .from("invoices")
        .select("id", { count: "exact", head: true });
      if (error) throw error;
      return count ?? 0;
    },
  });

  // Eğer Düzenleme (editId) modundaysak faturayı yükle
  const { data: existingInvoice } = useQuery({
    queryKey: ["invoice-detail", editId],
    queryFn: async () => {
      if (!editId) return null;
      const { data, error } = await supabase.from("invoices").select("*").eq("id", editId).single();
      if (error) throw error;
      return data;
    },
    enabled: Boolean(editId),
  });

  useEffect(() => {
    if (!existingInvoice) return;
    setType(existingInvoice.type || "SATIS");
    setCurrency(existingInvoice.currency || "TRY");
    setDate(existingInvoice.invoice_date || new Date().toISOString().slice(0, 10));
    setCustomerId(existingInvoice.customer_id || "");
    setWarehouseId(existingInvoice.warehouse_id || "");
    setNotes(existingInvoice.notes || "");
    setPaymentInfo(existingInvoice.payment_info || "");

    const customPrefix = existingInvoice.invoice_number ? existingInvoice.invoice_number.slice(0, 3) : "GIB";
    setSerialPrefix(customPrefix);

    if (existingInvoice.customer && typeof existingInvoice.customer === "object") {
      const c = existingInvoice.customer as Partial<InvoiceCustomer>;
      setCustomer({
        vknTckn: c.vknTckn || "",
        title: c.title || "",
        taxOffice: c.taxOffice || "",
        address: c.address || "",
        city: c.city || "",
        district: c.district || "",
        neighborhood: c.neighborhood || "",
        email: c.email || "",
        phone: c.phone || "",
        customPrefix: c.customPrefix || customPrefix,
      });
    }

    if (Array.isArray(existingInvoice.items) && existingInvoice.items.length > 0) {
      setItems(existingInvoice.items as InvoiceItem[]);
    }
  }, [existingInvoice]);

  const isTevkifatli = type === "TEVKIFAT" || Boolean(selectedTevkifatCode);
  const activeTevkifatRate = isTevkifatli ? Number(tevkifatRate) || 0 : 0;
  const totals = invoiceTotals(items, activeTevkifatRate);
  const wordsAmount = numberToTurkishWords(totals.grandTotal, currency);

  function handleTevkifatCodeChange(code: string) {
    setSelectedTevkifatCode(code);
    const match = TEVKIFAT_CODES.find((c) => c.code === code);
    if (match) {
      setTevkifatRate(String(match.rate));
      if (type !== "TEVKIFAT") setType("TEVKIFAT");
    } else if (code === "NONE") {
      setSelectedTevkifatCode("");
      setTevkifatRate("0");
    }
  }

  function updateItem(id: string, patch: Partial<InvoiceItem>) {
    setItems((prev) =>
      prev.map((i) => {
        if (i.id !== id) return i;
        const updated = { ...i, ...patch };
        if (updated.quantity !== undefined)
          updated.quantity = Math.max(0, Number(updated.quantity) || 0);
        if (updated.unitPrice !== undefined)
          updated.unitPrice = Math.max(0, Number(updated.unitPrice) || 0);
        if (updated.discountRate !== undefined)
          updated.discountRate = Math.min(100, Math.max(0, Number(updated.discountRate) || 0));
        if (updated.vatRate !== undefined)
          updated.vatRate = Math.max(0, Number(updated.vatRate) || 0);
        return updated;
      }),
    );
  }

  function applyProduct(id: string, productId: string) {
    const p = products.find((x) => x.id === productId);
    if (!p) return;
    updateItem(id, {
      productId: p.id,
      code: p.code || "",
      name: p.name,
      unit: p.unit || "Adet",
      unitPrice: Number(p.unit_price) || 0,
      vatRate: Number(p.vat_rate) || 20,
    });
  }

  function applyCustomer(selectedId: string) {
    const c = customers.find((x) => x.id === selectedId);
    if (!c) return;
    setCustomerId(c.id);
    const prefix = c.code ? c.code.replace(/[^a-zA-Z0-9]/g, "").slice(0, 3).toUpperCase() : serialPrefix;
    if (prefix && prefix.length >= 2) {
      setSerialPrefix(prefix);
    }
    setCustomer({
      vknTckn: c.vkn_tckn || "",
      title: c.title || "",
      taxOffice: c.tax_office || "",
      address: c.address || "",
      city: c.city || "",
      district: c.district || "",
      neighborhood: c.neighborhood ?? "",
      email: c.email || "",
      phone: c.phone || "",
      customPrefix: prefix,
    });
  }

  const saveInvoice = useMutation({
    mutationFn: async (newStatus: "TASLAK" | "ONAYLANDI" = "TASLAK") => {
      if (!customer.vknTckn.trim() || !customer.title.trim()) {
        throw new Error("Alıcı VKN/TCKN ve unvan bilgileri zorunludur.");
      }
      if (items.length === 0 || items.some((i) => !i.name.trim())) {
        throw new Error("En az bir geçerli açıklamayla fatura kalemi girmelisiniz.");
      }
      const { data: userData } = await supabase.auth.getUser();
      const userId = userData.user?.id;
      if (!userId) throw new Error("Oturum bulunamadı. Lütfen yeniden giriş yapınız.");

      const shouldPost = newStatus === "ONAYLANDI";
      const invoiceNumber =
        existingInvoice?.invoice_number ||
        generateInvoiceNumber(invoiceCount, serialPrefix || "GIB");

      const invoicePayload = {
        user_id: userId,
        customer_id: customerId || null,
        warehouse_id: warehouseId || null,
        posted: shouldPost,
        ettn: existingInvoice?.ettn || generateEttn(),
        invoice_number: invoiceNumber,
        type,
        status: newStatus,
        gib_approval_date: shouldPost ? new Date().toISOString() : null,
        invoice_date: date,
        currency,
        exchange_rate: 1,
        customer: JSON.parse(JSON.stringify(customer)),
        items: JSON.parse(JSON.stringify(items)),
        subtotal: totals.subtotal,
        total_discount: totals.totalDiscount,
        taxable_amount: totals.taxableAmount,
        total_vat: totals.totalVat,
        total_tevkifat: totals.totalTevkifat,
        grand_total: totals.grandTotal,
        notes: notes.trim(),
        payment_info: paymentInfo.trim(),
      };

      let insertedId = existingInvoice?.id;

      if (editId && existingInvoice) {
        // Mevcut faturayı güncelle
        const { error: updateError } = await supabase
          .from("invoices")
          .update(invoicePayload)
          .eq("id", editId);
        if (updateError) throw updateError;
      } else {
        // Yeni fatura ekle
        const { data: inserted, error: insertError } = await supabase
          .from("invoices")
          .insert(invoicePayload)
          .select("id, invoice_number")
          .single();
        if (insertError) throw insertError;
        insertedId = inserted.id;
      }

      if (shouldPost && insertedId) {
        const isReturn = type === "IADE";

        // Cari hesap hareketi
        if (customerId) {
          await supabase
            .from("account_transactions")
            .update({ deleted_at: new Date().toISOString(), deleted_by: userId })
            .eq("source_id", insertedId)
            .is("deleted_at", null);
          const { error: txnError } = await supabase.from("account_transactions").insert({
            user_id: userId,
            customer_id: customerId,
            txn_date: date,
            txn_type: isReturn ? "ALACAK" : "BORC",
            amount: totals.grandTotal,
            document_no: invoiceNumber,
            description: isReturn ? "İade faturası kaydı" : `${type} faturası borç kaydı`,
            source: "FATURA",
            source_id: insertedId,
          });
          if (txnError) throw txnError;
        }

        // Stok hareketleri
        await supabase
          .from("stock_movements")
          .update({ deleted_at: new Date().toISOString(), deleted_by: userId })
          .eq("source_id", insertedId)
          .is("deleted_at", null);
        const stockRows = items
          .filter((i) => i.productId)
          .map((i) => ({
            user_id: userId,
            product_id: i.productId as string,
            warehouse_id: warehouseId || null,
            customer_id: customerId || null,
            movement_date: date,
            movement_type: isReturn ? "GIRIS" : "CIKIS",
            quantity: Math.max(0, Number(i.quantity) || 0),
            unit_price: roundMoney(Number(i.unitPrice) || 0),
            document_no: invoiceNumber,
            description: isReturn
              ? "Fatura kaynaklı stok iade girişi"
              : "Fatura kaynaklı stok çıkışı",
            source: "FATURA",
            source_id: insertedId,
          }));

        if (stockRows.length > 0) {
          const { error: stockError } = await supabase.from("stock_movements").insert(stockRows);
          if (stockError) throw stockError;
        }
      }
    },
    onSuccess: (_data, newStatus) => {
      toast.success(
        editId
          ? "Fatura başarıyla güncellendi."
          : newStatus === "ONAYLANDI"
            ? "Fatura onaylandı; cari ve stok hareketleri işlendi."
            : "Fatura taslak olarak başarıyla kaydedildi.",
      );
      queryClient.invalidateQueries({ queryKey: ["invoices"] });
      queryClient.invalidateQueries({ queryKey: ["invoice-count"] });
      queryClient.invalidateQueries({ queryKey: ["account-transactions"] });
      queryClient.invalidateQueries({ queryKey: ["stock-movements"] });
      queryClient.invalidateQueries({ queryKey: ["product-stocks"] });
      navigate({ to: "/faturalar" });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const vknWarning = customer.vknTckn.trim() ? !isValidVknTckn(customer.vknTckn) : false;
  const selectedTypeDetails =
    INVOICE_TYPE_DETAILS[type] ?? INVOICE_TYPE_DETAILS["SATIS"]!;
  const currentTevkifatObj = TEVKIFAT_CODES.find((c) => c.code === selectedTevkifatCode);

  return (
    <AppShell
      title={editId ? "Faturayı Düzenle" : "Fatura Kes"}
      subtitle={
        editId
          ? `${existingInvoice?.invoice_number || "Fatura"} kaydını güncelliyorsunuz.`
          : "E-Arşiv / E-Fatura düzenleyin, KDV (%0, %1, %10, %20) ve tevkifatı otomatik hesaplayın."
      }
      actions={
        <div className="flex gap-2">
          {editId ? (
            <Button variant="outline" size="sm" onClick={() => navigate({ to: "/faturalar" })}>
              <ArrowLeft className="mr-1 size-4" /> Vazgeç
            </Button>
          ) : null}
          <Button
            variant="outline"
            onClick={() => saveInvoice.mutate("TASLAK")}
            disabled={saveInvoice.isPending}
          >
            {editId ? "Taslak Olarak Güncelle" : "Taslak Olarak Kaydet"}
          </Button>
          <Button onClick={() => saveInvoice.mutate("ONAYLANDI")} disabled={saveInvoice.isPending}>
            {editId ? "Kaydet & Onayla" : "GİB'e Gönder / Onayla"}
          </Button>
        </div>
      }
    >
      <div className="grid gap-6 lg:grid-cols-3">
        <div className="space-y-6 lg:col-span-2">
          {/* FATURA BİLGİLERİ */}
          <Card>
            <CardHeader className="pb-3">
              <div className="flex items-center justify-between">
                <CardTitle className="text-base">Fatura Bilgileri</CardTitle>
                <Badge variant="secondary">{selectedTypeDetails.badge}</Badge>
              </div>
            </CardHeader>
            <CardContent className="space-y-4">
              <div className="grid gap-4 sm:grid-cols-3">
                <div className="space-y-2">
                  <Label>Fatura Tipi</Label>
                  <Select
                    value={type}
                    onValueChange={(newType) => {
                      setType(newType);
                      if (newType === "ISTISNA") {
                        setItems((prev) => prev.map((item) => ({ ...item, vatRate: 0 })));
                        const obj = EXEMPTION_CODES.find((c) => c.code === selectedExemptionCode);
                        if (obj) {
                          setNotes((prev) => {
                            const clean = prev.replace(/KDV İstisna Kodu: [^\n]+/g, "").trim();
                            return `${clean ? clean + "\n" : ""}KDV İstisna Kodu: ${obj.code} - ${obj.name}`;
                          });
                        }
                      }
                    }}
                  >
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {INVOICE_TYPES.map((t) => (
                        <SelectItem key={t.value} value={t.value}>
                          {t.label}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
                <div className="space-y-2">
                  <Label htmlFor="date">Düzenleme Tarihi</Label>
                  <Input
                    id="date"
                    type="date"
                    value={date}
                    onChange={(e) => setDate(e.target.value)}
                  />
                </div>
                <div className="space-y-2">
                  <Label>Para Birimi</Label>
                  <Select value={currency} onValueChange={setCurrency}>
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {CURRENCY_OPTIONS.map((c) => (
                        <SelectItem key={c.code} value={c.code}>
                          {c.label}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
              </div>

              {/* Fatura Tipi İçin Seçilen Özelliklerin Listelenmesi Kutusu */}
              <div className="rounded-lg border border-primary/20 bg-primary/5 p-3.5 text-sm">
                <div className="flex items-center gap-2 font-semibold text-primary">
                  <Info className="size-4 shrink-0" />
                  <span>{selectedTypeDetails.title} Özellikleri</span>
                </div>
                <p className="mt-1 text-xs text-muted-foreground">
                  {selectedTypeDetails.description}
                </p>
                <ul className="mt-2 space-y-1">
                  {selectedTypeDetails.features.map((feat, idx) => (
                    <li key={idx} className="flex items-center gap-1.5 text-xs text-foreground/90">
                      <Check className="size-3.5 text-primary shrink-0" />
                      <span>{feat}</span>
                    </li>
                  ))}
                </ul>
              </div>

              {/* İstisna Faturası Seçildiğinde GİB KDV Muafiyet Kodu Listesi */}
              {type === "ISTISNA" ? (
                <div className="space-y-2 rounded-lg border border-primary/30 bg-background p-3.5 shadow-sm">
                  <Label className="text-xs font-semibold text-primary flex items-center gap-1.5">
                    <Check className="size-3.5" /> GİB KDV Muafiyet / İstisna Kodu & Gerekçesi *
                  </Label>
                  <Select
                    value={selectedExemptionCode}
                    onValueChange={(v) => {
                      setSelectedExemptionCode(v);
                      const obj = EXEMPTION_CODES.find((c) => c.code === v);
                      if (obj) {
                        setNotes((prev) => {
                          const clean = prev.replace(/KDV İstisna Kodu: [^\n]+/g, "").trim();
                          return `${clean ? clean + "\n" : ""}KDV İstisna Kodu: ${obj.code} - ${obj.name}`;
                        });
                      }
                    }}
                  >
                    <SelectTrigger className="h-9 text-xs">
                      <SelectValue placeholder="GİB İstisna Kodu Seçin..." />
                    </SelectTrigger>
                    <SelectContent>
                      {EXEMPTION_CODES.map((c) => (
                        <SelectItem key={c.code} value={c.code}>
                          {c.code} - {c.name}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <p className="text-[11px] text-muted-foreground">
                    Seçilen KDV muafiyet kodu ve gerekçesi faturada ve GİB e-arşiv XML çıktısında resmi olarak yer alacaktır.
                  </p>
                </div>
              ) : null}

              <div className="grid gap-4 sm:grid-cols-2">
                <div className="space-y-2">
                  <Label htmlFor="prefix">Fatura Seri / Ön Ek (Müşteriye/Firmaya Özel)</Label>
                  <div className="flex items-center gap-2">
                    <Input
                      id="prefix"
                      className="w-24 uppercase"
                      maxLength={3}
                      value={serialPrefix}
                      onChange={(e) => setSerialPrefix(e.target.value.toUpperCase())}
                      placeholder="EAR"
                    />
                    <span className="text-xs text-muted-foreground font-mono">
                      Örn No: {generateInvoiceNumber(invoiceCount, serialPrefix || "EAR")}
                    </span>
                  </div>
                </div>

                <div className="space-y-2">
                  <Label>Stok Çıkışı / Girişi Yapılacak Depo</Label>
                  <Select value={warehouseId} onValueChange={setWarehouseId}>
                    <SelectTrigger>
                      <SelectValue
                        placeholder={
                          warehouses.length === 0
                            ? "Depo tanımlı değil (opsiyonel)"
                            : "Depo seçin (opsiyonel)"
                        }
                      />
                    </SelectTrigger>
                    <SelectContent>
                      {warehouses.map((w) => (
                        <SelectItem key={w.id} value={w.id}>
                          {w.name}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
              </div>
            </CardContent>
          </Card>

          {/* ALICI BİLGİLERİ */}
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Alıcı (Müşteri) Firma Bilgileri</CardTitle>
              <CardDescription>
                Yalnızca temel firma bilgileri (Unvan ve VKN/TCKN) yeterlidir.
              </CardDescription>
            </CardHeader>
            <CardContent className="grid gap-4 sm:grid-cols-2">
              <div className="space-y-2 sm:col-span-2">
                <Label>Kayıtlı Cariden Hızlı Seç</Label>
                <Select onValueChange={applyCustomer}>
                  <SelectTrigger>
                    <SelectValue placeholder="Kayıtlı carilerden seçin (opsiyonel)" />
                  </SelectTrigger>
                  <SelectContent>
                    {customers.map((c) => (
                      <SelectItem key={c.id} value={c.id}>
                        {c.title} — {c.vkn_tckn} {c.code ? `(${c.code})` : ""}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>

              <div className="space-y-2">
                <Label htmlFor="c-vknTckn">VKN / TCKN *</Label>
                <Input
                  id="c-vknTckn"
                  value={customer.vknTckn}
                  onChange={(e) => setCustomer({ ...customer, vknTckn: e.target.value })}
                  placeholder="10 veya 11 haneli numara"
                />
                {vknWarning ? (
                  <p className="flex items-center gap-1 text-xs text-amber-600">
                    <AlertCircle className="size-3.5" /> Geçersiz VKN/TCKN formatı
                  </p>
                ) : null}
              </div>

              <div className="space-y-2">
                <Label htmlFor="c-title">Firma Unvanı / Ad Soyad *</Label>
                <Input
                  id="c-title"
                  value={customer.title}
                  onChange={(e) => setCustomer({ ...customer, title: e.target.value })}
                  placeholder="Firma veya müşteri unvanı"
                />
              </div>

              <div className="space-y-2">
                <Label htmlFor="c-taxOffice">Vergi Dairesi</Label>
                <Input
                  id="c-taxOffice"
                  value={customer.taxOffice}
                  onChange={(e) => setCustomer({ ...customer, taxOffice: e.target.value })}
                />
              </div>

              <div className="space-y-2">
                <Label htmlFor="c-phone">Telefon</Label>
                <Input
                  id="c-phone"
                  value={customer.phone}
                  onChange={(e) => setCustomer({ ...customer, phone: e.target.value })}
                />
              </div>

              <div className="space-y-2 sm:col-span-2">
                <Label htmlFor="c-email">E-posta</Label>
                <Input
                  id="c-email"
                  type="email"
                  value={customer.email}
                  onChange={(e) => setCustomer({ ...customer, email: e.target.value })}
                />
              </div>

              <AddressSelect
                value={{
                  city: customer.city,
                  district: customer.district,
                  neighborhood: customer.neighborhood,
                }}
                onChange={(v: { city: string; district: string; neighborhood: string }) =>
                  setCustomer({ ...customer, ...v })
                }
              />

              <div className="space-y-2 sm:col-span-2">
                <Label htmlFor="c-address">Açık Adres</Label>
                <Input
                  id="c-address"
                  value={customer.address}
                  onChange={(e) => setCustomer({ ...customer, address: e.target.value })}
                  placeholder="Cadde, sokak, bina no, kapı no"
                />
              </div>
            </CardContent>
          </Card>

          {/* TEVKİFAT KODU SEÇİM ALANI */}
          <Card>
            <CardHeader className="pb-3">
              <CardTitle className="text-base">Tevkifatlı İşlemler & Tevkifat Kodları</CardTitle>
              <CardDescription>
                Tevkifat kodu seçildiğinde KDV oranı ve tevkifat kesintisi otomatik hesaplanır.
              </CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
              <div className="space-y-2">
                <Label>Resmi GİB Tevkifat Kodu</Label>
                <Select
                  value={selectedTevkifatCode || "NONE"}
                  onValueChange={handleTevkifatCodeChange}
                >
                  <SelectTrigger>
                    <SelectValue placeholder="Tevkifat Kodu Seçin (Opsiyonel)" />
                  </SelectTrigger>
                  <SelectContent className="max-h-72">
                    <SelectItem value="NONE">Tevkifatsız İşlem</SelectItem>
                    {TEVKIFAT_CODES.map((tc) => (
                      <SelectItem key={tc.code} value={tc.code}>
                        {tc.label}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>

              {currentTevkifatObj ? (
                <div className="rounded-md bg-muted/60 p-3 text-xs">
                  <div className="font-semibold text-primary">
                    Seçilen Tevkifat: {currentTevkifatObj.label}
                  </div>
                  <div className="mt-1 text-muted-foreground">{currentTevkifatObj.name}</div>
                  <div className="mt-1 font-medium">Uygulanan Oran: %{currentTevkifatObj.rate}</div>
                </div>
              ) : null}
            </CardContent>
          </Card>

          {/* FATURA KALEMLERİ */}
          <Card>
            <CardHeader className="flex flex-row items-center justify-between">
              <div>
                <CardTitle className="text-base">Fatura Kalemleri</CardTitle>
                <CardDescription>KDV oranları (%0, %1, %10, %20), miktar ve birim</CardDescription>
              </div>
              <Button
                variant="outline"
                size="sm"
                className="gap-1.5"
                onClick={() => setItems([...items, newItem()])}
              >
                <PlusCircle className="size-4" /> Kalem Ekle
              </Button>
            </CardHeader>
            <CardContent className="space-y-4">
              {items.map((item, index) => {
                const t = itemTotals(item);
                return (
                  <div key={item.id} className="rounded-lg border border-border p-4 space-y-3">
                    <div className="flex items-center justify-between">
                      <span className="text-xs font-bold uppercase tracking-wider text-muted-foreground">
                        Kalem #{index + 1}
                      </span>
                      {items.length > 1 ? (
                        <Button
                          variant="ghost"
                          size="icon"
                          className="size-7 text-destructive"
                          onClick={() => setItems(items.filter((i) => i.id !== item.id))}
                        >
                          <Trash2 className="size-4" />
                        </Button>
                      ) : null}
                    </div>

                    <div className="grid gap-3 sm:grid-cols-2">
                      <div className="space-y-1 sm:col-span-2">
                        <Label className="text-xs">Katalogdan Seç</Label>
                        <Select onValueChange={(v) => applyProduct(item.id, v)}>
                          <SelectTrigger className="h-9">
                            <SelectValue
                              placeholder={
                                productsLoading
                                  ? "Katalog yükleniyor…"
                                  : products.length === 0
                                    ? "Katalogda ürün yok"
                                    : "Kayıtlı ürün/hizmet seçin"
                              }
                            />
                          </SelectTrigger>
                          <SelectContent>
                            {products.map((p) => (
                              <SelectItem key={p.id} value={p.id}>
                                {p.name} {p.code ? `(${p.code})` : ""} — {formatMoney(Number(p.unit_price), currency)}
                              </SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                      </div>

                      <div className="space-y-1 sm:col-span-2">
                        <Label className="text-xs">Kalem Açıklaması *</Label>
                        <Input
                          className="h-9"
                          value={item.name}
                          onChange={(e) => updateItem(item.id, { name: e.target.value })}
                          placeholder="Ürün veya hizmetin tam adı"
                        />
                      </div>

                      <div className="grid grid-cols-2 gap-2 sm:col-span-2 sm:grid-cols-5">
                        <div className="space-y-1">
                          <Label className="text-xs">Miktar</Label>
                          <Input
                            className="h-9"
                            type="number"
                            min="0.01"
                            step="0.01"
                            value={item.quantity}
                            onChange={(e) =>
                              updateItem(item.id, { quantity: Number(e.target.value) })
                            }
                          />
                        </div>

                        <div className="space-y-1">
                          <Label className="text-xs">Birim</Label>
                          <Select
                            value={item.unit || "Adet"}
                            onValueChange={(u) => updateItem(item.id, { unit: u })}
                          >
                            <SelectTrigger className="h-9">
                              <SelectValue />
                            </SelectTrigger>
                            <SelectContent className="max-h-60">
                              {UNIT_OPTIONS.map((u) => (
                                <SelectItem key={u} value={u}>
                                  {u}
                                </SelectItem>
                              ))}
                            </SelectContent>
                          </Select>
                        </div>

                        <div className="space-y-1">
                          <Label className="text-xs">Birim Fiyat</Label>
                          <Input
                            className="h-9"
                            type="number"
                            min="0"
                            step="0.01"
                            value={item.unitPrice}
                            onChange={(e) =>
                              updateItem(item.id, { unitPrice: Number(e.target.value) })
                            }
                          />
                        </div>

                        <div className="space-y-1">
                          <Label className="text-xs">İskonto %</Label>
                          <Input
                            className="h-9"
                            type="number"
                            min="0"
                            max="100"
                            step="0.01"
                            value={item.discountRate}
                            onChange={(e) =>
                              updateItem(item.id, { discountRate: Number(e.target.value) })
                            }
                          />
                        </div>

                        <div className="space-y-1">
                          <Label className="text-xs">KDV %</Label>
                          <Select
                            value={String(item.vatRate ?? 20)}
                            onValueChange={(v) => updateItem(item.id, { vatRate: Number(v) })}
                          >
                            <SelectTrigger className="h-9">
                              <SelectValue />
                            </SelectTrigger>
                            <SelectContent>
                              {VAT_RATES.map((rate) => (
                                <SelectItem key={rate} value={String(rate)}>
                                  %{rate} KDV
                                </SelectItem>
                              ))}
                            </SelectContent>
                          </Select>
                        </div>
                      </div>
                    </div>

                    <div className="flex items-center justify-between border-t border-border/50 pt-2 text-xs">
                      <span className="text-muted-foreground">
                        Matrah: {formatMoney(t.taxable, currency)} | KDV: {formatMoney(t.vat, currency)}
                      </span>
                      <span className="font-semibold text-sm">
                        Kalem Toplamı: {formatMoney(t.total, currency)}
                      </span>
                    </div>
                  </div>
                );
              })}
            </CardContent>
          </Card>

          {/* EK BİLGİLER */}
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Ek Bilgiler & Notlar</CardTitle>
            </CardHeader>
            <CardContent className="grid gap-4 sm:grid-cols-2">
              <div className="space-y-2">
                <Label htmlFor="notes">Fatura Notu</Label>
                <Textarea
                  id="notes"
                  value={notes}
                  onChange={(e) => setNotes(e.target.value)}
                  placeholder="Fatura üzerinde görünecek özel notlar veya sipariş no"
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="payment">Banka / Ödeme Bilgileri</Label>
                <Textarea
                  id="payment"
                  value={paymentInfo}
                  onChange={(e) => setPaymentInfo(e.target.value)}
                  placeholder="Banka Adı, IBAN ve ödeme vadesi detayları"
                />
              </div>
            </CardContent>
          </Card>
        </div>

        {/* SAĞ TARAF: FATURA ÖZETİ */}
        <div>
          <Card className="lg:sticky lg:top-6 space-y-4">
            <CardHeader className="pb-2">
              <CardTitle className="text-base">Fatura Özeti & Döküm</CardTitle>
            </CardHeader>
            <CardContent className="space-y-3 text-sm">
              <Row label="Mal/Hizmet Toplamı" value={formatMoney(totals.subtotal, currency)} />
              {totals.totalDiscount > 0 ? (
                <Row
                  label="Toplam İskonto"
                  value={`- ${formatMoney(totals.totalDiscount, currency)}`}
                />
              ) : null}
              <Row label="KDV Matrahı" value={formatMoney(totals.taxableAmount, currency)} />
              <Row label="Hesaplanan KDV" value={formatMoney(totals.totalVat, currency)} />

              {/* KDV Dilimlerine Göre Kırılım */}
              <div className="rounded-md bg-muted/40 p-2.5 space-y-1 text-xs">
                <span className="font-semibold text-muted-foreground">KDV Dilim Dağılımı:</span>
                {Object.entries(totals.vatBreakdown)
                  .filter(([_, v]) => v.taxable > 0)
                  .map(([rate, val]) => (
                    <div key={rate} className="flex justify-between text-muted-foreground">
                      <span>%{rate} KDV:</span>
                      <span>
                        Matrah: {formatMoney(val.taxable, currency)} | Vergi: {formatMoney(val.vat, currency)}
                      </span>
                    </div>
                  ))}
              </div>

              {isTevkifatli && (
                <div className="space-y-2 rounded-md bg-amber-500/10 border border-amber-500/20 p-3 text-xs">
                  <div className="flex justify-between font-medium text-amber-900 dark:text-amber-200">
                    <span>Tevkifat Oranı:</span>
                    <span>%{activeTevkifatRate}</span>
                  </div>
                  {selectedTevkifatCode && currentTevkifatObj ? (
                    <div className="text-amber-800/90 dark:text-amber-300/90 font-mono">
                      Kod: {currentTevkifatObj.code} - {currentTevkifatObj.name}
                    </div>
                  ) : null}
                  <Row
                    label="Tevkifat Tutarı (-)"
                    value={`- ${formatMoney(totals.totalTevkifat, currency)}`}
                  />
                </div>
              )}

              <div className="mt-4 flex items-center justify-between border-t border-border pt-3 text-lg font-bold">
                <span>Ödenecek Tutar</span>
                <span className="text-primary">{formatMoney(totals.grandTotal, currency)}</span>
              </div>

              {/* YAZI İLE ALANI */}
              <div className="rounded-md bg-muted p-2.5 text-xs text-muted-foreground">
                <span className="font-semibold text-foreground">Yazı İle: </span>
                <span className="italic">{wordsAmount}</span>
              </div>

              {/* Seçilen Tevkifat Kodu Faturanın En Altında Gösterim */}
              {isTevkifatli && selectedTevkifatCode && (
                <div className="border-t border-dashed border-border pt-2 text-xs text-primary font-medium">
                  📌 Faturaya İşlenecek Tevkifat Kodu:{" "}
                  <span className="font-bold">{selectedTevkifatCode}</span> (
                  {currentTevkifatObj?.name || "Tevkifatlı İşlem"})
                </div>
              )}

              <div className="space-y-2 pt-3">
                <Button
                  variant="outline"
                  className="w-full"
                  onClick={() => saveInvoice.mutate("TASLAK")}
                  disabled={saveInvoice.isPending}
                >
                  {saveInvoice.isPending
                    ? "Kaydediliyor…"
                    : editId
                      ? "Taslağı Güncelle"
                      : "Taslak Olarak Kaydet"}
                </Button>
                <Button
                  className="w-full"
                  onClick={() => saveInvoice.mutate("ONAYLANDI")}
                  disabled={saveInvoice.isPending}
                >
                  {saveInvoice.isPending
                    ? "İşleniyor…"
                    : editId
                      ? "Faturayı Güncelle & Onayla"
                      : "GİB'e Gönder / Onayla"}
                </Button>
              </div>
            </CardContent>
          </Card>
        </div>
      </div>
    </AppShell>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between">
      <span className="text-muted-foreground">{label}</span>
      <span className="font-medium">{value}</span>
    </div>
  );
}

