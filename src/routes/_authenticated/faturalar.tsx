import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import { Download, FileDown, Trash2, Edit, Filter, Plus, ArrowUpDown, FileText } from "lucide-react";
import { toast } from "sonner";

import { AppShell } from "@/components/AppShell";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { supabase } from "@/integrations/supabase/client";
import { isMissingColumnError, safeSoftDelete } from "@/lib/safe-supabase";
import {
  formatDate,
  formatMoney,
  INVOICE_STATUSES,
  INVOICE_TYPES,
  roundMoney,
} from "@/lib/invoice";
import { downloadInvoicesPdf, type InvoiceRecord, type SellerInfo } from "@/lib/pdf/invoice-pdf";

export const Route = createFileRoute("/_authenticated/faturalar")({
  head: () => ({
    meta: [
      { title: "Fatura Arşivi & Gelen/Giden Faturalar | e-Fatura Portalı" },
      {
        name: "description",
        content: "Kesilen tüm e-arşiv, gelen faturalar ve e-fatura kayıtlarınızı arayın, filtreleyin ve düzenleyin.",
      },
      { property: "og:title", content: "Fatura Arşivi & Gelen/Giden Faturalar | e-Fatura Portalı" },
      { property: "og:description", content: "Tüm faturalarınız ve filtreleme seçenekleri." },
    ],
  }),
  component: InvoicesPage,
});

type InvoiceRow = {
  id: string;
  user_id: string;
  invoice_number: string;
  invoice_date: string;
  type: string;
  status: string;
  currency: string;
  grand_total: number;
  total_vat: number;
  customer_id: string | null;
  warehouse_id: string | null;
  posted: boolean;
  items: unknown;
  customer: unknown;
  ettn: string;
};

const TYPE_BADGE_MAP: Record<string, { label: string; variant: "default" | "secondary" | "outline" | "destructive" }> = {
  SATIS: { label: "Satış", variant: "default" },
  E_ARSIV: { label: "e-Arşiv", variant: "secondary" },
  GELEN_FATURA: { label: "Gelen Fatura", variant: "outline" },
  GELEN_E_ARSIV: { label: "Gelen e-Arşiv", variant: "outline" },
  ALIS: { label: "Alış Faturası", variant: "default" },
  ALIS_IADE: { label: "Alış İadesi", variant: "destructive" },
  IADE: { label: "Satış İadesi", variant: "destructive" },
  TEVKIFAT: { label: "Tevkifatlı", variant: "default" },
  ISTISNA: { label: "İstisna (%0)", variant: "secondary" },
};

function InvoicesPage() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  // Filtreler
  const [activeTab, setActiveTab] = useState("ALL");
  const [statusFilter, setStatusFilter] = useState("ALL");
  const [typeFilter, setTypeFilter] = useState("ALL");
  const [invoiceNoSearch, setInvoiceNoSearch] = useState("");
  const [customerSearch, setCustomerSearch] = useState("");
  const [startDate, setStartDate] = useState("");
  const [endDate, setEndDate] = useState("");

  const [selected, setSelected] = useState<string[]>([]);
  const [downloading, setDownloading] = useState(false);

  const { data: profile } = useQuery({
    queryKey: ["profile"],
    queryFn: async () => {
      const { data, error } = await supabase.from("profiles").select("*").maybeSingle();
      if (error) throw error;
      return data;
    },
  });

  const { data: invoices = [], isLoading } = useQuery({
    queryKey: ["invoices"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("invoices")
        .select("*")
        .is("deleted_at", null)
        .order("created_at", { ascending: false });
      if (error && isMissingColumnError(error)) {
        const fallback = await supabase
          .from("invoices")
          .select("*")
          .order("created_at", { ascending: false });
        if (fallback.error) throw fallback.error;
        return fallback.data ?? [];
      }
      if (error) throw error;
      return data ?? [];
    },
  });

  const { data: payments = [] } = useQuery({
    queryKey: ["invoice-payments"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("account_transactions")
        .select("source_id, amount")
        .eq("source", "FATURA_TAHSILAT");
      if (error) throw error;
      return data ?? [];
    },
  });

  const paidByInvoice = useMemo(() => {
    const map = new Map<string, number>();
    for (const p of payments) {
      if (!p.source_id) continue;
      map.set(p.source_id, (map.get(p.source_id) ?? 0) + Number(p.amount));
    }
    return map;
  }, [payments]);

  const sign = useMutation({
    mutationFn: async (inv: InvoiceRow) => {
      const { error } = await supabase
        .from("invoices")
        .update({ status: "ONAYLANDI", gib_approval_date: new Date().toISOString(), posted: true })
        .eq("id", inv.id);
      if (error) throw error;

      if (inv.posted) return;
      const isReturn = inv.type === "IADE";

      if (inv.customer_id) {
        const { error: txnError } = await supabase.from("account_transactions").insert({
          user_id: inv.user_id,
          customer_id: inv.customer_id,
          txn_date: inv.invoice_date,
          txn_type: isReturn ? "ALACAK" : "BORC",
          amount: Number(inv.grand_total),
          document_no: inv.invoice_number,
          description: isReturn ? "İade faturası kaydı" : "Satış faturası borç kaydı",
          source: "FATURA",
          source_id: inv.id,
        });
        if (txnError) throw txnError;
      }

      const invItems =
        (inv.items as unknown as { productId?: string; quantity: number; unitPrice: number }[]) ??
        [];
      const stockRows = invItems
        .filter((i) => i.productId)
        .map((i) => ({
          user_id: inv.user_id,
          product_id: i.productId as string,
          warehouse_id: inv.warehouse_id,
          customer_id: inv.customer_id,
          movement_date: inv.invoice_date,
          movement_type: isReturn ? "GIRIS" : "CIKIS",
          quantity: Math.max(0, Number(i.quantity) || 0),
          unit_price: roundMoney(Number(i.unitPrice) || 0),
          document_no: inv.invoice_number,
          description: isReturn
            ? "Fatura kaynaklı stok iade girişi"
            : "Fatura kaynaklı stok çıkışı",
          source: "FATURA",
          source_id: inv.id,
        }));
      if (stockRows.length > 0) {
        const { error: stockError } = await supabase.from("stock_movements").insert(stockRows);
        if (stockError) throw stockError;
      }
    },
    onSuccess: () => {
      toast.success("Fatura onaylandı; cari ve stok hareketleri işlendi.");
      queryClient.invalidateQueries({ queryKey: ["invoices"] });
      queryClient.invalidateQueries({ queryKey: ["account-transactions"] });
      queryClient.invalidateQueries({ queryKey: ["customer-balances"] });
      queryClient.invalidateQueries({ queryKey: ["stock-movements"] });
      queryClient.invalidateQueries({ queryKey: ["product-stocks"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const sendToNes = useMutation({
    mutationFn: async (inv: InvoiceRow) => {
      const cust = inv.customer as { title?: string; name?: string; vknTckn?: string } | null;
      const { sendInvoiceToProvider } = await import("@/lib/efatura-settings.functions");
      const res = await sendInvoiceToProvider({
        data: {
          ettn: inv.ettn,
          invoiceNumber: inv.invoice_number,
          customerName: cust?.title || cust?.name || "",
          customerTaxNumber: cust?.vknTckn || "",
          grandTotal: Number(inv.grand_total),
          type: inv.type,
          isDirectSend: "true",
        },
      });
      if (!res.ok) {
        throw new Error(res.message);
      }
      return res;
    },
    onSuccess: (res) => {
      toast.success(res.message || "Fatura NES servisine başarıyla yüklendi.");
      queryClient.invalidateQueries({ queryKey: ["invoices"] });
    },
    onError: (e: Error) => toast.error(`Entegratör Gönderim Hatası: ${e.message}`),
  });

  const collect = useMutation({
    mutationFn: async ({ inv, amount }: { inv: InvoiceRow; amount: number }) => {
      if (!inv.customer_id)
        throw new Error(
          "Bu fatura bir cari karta bağlı değil. Tahsilatı Cariler ekranından girin.",
        );
      if (amount <= 0) throw new Error("Tahsil edilecek tutar kalmadı.");
      const { error } = await supabase.from("account_transactions").insert({
        user_id: inv.user_id,
        customer_id: inv.customer_id,
        txn_date: new Date().toISOString().slice(0, 10),
        txn_type: "TAHSILAT",
        amount: roundMoney(amount),
        document_no: inv.invoice_number,
        description: "Fatura tahsilatı",
        source: "FATURA_TAHSILAT",
        source_id: inv.id,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Tahsilat başarıyla kaydedildi.");
      queryClient.invalidateQueries({ queryKey: ["invoice-payments"] });
      queryClient.invalidateQueries({ queryKey: ["account-transactions"] });
      queryClient.invalidateQueries({ queryKey: ["customer-balances"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const cancel = useMutation({
    mutationFn: async (inv: InvoiceRow) => {
      const isPurchase = inv.type === "ALIS" || inv.type === "GELEN_FATURA" || inv.type === "GELEN_E_ARSIV";
      if (isPurchase) {
        const { data: _result, error } = await supabase.rpc("cancel_purchase_invoice", {
          p_invoice_id: inv.id,
          p_cancel_reason: "Kullanıcı tarafından iptal edildi",
        });
        if (error) throw error;
      } else {
        const { data: _result, error } = await supabase.rpc("cancel_sales_invoice", {
          p_invoice_id: inv.id,
          p_cancel_reason: "Kullanıcı tarafından iptal edildi",
        });
        if (error) throw error;
      }
    },
    onSuccess: () => {
      toast.success("Fatura iptal edildi; ilgili cari, muhasebe ve stok kayıtları terslendi.");
      queryClient.invalidateQueries({ queryKey: ["invoices"] });
      queryClient.invalidateQueries({ queryKey: ["account-transactions"] });
      queryClient.invalidateQueries({ queryKey: ["customer-balances"] });
      queryClient.invalidateQueries({ queryKey: ["stock-movements"] });
      queryClient.invalidateQueries({ queryKey: ["product-stocks"] });
      queryClient.invalidateQueries({ queryKey: ["trial-balance"] });
      queryClient.invalidateQueries({ queryKey: ["reconciliation-summary"] });
      queryClient.invalidateQueries({ queryKey: ["accounting-audit"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const deleteDraft = useMutation({
    mutationFn: async (id: string) => {
      const { data: userData } = await supabase.auth.getUser();
      const userId = userData.user?.id;
      await safeSoftDelete("invoices", id, userId);
    },
    onSuccess: () => {
      toast.success("Fatura başarıyla silindi.");
      queryClient.invalidateQueries({ queryKey: ["invoices"] });
      queryClient.invalidateQueries({ queryKey: ["invoice-count"] });
      queryClient.invalidateQueries({ queryKey: ["account-transactions"] });
      queryClient.invalidateQueries({ queryKey: ["customer-balances"] });
      queryClient.invalidateQueries({ queryKey: ["stock-movements"] });
      queryClient.invalidateQueries({ queryKey: ["product-stocks"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  // Filtreleme mantığı
  const filtered = useMemo(() => {
    return invoices.filter((inv) => {
      // Tab filtre
      if (activeTab === "OUTGOING" && (inv.type === "GELEN_FATURA" || inv.type === "GELEN_E_ARSIV"))
        return false;
      if (activeTab === "INCOMING" && inv.type !== "GELEN_FATURA" && inv.type !== "GELEN_E_ARSIV")
        return false;
      if (activeTab === "E_ARSIV" && inv.type !== "E_ARSIV" && inv.type !== "GELEN_E_ARSIV")
        return false;
      if (activeTab === "TEVKIFAT" && inv.type !== "TEVKIFAT") return false;
      if (activeTab === "IADE" && inv.type !== "IADE") return false;

      // Durum filtre
      if (statusFilter !== "ALL" && inv.status !== statusFilter) return false;

      // Fatura tipi filtre
      if (typeFilter !== "ALL" && inv.type !== typeFilter) return false;

      // Fatura No filtre
      if (invoiceNoSearch) {
        const q = invoiceNoSearch.toLowerCase();
        if (!inv.invoice_number.toLowerCase().includes(q) && !inv.ettn.toLowerCase().includes(q))
          return false;
      }

      // Müşteri / Cari filtre
      if (customerSearch) {
        const q = customerSearch.toLowerCase();
        const customer = inv.customer as { title?: string; vknTckn?: string } | null;
        const titleMatch = (customer?.title ?? "").toLowerCase().includes(q);
        const vknMatch = (customer?.vknTckn ?? "").includes(q);
        if (!titleMatch && !vknMatch) return false;
      }

      // Tarih filtre
      if (startDate && inv.invoice_date < startDate) return false;
      if (endDate && inv.invoice_date > endDate) return false;

      return true;
    });
  }, [
    invoices,
    activeTab,
    statusFilter,
    typeFilter,
    invoiceNoSearch,
    customerSearch,
    startDate,
    endDate,
  ]);

  const seller: SellerInfo = {
    companyTitle: profile?.company_title || "",
    vknTckn: profile?.vkn_tckn || "",
    taxOffice: profile?.tax_office || "",
    address: profile?.address || "",
    phone: profile?.phone || "",
    email: profile?.email || "",
  };

  const allSelected = filtered.length > 0 && filtered.every((inv) => selected.includes(inv.id));

  async function downloadSelected() {
    const records = invoices.filter((inv) =>
      selected.includes(inv.id),
    ) as unknown as InvoiceRecord[];
    if (records.length === 0) {
      toast.error("Önce fatura seçin.");
      return;
    }
    setDownloading(true);
    try {
      await downloadInvoicesPdf(records, seller);
      toast.success(`${records.length} fatura resmi formatta tek PDF olarak indirildi.`);
    } catch (error) {
      toast.error(error instanceof Error ? error.message : "PDF oluşturulamadı.");
    } finally {
      setDownloading(false);
    }
  }

  async function downloadSingle(inv: unknown) {
    try {
      await downloadInvoicesPdf(
        [inv as InvoiceRecord],
        seller,
        `fatura-${(inv as InvoiceRecord).invoice_number}.pdf`,
      );
      toast.success("Resmi fatura PDF olarak indirildi.");
    } catch (error) {
      toast.error(error instanceof Error ? error.message : "PDF indirilemedi.");
    }
  }

  return (
    <AppShell
      title="Fatura Arşivi"
      subtitle="Kesilen e-arşiv, e-fatura, gelen alış faturaları ve tahsilat takibi"
      actions={
        <div className="flex gap-2">
          <Button
            variant="outline"
            className="gap-2"
            disabled={selected.length === 0 || downloading}
            onClick={downloadSelected}
          >
            <FileDown className="size-4" />
            {downloading ? "Hazırlanıyor…" : `Seçilenleri İndir (${selected.length})`}
          </Button>
          <Button variant="outline" asChild>
            <Link to="/fatura-kes" search={{ mode: "ALIS" }}>
              <Plus className="mr-1 size-4" /> Alış Faturası Girişi
            </Link>
          </Button>
          <Button asChild>
            <Link to="/fatura-kes" search={{ mode: "SATIS" }}>
              <Plus className="mr-1 size-4" /> Yeni Satış Faturası
            </Link>
          </Button>
        </div>
      }
    >
      <div className="space-y-4">
        {/* Kategori Sekmeleri */}
        <Tabs value={activeTab} onValueChange={setActiveTab}>
          <TabsList className="grid grid-cols-3 sm:flex sm:flex-wrap h-auto p-1 gap-1">
            <TabsTrigger value="ALL">Tüm Faturalar</TabsTrigger>
            <TabsTrigger value="OUTGOING">Giden Faturalar</TabsTrigger>
            <TabsTrigger value="E_ARSIV">E-Arşiv</TabsTrigger>
            <TabsTrigger value="INCOMING">Gelen Faturalar (Alış)</TabsTrigger>
            <TabsTrigger value="TEVKIFAT">Tevkifatlı</TabsTrigger>
            <TabsTrigger value="IADE">İade</TabsTrigger>
          </TabsList>
        </Tabs>

        {/* Detaylı Filtreleme Kartı */}
        <Card>
          <CardHeader className="py-3 px-4">
            <CardTitle className="text-sm font-semibold flex items-center gap-2">
              <Filter className="size-4 text-primary" /> Fatura Filtreleme
            </CardTitle>
          </CardHeader>
          <CardContent className="px-4 pb-4 pt-0">
            <div className="grid gap-3 sm:grid-cols-2 md:grid-cols-4 lg:grid-cols-6 items-end">
              <div className="space-y-1">
                <label className="text-xs font-medium text-muted-foreground">Fatura Tipi</label>
                <Select value={typeFilter} onValueChange={setTypeFilter}>
                  <SelectTrigger className="h-8 text-xs">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="ALL">Tüm Tipler</SelectItem>
                    {INVOICE_TYPES.map((t) => (
                      <SelectItem key={t.value} value={t.value}>
                        {t.label}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>

              <div className="space-y-1">
                <label className="text-xs font-medium text-muted-foreground">Fatura No / ETTN</label>
                <Input
                  placeholder="Fatura No veya ETTN..."
                  className="h-8 text-xs"
                  value={invoiceNoSearch}
                  onChange={(e) => setInvoiceNoSearch(e.target.value)}
                />
              </div>

              <div className="space-y-1">
                <label className="text-xs font-medium text-muted-foreground">Müşteri Kaydı / VKN</label>
                <Input
                  placeholder="Firma Unvanı veya VKN..."
                  className="h-8 text-xs"
                  value={customerSearch}
                  onChange={(e) => setCustomerSearch(e.target.value)}
                />
              </div>

              <div className="space-y-1">
                <label className="text-xs font-medium text-muted-foreground">Durum</label>
                <Select value={statusFilter} onValueChange={setStatusFilter}>
                  <SelectTrigger className="h-8 text-xs">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="ALL">Tüm Durumlar</SelectItem>
                    <SelectItem value="TASLAK">Taslak</SelectItem>
                    <SelectItem value="ONAYLANDI">İletildi / Onaylı</SelectItem>
                    <SelectItem value="IPTAL">İptal</SelectItem>
                  </SelectContent>
                </Select>
              </div>

              <div className="space-y-1">
                <label className="text-xs font-medium text-muted-foreground">Başlangıç Tarihi</label>
                <Input
                  type="date"
                  className="h-8 text-xs"
                  value={startDate}
                  onChange={(e) => setStartDate(e.target.value)}
                />
              </div>

              <div className="space-y-1">
                <label className="text-xs font-medium text-muted-foreground">Bitiş Tarihi</label>
                <Input
                  type="date"
                  className="h-8 text-xs"
                  value={endDate}
                  onChange={(e) => setEndDate(e.target.value)}
                />
              </div>
            </div>
          </CardContent>
        </Card>

        {/* Fatura Listesi */}
        <Card>
          <CardHeader className="flex flex-wrap items-center justify-between gap-3 py-4">
            <div>
              <CardTitle className="text-base">Faturalar ({filtered.length})</CardTitle>
              <CardDescription>Resmi şekil şartlarına uygun çıktılar ve durum takibi</CardDescription>
            </div>
          </CardHeader>
          <CardContent>
            {isLoading ? (
              <p className="text-sm text-muted-foreground py-4">Yükleniyor…</p>
            ) : filtered.length === 0 ? (
              <div className="text-center py-8 text-muted-foreground text-sm space-y-2">
                <FileText className="size-8 mx-auto text-muted-foreground/50" />
                <p>Seçilen filtrelere uygun fatura bulunamadı.</p>
              </div>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground">
                      <th className="w-10 py-2 pr-2">
                        <Checkbox
                          checked={allSelected}
                          onCheckedChange={(checked) =>
                            setSelected(checked === true ? filtered.map((inv) => inv.id) : [])
                          }
                          aria-label="Tümünü seç"
                        />
                      </th>
                      <th className="py-2 pr-4">Fatura No</th>
                      <th className="py-2 pr-4">Tip</th>
                      <th className="py-2 pr-4">Alıcı / Müşteri</th>
                      <th className="py-2 pr-4">Tarih</th>
                      <th className="py-2 pr-4">KDV</th>
                      <th className="py-2 pr-4">Genel Toplam</th>
                      <th className="py-2 pr-4">Durum</th>
                      <th className="py-2 pr-4">Ödeme</th>
                      <th className="py-2 text-right">İşlemler</th>
                    </tr>
                  </thead>
                  <tbody>
                    {filtered.map((inv) => {
                      const customer = inv.customer as { title?: string; vknTckn?: string } | null;
                      const s = INVOICE_STATUSES[inv.status] ?? {
                        label: inv.status,
                        tone: "draft" as const,
                      };
                      const typeBadge = TYPE_BADGE_MAP[inv.type] || {
                        label: inv.type,
                        variant: "outline" as const,
                      };
                      const row = inv as unknown as InvoiceRow;
                      const paid = paidByInvoice.get(inv.id) ?? 0;
                      const remaining = Math.max(Number(inv.grand_total) - paid, 0);
                      const payLabel =
                        paid <= 0 ? "Ödenmedi" : remaining < 0.005 ? "Ödendi" : "Kısmi";

                      return (
                        <tr
                          key={inv.id}
                          className="border-b border-border/60 hover:bg-muted/40 last:border-0"
                        >
                          <td className="py-3 pr-2">
                            <Checkbox
                              checked={selected.includes(inv.id)}
                              onCheckedChange={(checked) =>
                                setSelected((prev) =>
                                  checked === true
                                    ? [...prev, inv.id]
                                    : prev.filter((id) => id !== inv.id),
                                )
                              }
                              aria-label={`${inv.invoice_number} seç`}
                            />
                          </td>
                          <td className="py-3 pr-4 font-medium font-mono text-xs">
                            {inv.invoice_number}
                          </td>
                          <td className="py-3 pr-4">
                            <Badge variant={typeBadge.variant} className="text-xs">
                              {typeBadge.label}
                            </Badge>
                          </td>
                          <td className="py-3 pr-4">
                            <span className="font-medium">{customer?.title ?? "-"}</span>
                            {customer?.vknTckn ? (
                              <span className="block text-xs text-muted-foreground">
                                {customer.vknTckn}
                              </span>
                            ) : null}
                          </td>
                          <td className="py-3 pr-4 whitespace-nowrap">{formatDate(inv.invoice_date)}</td>
                          <td className="py-3 pr-4">
                            {formatMoney(Number(inv.total_vat), inv.currency)}
                          </td>
                          <td className="py-3 pr-4 font-semibold whitespace-nowrap">
                            {formatMoney(Number(inv.grand_total), inv.currency)}
                          </td>
                          <td className="py-3 pr-4">
                            <Badge
                              variant={
                                s.tone === "cancel"
                                  ? "destructive"
                                  : s.tone === "sent"
                                    ? "default"
                                    : "secondary"
                              }
                            >
                              {s.label}
                            </Badge>
                          </td>
                          <td className="py-3 pr-4">
                            <Badge variant={payLabel === "Ödendi" ? "default" : "secondary"}>
                              {payLabel}
                            </Badge>
                            {paid > 0 && remaining >= 0.005 ? (
                              <span className="block text-xs text-muted-foreground">
                                Kalan: {formatMoney(remaining, inv.currency)}
                              </span>
                            ) : null}
                          </td>
                          <td className="py-3 text-right whitespace-nowrap">
                            <div className="flex items-center justify-end gap-1">
                              {/* Yalnızca Taslak Faturalar Düzenlenebilir */}
                              {inv.status === "TASLAK" && !inv.posted ? (
                                <Button
                                  size="sm"
                                  variant="outline"
                                  className="h-8 gap-1 px-2 text-xs"
                                  title="Faturayı Düzenle"
                                  onClick={() =>
                                    navigate({
                                      to: "/fatura-kes",
                                      search: { editId: inv.id },
                                    })
                                  }
                                >
                                  <Edit className="size-3.5" /> Düzenle
                                </Button>
                              ) : null}

                              <Button
                                size="icon"
                                variant="ghost"
                                className="size-8"
                                title="Resmi Şekil Şartlarına Uygun PDF İndir"
                                onClick={() => downloadSingle(inv)}
                              >
                                <Download className="size-4" />
                              </Button>

                              <Button
                                size="sm"
                                variant="outline"
                                className="h-8 gap-1 px-2 text-xs border-blue-500/40 text-blue-600 dark:text-blue-400 hover:bg-blue-50 dark:hover:bg-blue-950/40"
                                title="NES Bilgi Portalına e-Fatura / e-Arşiv Gönder"
                                onClick={() => sendToNes.mutate(row)}
                                disabled={sendToNes.isPending}
                              >
                                NES'e Gönder
                              </Button>

                              {inv.status === "TASLAK" ? (
                                <>
                                  <Button
                                    size="sm"
                                    variant="outline"
                                    className="h-8 text-xs"
                                    onClick={() => sign.mutate(row)}
                                    disabled={sign.isPending}
                                  >
                                    Onayla
                                  </Button>
                                  <Button
                                    size="icon"
                                    variant="ghost"
                                    className="size-8"
                                    title="Taslağı Sil"
                                    onClick={() => {
                                      if (
                                        confirm(
                                          "Bu taslak faturayı silmek istediğinize emin misiniz?",
                                        )
                                      ) {
                                        deleteDraft.mutate(inv.id);
                                      }
                                    }}
                                  >
                                    <Trash2 className="size-4 text-destructive" />
                                  </Button>
                                </>
                              ) : null}

                              {inv.status === "ONAYLANDI" && remaining >= 0.005 ? (
                                <Button
                                  size="sm"
                                  variant="ghost"
                                  className="h-8 text-xs"
                                  disabled={collect.isPending}
                                  onClick={() => collect.mutate({ inv: row, amount: remaining })}
                                >
                                  Tahsilat
                                </Button>
                              ) : null}

                              {(inv.type === "ALIS" || inv.type === "GELEN_FATURA" || inv.type === "GELEN_E_ARSIV") && inv.status === "ONAYLANDI" ? (
                                <Button
                                  size="sm"
                                  variant="outline"
                                  className="h-8 text-xs"
                                  onClick={() =>
                                    navigate({
                                      to: "/fatura-kes",
                                      search: { mode: "ALIS_IADE", returnInvoiceId: inv.id },
                                    })
                                  }
                                >
                                  İade Et
                                </Button>
                              ) : null}

                              {inv.status !== "IPTAL" && inv.status !== "TASLAK" ? (
                                <Button
                                  size="sm"
                                  variant="ghost"
                                  className="h-8 text-xs text-destructive hover:bg-destructive/10 hover:text-destructive"
                                  onClick={() => {
                                    if (
                                      confirm(
                                        "Bu faturayı iptal etmek istediğinize emin misiniz? Stok ve cari hareketleri dengelenecektir.",
                                      )
                                    ) {
                                      cancel.mutate(row);
                                    }
                                  }}
                                >
                                  İptal
                                </Button>
                              ) : null}
                            </div>
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </CardContent>
        </Card>
      </div>
    </AppShell>
  );
}
