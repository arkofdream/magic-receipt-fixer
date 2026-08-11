import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Download } from "lucide-react";
import { toast } from "sonner";

import { AppShell } from "@/components/AppShell";
import { ExcelImportDialog } from "@/components/ExcelImportDialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { supabase } from "@/integrations/supabase/client";
import { downloadWorkbook, parseNumber, pickColumn, type SheetRow } from "@/lib/excel";
import { formatMoney } from "@/lib/invoice";


export const Route = createFileRoute("/_authenticated/urunler")({
  head: () => ({
    meta: [
      { title: "Ürün & Hizmet Kataloğu | e-Fatura Portalı" },
      { name: "description", content: "Sık kullandığınız ürün ve hizmetleri fiyat ve KDV oranlarıyla saklayın." },
      { property: "og:title", content: "Ürün & Hizmet Kataloğu | e-Fatura Portalı" },
      { property: "og:description", content: "Ürün ve hizmet kataloğunuzu yönetin." },
    ],
  }),
  component: ProductsPage,
});

const emptyProduct = { name: "", unit: "Adet", unitPrice: "0", vatRate: "20" };

const PRODUCT_COLUMNS = [
  { header: "Ad", aliases: ["urun", "hizmet"], example: "Danışmanlık Hizmeti" },
  { header: "Birim", example: "Adet" },
  { header: "Birim Fiyat", example: "1500" },
  { header: "KDV %", example: "20" },
];

type ImportedProduct = { name: string; unit: string; unitPrice: number; vatRate: number };

function ProductsPage() {
  const queryClient = useQueryClient();
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState(emptyProduct);

  const { data: products = [], isLoading } = useQuery({
    queryKey: ["products"],
    queryFn: async () => {
      const { data, error } = await supabase.from("products").select("*").order("created_at", { ascending: false });
      if (error) throw error;
      return data;
    },
  });

  const createProduct = useMutation({
    mutationFn: async () => {
      const { data: userData } = await supabase.auth.getUser();
      const userId = userData.user?.id;
      if (!userId) throw new Error("Oturum bulunamadı.");
      const { error } = await supabase.from("products").insert({
        user_id: userId,
        name: form.name,
        unit: form.unit,
        unit_price: Number(form.unitPrice) || 0,
        vat_rate: Number(form.vatRate) || 0,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Ürün/hizmet eklendi.");
      setForm(emptyProduct);
      setOpen(false);
      queryClient.invalidateQueries({ queryKey: ["products"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const removeProduct = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from("products").delete().eq("id", id);
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Kayıt silindi.");
      queryClient.invalidateQueries({ queryKey: ["products"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  async function importProducts(rows: ImportedProduct[]) {
    const { data: userData } = await supabase.auth.getUser();
    const userId = userData.user?.id;
    if (!userId) throw new Error("Oturum bulunamadı.");
    const { error } = await supabase.from("products").insert(
      rows.map((r) => ({
        user_id: userId,
        name: r.name,
        unit: r.unit,
        unit_price: r.unitPrice,
        vat_rate: r.vatRate,
      })),
    );
    if (error) throw error;
    toast.success(`${rows.length} kalem içe aktarıldı.`);
    queryClient.invalidateQueries({ queryKey: ["products"] });
  }

  function exportProducts() {
    downloadWorkbook(
      PRODUCT_COLUMNS.map((c) => c.header),
      products.map((p) => [p.name, p.unit, Number(p.unit_price), Number(p.vat_rate)]),
      `urunler-${new Date().toISOString().slice(0, 10)}.xlsx`,
      "Ürünler",
    );
  }

  return (
    <AppShell
      title="Ürün & Hizmet Kataloğu"
      subtitle="Faturaya hızlı ekleme için kayıtlı kalemler"
      actions={
        <>
          <Button variant="ghost" className="gap-2" onClick={exportProducts} disabled={products.length === 0}>
            <Download className="size-4" />
            Excel'e Aktar
          </Button>
          <ExcelImportDialog<ImportedProduct>
            title="Excel'den Ürün İçe Aktar"
            templateName="urun-sablonu.xlsx"
            columns={PRODUCT_COLUMNS}
            mapRow={(row: SheetRow) => {
              const name = pickColumn(row, ["Ad", "Ürün", "Hizmet", "Ürün / Hizmet Adı", "Açıklama"]);
              if (!name) return null;
              return {
                name,
                unit: pickColumn(row, ["Birim"]) || "Adet",
                unitPrice: parseNumber(pickColumn(row, ["Birim Fiyat", "Fiyat"])),
                vatRate: parseNumber(pickColumn(row, ["KDV %", "KDV", "KDV Oranı"])),
              };
            }}
            onImport={importProducts}
          />
        <Dialog open={open} onOpenChange={setOpen}>
          <DialogTrigger asChild>
            <Button>Yeni Kalem</Button>
          </DialogTrigger>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>Ürün / Hizmet Ekle</DialogTitle>
            </DialogHeader>
            <form
              className="space-y-4"
              onSubmit={(e) => {
                e.preventDefault();
                createProduct.mutate();
              }}
            >
              <div className="space-y-2">
                <Label htmlFor="name">Ürün / Hizmet Adı</Label>
                <Input id="name" required value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
              </div>
              <div className="grid grid-cols-3 gap-3">
                <div className="space-y-2">
                  <Label htmlFor="unit">Birim</Label>
                  <Input id="unit" value={form.unit} onChange={(e) => setForm({ ...form, unit: e.target.value })} />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="price">Birim Fiyat</Label>
                  <Input
                    id="price"
                    type="number"
                    step="0.01"
                    required
                    value={form.unitPrice}
                    onChange={(e) => setForm({ ...form, unitPrice: e.target.value })}
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="vat">KDV %</Label>
                  <Input
                    id="vat"
                    type="number"
                    step="1"
                    value={form.vatRate}
                    onChange={(e) => setForm({ ...form, vatRate: e.target.value })}
                  />
                </div>
              </div>
              <Button type="submit" className="w-full" disabled={createProduct.isPending}>
                Kaydet
              </Button>
            </form>
          </DialogContent>
        </Dialog>
        </>
      }
    >
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Katalog ({products.length})</CardTitle>
        </CardHeader>
        <CardContent>
          {isLoading ? (
            <p className="text-sm text-muted-foreground">Yükleniyor…</p>
          ) : products.length === 0 ? (
            <p className="text-sm text-muted-foreground">Henüz kayıt yok.</p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground">
                    <th className="py-2 pr-4">Ad</th>
                    <th className="py-2 pr-4">Birim</th>
                    <th className="py-2 pr-4">Birim Fiyat</th>
                    <th className="py-2 pr-4">KDV</th>
                    <th className="py-2" />
                  </tr>
                </thead>
                <tbody>
                  {products.map((p) => (
                    <tr key={p.id} className="border-b border-border/60 last:border-0">
                      <td className="py-3 pr-4 font-medium">{p.name}</td>
                      <td className="py-3 pr-4">{p.unit}</td>
                      <td className="py-3 pr-4">{formatMoney(Number(p.unit_price))}</td>
                      <td className="py-3 pr-4">%{Number(p.vat_rate)}</td>
                      <td className="py-3 text-right">
                        <Button variant="ghost" size="sm" onClick={() => removeProduct.mutate(p.id)}>
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
