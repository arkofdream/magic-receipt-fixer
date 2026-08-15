import { createFileRoute, Link } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { FileDown } from "lucide-react";
import { toast } from "sonner";

import { AppShell } from "@/components/AppShell";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { supabase } from "@/integrations/supabase/client";
import { formatDate, formatMoney, INVOICE_STATUSES } from "@/lib/invoice";
import { downloadInvoicesPdf, type InvoiceRecord, type SellerInfo } from "@/lib/pdf/invoice-pdf";

export const Route = createFileRoute("/_authenticated/faturalar")({
  head: () => ({
    meta: [
      { title: "Fatura Arşivi | e-Fatura Portalı" },
      { name: "description", content: "Kesilen tüm e-arşiv ve e-fatura kayıtlarınızı arayın ve durumlarını takip edin." },
      { property: "og:title", content: "Fatura Arşivi | e-Fatura Portalı" },
      { property: "og:description", content: "Tüm faturalarınız tek listede." },
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
  customer_id: string | null;
  warehouse_id: string | null;
  posted: boolean;
  items: unknown;
};

function InvoicesPage() {
  const queryClient = useQueryClient();
  const [status, setStatus] = useState("ALL");
  const [search, setSearch] = useState("");
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
      const { data, error } = await supabase.from("invoices").select("*").order("created_at", { ascending: false });
      if (error) throw error;
      return data;
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

  const paidByInvoice = new Map<string, number>();
  for (const p of payments) {
    if (!p.source_id) continue;
    paidByInvoice.set(p.source_id, (paidByInvoice.get(p.source_id) ?? 0) + Number(p.amount));
  }

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
          description: isReturn ? "İade faturası" : "Satış faturası",
          source: "FATURA",
          source_id: inv.id,
        });
        if (txnError) throw txnError;
      }

      const invItems = (inv.items as unknown as { productId?: string; quantity: number; unitPrice: number }[]) ?? [];
      const stockRows = invItems
        .filter((i) => i.productId)
        .map((i) => ({
          user_id: inv.user_id,
          product_id: i.productId as string,
          warehouse_id: inv.warehouse_id,
          customer_id: inv.customer_id,
          movement_date: inv.invoice_date,
          movement_type: isReturn ? "GIRIS" : "CIKIS",
          quantity: Number(i.quantity),
          unit_price: Number(i.unitPrice),
          document_no: inv.invoice_number,
          description: "Fatura kaynaklı stok hareketi",
          source: "FATURA",
          source_id: inv.id,
        }));
      if (stockRows.length > 0) {
        const { error: stockError } = await supabase.from("stock_movements").insert(stockRows);
        if (stockError) throw stockError;
      }
    },
    onSuccess: () => {
      toast.success("Fatura GİB'e iletildi; cari ve stok hareketleri işlendi.");
      queryClient.invalidateQueries({ queryKey: ["invoices"] });
      queryClient.invalidateQueries({ queryKey: ["account-transactions"] });
      queryClient.invalidateQueries({ queryKey: ["customer-balances"] });
      queryClient.invalidateQueries({ queryKey: ["stock-movements"] });
      queryClient.invalidateQueries({ queryKey: ["product-stocks"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const collect = useMutation({
    mutationFn: async ({ inv, amount }: { inv: InvoiceRow; amount: number }) => {
      if (!inv.customer_id) throw new Error("Bu fatura bir cari karta bağlı değil. Tahsilatı Cariler ekranından girin.");
      if (amount <= 0) throw new Error("Tahsil edilecek tutar kalmadı.");
      const { error } = await supabase.from("account_transactions").insert({
        user_id: inv.user_id,
        customer_id: inv.customer_id,
        txn_date: new Date().toISOString().slice(0, 10),
        txn_type: "TAHSILAT",
        amount,
        document_no: inv.invoice_number,
        description: "Fatura tahsilatı",
        source: "FATURA_TAHSILAT",
        source_id: inv.id,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Tahsilat kaydedildi.");
      queryClient.invalidateQueries({ queryKey: ["invoice-payments"] });
      queryClient.invalidateQueries({ queryKey: ["account-transactions"] });
      queryClient.invalidateQueries({ queryKey: ["customer-balances"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const cancel = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase
        .from("invoices")
        .update({ status: "IPTAL", cancel_date: new Date().toISOString() })
        .eq("id", id);
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Fatura iptal edildi.");
      queryClient.invalidateQueries({ queryKey: ["invoices"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const filtered = invoices.filter((inv) => {
    if (status !== "ALL" && inv.status !== status) return false;
    if (!search) return true;
    const customer = inv.customer as { title?: string; vknTckn?: string } | null;
    const q = search.toLowerCase();
    return (
      inv.invoice_number.toLowerCase().includes(q) ||
      (customer?.title ?? "").toLowerCase().includes(q) ||
      (customer?.vknTckn ?? "").includes(q)
    );
  });

  const seller: SellerInfo = {
    companyTitle: profile?.company_title ?? "",
    vknTckn: profile?.vkn_tckn ?? "",
    taxOffice: profile?.tax_office ?? "",
    address: profile?.address ?? "",
    phone: profile?.phone ?? "",
    email: profile?.email ?? "",
  };

  const allSelected = filtered.length > 0 && filtered.every((inv) => selected.includes(inv.id));

  async function downloadSelected() {
    const records = invoices.filter((inv) => selected.includes(inv.id)) as unknown as InvoiceRecord[];
    if (records.length === 0) {
      toast.error("Önce fatura seçin.");
      return;
    }
    setDownloading(true);
    try {
      await downloadInvoicesPdf(records, seller);
      toast.success(`${records.length} fatura tek PDF olarak indirildi.`);
    } catch (error) {
      toast.error(error instanceof Error ? error.message : "PDF oluşturulamadı.");
    } finally {
      setDownloading(false);
    }
  }

  return (
    <AppShell
      title="Fatura Arşivi"
      subtitle="Kesilen faturalarınızın tamamı"
      actions={
        <>
          <Button
            variant="outline"
            className="gap-2"
            disabled={selected.length === 0 || downloading}
            onClick={downloadSelected}
          >
            <FileDown className="size-4" />
            {downloading ? "Hazırlanıyor…" : `Seçilenleri İndir (${selected.length})`}
          </Button>
          <Button asChild>
            <Link to="/fatura-kes">Yeni Fatura</Link>
          </Button>
        </>
      }
    >
      <Card>
        <CardHeader className="flex flex-wrap items-center justify-between gap-3">
          <CardTitle className="text-base">Faturalar ({filtered.length})</CardTitle>
          <div className="flex flex-wrap items-center gap-3">
            <Tabs value={status} onValueChange={setStatus}>
              <TabsList>
                <TabsTrigger value="ALL">Tümü</TabsTrigger>
                <TabsTrigger value="TASLAK">Taslak</TabsTrigger>
                <TabsTrigger value="ONAYLANDI">İletildi</TabsTrigger>
                <TabsTrigger value="IPTAL">İptal</TabsTrigger>
              </TabsList>
            </Tabs>
            <Input
              placeholder="Fatura no, unvan veya VKN ara"
              className="w-64"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
            />
          </div>
        </CardHeader>
        <CardContent>
          {isLoading ? (
            <p className="text-sm text-muted-foreground">Yükleniyor…</p>
          ) : filtered.length === 0 ? (
            <p className="text-sm text-muted-foreground">Kayıt bulunamadı.</p>
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
                    <th className="py-2 pr-4">ETTN</th>
                    <th className="py-2 pr-4">Alıcı</th>
                    <th className="py-2 pr-4">Tarih</th>
                    <th className="py-2 pr-4">KDV</th>
                    <th className="py-2 pr-4">Toplam</th>
                    <th className="py-2 pr-4">Durum</th>
                    <th className="py-2 pr-4">Ödeme</th>
                    <th className="py-2" />
                  </tr>
                </thead>
                <tbody>
                  {filtered.map((inv) => {
                    const customer = inv.customer as { title?: string; vknTckn?: string } | null;
                    const s = INVOICE_STATUSES[inv.status] ?? { label: inv.status, tone: "draft" as const };
                    const row = inv as unknown as InvoiceRow;
                    const paid = paidByInvoice.get(inv.id) ?? 0;
                    const remaining = Math.max(Number(inv.grand_total) - paid, 0);
                    const payLabel = paid <= 0 ? "Ödenmedi" : remaining < 0.005 ? "Ödendi" : "Kısmi";
                    return (
                      <tr key={inv.id} className="border-b border-border/60 last:border-0">
                        <td className="py-3 pr-2">
                          <Checkbox
                            checked={selected.includes(inv.id)}
                            onCheckedChange={(checked) =>
                              setSelected((prev) =>
                                checked === true ? [...prev, inv.id] : prev.filter((id) => id !== inv.id),
                              )
                            }
                            aria-label={`${inv.invoice_number} seç`}
                          />
                        </td>
                        <td className="py-3 pr-4 font-medium">{inv.invoice_number}</td>
                        <td className="py-3 pr-4 font-mono text-xs text-muted-foreground">
                          {inv.ettn.slice(0, 8)}…
                        </td>
                        <td className="py-3 pr-4">
                          {customer?.title ?? "-"}
                          <span className="block text-xs text-muted-foreground">{customer?.vknTckn}</span>
                        </td>
                        <td className="py-3 pr-4">{formatDate(inv.invoice_date)}</td>
                        <td className="py-3 pr-4">{formatMoney(Number(inv.total_vat), inv.currency)}</td>
                        <td className="py-3 pr-4 font-semibold">
                          {formatMoney(Number(inv.grand_total), inv.currency)}
                        </td>
                        <td className="py-3 pr-4">
                          <Badge
                            variant={
                              s.tone === "cancel" ? "destructive" : s.tone === "sent" ? "default" : "secondary"
                            }
                          >
                            {s.label}
                          </Badge>
                        </td>
                        <td className="py-3 text-right">
                          {inv.status === "TASLAK" ? (
                            <Button size="sm" variant="outline" onClick={() => sign.mutate(inv.id)}>
                              GİB'e Gönder
                            </Button>
                          ) : null}
                          {inv.status !== "IPTAL" ? (
                            <Button size="sm" variant="ghost" onClick={() => cancel.mutate(inv.id)}>
                              İptal
                            </Button>
                          ) : null}
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
    </AppShell>
  );
}
