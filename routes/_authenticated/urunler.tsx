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
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { supabase } from "@/integrations/supabase/client";
import { isMissingColumnError, safeSoftDelete } from "@/lib/safe-supabase";
import { downloadWorkbook, parseNumber, pickColumn, type SheetRow } from "@/lib/excel";
import { formatMoney } from "@/lib/invoice";

export const Route = createFileRoute("/_authenticated/urunler")({
  head: () => ({
    meta: [
      { title: "Ürün & Stok Kartları | e-Fatura Portalı" },
      {
        name: "description",
        content:
          "Ürün kartlarını kod, barkod, alış/satış fiyatı, KDV ve kritik stok seviyesiyle yönetin.",
      },
      { property: "og:title", content: "Ürün & Stok Kartları | e-Fatura Portalı" },
      { property: "og:description", content: "Ürün kartlarınızı ve stok seviyelerinizi yönetin." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: ProductsPage,
});

const emptyProduct = {
  code: "",
  barcode: "",
  name: "",
  description: "",
  category: "",
  unit: "Adet",
  purchasePrice: "0",
  unitPrice: "0",
  vatRate: "20",
  discountRate: "0",
  minStock: "0",
};

const PRODUCT_COLUMNS = [
  { header: "Ürün Kodu", example: "U-001" },
  { header: "Barkod", example: "8690000000000" },
  { header: "Ad", aliases: ["urun", "hizmet"], example: "Danışmanlık Hizmeti" },
  { header: "Kategori", example: "Hizmet" },
  { header: "Birim", example: "Adet" },
  { header: "Alış Fiyatı", example: "1000" },
  { header: "Satış Fiyatı", aliases: ["birimfiyat", "fiyat"], example: "1500" },
  { header: "KDV %", example: "20" },
  { header: "İskonto %", example: "0" },
  { header: "Min. Stok", example: "5" },
];

type ImportedProduct = {
  code: string;
  barcode: string;
  name: string;
  category: string;
  unit: string;
  purchasePrice: number;
  unitPrice: number;
  vatRate: number;
  discountRate: number;
  minStock: number;
};

function ProductsPage() {
  const queryClient = useQueryClient();
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState("");
  const [form, setForm] = useState(emptyProduct);

  const { data: products = [], isLoading } = useQuery({
    queryKey: ["products"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("products")
        .select("*")
        .is("deleted_at", null)
        .order("created_at", { ascending: false });
      if (error && isMissingColumnError(error)) {
        const fallback = await supabase
          .from("products")
          .select("*")
          .order("created_at", { ascending: false });
        if (fallback.error) throw fallback.error;
        return fallback.data;
      }
      if (error) throw error;
      return data;
    },
  });

  const { data: stocks = [] } = useQuery({
    queryKey: ["product-stocks"],
    queryFn: async () => {
      const { data, error } = await supabase.from("product_stocks").select("*");
      if (error) throw error;
      return data;
    },
  });

  const stockMap = useMemo(() => {
    const map = new Map<string, number>();
    for (const s of stocks) if (s.product_id) map.set(s.product_id, Number(s.quantity ?? 0));
    return map;
  }, [stocks]);

  const visible = useMemo(() => {
    const q = search.trim().toLocaleLowerCase("tr");
    if (!q) return products;
    return products.filter((p) =>
      [p.name, p.code, p.barcode, p.category]
        .filter(Boolean)
        .some((v) => String(v).toLocaleLowerCase("tr").includes(q)),
    );
  }, [products, search]);

  const criticalCount = useMemo(
    () =>
      products.filter(
        (p) => Number(p.min_stock ?? 0) > 0 && (stockMap.get(p.id) ?? 0) <= Number(p.min_stock),
      ).length,
    [products, stockMap],
  );

  async function currentUserId() {
    const { data: userData } = await supabase.auth.getUser();
    const userId = userData.user?.id;
    if (!userId) throw new Error("Oturum bulunamadı.");
    return userId;
  }

  const createProduct = useMutation({
    mutationFn: async () => {
      const userId = await currentUserId();
      const { error } = await supabase.from("products").insert({
        user_id: userId,
        code: form.code,
        barcode: form.barcode,
        name: form.name,
        description: form.description,
        category: form.category,
        unit: form.unit,
        purchase_price: Number(form.purchasePrice) || 0,
        unit_price: Number(form.unitPrice) || 0,
        vat_rate: Number(form.vatRate) || 0,
        discount_rate: Number(form.discountRate) || 0,
        min_stock: Number(form.minStock) || 0,
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
      const userId = await currentUserId();
      await safeSoftDelete("products", id, userId);
    },
    onSuccess: () => {
      toast.success("Ürün silindi.");
      queryClient.invalidateQueries({ queryKey: ["products"] });
      queryClient.invalidateQueries({ queryKey: ["product-stocks"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  async function importProducts(rows: ImportedProduct[]) {
    const userId = await currentUserId();
    const { error } = await supabase.from("products").insert(
      rows.map((r) => ({
        user_id: userId,
        code: r.code,
        barcode: r.barcode,
        name: r.name,
        category: r.category,
        unit: r.unit,
        purchase_price: r.purchasePrice,
        unit_price: r.unitPrice,
        vat_rate: r.vatRate,
        discount_rate: r.discountRate,
        min_stock: r.minStock,
      })),
    );
    if (error) throw error;
    toast.success(`${rows.length} kalem içe aktarıldı.`);
    queryClient.invalidateQueries({ queryKey: ["products"] });
  }

  function exportProducts() {
    downloadWorkbook(
      [...PRODUCT_COLUMNS.map((c) => c.header), "Mevcut Stok"],
      visible.map((p) => [
        p.code ?? "",
        p.barcode ?? "",
        p.name,
        p.category ?? "",
        p.unit,
        Number(p.purchase_price ?? 0),
        Number(p.unit_price),
        Number(p.vat_rate),
        Number(p.discount_rate ?? 0),
        Number(p.min_stock ?? 0),
        stockMap.get(p.id) ?? 0,
      ]),
      `urunler-${new Date().toISOString().slice(0, 10)}.xlsx`,
      "Ürünler",
    );
  }

  const numberFields: { key: keyof typeof emptyProduct; label: string; step?: string }[] = [
    { key: "purchasePrice", label: "Alış Fiyatı", step: "0.01" },
    { key: "unitPrice", label: "Satış Fiyatı", step: "0.01" },
    { key: "vatRate", label: "KDV %", step: "1" },
    { key: "discountRate", label: "İskonto %", step: "0.01" },
    { key: "minStock", label: "Min. Stok", step: "0.01" },
  ];

  return (
    <AppShell
      title="Ürün & Stok Kartları"
      subtitle="Fiyat, KDV, barkod ve kritik stok bilgileriyle katalog"
      actions={
        <>
          <Button
            variant="ghost"
            className="gap-2"
            onClick={exportProducts}
            disabled={visible.length === 0}
          >
            <Download className="size-4" />
            Excel'e Aktar
          </Button>
          <ExcelImportDialog<ImportedProduct>
            title="Excel'den Ürün İçe Aktar"
            templateName="urun-sablonu.xlsx"
            columns={PRODUCT_COLUMNS}
            mapRow={(row: SheetRow) => {
              const name = pickColumn(row, [
                "Ad",
                "Ürün",
                "Hizmet",
                "Ürün / Hizmet Adı",
                "Açıklama",
                "Adı",
              ]).trim();
              const hasAnyData = Object.values(row).some((v) => v && v.trim());
              if (!hasAnyData) return null;
              if (!name) return { error: "Ürün veya hizmet adı boş olamaz." };
              return {
                data: {
                  name,
                  code: pickColumn(row, ["Ürün Kodu", "Kod"]),
                  barcode: pickColumn(row, ["Barkod"]),
                  category: pickColumn(row, ["Kategori"]),
                  unit: pickColumn(row, ["Birim"]) || "Adet",
                  purchasePrice: parseNumber(pickColumn(row, ["Alış Fiyatı", "Alis Fiyati"])),
                  unitPrice: parseNumber(pickColumn(row, ["Satış Fiyatı", "Birim Fiyat", "Fiyat"])),
                  vatRate: parseNumber(pickColumn(row, ["KDV %", "KDV", "KDV Oranı"])) || 20,
                  discountRate: parseNumber(pickColumn(row, ["İskonto %", "İskonto"])),
                  minStock: parseNumber(pickColumn(row, ["Min. Stok", "Minimum Stok"])),
                },
              };
            }}
            onImport={importProducts}
          />
          <Dialog open={open} onOpenChange={setOpen}>
            <DialogTrigger asChild>
              <Button>Yeni Kalem</Button>
            </DialogTrigger>
            <DialogContent className="max-h-[85vh] overflow-y-auto">
              <DialogHeader>
                <DialogTitle>Ürün / Hizmet Kartı</DialogTitle>
              </DialogHeader>
              <form
                className="space-y-4"
                onSubmit={(e) => {
                  e.preventDefault();
                  createProduct.mutate();
                }}
              >
                <div className="grid gap-3 sm:grid-cols-2">
                  <div className="space-y-2">
                    <Label htmlFor="code">Ürün Kodu</Label>
                    <Input
                      id="code"
                      value={form.code}
                      onChange={(e) => setForm({ ...form, code: e.target.value })}
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="barcode">Barkod</Label>
                    <Input
                      id="barcode"
                      value={form.barcode}
                      onChange={(e) => setForm({ ...form, barcode: e.target.value })}
                    />
                  </div>
                </div>
                <div className="space-y-2">
                  <Label htmlFor="name">Ürün / Hizmet Adı</Label>
                  <Input
                    id="name"
                    required
                    value={form.name}
                    onChange={(e) => setForm({ ...form, name: e.target.value })}
                  />
                </div>
                <div className="grid gap-3 sm:grid-cols-3">
                  <div className="space-y-2">
                    <Label htmlFor="category">Kategori</Label>
                    <Input
                      id="category"
                      value={form.category}
                      onChange={(e) => setForm({ ...form, category: e.target.value })}
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="unit">Birim</Label>
                    <Input
                      id="unit"
                      value={form.unit}
                      onChange={(e) => setForm({ ...form, unit: e.target.value })}
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="description">Açıklama</Label>
                    <Input
                      id="description"
                      value={form.description}
                      onChange={(e) => setForm({ ...form, description: e.target.value })}
                    />
                  </div>
                </div>
                <div className="grid grid-cols-2 gap-3 sm:grid-cols-5">
                  {numberFields.map((f) => (
                    <div key={f.key} className="space-y-2">
                      <Label htmlFor={f.key}>{f.label}</Label>
                      <Input
                        id={f.key}
                        type="number"
                        step={f.step}
                        value={form[f.key]}
                        onChange={(e) => setForm({ ...form, [f.key]: e.target.value })}
                      />
                    </div>
                  ))}
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
      {criticalCount > 0 ? (
        <div className="mb-4 rounded-lg border border-destructive/40 bg-destructive/5 px-4 py-3 text-sm">
          <span className="font-medium">{criticalCount} üründe kritik stok seviyesi.</span>{" "}
          <span className="text-muted-foreground">
            Stok Yönetimi ekranından giriş yapabilirsiniz.
          </span>
        </div>
      ) : null}

      <Card>
        <CardHeader>
          <div className="flex flex-wrap items-center justify-between gap-3">
            <CardTitle className="text-base">Katalog ({visible.length})</CardTitle>
            <Input
              placeholder="Ara: ad, kod, barkod, kategori…"
              className="w-full sm:w-72"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
            />
          </div>
        </CardHeader>
        <CardContent>
          {isLoading ? (
            <p className="text-sm text-muted-foreground">Yükleniyor…</p>
          ) : visible.length === 0 ? (
            <p className="text-sm text-muted-foreground">Henüz kayıt yok.</p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground">
                    <th className="py-2 pr-4">Kod / Barkod</th>
                    <th className="py-2 pr-4">Ad</th>
                    <th className="py-2 pr-4">Kategori</th>
                    <th className="py-2 pr-4">Birim</th>
                    <th className="py-2 pr-4 text-right">Alış</th>
                    <th className="py-2 pr-4 text-right">Satış</th>
                    <th className="py-2 pr-4">KDV</th>
                    <th className="py-2 pr-4 text-right">Stok</th>
                    <th className="py-2" />
                  </tr>
                </thead>
                <tbody>
                  {visible.map((p) => {
                    const stock = stockMap.get(p.id) ?? 0;
                    const critical = Number(p.min_stock ?? 0) > 0 && stock <= Number(p.min_stock);
                    return (
                      <tr key={p.id} className="border-b border-border/60 last:border-0">
                        <td className="py-3 pr-4">
                          <div>{p.code || "-"}</div>
                          <div className="text-xs text-muted-foreground">{p.barcode || ""}</div>
                        </td>
                        <td className="py-3 pr-4 font-medium">{p.name}</td>
                        <td className="py-3 pr-4">{p.category || "-"}</td>
                        <td className="py-3 pr-4">{p.unit}</td>
                        <td className="py-3 pr-4 text-right">
                          {formatMoney(Number(p.purchase_price ?? 0))}
                        </td>
                        <td className="py-3 pr-4 text-right">
                          {formatMoney(Number(p.unit_price))}
                        </td>
                        <td className="py-3 pr-4">%{Number(p.vat_rate)}</td>
                        <td className="py-3 pr-4 text-right">
                          <span className="font-medium">{stock}</span>
                          {critical ? (
                            <Badge variant="destructive" className="ml-2">
                              Kritik
                            </Badge>
                          ) : null}
                        </td>
                        <td className="py-3 text-right">
                          <Button
                            variant="ghost"
                            size="sm"
                            onClick={() => removeProduct.mutate(p.id)}
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
    </AppShell>
  );
}
