import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import { Download, Copy, Pencil, Plus, Layers, Briefcase, Package } from "lucide-react";
import { toast } from "sonner";

import { AppShell } from "@/components/AppShell";
import { ExcelImportDialog } from "@/components/ExcelImportDialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
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
      { title: "Ürün & Hizmet Yönetimi | e-Fatura Portalı" },
      {
        name: "description",
        content:
          "Ürün ve hizmet kartlarını kod, barkod, alış/satış fiyatı, KDV ve kritik stok seviyesiyle yönetin ve güncelleyin.",
      },
      { property: "og:title", content: "Ürün & Hizmet Yönetimi | e-Fatura Portalı" },
      { property: "og:description", content: "Ürün ve hizmet kartlarınızı yönetin ve güncelleyin." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: ProductsPage,
});

const emptyProduct = {
  id: "",
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
  trackStock: true,
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
  const [activeTab, setActiveTab] = useState<"ALL" | "PRODUCTS" | "SERVICES">("ALL");
  const [form, setForm] = useState(emptyProduct);

  // Edit Product State
  const [editOpen, setEditOpen] = useState(false);
  const [editForm, setEditForm] = useState(emptyProduct);

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
    let list = products;
    if (activeTab === "PRODUCTS") {
      list = list.filter((p) => (p.category ?? "").toLocaleLowerCase("tr") !== "hizmet" && p.track_stock !== false);
    } else if (activeTab === "SERVICES") {
      list = list.filter((p) => (p.category ?? "").toLocaleLowerCase("tr") === "hizmet" || p.track_stock === false);
    }

    const q = search.trim().toLocaleLowerCase("tr");
    if (!q) return list;
    return list.filter((p) =>
      [p.name, p.code, p.barcode, p.category]
        .filter(Boolean)
        .some((v) => String(v).toLocaleLowerCase("tr").includes(q)),
    );
  }, [products, search, activeTab]);

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
      if (!form.name.trim()) throw new Error("Ürün veya hizmet adı boş olamaz.");
      const userId = await currentUserId();
      const isService = form.category?.toLowerCase() === "hizmet" || !form.trackStock;
      const { error } = await supabase.from("products").insert({
        user_id: userId,
        code: form.code.trim(),
        barcode: form.barcode.trim(),
        name: form.name.trim(),
        description: form.description,
        category: form.category || (isService ? "Hizmet" : "Genel"),
        unit: form.unit || (isService ? "Saat" : "Adet"),
        purchase_price: Number(form.purchasePrice) || 0,
        unit_price: Number(form.unitPrice) || 0,
        vat_rate: Number(form.vatRate) || 0,
        discount_rate: Number(form.discountRate) || 0,
        min_stock: isService ? 0 : Number(form.minStock) || 0,
        track_stock: !isService,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Ürün/hizmet başarıyla eklendi.");
      setForm(emptyProduct);
      setOpen(false);
      queryClient.invalidateQueries({ queryKey: ["products"] });
      queryClient.invalidateQueries({ queryKey: ["product-stocks"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const updateProduct = useMutation({
    mutationFn: async () => {
      if (!editForm.id) throw new Error("Güncellenecek ürün kimliği bulunamadı.");
      if (!editForm.name.trim()) throw new Error("Ürün veya hizmet adı boş olamaz.");
      const userId = await currentUserId();
      const isService = editForm.category?.toLowerCase() === "hizmet" || !editForm.trackStock;

      const { error } = await supabase
        .from("products")
        .update({
          code: editForm.code.trim(),
          barcode: editForm.barcode.trim(),
          name: editForm.name.trim(),
          description: editForm.description,
          category: editForm.category,
          unit: editForm.unit,
          purchase_price: Number(editForm.purchasePrice) || 0,
          unit_price: Number(editForm.unitPrice) || 0,
          vat_rate: Number(editForm.vatRate) || 0,
          discount_rate: Number(editForm.discountRate) || 0,
          min_stock: isService ? 0 : Number(editForm.minStock) || 0,
          track_stock: !isService,
          updated_at: new Date().toISOString(),
        })
        .eq("id", editForm.id)
        .eq("user_id", userId);

      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Ürün / Hizmet kartı başarıyla güncellendi.");
      setEditOpen(false);
      queryClient.invalidateQueries({ queryKey: ["products"] });
      queryClient.invalidateQueries({ queryKey: ["product-stocks"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  function handleOpenEditModal(p: any) {
    setEditForm({
      id: p.id,
      code: p.code || "",
      barcode: p.barcode || "",
      name: p.name || "",
      description: p.description || "",
      category: p.category || "",
      unit: p.unit || "Adet",
      purchasePrice: String(p.purchase_price ?? 0),
      unitPrice: String(p.unit_price ?? 0),
      vatRate: String(p.vat_rate ?? 20),
      discountRate: String(p.discount_rate ?? 0),
      minStock: String(p.min_stock ?? 0),
      trackStock: p.track_stock !== false,
    });
    setEditOpen(true);
  }

  const [copyOpen, setCopyOpen] = useState(false);
  const [copyForm, setCopyForm] = useState(emptyProduct);

  function handleOpenCopyModal(p: any) {
    setCopyForm({
      id: "",
      code: p.code ? `${p.code}-KOPYA` : "",
      barcode: "",
      name: `${p.name} - Kopyası`,
      description: p.description || "",
      category: p.category || "",
      unit: p.unit || "Adet",
      purchasePrice: String(p.purchase_price ?? 0),
      unitPrice: String(p.unit_price ?? 0),
      vatRate: String(p.vat_rate ?? 20),
      discountRate: String(p.discount_rate ?? 0),
      minStock: String(p.min_stock ?? 0),
      trackStock: p.track_stock !== false,
    });
    setCopyOpen(true);
  }

  const duplicateProduct = useMutation({
    mutationFn: async () => {
      if (!copyForm.name.trim()) throw new Error("Ürün adı boş olamaz.");
      const userId = await currentUserId();
      const isService = copyForm.category?.toLowerCase() === "hizmet" || !copyForm.trackStock;
      const { error } = await supabase.from("products").insert({
        user_id: userId,
        code: copyForm.code.trim(),
        barcode: copyForm.barcode.trim(),
        name: copyForm.name.trim(),
        description: copyForm.description,
        category: copyForm.category,
        unit: copyForm.unit,
        purchase_price: Number(copyForm.purchasePrice) || 0,
        unit_price: Number(copyForm.unitPrice) || 0,
        vat_rate: Number(copyForm.vatRate) || 0,
        discount_rate: Number(copyForm.discountRate) || 0,
        min_stock: isService ? 0 : Number(copyForm.minStock) || 0,
        track_stock: !isService,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Yeni kart kopyalanarak oluşturuldu.");
      setCopyOpen(false);
      queryClient.invalidateQueries({ queryKey: ["products"] });
      queryClient.invalidateQueries({ queryKey: ["product-stocks"] });
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
        track_stock: r.category?.toLowerCase() !== "hizmet",
      })),
    );
    if (error) throw error;
    queryClient.invalidateQueries({ queryKey: ["products"] });
  }

  function exportProducts() {
    if (!products.length) {
      toast.error("Dışa aktarılacak ürün bulunamadı.");
      return;
    }
    const headers = [
      "Ürün Kodu",
      "Barkod",
      "Ad",
      "Kategori",
      "Birim",
      "Alış Fiyatı",
      "Satış Fiyatı",
      "KDV %",
      "İskonto %",
      "Min. Stok",
      "Mevcut Stok",
      "Açıklama",
    ];
    const rows = products.map((p) => [
      p.code || "",
      p.barcode || "",
      p.name,
      p.category || "",
      p.unit,
      Number(p.purchase_price ?? 0),
      Number(p.unit_price),
      Number(p.vat_rate),
      Number(p.discount_rate ?? 0),
      Number(p.min_stock ?? 0),
      stockMap.get(p.id) ?? 0,
      p.description || "",
    ]);
    downloadWorkbook(headers, rows, "urunler_listesi", "Ürünler");
    toast.success("Excel dosyası indirildi.");
  }

  return (
    <AppShell
      title="Ürün & Hizmet Yönetimi"
      subtitle="Fiyat, KDV, stok seviyeleri ve hizmet kartlarınızı tek panelden yönetin ve güncelleyin."
    >
      <div className="grid gap-4 md:grid-cols-3">
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">
              Toplam Kart Sayısı
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{products.length}</div>
            <p className="text-xs text-muted-foreground mt-1">Tanımlı ürün ve hizmetler</p>
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">
              Kritik Stok Uyarısı
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className={`text-2xl font-bold ${criticalCount > 0 ? "text-destructive" : ""}`}>
              {criticalCount}
            </div>
            <p className="text-xs text-muted-foreground mt-1">Asgari seviyenin altındaki ürünler</p>
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">
              Hizmet Kartları
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">
              {products.filter((p) => (p.category ?? "").toLocaleLowerCase("tr") === "hizmet" || p.track_stock === false).length}
            </div>
            <p className="text-xs text-muted-foreground mt-1">Stoksuz hizmetler</p>
          </CardContent>
        </Card>
      </div>

      <Card>
        <CardHeader className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
          <div>
            <CardTitle>Kart Listesi</CardTitle>
            <Tabs
              value={activeTab}
              onValueChange={(v) => setActiveTab(v as any)}
              className="mt-2"
            >
              <TabsList className="h-8">
                <TabsTrigger value="ALL" className="text-xs gap-1.5 px-3">
                  <Layers className="size-3.5" /> Tümü ({products.length})
                </TabsTrigger>
                <TabsTrigger value="PRODUCTS" className="text-xs gap-1.5 px-3">
                  <Package className="size-3.5" /> Ürünler ({products.filter((p) => (p.category ?? "").toLocaleLowerCase("tr") !== "hizmet" && p.track_stock !== false).length})
                </TabsTrigger>
                <TabsTrigger value="SERVICES" className="text-xs gap-1.5 px-3">
                  <Briefcase className="size-3.5" /> Hizmetler ({products.filter((p) => (p.category ?? "").toLocaleLowerCase("tr") === "hizmet" || p.track_stock === false).length})
                </TabsTrigger>
              </TabsList>
            </Tabs>
          </div>
          <div className="flex flex-wrap gap-2">
            <Button variant="outline" size="sm" onClick={exportProducts} className="gap-2 text-xs">
              <Download className="size-4" /> Excel'e Aktar
            </Button>
            <ExcelImportDialog<ImportedProduct>
              title="Excel'den Ürün & Hizmet İçe Aktar"
              columns={PRODUCT_COLUMNS}
              templateName="urun-sablonu.xlsx"
              mapRow={(row: SheetRow) => {
                const name = pickColumn(row, ["Ad", "Ürün Adı", "Hizmet Adı", "urun", "hizmet"]);
                if (!name) return { error: "Ürün veya hizmet adı boş olamaz." };
                return {
                  data: {
                    code: pickColumn(row, ["Ürün Kodu", "Kod", "kod"]) || "",
                    barcode: pickColumn(row, ["Barkod", "barkod"]) || "",
                    name,
                    category: pickColumn(row, ["Kategori", "kategori"]) || "",
                    unit: pickColumn(row, ["Birim", "birim"]) || "Adet",
                    purchasePrice: parseNumber(pickColumn(row, ["Alış Fiyatı", "Alış"]), 0),
                    unitPrice: parseNumber(
                      pickColumn(row, ["Satış Fiyatı", "Birim Fiyat", "Fiyat"]),
                      0,
                    ),
                    vatRate: parseNumber(pickColumn(row, ["KDV %", "KDV", "Kdv"]), 20),
                    discountRate: parseNumber(pickColumn(row, ["İskonto %", "İskonto"]), 0),
                    minStock: parseNumber(pickColumn(row, ["Min. Stok", "Asgari Stok"]), 0),
                  },
                };
              }}
              onImport={importProducts}
            />

            {/* YENİ ÜRÜN / HİZMET EKLE MODALI */}
            <Dialog open={open} onOpenChange={setOpen}>
              <DialogTrigger asChild>
                <Button size="sm" className="gap-2 text-xs">
                  <Plus className="size-4" /> Yeni Kart Ekle
                </Button>
              </DialogTrigger>
              <DialogContent className="max-h-[85vh] overflow-y-auto">
                <DialogHeader>
                  <DialogTitle>Yeni Ürün / Hizmet Kartı</DialogTitle>
                </DialogHeader>
                <form
                  onSubmit={(e) => {
                    e.preventDefault();
                    createProduct.mutate();
                  }}
                  className="space-y-4 pt-2"
                >
                  <div className="grid grid-cols-2 gap-4">
                    <div>
                      <Label htmlFor="code">Ürün / Hizmet Kodu</Label>
                      <Input
                        id="code"
                        placeholder="Örn: U-001 veya H-01"
                        value={form.code}
                        onChange={(e) => setForm({ ...form, code: e.target.value })}
                      />
                    </div>
                    <div>
                      <Label htmlFor="barcode">Barkod</Label>
                      <Input
                        id="barcode"
                        placeholder="8690000000000"
                        value={form.barcode}
                        onChange={(e) => setForm({ ...form, barcode: e.target.value })}
                      />
                    </div>
                  </div>

                  <div>
                    <Label htmlFor="name">Ürün / Hizmet Adı *</Label>
                    <Input
                      id="name"
                      required
                      placeholder="Örn: Web Yazılım Danışmanlığı"
                      value={form.name}
                      onChange={(e) => setForm({ ...form, name: e.target.value })}
                    />
                  </div>

                  <div className="grid grid-cols-2 gap-4">
                    <div>
                      <Label htmlFor="category">Kategori</Label>
                      <Input
                        id="category"
                        placeholder="Örn: Hizmet, Elektronik, Gıda"
                        value={form.category}
                        onChange={(e) => setForm({ ...form, category: e.target.value })}
                      />
                    </div>
                    <div>
                      <Label htmlFor="unit">Birim</Label>
                      <Input
                        id="unit"
                        placeholder="Adet, Saat, Kg vb."
                        value={form.unit}
                        onChange={(e) => setForm({ ...form, unit: e.target.value })}
                      />
                    </div>
                  </div>

                  <div className="grid grid-cols-2 gap-4">
                    <div>
                      <Label htmlFor="purchasePrice">Birim Alış Fiyatı (TL)</Label>
                      <Input
                        id="purchasePrice"
                        type="number"
                        step="0.01"
                        value={form.purchasePrice}
                        onChange={(e) => setForm({ ...form, purchasePrice: e.target.value })}
                      />
                    </div>
                    <div>
                      <Label htmlFor="unitPrice">Birim Satış Fiyatı (TL) *</Label>
                      <Input
                        id="unitPrice"
                        type="number"
                        step="0.01"
                        required
                        value={form.unitPrice}
                        onChange={(e) => setForm({ ...form, unitPrice: e.target.value })}
                      />
                    </div>
                  </div>

                  <div className="grid grid-cols-3 gap-4">
                    <div>
                      <Label htmlFor="vatRate">KDV Oranı (%)</Label>
                      <Input
                        id="vatRate"
                        type="number"
                        value={form.vatRate}
                        onChange={(e) => setForm({ ...form, vatRate: e.target.value })}
                      />
                    </div>
                    <div>
                      <Label htmlFor="discountRate">Varsayılan İskonto (%)</Label>
                      <Input
                        id="discountRate"
                        type="number"
                        value={form.discountRate}
                        onChange={(e) => setForm({ ...form, discountRate: e.target.value })}
                      />
                    </div>
                    <div>
                      <Label htmlFor="minStock">Asgari Stok Seviyesi</Label>
                      <Input
                        id="minStock"
                        type="number"
                        value={form.minStock}
                        onChange={(e) => setForm({ ...form, minStock: e.target.value })}
                      />
                    </div>
                  </div>

                  <div>
                    <Label htmlFor="description">Açıklama</Label>
                    <Input
                      id="description"
                      placeholder="Kart detayları veya notlar"
                      value={form.description}
                      onChange={(e) => setForm({ ...form, description: e.target.value })}
                    />
                  </div>

                  <Button type="submit" className="w-full" disabled={createProduct.isPending}>
                    {createProduct.isPending ? "Kaydediliyor…" : "Kaydet"}
                  </Button>
                </form>
              </DialogContent>
            </Dialog>
          </div>
        </CardHeader>

        <CardContent className="space-y-4">
          <Input
            placeholder="Kart adı, kod, barkod veya kategori ile ara…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />

          {isLoading ? (
            <div className="py-8 text-center text-muted-foreground">Yükleniyor…</div>
          ) : visible.length === 0 ? (
            <div className="py-8 text-center text-muted-foreground">
              {search ? "Aramaya uygun kart bulunamadı." : "Henüz ürün veya hizmet eklenmemiş."}
            </div>
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
                    <th className="py-2 text-right">İşlemler</th>
                  </tr>
                </thead>
                <tbody>
                  {visible.map((p) => {
                    const isService = (p.category ?? "").toLocaleLowerCase("tr") === "hizmet" || p.track_stock === false;
                    const stock = stockMap.get(p.id) ?? 0;
                    const critical = !isService && Number(p.min_stock ?? 0) > 0 && stock <= Number(p.min_stock);
                    return (
                      <tr key={p.id} className="border-b border-border/60 hover:bg-muted/30 last:border-0">
                        <td className="py-3 pr-4">
                          <div className="font-mono">{p.code || "-"}</div>
                          <div className="text-xs text-muted-foreground font-mono">{p.barcode || ""}</div>
                        </td>
                        <td className="py-3 pr-4 font-medium">
                          <div className="flex items-center gap-1.5">
                            {p.name}
                            {isService && (
                              <Badge variant="secondary" className="text-[10px] py-0 px-1.5">Hizmet</Badge>
                            )}
                          </div>
                        </td>
                        <td className="py-3 pr-4 text-muted-foreground">{p.category || "-"}</td>
                        <td className="py-3 pr-4">{p.unit}</td>
                        <td className="py-3 pr-4 text-right">
                          {formatMoney(Number(p.purchase_price ?? 0))}
                        </td>
                        <td className="py-3 pr-4 text-right font-medium">
                          {formatMoney(Number(p.unit_price))}
                        </td>
                        <td className="py-3 pr-4">%{Number(p.vat_rate)}</td>
                        <td className="py-3 pr-4 text-right">
                          {isService ? (
                            <span className="text-xs text-muted-foreground">Stoksuz</span>
                          ) : (
                            <>
                              <span className="font-medium">{stock}</span>
                              {critical ? (
                                <Badge variant="destructive" className="ml-2 text-[10px] py-0">
                                  Kritik
                                </Badge>
                              ) : null}
                            </>
                          )}
                        </td>
                        <td className="py-3 text-right space-x-1 whitespace-nowrap">
                          {/* GÜNCELLE BUTONU */}
                          <Button
                            variant="outline"
                            size="sm"
                            title="Kartı Güncelle"
                            className="gap-1 text-xs h-7 px-2"
                            onClick={() => handleOpenEditModal(p)}
                          >
                            <Pencil className="size-3 text-primary" /> Güncelle
                          </Button>
                          <Button
                            variant="ghost"
                            size="sm"
                            title="Kartı Kopyala"
                            className="gap-1 text-xs h-7 px-2"
                            onClick={() => handleOpenCopyModal(p)}
                          >
                            <Copy className="size-3" /> Kopyala
                          </Button>
                          <Button
                            variant="ghost"
                            size="sm"
                            className="text-destructive text-xs h-7 px-2 hover:bg-destructive/10"
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

      {/* GÜNCELLEME (EDIT) MODALI */}
      <Dialog open={editOpen} onOpenChange={setEditOpen}>
        <DialogContent className="max-h-[85vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2">
              <Pencil className="size-4 text-primary" /> Ürün / Hizmet Kartını Güncelle
            </DialogTitle>
          </DialogHeader>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              updateProduct.mutate();
            }}
            className="space-y-4 pt-2"
          >
            <div className="grid grid-cols-2 gap-4">
              <div>
                <Label htmlFor="edit-code">Ürün / Hizmet Kodu</Label>
                <Input
                  id="edit-code"
                  placeholder="Örn: U-001"
                  value={editForm.code}
                  onChange={(e) => setEditForm({ ...editForm, code: e.target.value })}
                />
              </div>
              <div>
                <Label htmlFor="edit-barcode">Barkod</Label>
                <Input
                  id="edit-barcode"
                  placeholder="8690000000000"
                  value={editForm.barcode}
                  onChange={(e) => setEditForm({ ...editForm, barcode: e.target.value })}
                />
              </div>
            </div>

            <div>
              <Label htmlFor="edit-name">Ürün / Hizmet Adı *</Label>
              <Input
                id="edit-name"
                required
                value={editForm.name}
                onChange={(e) => setEditForm({ ...editForm, name: e.target.value })}
              />
            </div>

            <div className="grid grid-cols-2 gap-4">
              <div>
                <Label htmlFor="edit-category">Kategori</Label>
                <Input
                  id="edit-category"
                  placeholder="Hizmet, Elektronik vb."
                  value={editForm.category}
                  onChange={(e) => setEditForm({ ...editForm, category: e.target.value })}
                />
              </div>
              <div>
                <Label htmlFor="edit-unit">Birim</Label>
                <Input
                  id="edit-unit"
                  value={editForm.unit}
                  onChange={(e) => setEditForm({ ...editForm, unit: e.target.value })}
                />
              </div>
            </div>

            <div className="grid grid-cols-2 gap-4">
              <div>
                <Label htmlFor="edit-purchasePrice">Birim Alış Fiyatı (TL)</Label>
                <Input
                  id="edit-purchasePrice"
                  type="number"
                  step="0.01"
                  value={editForm.purchasePrice}
                  onChange={(e) => setEditForm({ ...editForm, purchasePrice: e.target.value })}
                />
              </div>
              <div>
                <Label htmlFor="edit-unitPrice">Birim Satış Fiyatı (TL) *</Label>
                <Input
                  id="edit-unitPrice"
                  type="number"
                  step="0.01"
                  required
                  value={editForm.unitPrice}
                  onChange={(e) => setEditForm({ ...editForm, unitPrice: e.target.value })}
                />
              </div>
            </div>

            <div className="grid grid-cols-3 gap-4">
              <div>
                <Label htmlFor="edit-vatRate">KDV Oranı (%)</Label>
                <Input
                  id="edit-vatRate"
                  type="number"
                  value={editForm.vatRate}
                  onChange={(e) => setEditForm({ ...editForm, vatRate: e.target.value })}
                />
              </div>
              <div>
                <Label htmlFor="edit-discountRate">İskonto (%)</Label>
                <Input
                  id="edit-discountRate"
                  type="number"
                  value={editForm.discountRate}
                  onChange={(e) => setEditForm({ ...editForm, discountRate: e.target.value })}
                />
              </div>
              <div>
                <Label htmlFor="edit-minStock">Asgari Stok Seviyesi</Label>
                <Input
                  id="edit-minStock"
                  type="number"
                  value={editForm.minStock}
                  onChange={(e) => setEditForm({ ...editForm, minStock: e.target.value })}
                />
              </div>
            </div>

            <div>
              <Label htmlFor="edit-description">Açıklama</Label>
              <Input
                id="edit-description"
                placeholder="Kart detayları veya notlar"
                value={editForm.description}
                onChange={(e) => setEditForm({ ...editForm, description: e.target.value })}
              />
            </div>

            <div className="flex gap-2 pt-2">
              <Button type="button" variant="outline" className="flex-1" onClick={() => setEditOpen(false)}>
                İptal
              </Button>
              <Button type="submit" className="flex-1" disabled={updateProduct.isPending}>
                {updateProduct.isPending ? "Güncelleniyor…" : "Değişiklikleri Kaydet"}
              </Button>
            </div>
          </form>
        </DialogContent>
      </Dialog>

      {/* STOK KARTI KOPYALAMA MODALI */}
      <Dialog open={copyOpen} onOpenChange={setCopyOpen}>
        <DialogContent className="max-h-[85vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2">
              <Copy className="size-4 text-primary" /> Stok Kartı Kopyala
            </DialogTitle>
          </DialogHeader>
          <div className="p-3 bg-muted/60 rounded-md text-xs space-y-1 text-muted-foreground border border-border/60 mb-2">
            <p className="font-semibold text-foreground">Kopyalama Bilgisi</p>
            <p>
              Mevcut kartın tüm birim, KDV ve fiyat bilgileri şablon olarak alındı. Yeni kart için
              farklı bir isim ve kod belirleyerek kaydedebilirsiniz.
            </p>
          </div>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              duplicateProduct.mutate();
            }}
            className="space-y-4 pt-2"
          >
            <div className="grid grid-cols-2 gap-4">
              <div>
                <Label htmlFor="copy-code">Yeni Ürün Kodu</Label>
                <Input
                  id="copy-code"
                  placeholder="Örn: U-002"
                  value={copyForm.code}
                  onChange={(e) => setCopyForm({ ...copyForm, code: e.target.value })}
                />
              </div>
              <div>
                <Label htmlFor="copy-barcode">Yeni Barkod (Opsiyonel)</Label>
                <Input
                  id="copy-barcode"
                  placeholder="Yeni barkod girin"
                  value={copyForm.barcode}
                  onChange={(e) => setCopyForm({ ...copyForm, barcode: e.target.value })}
                />
              </div>
            </div>

            <div>
              <Label htmlFor="copy-name">Ürün / Hizmet Adı *</Label>
              <Input
                id="copy-name"
                required
                value={copyForm.name}
                onChange={(e) => setCopyForm({ ...copyForm, name: e.target.value })}
              />
            </div>

            <div className="grid grid-cols-2 gap-4">
              <div>
                <Label htmlFor="copy-category">Kategori</Label>
                <Input
                  id="copy-category"
                  value={copyForm.category}
                  onChange={(e) => setCopyForm({ ...copyForm, category: e.target.value })}
                />
              </div>
              <div>
                <Label htmlFor="copy-unit">Birim</Label>
                <Input
                  id="copy-unit"
                  value={copyForm.unit}
                  onChange={(e) => setCopyForm({ ...copyForm, unit: e.target.value })}
                />
              </div>
            </div>

            <div className="grid grid-cols-2 gap-4">
              <div>
                <Label htmlFor="copy-purchasePrice">Birim Alış Fiyatı (TL)</Label>
                <Input
                  id="copy-purchasePrice"
                  type="number"
                  step="0.01"
                  value={copyForm.purchasePrice}
                  onChange={(e) => setCopyForm({ ...copyForm, purchasePrice: e.target.value })}
                />
              </div>
              <div>
                <Label htmlFor="copy-unitPrice">Birim Satış Fiyatı (TL) *</Label>
                <Input
                  id="copy-unitPrice"
                  type="number"
                  step="0.01"
                  required
                  value={copyForm.unitPrice}
                  onChange={(e) => setCopyForm({ ...copyForm, unitPrice: e.target.value })}
                />
              </div>
            </div>

            <div className="grid grid-cols-3 gap-4">
              <div>
                <Label htmlFor="copy-vatRate">KDV Oranı (%)</Label>
                <Input
                  id="copy-vatRate"
                  type="number"
                  value={copyForm.vatRate}
                  onChange={(e) => setCopyForm({ ...copyForm, vatRate: e.target.value })}
                />
              </div>
              <div>
                <Label htmlFor="copy-discountRate">İskonto (%)</Label>
                <Input
                  id="copy-discountRate"
                  type="number"
                  value={copyForm.discountRate}
                  onChange={(e) => setCopyForm({ ...copyForm, discountRate: e.target.value })}
                />
              </div>
              <div>
                <Label htmlFor="copy-minStock">Asgari Stok</Label>
                <Input
                  id="copy-minStock"
                  type="number"
                  value={copyForm.minStock}
                  onChange={(e) => setCopyForm({ ...copyForm, minStock: e.target.value })}
                />
              </div>
            </div>

            <div>
              <Label htmlFor="copy-description">Açıklama</Label>
              <Input
                id="copy-description"
                value={copyForm.description}
                onChange={(e) => setCopyForm({ ...copyForm, description: e.target.value })}
              />
            </div>

            <div className="flex gap-2 pt-2">
              <Button type="button" variant="outline" className="flex-1" onClick={() => setCopyOpen(false)}>
                İptal
              </Button>
              <Button type="submit" className="flex-1" disabled={duplicateProduct.isPending}>
                {duplicateProduct.isPending ? "Oluşturuluyor…" : "Kopyayı Oluştur"}
              </Button>
            </div>
          </form>
        </DialogContent>
      </Dialog>
    </AppShell>
  );
}
