import { createFileRoute, Link, useParams } from "@tanstack/react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { ArrowLeft, RefreshCw, FileText, CheckCircle, AlertCircle, Clock, Send, ShieldCheck, Download } from "lucide-react";
import { toast } from "sonner";

import { AppShell } from "@/components/AppShell";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { INVOICE_STATUSES } from "@/lib/invoice";

export const Route = createFileRoute("/_authenticated/faturalar_/$id")({
  component: InvoiceDetailPage,
});

function InvoiceDetailPage() {
  const { id } = useParams({ from: "/_authenticated/faturalar_/$id" });
  const queryClient = useQueryClient();
  const [refreshing, setRefreshing] = useState(false);

  const { data: invoiceRes, isLoading, error } = useQuery({
    queryKey: ["invoice-detail", id],
    queryFn: async () => {
      const res = await fetch(`/api/invoices/${encodeURIComponent(id)}`);
      const json = await res.json();
      if (!res.ok || !json.success) {
        throw new Error(json.message || "Fatura detayları alınamadı.");
      }
      return json.data;
    },
  });

  const invoice = invoiceRes;

  async function handleRefreshStatus() {
    if (!invoice?.id) return;
    setRefreshing(true);
    try {
      const res = await fetch(`/api/invoices/${encodeURIComponent(invoice.id)}/status`);
      const json = await res.json();
      if (!res.ok || !json.success) {
        throw new Error(json.message || "Durum güncellenemedi.");
      }
      toast.success(json.message || "EDM canlı durum güncellendi.");
      queryClient.invalidateQueries({ queryKey: ["invoice-detail", id] });
      queryClient.invalidateQueries({ queryKey: ["invoices"] });
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : "Durum güncellenirken hata oluştu.");
    } finally {
      setRefreshing(false);
    }
  }

  if (isLoading) {
    return (
      <AppShell title="Fatura Yükleniyor...">
        <div className="p-12 text-center text-muted-foreground">Fatura detayları getiriliyor...</div>
      </AppShell>
    );
  }

  if (error || !invoice) {
    return (
      <AppShell title="Fatura Bulunamadı">
        <div className="p-8 space-y-4 text-center">
          <AlertCircle className="size-12 text-destructive mx-auto" />
          <h2 className="text-lg font-bold">Fatura Detayı Yüklenemedi</h2>
          <p className="text-sm text-muted-foreground">{error instanceof Error ? error.message : "Fatura bulunamadı."}</p>
          <Button asChild variant="outline">
            <Link to="/faturalar">Faturalara Dön</Link>
          </Button>
        </div>
      </AppShell>
    );
  }

  const statusInfo = INVOICE_STATUSES[invoice.status] || { label: invoice.status, tone: "draft" };

  return (
    <AppShell
      title={`Fatura Detayı: ${invoice.invoice_number || invoice.ettn}`}
      subtitle="Fatura mali özeti, kalemler ve EDM Bilişim entegratör canlı durumu"
      actions={
        <div className="flex gap-2">
          <Button variant="outline" asChild>
            <Link to="/faturalar">
              <ArrowLeft className="mr-1 size-4" /> Faturalara Dön
            </Link>
          </Button>
          {invoice.raw_ubl_xml && (
            <Button variant="outline" asChild>
              <a href={`/api/invoices/${invoice.id}/xml`} target="_blank" rel="noreferrer">
                <Download className="mr-1 size-4" /> UBL XML İndir
              </a>
            </Button>
          )}
          <Button disabled={refreshing} onClick={handleRefreshStatus} className="gap-1">
            <RefreshCw className={`size-4 ${refreshing ? "animate-spin" : ""}`} />
            {refreshing ? "Sorgulanıyor..." : "EDM Durumunu Güncelle"}
          </Button>
        </div>
      }
    >
      <div className="space-y-6">
        {/* Üst Fatura Kartı */}
        <Card>
          <CardHeader className="py-4 border-b">
            <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
              <div>
                <CardTitle className="text-xl font-bold flex items-center gap-2">
                  <FileText className="size-6 text-primary" /> {invoice.invoice_number}
                </CardTitle>

                <CardDescription className="text-xs font-mono mt-1">
                  ETTN (UUID): {invoice.ettn}
                </CardDescription>
              </div>
              <div className="flex items-center gap-2">
                <Badge className="text-sm px-3 py-1 font-semibold">{statusInfo.label}</Badge>
              </div>
            </div>
          </CardHeader>

          <CardContent className="grid grid-cols-2 sm:grid-cols-4 gap-4 pt-4 text-xs">
            <div>
              <span className="text-muted-foreground block">Sağlayıcı (Provider)</span>
              <span className="font-semibold text-sm">{invoice.provider || "EDM"}</span>
            </div>
            <div>
              <span className="text-muted-foreground block">EDM Referans (TRXID)</span>
              <span className="font-mono font-semibold text-sm">{invoice.provider_reference || invoice.trx_id || "Henüz Alınmadı"}</span>
            </div>
            <div>
              <span className="text-muted-foreground block">Fatura Tarihi</span>
              <span className="font-semibold text-sm">{invoice.invoice_date || invoice.created_at?.slice(0, 10)}</span>
            </div>
            <div>
              <span className="text-muted-foreground block">Para Birimi</span>
              <span className="font-semibold text-sm">{invoice.currency || "TRY"}</span>
            </div>
          </CardContent>
        </Card>

        {/* Hata Mesajı Kartı (Varsa) */}
        {(invoice.status === "FAILED" || invoice.status === "REJECTED" || invoice.error_message) && (
          <Card className="border-destructive/50 bg-destructive/10">
            <CardHeader className="py-3">
              <CardTitle className="text-sm font-semibold text-destructive flex items-center gap-2">
                <AlertCircle className="size-4" /> EDM İşlem Hatası Bildirimi
              </CardTitle>
            </CardHeader>
            <CardContent className="text-xs space-y-1 text-destructive">
              <p className="font-semibold">{invoice.error_message || invoice.edm_return_message || "EDM servisi işlemi tamamlayamadı."}</p>
              {invoice.edm_return_code && <p className="font-mono text-[11px]">Hata Kodu: {invoice.edm_return_code}</p>}
            </CardContent>
          </Card>
        )}

        {/* Satıcı ve Alıcı Detayları */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
          <Card>
            <CardHeader className="py-3 bg-muted/20">
              <CardTitle className="text-sm font-semibold">Satıcı (Düzenleyen)</CardTitle>
            </CardHeader>
            <CardContent className="pt-3 text-xs space-y-1">
              <p className="font-bold text-sm">{invoice.seller_name || "Fuat Ekiz Teknoloji A.Ş."}</p>
              <p className="text-muted-foreground">VKN/TCKN: {invoice.seller_tax_number || "3230512384"}</p>
            </CardContent>
          </Card>

          <Card>
            <CardHeader className="py-3 bg-muted/20">
              <CardTitle className="text-sm font-semibold">Alıcı (Müşteri)</CardTitle>
            </CardHeader>
            <CardContent className="pt-3 text-xs space-y-1">
              <p className="font-bold text-sm">{invoice.buyer_name}</p>
              <p className="text-muted-foreground">VKN/TCKN: {invoice.buyer_tax_number}</p>
              {invoice.customer?.tax_office && <p className="text-muted-foreground">Vergi Dairesi: {invoice.customer.tax_office}</p>}
              {invoice.customer?.address && <p className="text-muted-foreground">Adres: {invoice.customer.address}</p>}
            </CardContent>
          </Card>
        </div>

        {/* Kalemler Tablosu */}
        <Card>
          <CardHeader className="py-3">
            <CardTitle className="text-sm font-semibold">Fatura Kalemleri</CardTitle>
          </CardHeader>
          <CardContent className="p-0">
            <div className="divide-y text-xs">
              <div className="grid grid-cols-12 gap-2 p-3 font-semibold bg-muted/30">
                <div className="col-span-1">#</div>
                <div className="col-span-5">Ürün / Hizmet Adı</div>
                <div className="col-span-2 text-right">Miktar</div>
                <div className="col-span-2 text-right">Birim Fiyat</div>
                <div className="col-span-2 text-right">Toplam</div>
              </div>
              {Array.isArray(invoice.items) && invoice.items.length > 0 ? (
                invoice.items.map((item: any, idx: number) => {
                  const q = item.quantity || 1;
                  const p = item.unitPrice || item.price || 0;
                  const ext = q * p;
                  return (
                    <div key={idx} className="grid grid-cols-12 gap-2 p-3 items-center">
                      <div className="col-span-1 font-mono text-muted-foreground">{idx + 1}</div>
                      <div className="col-span-5 font-medium">{item.name}</div>
                      <div className="col-span-2 text-right font-mono">{q}</div>
                      <div className="col-span-2 text-right font-mono">{p.toFixed(2)} TL</div>
                      <div className="col-span-2 text-right font-mono font-semibold">{ext.toFixed(2)} TL</div>
                    </div>
                  );
                })
              ) : (
                <div className="p-4 text-center text-muted-foreground">Satır bilgisi bulunamadı.</div>
              )}
            </div>
          </CardContent>
        </Card>

        {/* Finansal Özet */}
        <div className="flex justify-end">
          <Card className="w-full sm:w-80 bg-muted/20">
            <CardContent className="p-4 space-y-2 text-xs">
              <div className="flex justify-between py-1 border-b">
                <span className="text-muted-foreground">Ara Toplam:</span>
                <span className="font-mono font-semibold">{Number(invoice.subtotal || invoice.taxable_amount || 0).toFixed(2)} TL</span>
              </div>
              <div className="flex justify-between py-1 border-b">
                <span className="text-muted-foreground">Toplam KDV:</span>
                <span className="font-mono text-primary font-semibold">{Number(invoice.total_vat || 0).toFixed(2)} TL</span>
              </div>
              <div className="flex justify-between py-2 text-sm font-bold">
                <span>Genel Toplam:</span>
                <span className="font-mono text-base text-emerald-600 dark:text-emerald-400">
                  {Number(invoice.grand_total || 0).toFixed(2)} TL
                </span>
              </div>
            </CardContent>
          </Card>
        </div>
      </div>
    </AppShell>
  );
}
