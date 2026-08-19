import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import { Download } from "lucide-react";
import { toast } from "sonner";

import { AppShell } from "@/components/AppShell";
import { AddressSelect } from "@/components/AddressSelect";
import { ExcelImportDialog } from "@/components/ExcelImportDialog";
import { CariDetailDialog } from "@/components/CariDetailDialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { supabase } from "@/integrations/supabase/client";
import { downloadWorkbook, parseNumber, pickColumn, type SheetRow } from "@/lib/excel";
import { emptyCustomer, formatMoney, type InvoiceCustomer } from "@/lib/invoice";
import { PARTNER_LABELS, type PartnerType } from "@/lib/cari";

export const Route = createFileRoute("/_authenticated/cariler")({
  head: () => ({
    meta: [
      { title: "Cari Hesaplar | e-Fatura Portalı" },
      {
        name: "description",
        content:
          "Müşteri ve tedarikçi cari hesaplarınızı bakiye, borç, alacak ve ekstre takibiyle yönetin.",
      },
      { property: "og:title", content: "Cari Hesaplar | e-Fatura Portalı" },
      {
        property: "og:description",
        content: "Müşteri ve tedarikçi cari hesaplarınızı tek yerden yönetin.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: CustomersPage,
});

const IMPORT_COLUMNS = [
  { header: "VKN/TCKN", aliases: ["vkn", "tckn", "vergino"], example: "1234567890" },
  { header: "Unvan", aliases: ["unvanadsoyad", "adsoyad", "musteri"], example: "Örnek Ltd. Şti." },
  { header: "Cari Kod", example: "M-001" },
  { header: "Yetkili", example: "Ayşe Yılmaz" },
  { header: "Vergi Dairesi", example: "Kadıköy" },
  { header: "Adres", example: "Örnek Cad. No:1" },
  { header: "İl", example: "İstanbul" },
  { header: "İlçe", example: "Kadıköy" },
  { header: "Mahalle", example: "Caferağa" },
  { header: "E-posta", aliases: ["eposta", "mail"], example: "info@ornek.com" },
  { header: "Telefon", example: "05001234567" },
  { header: "Grup", example: "Bayi" },
  { header: "Vade (Gün)", example: "30" },
  { header: "Risk Limiti", example: "50000" },
  { header: "Açılış Bakiyesi", example: "0" },
];

type ExtraFields = {
  code: string;
  contactName: string;
  partnerGroup: string;
  paymentTermDays: number;
  riskLimit: number;
  openingBalance: number;
  note: string;
};

type FormState = InvoiceCustomer & ExtraFields;

const emptyExtras: ExtraFields = {
  code: "",
  contactName: "",
  partnerGroup: "",
  paymentTermDays: 0,
  riskLimit: 0,
  openingBalance: 0,
  note: "",
};

type ImportedCustomer = FormState;

function CustomersPage() {
  const queryClient = useQueryClient();
  const [open, setOpen] = useState(false);
  const [tab, setTab] = useState<PartnerType>("MUSTERI");
  const [search, setSearch] = useState("");
  const [detailId, setDetailId] = useState<string | null>(null);
  const [form, setForm] = useState<FormState>({ ...emptyCustomer, ...emptyExtras });

  const { data: customers = [], isLoading } = useQuery({
    queryKey: ["customers"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("customers")
        .select("*")
        .order("created_at", { ascending: false });
      if (error) throw error;
      return data;
    },
  });

  const { data: balances = [] } = useQuery({
    queryKey: ["customer-balances"],
    queryFn: async () => {
      const { data, error } = await supabase.from("customer_balances").select("*");
      if (error) throw error;
      return data;
    },
  });

  const balanceMap = useMemo(() => {
    const map = new Map<string, { debit: number; credit: number; balance: number }>();
    for (const b of balances) {
      if (!b.customer_id) continue;
      map.set(b.customer_id, {
        debit: Number(b.total_debit ?? 0),
        credit: Number(b.total_credit ?? 0),
        balance: Number(b.balance ?? 0),
      });
    }
    return map;
  }, [balances]);

  const visible = useMemo(() => {
    const q = search.trim().toLocaleLowerCase("tr");
    return customers
      .filter((c) => (c.partner_type ?? "MUSTERI") === tab)
      .filter((c) =>
        q
          ? [c.title, c.vkn_tckn, c.code, c.phone, c.email]
              .filter(Boolean)
              .some((v) => String(v).toLocaleLowerCase("tr").includes(q))
          : true,
      );
  }, [customers, tab, search]);

  const summary = useMemo(() => {
    let receivable = 0;
    let payable = 0;
    for (const c of customers) {
      const b = balanceMap.get(c.id)?.balance ?? 0;
      if (b > 0) receivable += b;
      else payable += Math.abs(b);
    }
    return { receivable, payable };
  }, [customers, balanceMap]);

  async function currentUserId() {
    const { data: userData } = await supabase.auth.getUser();
    const userId = userData.user?.id;
    if (!userId) throw new Error("Oturum bulunamadı.");
    return userId;
  }

  function toRow(userId: string, values: FormState, partnerType: PartnerType) {
    return {
      user_id: userId,
      partner_type: partnerType,
      vkn_tckn: values.vknTckn,
      title: values.title,
      tax_office: values.taxOffice,
      address: values.address,
      city: values.city,
      district: values.district,
      neighborhood: values.neighborhood,
      email: values.email,
      phone: values.phone,
      code: values.code,
      contact_name: values.contactName,
      partner_group: values.partnerGroup,
      payment_term_days: Number(values.paymentTermDays) || 0,
      risk_limit: Number(values.riskLimit) || 0,
      opening_balance: Number(values.openingBalance) || 0,
      note: values.note,
    };
  }

  const createCustomer = useMutation({
    mutationFn: async (values: FormState) => {
      const userId = await currentUserId();
      const { error } = await supabase.from("customers").insert(toRow(userId, values, tab));
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success(`${PARTNER_LABELS[tab]} kaydedildi.`);
      setForm({ ...emptyCustomer, ...emptyExtras });
      setOpen(false);
      queryClient.invalidateQueries({ queryKey: ["customers"] });
      queryClient.invalidateQueries({ queryKey: ["customer-balances"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const removeCustomer = useMutation({
    mutationFn: async (id: string) => {
      const { data: userData } = await supabase.auth.getUser();
      const userId = userData.user?.id;
      const { error } = await supabase
        .from("customers")
        .update({
          deleted_at: new Date().toISOString(),
          deleted_by: userId || null,
        })
        .eq("id", id);
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Cari silindi (Çöp Kutusuna taşındı).");
      queryClient.invalidateQueries({ queryKey: ["customers"] });
      queryClient.invalidateQueries({ queryKey: ["customer-balances"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  async function importCustomers(rows: ImportedCustomer[]) {
    const userId = await currentUserId();
    const { error } = await supabase
      .from("customers")
      .insert(rows.map((r) => toRow(userId, r, tab)));
    if (error) throw error;
    toast.success(`${rows.length} cari içe aktarıldı.`);
    queryClient.invalidateQueries({ queryKey: ["customers"] });
    queryClient.invalidateQueries({ queryKey: ["customer-balances"] });
  }

  function exportCustomers() {
    downloadWorkbook(
      [...IMPORT_COLUMNS.map((c) => c.header), "Bakiye"],
      visible.map((c) => [
        c.vkn_tckn,
        c.title,
        c.code ?? "",
        c.contact_name ?? "",
        c.tax_office,
        c.address,
        c.city,
        c.district,
        c.neighborhood ?? "",
        c.email,
        c.phone,
        c.partner_group ?? "",
        Number(c.payment_term_days ?? 0),
        Number(c.risk_limit ?? 0),
        Number(c.opening_balance ?? 0),
        balanceMap.get(c.id)?.balance ?? 0,
      ]),
      `cariler-${new Date().toISOString().slice(0, 10)}.xlsx`,
      "Cariler",
    );
  }

  const textFields: { key: keyof FormState; label: string; required?: boolean; type?: string }[] = [
    { key: "code", label: "Cari Kod" },
    { key: "vknTckn", label: "VKN / TCKN", required: true },
    { key: "title", label: "Firma / Unvan", required: true },
    { key: "contactName", label: "Ad Soyad (Yetkili)" },
    { key: "taxOffice", label: "Vergi Dairesi" },
    { key: "email", label: "E-posta" },
    { key: "phone", label: "Telefon" },
    { key: "partnerGroup", label: `${PARTNER_LABELS[tab]} Grubu` },
    { key: "paymentTermDays", label: "Vade (Gün)", type: "number" },
    { key: "riskLimit", label: "Risk Limiti", type: "number" },
    { key: "openingBalance", label: "Açılış Bakiyesi (Borç +)", type: "number" },
  ];

  const detailCustomer = customers.find((c) => c.id === detailId) ?? null;

  return (
    <AppShell
      title="Cari Hesaplar"
      subtitle="Müşteri ve tedarikçi kartları, bakiye ve ekstre takibi"
      actions={
        <>
          <Button
            variant="ghost"
            className="gap-2"
            onClick={exportCustomers}
            disabled={visible.length === 0}
          >
            <Download className="size-4" />
            Excel'e Aktar
          </Button>
          <ExcelImportDialog<ImportedCustomer>
            title="Excel'den Cari İçe Aktar"
            templateName="cari-sablonu.xlsx"
            columns={IMPORT_COLUMNS}
            mapRow={(row: SheetRow) => {
              const vknTckn = pickColumn(row, ["VKN/TCKN", "VKN", "TCKN", "Vergi No", "TC"]).trim();
              const title = pickColumn(row, [
                "Unvan",
                "Unvan / Ad Soyad",
                "Ad Soyad",
                "Müşteri",
                "Firma",
              ]).trim();
              if (!vknTckn && !title) return null;
              if (!title) return { error: "Unvan / Firma Adı alanı boş olamaz." };
              if (!vknTckn) return { error: "VKN / TCKN alanı boş olamaz." };
              return {
                data: {
                  vknTckn,
                  title,
                  taxOffice: pickColumn(row, ["Vergi Dairesi"]),
                  address: pickColumn(row, ["Adres"]),
                  city: pickColumn(row, ["İl", "Şehir"]),
                  district: pickColumn(row, ["İlçe"]),
                  neighborhood: pickColumn(row, ["Mahalle", "Mahalle / Köy"]),
                  email: pickColumn(row, ["E-posta", "Email", "Mail"]),
                  phone: pickColumn(row, ["Telefon", "Tel", "GSM"]),
                  code: pickColumn(row, ["Cari Kod", "Kod"]),
                  contactName: pickColumn(row, ["Yetkili", "Ad Soyad"]),
                  partnerGroup: pickColumn(row, ["Grup", "Müşteri Grubu", "Tedarikçi Grubu"]),
                  paymentTermDays: parseNumber(pickColumn(row, ["Vade (Gün)", "Vade"])),
                  riskLimit: parseNumber(pickColumn(row, ["Risk Limiti", "Risk"])),
                  openingBalance: parseNumber(pickColumn(row, ["Açılış Bakiyesi", "Bakiye"])),
                  note: pickColumn(row, ["Açıklama", "Not"]),
                },
              };
            }}
            onImport={importCustomers}
          />
          <Dialog open={open} onOpenChange={setOpen}>
            <DialogTrigger asChild>
              <Button>Yeni {PARTNER_LABELS[tab]}</Button>
            </DialogTrigger>
            <DialogContent className="max-h-[85vh] overflow-y-auto">
              <DialogHeader>
                <DialogTitle>Yeni {PARTNER_LABELS[tab]} Kartı</DialogTitle>
              </DialogHeader>
              <form
                className="grid gap-4 sm:grid-cols-2"
                onSubmit={(e) => {
                  e.preventDefault();
                  createCustomer.mutate(form);
                }}
              >
                {textFields.map((f) => (
                  <div key={f.key} className="space-y-2">
                    <Label htmlFor={f.key}>{f.label}</Label>
                    <Input
                      id={f.key}
                      type={f.type ?? "text"}
                      step={f.type === "number" ? "0.01" : undefined}
                      required={f.required ?? false}
                      value={String(form[f.key] ?? "")}
                      onChange={(e) =>
                        setForm({
                          ...form,
                          [f.key]:
                            f.type === "number" ? Number(e.target.value) || 0 : e.target.value,
                        })
                      }
                    />
                  </div>
                ))}
                <AddressSelect
                  value={{
                    city: form.city,
                    district: form.district,
                    neighborhood: form.neighborhood,
                  }}
                  onChange={(v) => setForm({ ...form, ...v })}
                />
                <div className="space-y-2 sm:col-span-2">
                  <Label htmlFor="address">Açık Adres</Label>
                  <Input
                    id="address"
                    value={form.address}
                    onChange={(e) => setForm({ ...form, address: e.target.value })}
                  />
                </div>
                <div className="space-y-2 sm:col-span-2">
                  <Label htmlFor="note">Açıklama / Not</Label>
                  <Input
                    id="note"
                    value={form.note}
                    onChange={(e) => setForm({ ...form, note: e.target.value })}
                  />
                </div>
                <div className="sm:col-span-2">
                  <Button type="submit" className="w-full" disabled={createCustomer.isPending}>
                    Kaydet
                  </Button>
                </div>
              </form>
            </DialogContent>
          </Dialog>
        </>
      }
    >
      <div className="mb-4 grid gap-3 sm:grid-cols-2">
        <Card>
          <CardContent className="pt-6">
            <p className="text-xs text-muted-foreground">Toplam Alacak (müşterilerden)</p>
            <p className="text-2xl font-semibold">{formatMoney(summary.receivable)}</p>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="pt-6">
            <p className="text-xs text-muted-foreground">Toplam Borç (tedarikçilere)</p>
            <p className="text-2xl font-semibold">{formatMoney(summary.payable)}</p>
          </CardContent>
        </Card>
      </div>

      <Card>
        <CardHeader className="gap-3">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <CardTitle className="text-base">
              {PARTNER_LABELS[tab]} Listesi ({visible.length})
            </CardTitle>
            <Input
              placeholder="Ara: unvan, VKN, kod, telefon…"
              className="w-full sm:w-72"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
            />
          </div>
          <Tabs value={tab} onValueChange={(v) => setTab(v as PartnerType)}>
            <TabsList>
              <TabsTrigger value="MUSTERI">Müşteriler</TabsTrigger>
              <TabsTrigger value="TEDARIKCI">Tedarikçiler</TabsTrigger>
            </TabsList>
          </Tabs>
        </CardHeader>
        <CardContent>
          {isLoading ? (
            <p className="text-sm text-muted-foreground">Yükleniyor…</p>
          ) : visible.length === 0 ? (
            <p className="text-sm text-muted-foreground">Bu listede kayıt yok.</p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground">
                    <th className="py-2 pr-4">Kod / VKN</th>
                    <th className="py-2 pr-4">Unvan</th>
                    <th className="py-2 pr-4">İletişim</th>
                    <th className="py-2 pr-4">Vade</th>
                    <th className="py-2 pr-4 text-right">Borç</th>
                    <th className="py-2 pr-4 text-right">Alacak</th>
                    <th className="py-2 pr-4 text-right">Bakiye</th>
                    <th className="py-2" />
                  </tr>
                </thead>
                <tbody>
                  {visible.map((c) => {
                    const b = balanceMap.get(c.id) ?? { debit: 0, credit: 0, balance: 0 };
                    const overLimit =
                      Number(c.risk_limit ?? 0) > 0 && b.balance > Number(c.risk_limit);
                    return (
                      <tr key={c.id} className="border-b border-border/60 last:border-0">
                        <td className="py-3 pr-4">
                          <div className="font-medium">{c.code || "-"}</div>
                          <div className="text-xs text-muted-foreground">{c.vkn_tckn}</div>
                        </td>
                        <td className="py-3 pr-4">
                          <div className="font-medium">{c.title}</div>
                          <div className="text-xs text-muted-foreground">
                            {[c.partner_group, c.city].filter(Boolean).join(" · ") || "-"}
                          </div>
                        </td>
                        <td className="py-3 pr-4">{c.email || c.phone || "-"}</td>
                        <td className="py-3 pr-4">{Number(c.payment_term_days ?? 0)} gün</td>
                        <td className="py-3 pr-4 text-right">{formatMoney(b.debit)}</td>
                        <td className="py-3 pr-4 text-right">{formatMoney(b.credit)}</td>
                        <td className="py-3 pr-4 text-right">
                          <span className="font-medium">{formatMoney(Math.abs(b.balance))}</span>
                          <div className="text-xs text-muted-foreground">
                            {b.balance > 0 ? "Borçlu" : b.balance < 0 ? "Alacaklı" : "Kapalı"}
                          </div>
                          {overLimit ? (
                            <Badge variant="destructive" className="mt-1">
                              Risk limiti aşıldı
                            </Badge>
                          ) : null}
                        </td>
                        <td className="py-3 text-right whitespace-nowrap">
                          <Button variant="outline" size="sm" onClick={() => setDetailId(c.id)}>
                            Ekstre
                          </Button>
                          <Button
                            variant="ghost"
                            size="sm"
                            onClick={() => removeCustomer.mutate(c.id)}
                          >
                            Sil
                          </Button>
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

      <CariDetailDialog
        customer={detailCustomer as never}
        partners={customers as never}
        onClose={() => setDetailId(null)}
      />
    </AppShell>
  );
}
