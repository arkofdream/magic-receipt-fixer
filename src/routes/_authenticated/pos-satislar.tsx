import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import { Download, CreditCard, Search, Calculator, FilePlus2, Filter, Percent, Calendar } from "lucide-react";
import { toast } from "sonner";

import { AppShell } from "@/components/AppShell";
import { ExcelImportDialog } from "@/components/ExcelImportDialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { supabase } from "@/integrations/supabase/client";
import { downloadWorkbook, parseNumber, pickColumn, type SheetRow } from "@/lib/excel";
import {
  formatDate,
  formatMoney,
  generateEttn,
  generateInvoiceNumber,
  invoiceTotals,
  newItem,
} from "@/lib/invoice";

export const Route = createFileRoute("/_authenticated/pos-satislar")({
  head: () => ({
    meta: [
      { title: "POS Satışları & Komisyon Sorgulama | e-Fatura Portalı" },
      {
        name: "description",
        content:
          "POS ve kasa satışlarını sorgulayın, banka komisyon ve valör kesintilerini hesaplayın, tek tıkla hızlı fatura kesin.",
      },
      { property: "og:title", content: "POS Satışları & Komisyon Sorgulama | e-Fatura Portalı" },
      { property: "og:description", content: "POS komisyon hesabı ve hızlı fatura kesme." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: PosSalesPage,
});

const POS_BANKS = [
  "Garanti BBVA POS",
  "Akbank POS",
  "Türkiye İş Bankası POS",
  "Yapı Kredi POS",
  "Kuveyt Türk POS",
  "Ziraat Bankası POS",
  "QNB Finansbank POS",
  "Halkbank POS",
  "Vakıfbank POS",
  "Diğer / Fiziki Kasa",
] as const;

const PAYMENT_TYPES = [
  { value: "KREDI_KARTI", label: "Kredi Kartı (Tek Çekim)" },
  { value: "TAKSITLI_KART", label: "Kredi Kartı (Taksitli)" },
  { value: "NAKIT", label: "Nakit Kasa" },
  { value: "DIGER", label: "Diğer Ödeme" },
] as const;

const IMPORT_COLUMNS = [
  { header: "Tarih", example: "2026-08-10" },
  { header: "Açıklama", aliases: ["aciklama"], example: "Perakende satış" },
  { header: "Belge No", aliases: ["fisno", "belgeno"], example: "Z-0001" },
  { header: "Banka / Cihaz", example: "Garanti BBVA POS" },
  { header: "Ödeme Tipi", aliases: ["odemetipi", "odeme"], example: "Kredi Kartı" },
  { header: "KDV Oranı", aliases: ["kdvorani", "kdv"], example: "20" },
  { header: "Tutar (KDV Dahil)", aliases: ["tutar", "brut", "toplam"], example: "1200,00" },
  { header: "Komisyon %", example: "1.99" },
];

type PosForm = {
  sale_date: string;
  description: string;
  document_no: string;
  bank_name: string;
  payment_type: string;
  vat_rate: string;
  gross_amount: string;
  commission_rate: string;
  blockage_days: string;
};

type PosRow = {
  id?: string;
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
  bank_name: "Garanti BBVA POS",
  payment_type: "KREDI_KARTI",
  vat_rate: "20",
  gross_amount: "",
  commission_rate: "1.89",
  blockage_days: "1",
};

/** KDV dahil tutardan net ve KDV tutarını hesaplar. */
function splitVat(gross: number, vatRate: number) {
  const net = gross / (1 + vatRate / 100);
  return { net_amount: Number(net.toFixed(2)), vat_amount: Number((gross - net).toFixed(2)) };
}

function normalizePaymentType(raw: string) {
  const v = raw.toLocaleLowerCase("tr-TR");
  if (v.includes("taksit")) return "TAKSITLI_KART";
  if (v.includes("kart")) return "KREDI_KARTI";
  if (v.includes("nakit")) return "NAKIT";
  return v ? "DIGER" : "NAKIT";
}

function PosSalesPage() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [open, setOpen] = useState(false);
  const [quickInvoiceOpen, setQuickInvoiceOpen] = useState(false);
  const [selectedSaleForInvoice, setSelectedSaleForInvoice] = useState<PosRow | null>(null);
  const [quickCustomer, setQuickCustomer] = useState({
    title: "",
    vknTckn: "11111111111",
    email: "",
    address: "",
  });

  const [form, setForm] = useState<PosForm>(emptyForm);

  // Filtreler & POS Sorgulama
  const [searchDocNo, setSearchDocNo] = useState("");
  const [filterPaymentType, setFilterPaymentType] = useState("ALL");
  const [start, setStart] = useState(() => todayIso().slice(0, 8) + "01");
  const [end, setEnd] = useState(todayIso());
  const [globalCommissionRate, setGlobalCommissionRate] = useState<number>(1.89);
  const [globalValorDays, setGlobalValorDays] = useState<number>(1);

  const { data: sales = [], isLoading } = useQuery({
    queryKey: ["pos-sales", start, end],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("pos_sales")
        .select("*")
        .is("deleted_at", null)
        .gte("sale_date", start)
        .lte("sale_date", end)
        .order("sale_date", { ascending: false });
      if (error) throw error;
      return data ?? [];
    },
  });

  const { data: invoiceCount = 0 } = useQuery({
    queryKey: ["invoice-count"],
    queryFn: async () => {
      const { count, error } = await supabase
        .from("invoices")
        .select("id", { count: "exact", head: true })
        .is("deleted_at", null);
      if (error) throw error;
      return count ?? 0;
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
          description: values.description ? `${values.bank_name} - ${values.description}` : values.bank_name,
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
      const userId = await currentUserId();
      const { error } = await supabase
        .from("pos_sales")
        .update({
          deleted_at: new Date().toISOString(),
          deleted_by: userId,
        })
        .eq("id", id);
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Kayıt silindi (Çöp Kutusuna taşındı).");
      queryClient.invalidateQueries({ queryKey: ["pos-sales"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  // Hızlı Fatura Kesme Mutation
  const createQuickInvoice = useMutation({
    mutationFn: async () => {
      if (!selectedSaleForInvoice) throw new Error("Satış kaydı seçilmedi.");
      if (!quickCustomer.title.trim()) throw new Error("Müşteri / Alıcı Unvanı giriniz.");

      const userId = await currentUserId();
      const invoiceNumber = generateInvoiceNumber(invoiceCount, "EAR");
      const gross = Number(selectedSaleForInvoice.gross_amount) || 0;
      const vatRate = Number(selectedSaleForInvoice.vat_rate) || 20;
      const { net_amount, vat_amount } = splitVat(gross, vatRate);

      const items = [
        {
          ...newItem(),
          name: selectedSaleForInvoice.description || "Perakende POS Satışı",
          unit: "Adet",
          quantity: 1,
          unitPrice: net_amount,
          vatRate: vatRate,
        },
      ];
      const totals = invoiceTotals(items, 0);

      const { error } = await supabase.from("invoices").insert({
        user_id: userId,
        invoice_number: invoiceNumber,
        type: "E_ARSIV",
        status: "ONAYLANDI",
        ettn: generateEttn(),
        invoice_date: selectedSaleForInvoice.sale_date,
        currency: "TRY",
        exchange_rate: 1,
        posted: true,
        customer: {
          vknTckn: quickCustomer.vknTckn || "11111111111",
          title: quickCustomer.title,
          taxOffice: "",
          address: quickCustomer.address || "Nihai Tüketici",
          city: "İstanbul",
          district: "",
          neighborhood: "",
          email: quickCustomer.email || "",
          phone: "",
        },
        items,
        subtotal: totals.subtotal,
        total_discount: 0,
        taxable_amount: totals.taxableAmount,
        total_vat: totals.totalVat,
        total_tevkifat: 0,
        grand_total: totals.grandTotal,
        notes: `POS Fiş No: ${selectedSaleForInvoice.document_no || "-"} kaynaklı hızlı fatura`,
        payment_info: `Ödeme Türü: ${selectedSaleForInvoice.payment_type}`,
      });

      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("POS satışı için e-Arşiv faturası anında oluşturuldu!");
      setQuickInvoiceOpen(false);
      setSelectedSaleForInvoice(null);
      queryClient.invalidateQueries({ queryKey: ["invoices"] });
      queryClient.invalidateQueries({ queryKey: ["invoice-count"] });
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

  // POS Sorgulama & Filtreleme
  const filteredSales = useMemo(() => {
    return sales.filter((s) => {
      if (filterPaymentType !== "ALL" && s.payment_type !== filterPaymentType) return false;
      if (searchDocNo) {
        const q = searchDocNo.toLowerCase();
        const docMatch = (s.document_no ?? "").toLowerCase().includes(q);
        const descMatch = (s.description ?? "").toLowerCase().includes(q);
        if (!docMatch && !descMatch) return false;
      }
      return true;
    });
  }, [sales, filterPaymentType, searchDocNo]);

  // KOMİSYON & VALÖR HESAPLAMALARI
  const summary = useMemo(() => {
    let net = 0;
    let vat = 0;
    let gross = 0;
    let cardGross = 0;
    let cashGross = 0;

    for (const s of filteredSales) {
      const g = Number(s.gross_amount) || 0;
      const n = Number(s.net_amount) || 0;
      const v = Number(s.vat_amount) || 0;

      net += n;
      vat += v;
      gross += g;

      if (s.payment_type === "KREDI_KARTI" || s.payment_type === "TAKSITLI_KART") {
        cardGross += g;
      } else {
        cashGross += g;
      }
    }

    // Komisyon hesabı
    const totalCommissionCut = (cardGross * globalCommissionRate) / 100;
    const netBankSettlement = cardGross - totalCommissionCut;

    return {
      net,
      vat,
      gross,
      cardGross,
      cashGross,
      totalCommissionCut,
      netBankSettlement,
    };
  }, [filteredSales, globalCommissionRate]);

  function exportSales() {
    downloadWorkbook(
      [
        "Tarih",
        "Açıklama / Cihaz",
        "Belge No",
        "Ödeme Tipi",
        "KDV Oranı",
        "Matrah",
        "KDV",
        "Tutar (KDV Dahil)",
        "Banka Komisyon Kesintisi",
        "Net Hesaba Geçecek",
      ],
      filteredSales.map((s) => {
        const isCard = s.payment_type === "KREDI_KARTI" || s.payment_type === "TAKSITLI_KART";
        const comm = isCard ? (Number(s.gross_amount) * globalCommissionRate) / 100 : 0;
        const netPass = Number(s.gross_amount) - comm;
        return [
          s.sale_date,
          s.description,
          s.document_no,
          PAYMENT_TYPES.find((p) => p.value === s.payment_type)?.label ?? s.payment_type,
          Number(s.vat_rate),
          Number(s.net_amount),
          Number(s.vat_amount),
          Number(s.gross_amount),
          Number(comm.toFixed(2)),
          Number(netPass.toFixed(2)),
        ];
      }),
      `pos-satislari-${start}_${end}.xlsx`,
      "POS Satışları",
    );
  }

  return (
    <AppShell
      title="POS Satışları & Komisyon Sorgulama"
      subtitle="POS slipleri, banka komisyon/valör hesabı ve tek tıkla hızlı fatura kesme"
      actions={
        <div className="flex gap-2">
          <Button
            variant="outline"
            className="gap-2"
            onClick={exportSales}
            disabled={filteredSales.length === 0}
          >
            <Download className="size-4" /> Excel'e Aktar
          </Button>
          <ExcelImportDialog<PosRow>
            title="Excel'den POS Satışı İçe Aktar"
            templateName="pos-satis-sablonu.xlsx"
            columns={IMPORT_COLUMNS}
            mapRow={(row: SheetRow) => {
              const gross = parseNumber(
                pickColumn(row, ["Tutar (KDV Dahil)", "Tutar", "Toplam", "Brüt", "Tutar (TL)"]),
              );
              const hasAnyData = Object.values(row).some((v) => v && v.trim());
              if (!hasAnyData) return null;
              if (gross <= 0)
                return { error: "Geçerli bir satış tutarı (KDV dahil) girilmelidir." };
              const rawDate = pickColumn(row, ["Tarih"]);
              const parsedDate = rawDate.includes(".")
                ? rawDate.split(".").reverse().join("-")
                : rawDate || todayIso();
              return {
                data: {
                  sale_date: parsedDate.slice(0, 10),
                  description: pickColumn(row, ["Açıklama", "Banka / Cihaz", "Aciklama"]),
                  document_no: pickColumn(row, ["Belge No", "Fiş No", "Fis No"]),
                  payment_type: normalizePaymentType(
                    pickColumn(row, ["Ödeme Tipi", "Ödeme", "Odeme"]),
                  ),
                  vat_rate: parseNumber(pickColumn(row, ["KDV Oranı", "KDV"])) || 20,
                  gross_amount: gross,
                },
              };
            }}
            onImport={importSales}
          />
          <Dialog open={open} onOpenChange={setOpen}>
            <DialogTrigger asChild>
              <Button className="gap-1.5">
                <CreditCard className="size-4" /> Yeni POS Satışı
              </Button>
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
                  <Label htmlFor="document_no">Belge / Fiş / Slip No</Label>
                  <Input
                    id="document_no"
                    placeholder="Örn: SLIP-0941"
                    value={form.document_no}
                    onChange={(e) => setForm({ ...form, document_no: e.target.value })}
                  />
                </div>
                <div className="space-y-2 sm:col-span-2">
                  <Label>POS Cihazı / Banka</Label>
                  <Select
                    value={form.bank_name}
                    onValueChange={(v) => setForm({ ...form, bank_name: v })}
                  >
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {POS_BANKS.map((bank) => (
                        <SelectItem key={bank} value={bank}>
                          {bank}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
                <div className="space-y-2 sm:col-span-2">
                  <Label htmlFor="description">Açıklama</Label>
                  <Input
                    id="description"
                    placeholder="Ürün veya işlem açıklaması"
                    value={form.description}
                    onChange={(e) => setForm({ ...form, description: e.target.value })}
                  />
                </div>
                <div className="space-y-2">
                  <Label>Ödeme Tipi</Label>
                  <Select
                    value={form.payment_type}
                    onValueChange={(v) => setForm({ ...form, payment_type: v })}
                  >
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
                  <Select
                    value={form.vat_rate}
                    onValueChange={(v) => setForm({ ...form, vat_rate: v })}
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
                <div className="space-y-2 sm:col-span-2">
                  <Label htmlFor="gross_amount">Satış Tutarı (KDV Dahil)</Label>
                  <Input
                    id="gross_amount"
                    required
                    placeholder="0.00 ₺"
                    value={form.gross_amount}
                    onChange={(e) => setForm({ ...form, gross_amount: e.target.value })}
                  />
                </div>
                <div className="sm:col-span-2 pt-2">
                  <Button type="submit" className="w-full" disabled={createSale.isPending}>
                    Kaydet
                  </Button>
                </div>
              </form>
            </DialogContent>
          </Dialog>
        </div>
      }
    >
      <div className="space-y-6">
        {/* POS SORGULAMA & KOMİSYON HESAPLAMA PANELİ */}
        <div className="grid gap-4 md:grid-cols-3">
          <Card className="md:col-span-2">
            <CardHeader className="pb-3">
              <CardTitle className="text-base flex items-center gap-2">
                <Search className="size-4 text-primary" /> POS İşlemleri Sorgulama
              </CardTitle>
              <CardDescription>Tarih aralığı, fiş/slip no ve ödeme tipine göre arayın.</CardDescription>
            </CardHeader>
            <CardContent className="grid gap-3 sm:grid-cols-3">
              <div className="space-y-1">
                <Label className="text-xs">Başlangıç</Label>
                <Input
                  className="h-8 text-xs"
                  type="date"
                  value={start}
                  onChange={(e) => setStart(e.target.value)}
                />
              </div>
              <div className="space-y-1">
                <Label className="text-xs">Bitiş</Label>
                <Input
                  className="h-8 text-xs"
                  type="date"
                  value={end}
                  onChange={(e) => setEnd(e.target.value)}
                />
              </div>
              <div className="space-y-1">
                <Label className="text-xs">Ödeme Tipi</Label>
                <Select value={filterPaymentType} onValueChange={setFilterPaymentType}>
                  <SelectTrigger className="h-8 text-xs">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="ALL">Tümü</SelectItem>
                    {PAYMENT_TYPES.map((p) => (
                      <SelectItem key={p.value} value={p.value}>
                        {p.label}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
              <div className="space-y-1 sm:col-span-3">
                <Label className="text-xs">Slip / Fiş No veya Açıklama Ara</Label>
                <Input
                  className="h-8 text-xs"
                  placeholder="Slip no, banka veya açıklama ile filtrele..."
                  value={searchDocNo}
                  onChange={(e) => setSearchDocNo(e.target.value)}
                />
              </div>
            </CardContent>
          </Card>

          {/* POS KOMİSYON VE VALÖR HESAPLAYICI */}
          <Card className="bg-primary/5 border-primary/20">
            <CardHeader className="pb-3">
              <CardTitle className="text-base flex items-center gap-2 text-primary">
                <Percent className="size-4" /> Banka POS Komisyon Oranı
              </CardTitle>
              <CardDescription>Kartlı satışlardan kesilecek komisyon & valör</CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
              <div className="grid grid-cols-2 gap-2">
                <div className="space-y-1">
                  <Label className="text-xs font-semibold">Komisyon %</Label>
                  <Input
                    type="number"
                    step="0.01"
                    className="h-8 text-xs bg-background"
                    value={globalCommissionRate}
                    onChange={(e) => setGlobalCommissionRate(Number(e.target.value) || 0)}
                  />
                </div>
                <div className="space-y-1">
                  <Label className="text-xs font-semibold">Valör (Gün)</Label>
                  <Input
                    type="number"
                    min="0"
                    className="h-8 text-xs bg-background"
                    value={globalValorDays}
                    onChange={(e) => setGlobalValorDays(Number(e.target.value) || 0)}
                  />
                </div>
              </div>
              <div className="rounded-md bg-background/80 p-2.5 space-y-1 text-xs border border-border">
                <div className="flex justify-between text-muted-foreground">
                  <span>Hesaplanan Kesinti:</span>
                  <span className="font-semibold text-destructive">
                    - {formatMoney(summary.totalCommissionCut)}
                  </span>
                </div>
                <div className="flex justify-between font-bold text-primary pt-1 border-t border-border/50">
                  <span>Net Geçecek Tutar:</span>
                  <span>{formatMoney(summary.netBankSettlement)}</span>
                </div>
              </div>
            </CardContent>
          </Card>
        </div>

        {/* ÖZET KARTLARI */}
        <div className="grid gap-3 sm:grid-cols-4">
          <SummaryCard label="Toplam Brüt Satış" value={formatMoney(summary.gross)} />
          <SummaryCard label="Kredi Kartı Satışları" value={formatMoney(summary.cardGross)} />
          <SummaryCard label="Tahmini Komisyon Kesintisi" value={`- ${formatMoney(summary.totalCommissionCut)}`} tone="destructive" />
          <SummaryCard label="Net Hesaba Geçecek" value={formatMoney(summary.netBankSettlement + summary.cashGross)} tone="primary" />
        </div>

        {/* SATIŞ KAYITLARI & HIZLI FATURA KESME */}
        <Card>
          <CardHeader className="py-4">
            <CardTitle className="text-base">Sorgulanan POS Satışları ({filteredSales.length})</CardTitle>
            <CardDescription>
              Tek tıkla "Hızlı Fatura Kes" butonu ile slipleri e-Arşiv faturaya dönüştürebilirsiniz.
            </CardDescription>
          </CardHeader>
          <CardContent>
            {isLoading ? (
              <p className="text-sm text-muted-foreground py-4">Yükleniyor…</p>
            ) : filteredSales.length === 0 ? (
              <p className="text-sm text-muted-foreground py-4">Seçilen aralıkta POS satışı bulunamadı.</p>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground">
                      <th className="py-2.5 pr-4">Tarih</th>
                      <th className="py-2.5 pr-4">Açıklama / Cihaz</th>
                      <th className="py-2.5 pr-4">Belge / Slip No</th>
                      <th className="py-2.5 pr-4">Ödeme</th>
                      <th className="py-2.5 pr-4 text-right">KDV Matrahı</th>
                      <th className="py-2.5 pr-4 text-right">KDV</th>
                      <th className="py-2.5 pr-4 text-right">Brüt Tutar</th>
                      <th className="py-2.5 pr-4 text-right">Komisyon (%{globalCommissionRate})</th>
                      <th className="py-2.5 text-right font-bold">İşlemler</th>
                    </tr>
                  </thead>
                  <tbody>
                    {filteredSales.map((s) => {
                      const isCard = s.payment_type === "KREDI_KARTI" || s.payment_type === "TAKSITLI_KART";
                      const itemCommission = isCard ? (Number(s.gross_amount) * globalCommissionRate) / 100 : 0;
                      return (
                        <tr key={s.id} className="border-b border-border/60 hover:bg-muted/30 last:border-0">
                          <td className="py-3 pr-4 whitespace-nowrap">{formatDate(s.sale_date)}</td>
                          <td className="py-3 pr-4 font-medium">{s.description || "-"}</td>
                          <td className="py-3 pr-4 font-mono text-xs text-muted-foreground">{s.document_no || "-"}</td>
                          <td className="py-3 pr-4">
                            <Badge variant={isCard ? "default" : "secondary"} className="text-xs">
                              {PAYMENT_TYPES.find((p) => p.value === s.payment_type)?.label ?? s.payment_type}
                            </Badge>
                          </td>
                          <td className="py-3 pr-4 text-right">{formatMoney(Number(s.net_amount))}</td>
                          <td className="py-3 pr-4 text-right text-xs text-muted-foreground">%{Number(s.vat_rate)} ({formatMoney(Number(s.vat_amount))})</td>
                          <td className="py-3 pr-4 text-right font-semibold whitespace-nowrap">
                            {formatMoney(Number(s.gross_amount))}
                          </td>
                          <td className="py-3 pr-4 text-right text-xs text-destructive">
                            {isCard ? `- ${formatMoney(itemCommission)}` : "-"}
                          </td>
                          <td className="py-3 text-right whitespace-nowrap">
                            <div className="flex items-center justify-end gap-1.5">
                              {/* Hızlı Fatura Kes Butonu */}
                              <Button
                                size="sm"
                                variant="outline"
                                className="h-7 px-2 text-xs gap-1 text-primary border-primary/30 hover:bg-primary/10"
                                onClick={() => {
                                  setSelectedSaleForInvoice(s as PosRow);
                                  setQuickCustomer({
                                    title: "Nihai Tüketici (Perakende Müşteri)",
                                    vknTckn: "11111111111",
                                    email: "",
                                    address: "Türkiye",
                                  });
                                  setQuickInvoiceOpen(true);
                                }}
                              >
                                <FilePlus2 className="size-3.5" /> Hızlı Fatura Kes
                              </Button>
                              <Button
                                variant="ghost"
                                size="sm"
                                className="h-7 text-xs text-destructive"
                                onClick={() => removeSale.mutate(s.id)}
                              >
                                Sil
                              </Button>
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

        {/* HIZLI FATURA KESME DİALOGU */}
        <Dialog open={quickInvoiceOpen} onOpenChange={setQuickInvoiceOpen}>
          <DialogContent className="max-w-md">
            <DialogHeader>
              <DialogTitle className="flex items-center gap-2">
                <FilePlus2 className="size-5 text-primary" /> POS Satışından Hızlı e-Arşiv Fatura Kes
              </DialogTitle>
            </DialogHeader>
            {selectedSaleForInvoice ? (
              <div className="space-y-4">
                <div className="rounded-lg bg-muted/50 p-3 text-xs space-y-1">
                  <div className="flex justify-between">
                    <span className="text-muted-foreground">Tarih:</span>
                    <span className="font-semibold">{selectedSaleForInvoice.sale_date}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-muted-foreground">Tutar (KDV Dahil):</span>
                    <span className="font-bold text-primary text-sm">
                      {formatMoney(selectedSaleForInvoice.gross_amount)}
                    </span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-muted-foreground">Slip No:</span>
                    <span>{selectedSaleForInvoice.document_no || "-"}</span>
                  </div>
                </div>

                <div className="space-y-3">
                  <div className="space-y-1">
                    <Label className="text-xs">Müşteri / Alıcı Unvanı *</Label>
                    <Input
                      placeholder="Ad Soyad veya Firma Unvanı"
                      value={quickCustomer.title}
                      onChange={(e) =>
                        setQuickCustomer({ ...quickCustomer, title: e.target.value })
                      }
                    />
                  </div>
                  <div className="space-y-1">
                    <Label className="text-xs">VKN veya TCKN</Label>
                    <Input
                      placeholder="11111111111 (Nihai tüketici)"
                      value={quickCustomer.vknTckn}
                      onChange={(e) =>
                        setQuickCustomer({ ...quickCustomer, vknTckn: e.target.value })
                      }
                    />
                  </div>
                  <div className="space-y-1">
                    <Label className="text-xs">E-posta (e-Arşiv iletimi için)</Label>
                    <Input
                      type="email"
                      placeholder="musteri@eposta.com"
                      value={quickCustomer.email}
                      onChange={(e) =>
                        setQuickCustomer({ ...quickCustomer, email: e.target.value })
                      }
                    />
                  </div>
                </div>

                <Button
                  className="w-full"
                  disabled={createQuickInvoice.isPending}
                  onClick={() => createQuickInvoice.mutate()}
                >
                  {createQuickInvoice.isPending ? "Fatura Kesiliyor…" : "e-Arşiv Faturayı Kes & Onayla"}
                </Button>
              </div>
            ) : null}
          </DialogContent>
        </Dialog>
      </div>
    </AppShell>
  );
}

function SummaryCard({ label, value, tone }: { label: string; value: string; tone?: "primary" | "destructive" }) {
  return (
    <Card>
      <CardContent className="p-5">
        <p className="text-xs uppercase text-muted-foreground font-medium">{label}</p>
        <p
          className={`mt-1 text-xl font-bold ${
            tone === "destructive"
              ? "text-destructive"
              : tone === "primary"
                ? "text-primary"
                : "text-foreground"
          }`}
        >
          {value}
        </p>
      </CardContent>
    </Card>
  );
}

