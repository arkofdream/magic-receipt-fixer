import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import { FileDown } from "lucide-react";
import { toast } from "sonner";

import { AppShell } from "@/components/AppShell";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { supabase } from "@/integrations/supabase/client";
import { formatMoney, itemTotals, type InvoiceItem } from "@/lib/invoice";
import { downloadZReportPdf, type SellerInfo, type ZReportData } from "@/lib/pdf/invoice-pdf";

export const Route = createFileRoute("/_authenticated/z-raporu")({
  head: () => ({
    meta: [
      { title: "Günlük Z Raporu | e-Fatura Portalı" },
      {
        name: "description",
        content: "Seçilen güne ait fatura adedi, KDV kırılımı ve toplam ciroyu görün, Z raporunu PDF olarak indirin.",
      },
      { property: "og:title", content: "Günlük Z Raporu | e-Fatura Portalı" },
      { property: "og:description", content: "Günlük ciro ve KDV özeti." },
    ],
  }),
  component: ZReportPage,
});

function ZReportPage() {
  const today = new Date().toISOString().slice(0, 10);
  const [date, setDate] = useState(today);
  const [posTotal, setPosTotal] = useState("");

  const { data: invoices = [], isLoading } = useQuery({
    queryKey: ["invoices", "z-report", date],
    queryFn: async () => {
      const { data, error } = await supabase.from("invoices").select("*").eq("invoice_date", date);
      if (error) throw error;
      return data;
    },
  });

  const { data: profile } = useQuery({
    queryKey: ["profile"],
    queryFn: async () => {
      const { data, error } = await supabase.from("profiles").select("*").maybeSingle();
      if (error) throw error;
      return data;
    },
  });

  const report: ZReportData = useMemo(() => {
    const active = invoices.filter((inv) => inv.status !== "IPTAL");
    const breakdown = new Map<number, { taxable: number; vat: number }>();
    for (const inv of active) {
      const items = (inv.items as unknown as InvoiceItem[]) ?? [];
      for (const item of items) {
        const t = itemTotals(item);
        const current = breakdown.get(item.vatRate) ?? { taxable: 0, vat: 0 };
        breakdown.set(item.vatRate, { taxable: current.taxable + t.taxable, vat: current.vat + t.vat });
      }
    }
    const sum = (key: keyof (typeof active)[number]) =>
      active.reduce((acc, inv) => acc + Number(inv[key] ?? 0), 0);

    return {
      date,
      invoiceCount: active.length,
      cancelledCount: invoices.length - active.length,
      subtotal: sum("subtotal"),
      discount: sum("total_discount"),
      taxable: sum("taxable_amount"),
      vat: sum("total_vat"),
      tevkifat: sum("total_tevkifat"),
      grandTotal: sum("grand_total"),
      vatBreakdown: [...breakdown.entries()]
        .sort((a, b) => a[0] - b[0])
        .map(([rate, v]) => ({ rate, taxable: v.taxable, vat: v.vat })),
      ...(posTotal ? { posTotal: Number(posTotal) || 0 } : {}),
    };
  }, [invoices, date, posTotal]);

  const seller: SellerInfo = {
    companyTitle: profile?.company_title ?? "",
    vknTckn: profile?.vkn_tckn ?? "",
    taxOffice: profile?.tax_office ?? "",
    address: profile?.address ?? "",
    phone: profile?.phone ?? "",
    email: profile?.email ?? "",
  };

  const summary: [string, string][] = [
    ["Fatura Adedi", String(report.invoiceCount)],
    ["İptal Edilen", String(report.cancelledCount)],
    ["Ara Toplam", formatMoney(report.subtotal)],
    ["İskonto", formatMoney(report.discount)],
    ["KDV Matrahı", formatMoney(report.taxable)],
    ["Toplam KDV", formatMoney(report.vat)],
    ["Tevkifat", formatMoney(report.tevkifat)],
    ["Günlük Toplam", formatMoney(report.grandTotal)],
  ];

  return (
    <AppShell
      title="Günlük Z Raporu"
      subtitle="Seçilen güne ait ciro, KDV ve fatura özeti"
      actions={
        <Button
          className="gap-2"
          disabled={isLoading}
          onClick={async () => {
            try {
              await downloadZReportPdf(report, seller);
              toast.success("Z raporu indirildi.");
            } catch (error) {
              toast.error(error instanceof Error ? error.message : "Rapor oluşturulamadı.");
            }
          }}
        >
          <FileDown className="size-4" />
          Z Raporunu İndir (PDF)
        </Button>
      }
    >
      <div className="grid gap-6 lg:grid-cols-[320px_1fr]">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Rapor Ayarları</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="z-date">Rapor Tarihi</Label>
              <Input id="z-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
            </div>
            <div className="space-y-2">
              <Label htmlFor="z-pos">POS / Yazarkasa Tahsilatı (opsiyonel)</Label>
              <Input
                id="z-pos"
                type="number"
                step="0.01"
                placeholder="0,00"
                value={posTotal}
                onChange={(e) => setPosTotal(e.target.value)}
              />
              <p className="text-xs text-muted-foreground">
                Yazarkasa/POS toplamını elle girerek rapora ekleyebilirsiniz.
              </p>
            </div>
          </CardContent>
        </Card>

        <div className="space-y-6">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Günlük Özet</CardTitle>
            </CardHeader>
            <CardContent>
              {isLoading ? (
                <p className="text-sm text-muted-foreground">Yükleniyor…</p>
              ) : (
                <dl className="grid gap-3 sm:grid-cols-2">
                  {summary.map(([label, value]) => (
                    <div key={label} className="rounded-md border border-border px-4 py-3">
                      <dt className="text-xs uppercase text-muted-foreground">{label}</dt>
                      <dd className="mt-1 text-lg font-semibold">{value}</dd>
                    </div>
                  ))}
                </dl>
              )}
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">KDV Kırılımı</CardTitle>
            </CardHeader>
            <CardContent>
              {report.vatBreakdown.length === 0 ? (
                <p className="text-sm text-muted-foreground">Bu tarihte fatura bulunmuyor.</p>
              ) : (
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground">
                      <th className="py-2 pr-4">KDV Oranı</th>
                      <th className="py-2 pr-4">Matrah</th>
                      <th className="py-2">KDV</th>
                    </tr>
                  </thead>
                  <tbody>
                    {report.vatBreakdown.map((row) => (
                      <tr key={row.rate} className="border-b border-border/60 last:border-0">
                        <td className="py-3 pr-4 font-medium">%{row.rate}</td>
                        <td className="py-3 pr-4">{formatMoney(row.taxable)}</td>
                        <td className="py-3">{formatMoney(row.vat)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </CardContent>
          </Card>
        </div>
      </div>
    </AppShell>
  );
}
