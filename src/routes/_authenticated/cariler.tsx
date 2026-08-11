import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Download } from "lucide-react";
import { toast } from "sonner";

import { AppShell } from "@/components/AppShell";
import { AddressSelect } from "@/components/AddressSelect";
import { ExcelImportDialog } from "@/components/ExcelImportDialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { supabase } from "@/integrations/supabase/client";
import { downloadWorkbook, parseNumber, pickColumn, type SheetRow } from "@/lib/excel";
import { emptyCustomer, type InvoiceCustomer } from "@/lib/invoice";

export const Route = createFileRoute("/_authenticated/cariler")({
  head: () => ({
    meta: [
      { title: "Cari Rehberi | e-Fatura Portalı" },
      { name: "description", content: "Müşteri ve cari kayıtlarınızı VKN/TCKN bilgileriyle yönetin, Excel'den toplu içe aktarın." },
      { property: "og:title", content: "Cari Rehberi | e-Fatura Portalı" },
      { property: "og:description", content: "Müşteri kayıtlarınızı tek yerden yönetin." },
    ],
  }),
  component: CustomersPage,
});

const IMPORT_COLUMNS = [
  { header: "VKN/TCKN", aliases: ["vkn", "tckn", "vergino"], example: "1234567890" },
  { header: "Unvan", aliases: ["unvanadsoyad", "adsoyad", "musteri"], example: "Örnek Ltd. Şti." },
  { header: "Vergi Dairesi", example: "Kadıköy" },
  { header: "Adres", example: "Örnek Cad. No:1" },
  { header: "İl", example: "İstanbul" },
  { header: "İlçe", example: "Kadıköy" },
  { header: "Mahalle", example: "Caferağa" },
  { header: "E-posta", aliases: ["eposta", "mail"], example: "info@ornek.com" },
  { header: "Telefon", example: "05001234567" },
];

type ImportedCustomer = Omit<InvoiceCustomer, "vknTckn"> & { vknTckn: string };

function CustomersPage() {
  const queryClient = useQueryClient();
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState<InvoiceCustomer>(emptyCustomer);

  const { data: customers = [], isLoading } = useQuery({
    queryKey: ["customers"],
    queryFn: async () => {
      const { data, error } = await supabase.from("customers").select("*").order("created_at", { ascending: false });
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

  function toRow(userId: string, values: InvoiceCustomer) {
    return {
      user_id: userId,
      vkn_tckn: values.vknTckn,
      title: values.title,
      tax_office: values.taxOffice,
      address: values.address,
      city: values.city,
      district: values.district,
      neighborhood: values.neighborhood,
      email: values.email,
      phone: values.phone,
    };
  }

  const createCustomer = useMutation({
    mutationFn: async (values: InvoiceCustomer) => {
      const userId = await currentUserId();
      const { error } = await supabase.from("customers").insert(toRow(userId, values));
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Cari kaydedildi.");
      setForm(emptyCustomer);
      setOpen(false);
      queryClient.invalidateQueries({ queryKey: ["customers"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const removeCustomer = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from("customers").delete().eq("id", id);
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Cari silindi.");
      queryClient.invalidateQueries({ queryKey: ["customers"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  async function importCustomers(rows: ImportedCustomer[]) {
    const userId = await currentUserId();
    const { error } = await supabase.from("customers").insert(rows.map((r) => toRow(userId, r)));
    if (error) throw error;
    toast.success(`${rows.length} cari içe aktarıldı.`);
    queryClient.invalidateQueries({ queryKey: ["customers"] });
  }

  function exportCustomers() {
    downloadWorkbook(
      IMPORT_COLUMNS.map((c) => c.header),
      customers.map((c) => [
        c.vkn_tckn,
        c.title,
        c.tax_office,
        c.address,
        c.city,
        c.district,
        c.neighborhood ?? "",
        c.email,
        c.phone,
      ]),
      `cariler-${new Date().toISOString().slice(0, 10)}.xlsx`,
      "Cariler",
    );
  }

  const textFields: { key: keyof InvoiceCustomer; label: string; required?: boolean }[] = [
    { key: "vknTckn", label: "VKN / TCKN", required: true },
    { key: "title", label: "Unvan / Ad Soyad", required: true },
    { key: "taxOffice", label: "Vergi Dairesi" },
    { key: "email", label: "E-posta" },
    { key: "phone", label: "Telefon" },
  ];

  return (
    <AppShell
      title="Cari (Müşteri) Rehberi"
      subtitle="Faturalarınızda kullanacağınız alıcı bilgileri"
      actions={
        <>
          <Button variant="ghost" className="gap-2" onClick={exportCustomers} disabled={customers.length === 0}>
            <Download className="size-4" />
            Excel'e Aktar
          </Button>
          <ExcelImportDialog<ImportedCustomer>
            title="Excel'den Cari İçe Aktar"
            templateName="cari-sablonu.xlsx"
            columns={IMPORT_COLUMNS}
            mapRow={(row: SheetRow) => {
              const vknTckn = pickColumn(row, ["VKN/TCKN", "VKN", "TCKN", "Vergi No"]);
              const title = pickColumn(row, ["Unvan", "Unvan / Ad Soyad", "Ad Soyad", "Müşteri"]);
              if (!vknTckn && !title) return null;
              return {
                vknTckn,
                title,
                taxOffice: pickColumn(row, ["Vergi Dairesi"]),
                address: pickColumn(row, ["Adres"]),
                city: pickColumn(row, ["İl", "Şehir"]),
                district: pickColumn(row, ["İlçe"]),
                neighborhood: pickColumn(row, ["Mahalle", "Mahalle / Köy"]),
                email: pickColumn(row, ["E-posta", "Email", "Mail"]),
                phone: pickColumn(row, ["Telefon", "Tel", "GSM"]),
              };
            }}
            onImport={importCustomers}
          />
          <Dialog open={open} onOpenChange={setOpen}>
            <DialogTrigger asChild>
              <Button>Yeni Cari</Button>
            </DialogTrigger>
            <DialogContent className="max-h-[85vh] overflow-y-auto">
              <DialogHeader>
                <DialogTitle>Yeni Cari Kaydı</DialogTitle>
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
                      required={f.required ?? false}
                      value={form[f.key]}
                      onChange={(e) => setForm({ ...form, [f.key]: e.target.value })}
                    />
                  </div>
                ))}
                <AddressSelect
                  value={{ city: form.city, district: form.district, neighborhood: form.neighborhood }}
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
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Kayıtlı Cariler ({customers.length})</CardTitle>
        </CardHeader>
        <CardContent>
          {isLoading ? (
            <p className="text-sm text-muted-foreground">Yükleniyor…</p>
          ) : customers.length === 0 ? (
            <p className="text-sm text-muted-foreground">Henüz cari kaydı yok.</p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground">
                    <th className="py-2 pr-4">VKN / TCKN</th>
                    <th className="py-2 pr-4">Unvan</th>
                    <th className="py-2 pr-4">Vergi Dairesi</th>
                    <th className="py-2 pr-4">İl / İlçe / Mahalle</th>
                    <th className="py-2 pr-4">İletişim</th>
                    <th className="py-2" />
                  </tr>
                </thead>
                <tbody>
                  {customers.map((c) => (
                    <tr key={c.id} className="border-b border-border/60 last:border-0">
                      <td className="py-3 pr-4 font-medium">{c.vkn_tckn}</td>
                      <td className="py-3 pr-4">{c.title}</td>
                      <td className="py-3 pr-4">{c.tax_office || "-"}</td>
                      <td className="py-3 pr-4">
                        {[c.city, c.district, c.neighborhood].filter(Boolean).join(" / ") || "-"}
                      </td>
                      <td className="py-3 pr-4">{c.email || c.phone || "-"}</td>
                      <td className="py-3 text-right">
                        <Button variant="ghost" size="sm" onClick={() => removeCustomer.mutate(c.id)}>
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
    </AppShell>
  );
}
