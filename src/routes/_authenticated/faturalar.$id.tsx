import { createFileRoute, Link, useParams } from "@tanstack/react-router";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { ArrowLeft, RefreshCw, FileText, CheckCircle, AlertCircle, Clock, Send, ShieldCheck } from "lucide-react";
import { toast } from "sonner";

import { AppShell } from "@/components/AppShell";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { INVOICE_STATUSES } from "@/lib/invoice";

export const Route = createFileRoute("/_authenticated/faturalar/$id")({
  component: InvoiceDetailPage,
});

function InvoiceDetailPage() {
  const { id } = useParams({ from: "/_authenticated/faturalar/$id" });
  const queryClient = useQueryClient();
  const [refreshing, setRefreshing] = useState(false);

  const { data: invoiceRes, isLoading, error } = useQuery({
    queryKey: ["invoice-detail", id],
    queryFn: async () => {
      const res = await fetch(`/api/invoices/${encodeURIComponent(id)}`);
      const json = await res.json();
      if (!res.ok || !json.success) {
        throw new Error(json.message || "Fatura detayı alınamadı.");
      }
      return json.data;
    },
  });

  async function handleRefreshStatus() {
    setRefreshing(true);
    try {
      const res = await fetch(`/api/invoices/${encodeURIComponent(id)}/status`);
      const json = await res.json();
      if (!res.ok || !json.success) {
        throw new Error(json.message || "Durum güncellenemedi.");
      }

      toast.success(`Fatura durumu EDM'den güncellendi: ${json.data?.status || "Başarılı"}`);
      queryClient.invalidateQueries({ queryKey: ["invoice-detail", id] });
      queryClient.invalidateQueries({ queryKey: ["invoices"] });
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : "Durum güncelleme hatası.");
    } finally {
      setRefreshing(false);
    }
  }

  if (isLoading) {
    return (
      <AppShell title="Fatura Detayı" subtitle="Yükleniyor...">
        <div className="p-8 text-center text-muted-foreground text-sm">Fatura detayları yükleniyor...</div>
      </AppShell>
    );
  }

  if (error || !invoiceRes) {
    return (
      <AppShell title="Fatura Detayı" subtitle="Hata">
        <Card className="border-destructive/30 bg-destructive/5">
          <CardContent className="p-6 text-center space-y-4">
            <AlertCircle className="size-8 mx-auto text-destructive" />
            <p className="text-sm font-medium text-destructive">
              {error instanceof Error ? error.message : "Fatura bulunamadı."}
            </p>
            <Button variant="outline" asChild>
              <Link to="/faturalar">Faturalara Dön</Link>
            </Button>
          </CardContent>
        </Card>
      </AppShell>
    );
  }

  const inv = invoiceRes;
  const statusMeta = INVOICE_STATUSES[inv.status] || { label: inv.status, tone: "draft" };

  return (
    <AppShell
      title={`Fatura No: ${inv.invoiceNumber}`}
      subtitle={`ETTN / UUID: ${inv.ettn}`}
      actions={
        <div className="flex gap-2">
          <Button
            variant="outline"
            className="gap-2"
            disabled={refreshing}
            onClick={handleRefreshStatus}
          >
            <RefreshCw className={`size-4 ${refreshing ? "animate-spin" : ""}`} />
            {refreshing ? "Güncelleniyor..." : "EDM Durumunu Güncelle"}
          </Button>
          <Button variant="outline" asChild>
            <Link to="/faturalar">
              <ArrowLeft className="mr-1 size-4" /> Faturalara Dön
            </Link>
          </Button>
        </div>
      }
    >
      <div className="space-y-6">
        {/* Üst Durum Kartı */}
        <Card>
          <CardContent className="py-4 flex flex-wrap items-center justify-between gap-4">
            <div className="flex items-center gap-3">
              <Badge
                variant={
                  statusMeta.tone === "cancel"
                    ? "destructive"
                    : statusMeta.tone === "sent"
                    ? "default"
                    : "secondary"
                }
                className="text-sm px-3 py-1"
              >
                {statusMeta.label}
              </Badge>
              <span className="text-xs text-muted-foreground font-mono">
                Entegratör: {inv.provider || "EDM TEST"}
              </span>
            </div>

            <div className="flex items-center gap-4 text-xs">
              <div>
                <span className="text-muted-foreground block">Tarih:</span>
                <span className="font-semibold">{inv.invoiceDate || "-"}</span>
              </div>
              <div>
                <span className="text-muted-foreground block">Para Birimi:</span>
                <span className="font-semibold font-mono">{inv.currency || "TRY"}</span>
              </div>
              <div>
                <span className="text-muted-foreground block">Genel Toplam:</span>
                <span className="font-bold text-primary text-sm">
                  {Number(inv.grandTotal || 0).toLocaleString("tr-TR", { minimumFractionDigits: 2 })} {inv.currency || "TRY"}
                </span>
              </div>
            </div>
          </CardContent>
        </Card>

        {/* EDM Referans ve Durum Bilgileri */}
        <Card className="border-primary/20 bg-primary/5">
          <CardHeader className="py-3">
            <CardTitle className="text-sm font-semibold flex items-center gap-2">
              <ShieldCheck className="size-4 text-primary" /> EDM Entegrasyon Detayları
            </CardTitle>
          </CardHeader>
          <CardContent className="py-2 grid gap-3 sm:grid-cols-2 md:grid-cols-4 text-xs">
            <div>
              <span className="text-muted-foreground block">EDM Referansı (TRXID):</span>
              <span className="font-mono font-semibold">{inv.providerReference || inv.trxId || "Henüz Alınmadı"}</span>
            </div>
            <div>
              <span className="text-muted-foreground block">EDM Ham Durumu:</span>
              <span className="font-semibold">{inv.edmStatus || inv.status || "-"}</span>
            </div>
            <div>
              <span className="text-muted-foreground block">Gönderim Tarihi:</span>
              <span>{inv.sentAt ? new Date(inv.sentAt).toLocaleString("tr-TR") : "-"}</span>
            </div>
            <div>
              <span className="text-muted-foreground block">İşlenme Tarihi:</span>
              <span>{inv.processedAt ? new Date(inv.processedAt).toLocaleString("tr-TR") : "-"}</span>
            </div>
          </CardContent>
        </Card>

        {/* Satıcı & Alıcı Taraf Kartları */}
        <div className="grid gap-6 md:grid-cols-2">
          <Card>
            <CardHeader className="py-3">
              <CardTitle className="text-sm font-semibold">Satıcı (Gönderen)</CardTitle>
            </CardHeader>
            <CardContent className="space-y-1 text-xs">
              <p className="font-bold text-sm">{inv.seller?.name || "-"}</p>
              <p><span className="text-muted-foreground">VKN/TCKN:</span> <span className="font-mono">{inv.seller?.taxNumber || "-"}</span></p>
            </CardContent>
          </Card>

          <Card>
            <CardHeader className="py-3">
              <CardTitle className="text-sm font-semibold">Alıcı (Müşteri)</CardTitle>
            </CardHeader>
            <CardContent className="space-y-1 text-xs">
              <p className="font-bold text-sm">{inv.buyer?.name || "-"}</p>
              <p><span className="text-muted-foreground">VKN/TCKN:</span> <span className="font-mono">{inv.buyer?.taxNumber || "-"}</span></p>
              {inv.buyer?.details?.address ? <p><span className="text-muted-foreground">Adres:</span> {inv.buyer.details.address}</p> : null}
            </CardContent>
          </Card>
        </div>

        {/* Kalemler Tablosu */}
        <Card>
          <CardHeader className="py-3">
            <CardTitle className="text-sm font-semibold">Fatura Kalemleri</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="overflow-x-auto">
              <table className="w-full text-xs">
                <thead>
                  <tr className="border-b border-border text-left uppercase text-muted-foreground">
                    <th className="py-2 pr-2">Ürün/Hizmet</th>
                    <th className="py-2 pr-2 w-20">Miktar</th>
                    <th className="py-2 pr-2 w-24">Birim Fiyat</th>
                    <th className="py-2 pr-2 w-20">KDV</th>
                    <th className="py-2 pr-2 text-right">Toplam</th>
                  </tr>
                </thead>
                <tbody>
                  {Array.isArray(inv.items) && inv.items.map((item: any, idx: number) => (
                    <tr key={idx} className="border-b border-border/50">
                      <td className="py-2 pr-2 font-medium">{item.name || item.description || "Kalem"}</td>
                      <td className="py-2 pr-2 font-mono">{item.quantity || 1} {item.unit || "ADET"}</td>
                      <td className="py-2 pr-2 font-mono">{Number(item.unitPrice || 0).toLocaleString("tr-TR", { minimumFractionDigits: 2 })}</td>
                      <td className="py-2 pr-2 font-mono">% {item.vatRate ?? 20}</td>
                      <td className="py-2 pr-2 text-right font-mono font-medium">
                        {(Number(item.quantity || 1) * Number(item.unitPrice || 0)).toLocaleString("tr-TR", { minimumFractionDigits: 2 })} {inv.currency || "TRY"}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            {/* Dip Hesap Özeti */}
            <div className="flex justify-end pt-4 border-t mt-4">
              <div className="w-64 space-y-1.5 text-xs">
                <div className="flex justify-between py-0.5 text-muted-foreground">
                  <span>Ara Toplam:</span>
                  <span className="font-mono">{Number(inv.subtotal || 0).toLocaleString("tr-TR", { minimumFractionDigits: 2 })} {inv.currency || "TRY"}</span>
                </div>
                <div className="flex justify-between py-0.5 text-muted-foreground">
                  <span>Toplam KDV:</span>
                  <span className="font-mono">{Number(inv.totalVat || 0).toLocaleString("tr-TR", { minimumFractionDigits: 2 })} {inv.currency || "TRY"}</span>
                </div>
                <div className="flex justify-between py-1 text-sm font-bold text-primary border-t">
                  <span>Genel Toplam:</span>
                  <span className="font-mono">{Number(inv.grandTotal || 0).toLocaleString("tr-TR", { minimumFractionDigits: 2 })} {inv.currency || "TRY"}</span>
                </div>
              </div>
            </div>
          </CardContent>
        </Card>
      </div>
    </AppShell>
  );
}
