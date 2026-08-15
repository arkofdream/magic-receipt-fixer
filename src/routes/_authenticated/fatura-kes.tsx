import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Trash2 } from "lucide-react";
import { toast } from "sonner";

import { AppShell } from "@/components/AppShell";
import { AddressSelect } from "@/components/AddressSelect";


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
import { supabase } from "@/integrations/supabase/client";
import {
  emptyCustomer,
  formatMoney,
  generateEttn,
  generateInvoiceNumber,
  INVOICE_TYPES,
  invoiceTotals,
  itemTotals,
  newItem,
  type InvoiceCustomer,
  type InvoiceItem,
} from "@/lib/invoice";

export const Route = createFileRoute("/_authenticated/fatura-kes")({
  head: () => ({
    meta: [
      { title: "Fatura Kes | e-Fatura Portalı" },
      { name: "description", content: "Alıcı bilgileri ve kalemlerle e-arşiv/e-fatura hazırlayın, KDV ve tevkifatı otomatik hesaplayın." },
      { property: "og:title", content: "Fatura Kes | e-Fatura Portalı" },
      { property: "og:description", content: "Yeni e-arşiv veya e-fatura oluşturun." },
    ],
  }),
  component: NewInvoicePage,
});

function NewInvoicePage() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  const [type, setType] = useState("SATIS");
  const [currency, setCurrency] = useState("TRY");
  const [date, setDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [customer, setCustomer] = useState<InvoiceCustomer>(emptyCustomer);
  const [customerId, setCustomerId] = useState<string>("");
  const [warehouseId, setWarehouseId] = useState<string>("");
  const [items, setItems] = useState<InvoiceItem[]>([newItem()]);
  const [tevkifatRate, setTevkifatRate] = useState("0");
  const [notes, setNotes] = useState("");
  const [paymentInfo, setPaymentInfo] = useState("");

  const { data: customers = [] } = useQuery({
    queryKey: ["customers"],
    queryFn: async () => {
      const { data, error } = await supabase.from("customers").select("*").order("title");
      if (error) throw error;
      return data;
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


  const { data: invoiceCount = 0 } = useQuery({
    queryKey: ["invoice-count"],
    queryFn: async () => {
      const { count, error } = await supabase.from("invoices").select("id", { count: "exact", head: true });
      if (error) throw error;
      return count ?? 0;
    },
  });

  const totals = invoiceTotals(items);
  const totalTevkifat = (totals.totalVat * (Number(tevkifatRate) || 0)) / 100;
  const grandTotal = totals.grandTotal - totalTevkifat;

  function updateItem(id: string, patch: Partial<InvoiceItem>) {
    setItems((prev) => prev.map((i) => (i.id === id ? { ...i, ...patch } : i)));
  }

  function applyProduct(id: string, productId: string) {
    const p = products.find((x) => x.id === productId);
    if (!p) return;
    updateItem(id, {
      name: p.name,
      unit: p.unit,
      unitPrice: Number(p.unit_price),
      vatRate: Number(p.vat_rate),
    });
  }

  function applyCustomer(customerId: string) {
    const c = customers.find((x) => x.id === customerId);
    if (!c) return;
    setCustomer({
      vknTckn: c.vkn_tckn,
      title: c.title,
      taxOffice: c.tax_office,
      address: c.address,
      city: c.city,
      district: c.district,
      neighborhood: c.neighborhood ?? "",
      email: c.email,
      phone: c.phone,
    });
  }

  const saveInvoice = useMutation({
    mutationFn: async (newStatus: "TASLAK" | "ONAYLANDI" = "TASLAK") => {
      if (!customer.vknTckn || !customer.title) throw new Error("Alıcı VKN/TCKN ve unvan zorunludur.");
      if (items.length === 0 || items.some((i) => !i.name)) throw new Error("En az bir dolu kalem girmelisiniz.");
      const { data: userData } = await supabase.auth.getUser();
      const userId = userData.user?.id;
      if (!userId) throw new Error("Oturum bulunamadı.");

      const { error } = await supabase.from("invoices").insert({
        user_id: userId,
        ettn: generateEttn(),
        invoice_number: generateInvoiceNumber(invoiceCount),
        type,
        status: newStatus,
        gib_approval_date: newStatus === "ONAYLANDI" ? new Date().toISOString() : null,
        invoice_date: date,
        currency,
        exchange_rate: 1,
        customer: JSON.parse(JSON.stringify(customer)),
        items: JSON.parse(JSON.stringify(items)),
        subtotal: totals.subtotal,
        total_discount: totals.totalDiscount,
        taxable_amount: totals.taxableAmount,
        total_vat: totals.totalVat,
        total_tevkifat: totalTevkifat,
        grand_total: grandTotal,
        notes,
        payment_info: paymentInfo,
      });
      if (error) throw error;
    },
    onSuccess: (_data, newStatus) => {
      toast.success(newStatus === "ONAYLANDI" ? "Fatura kaydedildi ve GİB'e gönderildi." : "Fatura taslak olarak kaydedildi.");
      queryClient.invalidateQueries({ queryKey: ["invoices"] });
      queryClient.invalidateQueries({ queryKey: ["invoice-count"] });
      navigate({ to: "/faturalar" });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  return (
    <AppShell
      title="Fatura Kes"
      subtitle="E-Arşiv / E-Fatura düzenle"
      actions={
        <>
          <Button variant="outline" onClick={() => saveInvoice.mutate("TASLAK")} disabled={saveInvoice.isPending}>
            Taslak Olarak Kaydet
          </Button>
          <Button onClick={() => saveInvoice.mutate("ONAYLANDI")} disabled={saveInvoice.isPending}>
            GİB'e Gönder
          </Button>
        </>
      }


    >
      <div className="grid gap-6 lg:grid-cols-3">
        <div className="space-y-6 lg:col-span-2">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Fatura Bilgileri</CardTitle>
            </CardHeader>
            <CardContent className="grid gap-4 sm:grid-cols-3">
              <div className="space-y-2">
                <Label>Fatura Tipi</Label>
                <Select value={type} onValueChange={setType}>
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
                <Input id="date" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
              </div>
              <div className="space-y-2">
                <Label>Para Birimi</Label>
                <Select value={currency} onValueChange={setCurrency}>
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {["TRY", "USD", "EUR", "GBP"].map((c) => (
                      <SelectItem key={c} value={c}>
                        {c}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">Alıcı (Müşteri) Bilgileri</CardTitle>
            </CardHeader>
            <CardContent className="grid gap-4 sm:grid-cols-2">
              <div className="space-y-2 sm:col-span-2">
                <Label>Kayıtlı Cariden Seç</Label>
                <Select onValueChange={applyCustomer}>
                  <SelectTrigger>
                    <SelectValue placeholder="Cari seçin (opsiyonel)" />
                  </SelectTrigger>
                  <SelectContent>
                    {customers.map((c) => (
                      <SelectItem key={c.id} value={c.id}>
                        {c.title} — {c.vkn_tckn}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
              {(
                [
                  ["vknTckn", "VKN / TCKN"],
                  ["title", "Unvan / Ad Soyad"],
                  ["taxOffice", "Vergi Dairesi"],
                  ["email", "E-posta"],
                  ["phone", "Telefon"],
                ] as [keyof InvoiceCustomer, string][]
              ).map(([key, label]) => (
                <div key={key} className="space-y-2">
                  <Label htmlFor={`c-${key}`}>{label}</Label>
                  <Input
                    id={`c-${key}`}
                    value={customer[key]}
                    onChange={(e) => setCustomer({ ...customer, [key]: e.target.value })}
                  />
                </div>
              ))}
              <AddressSelect
                value={{ city: customer.city, district: customer.district, neighborhood: customer.neighborhood }}
                onChange={(v: { city: string; district: string; neighborhood: string }) => setCustomer({ ...customer, ...v })}
              />

              <div className="space-y-2 sm:col-span-2">
                <Label htmlFor="c-address">Adres</Label>
                <Input
                  id="c-address"
                  value={customer.address}
                  onChange={(e) => setCustomer({ ...customer, address: e.target.value })}
                />
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardHeader className="flex flex-row items-center justify-between">
              <CardTitle className="text-base">Fatura Kalemleri</CardTitle>
              <Button variant="outline" size="sm" onClick={() => setItems([...items, newItem()])}>
                Kalem Ekle
              </Button>
            </CardHeader>
            <CardContent className="space-y-4">
              {items.map((item, index) => {
                const t = itemTotals(item);
                return (
                  <div key={item.id} className="rounded-md border border-border p-4">
                    <div className="mb-3 flex items-center justify-between">
                      <span className="text-xs font-semibold uppercase text-muted-foreground">
                        Kalem {index + 1}
                      </span>
                      <Button
                        variant="ghost"
                        size="icon"
                        onClick={() => setItems(items.filter((i) => i.id !== item.id))}
                      >
                        <Trash2 className="size-4" />
                      </Button>
                    </div>
                    <div className="grid gap-3 sm:grid-cols-2">
                      <div className="space-y-2 sm:col-span-2">
                        <Label>Katalogdan Seç</Label>
                        <Select onValueChange={(v) => applyProduct(item.id, v)}>
                          <SelectTrigger>
                            <SelectValue
                              placeholder={
                                productsLoading
                                  ? "Katalog yükleniyor…"
                                  : productsError
                                    ? "Katalog yüklenemedi"
                                    : products.length === 0
                                      ? "Katalogda kayıtlı ürün yok"
                                      : "Ürün/hizmet seçin (opsiyonel)"
                              }
                            />
                          </SelectTrigger>
                          <SelectContent>
                            {products.length === 0 ? (
                              <div className="px-3 py-2 text-sm text-muted-foreground">
                                {productsLoading
                                  ? "Yükleniyor…"
                                  : productsError
                                    ? "Katalog yüklenemedi, sayfayı yenileyin."
                                    : "Ürün & Hizmet sayfasından kalem ekleyin."}
                              </div>
                            ) : (
                              products.map((p) => (
                                <SelectItem key={p.id} value={p.id}>
                                  {p.name} — {formatMoney(Number(p.unit_price), currency)}
                                </SelectItem>
                              ))
                            )}
                          </SelectContent>
                        </Select>
                      </div>

                      <div className="space-y-2 sm:col-span-2">
                        <Label>Açıklama</Label>
                        <Input value={item.name} onChange={(e) => updateItem(item.id, { name: e.target.value })} />
                      </div>
                      <div className="grid grid-cols-2 gap-3 sm:col-span-2 sm:grid-cols-5">
                        <div className="space-y-2">
                          <Label>Miktar</Label>
                          <Input
                            type="number"
                            step="0.01"
                            value={item.quantity}
                            onChange={(e) => updateItem(item.id, { quantity: Number(e.target.value) })}
                          />
                        </div>
                        <div className="space-y-2">
                          <Label>Birim</Label>
                          <Input value={item.unit} onChange={(e) => updateItem(item.id, { unit: e.target.value })} />
                        </div>
                        <div className="space-y-2">
                          <Label>Birim Fiyat</Label>
                          <Input
                            type="number"
                            step="0.01"
                            value={item.unitPrice}
                            onChange={(e) => updateItem(item.id, { unitPrice: Number(e.target.value) })}
                          />
                        </div>
                        <div className="space-y-2">
                          <Label>İskonto %</Label>
                          <Input
                            type="number"
                            step="0.01"
                            value={item.discountRate}
                            onChange={(e) => updateItem(item.id, { discountRate: Number(e.target.value) })}
                          />
                        </div>
                        <div className="space-y-2">
                          <Label>KDV %</Label>
                          <Input
                            type="number"
                            step="1"
                            value={item.vatRate}
                            onChange={(e) => updateItem(item.id, { vatRate: Number(e.target.value) })}
                          />
                        </div>
                      </div>
                    </div>
                    <p className="mt-3 text-right text-sm font-medium">
                      Kalem Toplamı: {formatMoney(t.total, currency)}
                    </p>
                  </div>
                );
              })}
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">Notlar</CardTitle>
            </CardHeader>
            <CardContent className="grid gap-4 sm:grid-cols-2">
              <div className="space-y-2">
                <Label htmlFor="notes">Fatura Notu</Label>
                <Textarea id="notes" value={notes} onChange={(e) => setNotes(e.target.value)} />
              </div>
              <div className="space-y-2">
                <Label htmlFor="payment">Ödeme Bilgisi</Label>
                <Textarea id="payment" value={paymentInfo} onChange={(e) => setPaymentInfo(e.target.value)} />
              </div>
            </CardContent>
          </Card>
        </div>

        <div>
          <Card className="lg:sticky lg:top-6">
            <CardHeader>
              <CardTitle className="text-base">Özet</CardTitle>
            </CardHeader>
            <CardContent className="space-y-3 text-sm">
              <Row label="Ara Toplam" value={formatMoney(totals.subtotal, currency)} />
              <Row label="Toplam İskonto" value={formatMoney(totals.totalDiscount, currency)} />
              <Row label="KDV Matrahı" value={formatMoney(totals.taxableAmount, currency)} />
              <Row label="Hesaplanan KDV" value={formatMoney(totals.totalVat, currency)} />
              <div className="space-y-2 pt-2">
                <Label htmlFor="tevkifat">Tevkifat Oranı (%)</Label>
                <Input
                  id="tevkifat"
                  type="number"
                  step="1"
                  value={tevkifatRate}
                  onChange={(e) => setTevkifatRate(e.target.value)}
                />
              </div>
              <Row label="Tevkifat" value={`- ${formatMoney(totalTevkifat, currency)}`} />
              <div className="mt-3 flex items-center justify-between border-t border-border pt-3 text-base font-bold">
                <span>Genel Toplam</span>
                <span>{formatMoney(grandTotal, currency)}</span>
              </div>
              <Button
                variant="outline"
                className="w-full"
                onClick={() => saveInvoice.mutate("TASLAK")}
                disabled={saveInvoice.isPending}
              >
                Faturayı Kaydet
              </Button>
              <Button className="w-full" onClick={() => saveInvoice.mutate("ONAYLANDI")} disabled={saveInvoice.isPending}>
                GİB'e Gönder
              </Button>
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
