import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";

import { AppShell } from "@/components/AppShell";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { supabase } from "@/integrations/supabase/client";
import { formatDate, formatMoney, INVOICE_STATUSES } from "@/lib/invoice";

export const Route = createFileRoute("/_authenticated/dashboard")({
  head: () => ({
    meta: [
      { title: "Kontrol Paneli | e-Fatura Portalı" },
      {
        name: "description",
        content: "Kesilen fatura sayısı, toplam tutar ve KDV özetinizi görüntüleyin.",
      },
      { property: "og:title", content: "Kontrol Paneli | e-Fatura Portalı" },
      { property: "og:description", content: "Fatura özetiniz ve son kesilen faturalar." },
    ],
  }),
  component: Dashboard,
});

function Dashboard() {
  const { data: invoices = [], isLoading } = useQuery({
    queryKey: ["invoices"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("invoices")
        .select("*")
        .order("created_at", { ascending: false });
      if (error) throw error;
      return data;
    },
  });

  const active = invoices.filter((i) => i.status !== "IPTAL");
  const totalAmount = active.reduce((s, i) => s + Number(i.grand_total), 0);
  const totalVat = active.reduce((s, i) => s + Number(i.total_vat), 0);
  const draftCount = invoices.filter((i) => i.status === "TASLAK").length;

  const metrics = [
    { label: "Toplam Fatura", value: String(invoices.length) },
    { label: "Toplam Tutar", value: formatMoney(totalAmount) },
    { label: "Toplam KDV", value: formatMoney(totalVat) },
    { label: "Taslak Fatura", value: String(draftCount) },
  ];

  return (
    <AppShell
      title="Kontrol Paneli"
      subtitle="GİB E-Fatura ve E-Arşiv işlemleri yönetimi"
      actions={
        <Button asChild>
          <Link to="/fatura-kes">Yeni Fatura Kes</Link>
        </Button>
      }
    >
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {metrics.map((m) => (
          <Card key={m.label}>
            <CardHeader className="pb-2">
              <CardTitle className="text-sm font-medium text-muted-foreground">{m.label}</CardTitle>
            </CardHeader>
            <CardContent>
              <p className="text-2xl font-bold tracking-tight">{m.value}</p>
            </CardContent>
          </Card>
        ))}
      </div>

      <Card className="mt-6">
        <CardHeader>
          <CardTitle className="text-base">Son Kesilen Faturalar</CardTitle>
        </CardHeader>
        <CardContent>
          {isLoading ? (
            <p className="text-sm text-muted-foreground">Yükleniyor…</p>
          ) : invoices.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              Henüz fatura yok.{" "}
              <Link to="/fatura-kes" className="font-medium text-primary underline">
                İlk faturanızı kesin.
              </Link>
            </p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground">
                    <th className="py-2 pr-4">Fatura No</th>
                    <th className="py-2 pr-4">Alıcı</th>
                    <th className="py-2 pr-4">Tarih</th>
                    <th className="py-2 pr-4">Tutar</th>
                    <th className="py-2">Durum</th>
                  </tr>
                </thead>
                <tbody>
                  {invoices.slice(0, 5).map((inv) => {
                    const customer = inv.customer as { title?: string } | null;
                    const status = INVOICE_STATUSES[inv.status] ?? {
                      label: inv.status,
                      tone: "draft",
                    };
                    return (
                      <tr key={inv.id} className="border-b border-border/60 last:border-0">
                        <td className="py-3 pr-4 font-medium">{inv.invoice_number}</td>
                        <td className="py-3 pr-4">{customer?.title ?? "-"}</td>
                        <td className="py-3 pr-4">{formatDate(inv.invoice_date)}</td>
                        <td className="py-3 pr-4">
                          {formatMoney(Number(inv.grand_total), inv.currency)}
                        </td>
                        <td className="py-3">
                          <Badge
                            variant={
                              status.tone === "cancel"
                                ? "destructive"
                                : status.tone === "sent"
                                  ? "default"
                                  : "secondary"
                            }
                          >
                            {status.label}
                          </Badge>
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
