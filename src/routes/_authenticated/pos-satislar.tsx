import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import { Download } from "lucide-react";
import { toast } from "sonner";

import { AppShell } from "@/components/AppShell";
import { ExcelImportDialog } from "@/components/ExcelImportDialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { supabase } from "@/integrations/supabase/client";
import { downloadWorkbook, parseNumber, pickColumn, type SheetRow } from "@/lib/excel";
import { formatMoney } from "@/lib/invoice";

export const Route = createFileRoute("/_authenticated/pos-satislar")({
  head: () => ({
    meta: [
      { title: "POS Satışları | e-Fatura Portalı" },
      {
        name: "description",
        content: "Vergi dairesine bildirilecek POS ve kasa satışlarını tarih aralığına göre görüntüleyin, elle veya Excel ile ekleyin.",
      },
      { property: "og:title", content: "POS Satışları | e-Fatura Portalı" },
      { property: "og:description", content: "POS ve kasa satışlarınızın KDV kırılımlı dökümü." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: PosSalesPage,
});

const PAYMENT_TYPES = [
  { value: "NAKIT", label: "Nakit" },
  { value: "KREDI_KARTI", label: "Kredi Kartı" },
  { value: "DIGER", label: "Diğer" },
] as const;

const IMPORT_COLUMNS = [
  { header: "Tarih", example: "2026-08-10" },
  { header: "Açıklama", aliases: ["aciklama"], example: "Perakende satış" },
  { header: "Belge No", aliases: ["fisno", "belgeno"], example: "Z-0001" },
  { header: "Ödeme Tipi", aliases: ["odemetipi", "odeme"], example: "Kredi Kartı" },
  { header: "KDV Oranı", aliases: ["kdvorani", "kdv"], example: "20" },
  { header: "Tutar (KDV Dahil)", aliases: ["tutar", "brut", "toplam"], example: "1200,00" },
];

type PosForm = {
  sale_date: string;
  description: string;
  document_no: string;
  payment_type: string;
  vat_rate: string;
  gross_amount: string;
};

type PosRow = {
  sale_date: string;
  description: string;
  document_no: string;
  payment_type: string;
  vat_rate: number;
  gross_amount: number;
};

function todayIso() {
  return new Date().toISOString().slice(0, 10);
}

const emptyForm: PosForm = {
  sale_date: todayIso(),
  description: "",
  document_no: "",
  payment_type: "NAKIT",
  vat_rate: "20",
  gross_amount: "",
};

/** KDV dahil tutardan net ve KDV tutarını hesaplar. */
function splitVat(gross: number, vatRate: number) {
  const net = gross / (1 + vatRate / 100);
  return { net_amount: Number(net.toFixed(2)), vat_amount: Number((gross - net).toFixed(2)) };
}

function normalizePaymentType(raw: string) {
  const v = raw.toLocaleLowerCase("tr-TR");
  if (v.includes("kart")) return "KREDI_KARTI";
  if (v.includes("nakit")) return "NAKIT";
  return v ? "DIGER" : "NAKIT";
}

function PosSalesPage() {
  const queryClient = useQueryClient();
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState<PosForm>(emptyForm);
  const [start, setStart] = useState(() => todayIso().slice(0, 8) + "01");
  const [end, setEnd] = useState(todayIso());

  const { data: sales = [], isLoading } = useQuery({
    queryKey: ["pos-sales", start, end],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("pos_sales")
        .select("*")
        .gte("sale_date", start)
        .lte("sale_date", end)
        .order("sale_date", { ascending: false });
      if (error) throw error;
      return data;
    },
  });

  async function currentUserId() {
    const { data: userData } = await supabase.auth.getUser();
    const userId = userData.user?.id;
    if (!userId) throw new Error("Oturum bulunamadı.");
    return userId;
  }

  function toRow(userId: string, row: PosRow) {
    const { net_amount, vat_amount } = splitVat(row.gross_amount, row.vat_rate);
    return { user_id: userId, ...row, net_amount, vat_amount };
  }

  const createSale = useMutation({
    mutationFn: async (values: PosForm) => {
      const userId = await currentUserId();
      const { error } = await supabase.from("pos_sales").insert(
        toRow(userId, {
          sale_date: values.sale_date,
          description: values.description,
          document_no: values.document_no,
          payment_type: values.payment_type,
          vat_rate: Number(values.vat_rate) || 0,
          gross_amount: parseNumber(values.gross_amount),
        }),
      );
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("POS satışı kaydedildi.");
      setForm({ ...emptyForm, sale_date: form.sale_date });
      setOpen(false);
      queryClient.invalidateQueries({ queryKey: ["pos-sales"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const removeSale = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from("pos_sales").delete().eq("id", id);
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Kayıt silindi.");
      queryClient.invalidateQueries({ queryKey: ["pos-sales"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  async function importSales(rows: PosRow[]) {
    const userId = await currentUserId();
    const { error } = await supabase.from("pos_sales").insert(rows.map((r) => toRow(userId, r)));
    if (error) throw error;
    toast.success(`${rows.length} POS satışı içe aktarıldı.`);
    queryClient.invalidateQueries({ queryKey: ["pos-sales"] });
  }

  function exportSales() {
    downloadWorkbook(
      ["Tarih", "Açıklama", "Belge No", "Ödeme Tipi", "KDV Oranı", "Matrah", "KDV", "Tutar (KDV Dahil)"],
      sales.map((s) => [
        s.sale_date,
        s.description,
        s.document_no,
        PAYMENT_TYPES.find((p) => p.value === s.payment_type)?.label ?? s.payment_type,
        Number(s.vat_rate),
        Number(s.net_amount),
        Number(s.vat_amount),
        Number(s.gross_amount),
      ]),
      `pos-satislari-${start}_${end}.xlsx`,
      "POS Satışları",
    );
  }

  const summary = useMemo(() => {
    const byVat = new Map<number, { net: number; vat: number; gross: number }>();
    const byPayment = new Map<string, number>();
    let net = 0;
    let vat = 0;
    let gross = 0;
    for (const s of sales) {
      const rate = Number(s.vat_rate);
      const entry = byVat.get(rate) ?? { net: 0, vat: 0, gross: 0 };
      entry.net += Number(s.net_amount);
      entry.vat += Number(s.vat_amount);
      entry.gross += Number(s.gross_amount);
      byVat.set(rate, entry);
      byPayment.set(s.payment_type, (byPayment.get(s.payment_type) ?? 0) + Number(s.gross_amount));
      net += Number(s.net_amount);
      vat += Number(s.vat_amount);
      gross += Number(s.gross_amount);
    }
    return {
      net,
      vat,
      gross,
      byVat: [...byVat.entries()].sort((a, b) => a[0] - b[0]),
      byPayment: [...byPayment.entries()],
    };
  }, [sales]);

  return (
    <AppShell
      title="POS / Vergi Dairesi Satış Görünümü"
      subtitle="Faturasız kasa ve POS satışlarınızın KDV kırılımlı dökümü"
      actions={
        <>
          <Button variant="ghost" className="gap-2" onClick={exportSales} disabled={sales.length === 0}>
            <Download className="size-4" />
            Excel'e Aktar
          </Button>
          <ExcelImportDialog<PosRow>
            title="Excel'den POS Satışı İçe Aktar"
            templateName="pos-satis-sablonu.xlsx"
            columns={IMPORT_COLUMNS}
            mapRow={(row: SheetRow) => {
              const gross = parseNumber(pickColumn(row, ["Tutar (KDV Dahil)", "Tutar", "Toplam", "Brüt"]));
              if (!gross) return null;
              const rawDate = pickColumn(row, ["Tarih"]);
              const parsedDate = rawDate.includes(".")
                ? rawDate.split(".").reverse().join("-")
                : rawDate || todayIso();
              return {
                sale_date: parsedDate.slice(0, 10),
                description: pickColumn(row, ["Açıklama", "Aciklama"]),
                document_no: pickColumn(row, ["Belge No", "Fiş No", "Fis No"]),
                payment_type: normalizePaymentType(pickColumn(row, ["Ödeme Tipi", "Ödeme", "Odeme"])),
                vat_rate: parseNumber(pickColumn(row, ["KDV Oranı", "KDV"])) || 20,
                gross_amount: gross,
              };
            }}
            onImport={importSales}
          />
          <Dialog open={open} onOpenChange={setOpen}>
            <DialogTrigger asChild>
              <Button>Yeni Satış</Button>
            </DialogTrigger>
            <DialogContent className="max-h-[85vh] overflow-y-auto">
              <DialogHeader>
                <DialogTitle>Yeni POS / Kasa Satışı</DialogTitle>
              </DialogHeader>
              <form
                className="grid gap-4 sm:grid-cols-2"
                onSubmit={(e) => {
                  e.preventDefault();
                  createSale.mutate(form);
                }}
              >
                <div className="space-y-2">
                  <Label htmlFor="sale_date">Tarih</Label>
                  <Input
                    id="sale_date"
                    type="date"
                    required
                    value={form.sale_date}
                    onChange={(e) => setForm({ ...form, sale_date: e.target.value })}
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="document_no">Belge / Fiş No</Label>
                  <Input
                    id="document_no"
                    value={form.document_no}
                    onChange={(e) => setForm({ ...form, document_no: e.target.value })}
                  />
                </div>
                <div className="space-y-2 sm:col-span-2">
                  <Label htmlFor="description">Açıklama</Label>
                  <Input
                    id="description"
                    value={form.description}
                    onChange={(e) => setForm({ ...form, description: e.target.value })}
                  />
                </div>
                <div className="space-y-2">
                  <Label>Ödeme Tipi</Label>
                  <Select value={form.payment_type} onValueChange={(v) => setForm({ ...form, payment_type: v })}>
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {PAYMENT_TYPES.map((p) => (
                        <SelectItem key={p.value} value={p.value}>
                          {p.label}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
                <div className="space-y-2">
                  <Label htmlFor="vat_rate">KDV Oranı (%)</Label>
                  <Input
                    id="vat_rate"
                    type="number"
                    min="0"
                    step="1"
                    value={form.vat_rate}
                    onChange={(e) => setForm({ ...form, vat_rate: e.target.value })}
                  />
                </div>
                <div className="space-y-2 sm:col-span-2">
                  <Label htmlFor="gross_amount">Tutar (KDV Dahil)</Label>
                  <Input
                    id="gross_amount"
                    required
                    value={form.gross_amount}
                    onChange={(e) => setForm({ ...form, gross_amount: e.target.value })}
                  />
                  <p className="text-xs text-muted-foreground">
                    Matrah ve KDV tutarı otomatik hesaplanır.
                  </p>
                </div>
                <div className="sm:col-span-2">
                  <Button type="submit" className="w-full" disabled={createSale.isPending}>
                    Kaydet
                  </Button>
                </div>
              </form>
            </DialogContent>
          </Dialog>
        </>
      }
    >
      <div className="space-y-6">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Tarih Aralığı</CardTitle>
          </CardHeader>
          <CardContent className="grid gap-4 sm:grid-cols-2">
            <div className="space-y-2">
              <Label htmlFor="start">Başlangıç</Label>
              <Input id="start" type="date" value={start} onChange={(e) => setStart(e.target.value)} />
            </div>
            <div className="space-y-2">
              <Label htmlFor="end">Bitiş</Label>
              <Input id="end" type="date" value={end} onChange={(e) => setEnd(e.target.value)} />
            </div>
          </CardContent>
        </Card>

        <div className="grid gap-4 sm:grid-cols-3">
          <SummaryCard label="Toplam Matrah" value={formatMoney(summary.net)} />
          <SummaryCard label="Toplam KDV" value={formatMoney(summary.vat)} />
          <SummaryCard label="Genel Toplam" value={formatMoney(summary.gross)} />
        </div>

        <div className="grid gap-6 lg:grid-cols-2">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">KDV Kırılımı</CardTitle>
            </CardHeader>
            <CardContent>
              {summary.byVat.length === 0 ? (
                <p className="text-sm text-muted-foreground">Kayıt yok.</p>
              ) : (
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground">
                      <th className="py-2 pr-4">Oran</th>
                      <th className="py-2 pr-4">Matrah</th>
                      <th className="py-2 pr-4">KDV</th>
                      <th className="py-2">Toplam</th>
                    </tr>
                  </thead>
                  <tbody>
                    {summary.byVat.map(([rate, v]) => (
                      <tr key={rate} className="border-b border-border/60 last:border-0">
                        <td className="py-2 pr-4">%{rate}</td>
                        <td className="py-2 pr-4">{formatMoney(v.net)}</td>
                        <td className="py-2 pr-4">{formatMoney(v.vat)}</td>
                        <td className="py-2">{formatMoney(v.gross)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">Ödeme Tipine Göre</CardTitle>
            </CardHeader>
            <CardContent>
              {summary.byPayment.length === 0 ? (
                <p className="text-sm text-muted-foreground">Kayıt yok.</p>
              ) : (
                <ul className="space-y-2 text-sm">
                  {summary.byPayment.map(([type, total]) => (
                    <li key={type} className="flex items-center justify-between">
                      <span>{PAYMENT_TYPES.find((p) => p.value === type)?.label ?? type}</span>
                      <span className="font-medium">{formatMoney(total)}</span>
                    </li>
                  ))}
                </ul>
              )}
            </CardContent>
          </Card>
        </div>

        <Card>
          <CardHeader>
            <CardTitle className="text-base">Satış Kayıtları ({sales.length})</CardTitle>
          </CardHeader>
          <CardContent>
            {isLoading ? (
              <p className="text-sm text-muted-foreground">Yükleniyor…</p>
            ) : sales.length === 0 ? (
              <p className="text-sm text-muted-foreground">Seçilen aralıkta POS satışı yok.</p>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground">
                      <th className="py-2 pr-4">Tarih</th>
                      <th className="py-2 pr-4">Açıklama</th>
                      <th className="py-2 pr-4">Belge No</th>
                      <th className="py-2 pr-4">Ödeme</th>
                      <th className="py-2 pr-4">KDV</th>
                      <th className="py-2 pr-4">Matrah</th>
                      <th className="py-2 pr-4">Toplam</th>
                      <th className="py-2" />
                    </tr>
                  </thead>
                  <tbody>
                    {sales.map((s) => (
                      <tr key={s.id} className="border-b border-border/60 last:border-0">
                        <td className="py-3 pr-4">{s.sale_date}</td>
                        <td className="py-3 pr-4">{s.description || "-"}</td>
                        <td className="py-3 pr-4">{s.document_no || "-"}</td>
                        <td className="py-3 pr-4">
                          {PAYMENT_TYPES.find((p) => p.value === s.payment_type)?.label ?? s.payment_type}
                        </td>
                        <td className="py-3 pr-4">%{Number(s.vat_rate)}</td>
                        <td className="py-3 pr-4">{formatMoney(Number(s.net_amount))}</td>
                        <td className="py-3 pr-4 font-medium">{formatMoney(Number(s.gross_amount))}</td>
                        <td className="py-3 text-right">
                          <Button variant="ghost" size="sm" onClick={() => removeSale.mutate(s.id)}>
                            Sil
                          </Button>
                        </td>
                      </tr>
                    ))}
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

function SummaryCard({ label, value }: { label: string; value: string }) {
  return (
    <Card>
      <CardContent className="p-5">
        <p className="text-xs uppercase text-muted-foreground">{label}</p>
        <p className="mt-1 text-xl font-semibold">{value}</p>
      </CardContent>
    </Card>
  );
}
