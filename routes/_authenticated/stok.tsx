import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import { Download } from "lucide-react";
import { toast } from "sonner";

import { AppShell } from "@/components/AppShell";
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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { supabase } from "@/integrations/supabase/client";
import { downloadWorkbook } from "@/lib/excel";
import { formatDate, formatMoney } from "@/lib/invoice";
import { STOCK_LABELS, addDaysISO, today, type StockMovementType } from "@/lib/cari";

export const Route = createFileRoute("/_authenticated/stok")({
  head: () => ({
    meta: [
      { title: "Stok Yönetimi | e-Fatura Portalı" },
      {
        name: "description",
        content:
          "Depo tanımlayın, stok giriş-çıkış ve transfer hareketlerini kaydedin, kritik stokları izleyin.",
      },
      { property: "og:title", content: "Stok Yönetimi | e-Fatura Portalı" },
      { property: "og:description", content: "Depo, stok hareketi ve kritik stok takibi." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: StockPage,
});

const emptyMovement = {
  productId: "",
  warehouseId: "",
  targetWarehouseId: "",
  movementType: "GIRIS" as StockMovementType,
  quantity: "",
  unitPrice: "0",
  movementDate: today(),
  documentNo: "",
  description: "",
};

function StockPage() {
  const queryClient = useQueryClient();
  const [movementOpen, setMovementOpen] = useState(false);
  const [warehouseOpen, setWarehouseOpen] = useState(false);
  const [form, setForm] = useState(emptyMovement);
  const [warehouseForm, setWarehouseForm] = useState({ name: "", address: "" });
  const [filters, setFilters] = useState({
    productId: "ALL",
    from: addDaysISO(today(), -90),
    to: today(),
  });

  const { data: products = [] } = useQuery({
    queryKey: ["products", "stock"],
    queryFn: async () => {
      const { data, error } = await supabase.from("products").select("*").order("name");
      if (error) throw error;
      return data;
    },
  });

  const { data: warehouses = [] } = useQuery({
    queryKey: ["warehouses"],
    queryFn: async () => {
      const { data, error } = await supabase.from("warehouses").select("*").order("created_at");
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

  const { data: movements = [], isLoading } = useQuery({
    queryKey: ["stock-movements", filters],
    queryFn: async () => {
      let query = supabase
        .from("stock_movements")
        .select("*")
        .gte("movement_date", filters.from)
        .lte("movement_date", filters.to)
        .order("movement_date", { ascending: false })
        .order("created_at", { ascending: false });
      if (filters.productId !== "ALL") query = query.eq("product_id", filters.productId);
      const { data, error } = await query;
      if (error) throw error;
      return data;
    },
  });

  const productMap = useMemo(() => new Map(products.map((p) => [p.id, p])), [products]);
  const warehouseMap = useMemo(() => new Map(warehouses.map((w) => [w.id, w])), [warehouses]);
  const stockMap = useMemo(() => {
    const map = new Map<string, number>();
    for (const s of stocks) if (s.product_id) map.set(s.product_id, Number(s.quantity ?? 0));
    return map;
  }, [stocks]);

  const critical = useMemo(
    () =>
      products.filter(
        (p) => Number(p.min_stock ?? 0) > 0 && (stockMap.get(p.id) ?? 0) <= Number(p.min_stock),
      ),
    [products, stockMap],
  );

  async function currentUserId() {
    const { data } = await supabase.auth.getUser();
    const id = data.user?.id;
    if (!id) throw new Error("Oturum bulunamadı.");
    return id;
  }

  function refresh() {
    queryClient.invalidateQueries({ queryKey: ["stock-movements"] });
    queryClient.invalidateQueries({ queryKey: ["product-stocks"] });
  }

  const addWarehouse = useMutation({
    mutationFn: async () => {
      const userId = await currentUserId();
      const { error } = await supabase.from("warehouses").insert({
        user_id: userId,
        name: warehouseForm.name,
        address: warehouseForm.address,
        is_default: warehouses.length === 0,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Depo eklendi.");
      setWarehouseForm({ name: "", address: "" });
      setWarehouseOpen(false);
      queryClient.invalidateQueries({ queryKey: ["warehouses"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const removeWarehouse = useMutation({
    mutationFn: async (id: string) => {
      const { data: userData } = await supabase.auth.getUser();
      const userId = userData.user?.id;
      const { error } = await supabase
        .from("warehouses")
        .update({
          deleted_at: new Date().toISOString(),
          deleted_by: userId || null,
        })
        .eq("id", id);
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Depo silindi (Çöp Kutusuna taşındı).");
      queryClient.invalidateQueries({ queryKey: ["warehouses"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const addMovement = useMutation({
    mutationFn: async () => {
      const quantity = Number(form.quantity);
      if (!form.productId) throw new Error("Ürün seçin.");
      if (!quantity || quantity <= 0) throw new Error("Geçerli bir miktar girin.");
      const userId = await currentUserId();

      // Transfer, kaynak depodan çıkış + hedef depoya giriş olarak iki hareket yazar.
      if (form.movementType === "TRANSFER") {
        if (
          !form.warehouseId ||
          !form.targetWarehouseId ||
          form.warehouseId === form.targetWarehouseId
        ) {
          throw new Error("Farklı kaynak ve hedef depo seçin.");
        }
        const base = {
          user_id: userId,
          product_id: form.productId,
          quantity,
          unit_price: Number(form.unitPrice) || 0,
          movement_date: form.movementDate,
          document_no: form.documentNo,
          description: form.description || "Depo transferi",
          source: "TRANSFER",
        };
        const { error } = await supabase.from("stock_movements").insert([
          {
            ...base,
            movement_type: "CIKIS",
            warehouse_id: form.warehouseId,
            target_warehouse_id: form.targetWarehouseId,
          },
          { ...base, movement_type: "GIRIS", warehouse_id: form.targetWarehouseId },
        ]);
        if (error) throw error;
        return;
      }

      const { error } = await supabase.from("stock_movements").insert({
        user_id: userId,
        product_id: form.productId,
        warehouse_id: form.warehouseId || null,
        movement_type: form.movementType,
        quantity,
        unit_price: Number(form.unitPrice) || 0,
        movement_date: form.movementDate,
        document_no: form.documentNo,
        description: form.description,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Stok hareketi kaydedildi.");
      setForm({ ...emptyMovement, movementDate: today() });
      setMovementOpen(false);
      refresh();
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const removeMovement = useMutation({
    mutationFn: async (id: string) => {
      const { data: userData } = await supabase.auth.getUser();
      const userId = userData.user?.id;
      const { error } = await supabase
        .from("stock_movements")
        .update({
          deleted_at: new Date().toISOString(),
          deleted_by: userId || null,
        })
        .eq("id", id);
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Stok hareketi silindi (Çöp Kutusuna taşındı).");
      refresh();
    },
    onError: (e: Error) => toast.error(e.message),
  });

  function exportMovements() {
    downloadWorkbook(
      ["Tarih", "Ürün", "Tür", "Depo", "Miktar", "Birim Fiyat", "Belge No", "Açıklama"],
      movements.map((m) => [
        m.movement_date,
        productMap.get(m.product_id)?.name ?? "",
        STOCK_LABELS[m.movement_type as StockMovementType] ?? m.movement_type,
        m.warehouse_id ? (warehouseMap.get(m.warehouse_id)?.name ?? "") : "",
        Number(m.quantity),
        Number(m.unit_price),
        m.document_no,
        m.description,
      ]),
      `stok-hareketleri-${today()}.xlsx`,
      "Stok",
    );
  }

  return (
    <AppShell
      title="Stok Yönetimi"
      subtitle="Depolar, stok giriş/çıkış ve transfer hareketleri"
      actions={
        <>
          <Dialog open={warehouseOpen} onOpenChange={setWarehouseOpen}>
            <DialogTrigger asChild>
              <Button variant="outline">Yeni Depo</Button>
            </DialogTrigger>
            <DialogContent>
              <DialogHeader>
                <DialogTitle>Depo Tanımla</DialogTitle>
              </DialogHeader>
              <form
                className="space-y-4"
                onSubmit={(e) => {
                  e.preventDefault();
                  addWarehouse.mutate();
                }}
              >
                <div className="space-y-2">
                  <Label htmlFor="wname">Depo Adı</Label>
                  <Input
                    id="wname"
                    required
                    value={warehouseForm.name}
                    onChange={(e) => setWarehouseForm({ ...warehouseForm, name: e.target.value })}
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="waddress">Adres</Label>
                  <Input
                    id="waddress"
                    value={warehouseForm.address}
                    onChange={(e) =>
                      setWarehouseForm({ ...warehouseForm, address: e.target.value })
                    }
                  />
                </div>
                <Button type="submit" className="w-full" disabled={addWarehouse.isPending}>
                  Kaydet
                </Button>
              </form>
            </DialogContent>
          </Dialog>

          <Dialog open={movementOpen} onOpenChange={setMovementOpen}>
            <DialogTrigger asChild>
              <Button>Stok Hareketi</Button>
            </DialogTrigger>
            <DialogContent className="max-h-[85vh] overflow-y-auto">
              <DialogHeader>
                <DialogTitle>Yeni Stok Hareketi</DialogTitle>
              </DialogHeader>
              <form
                className="grid gap-3 sm:grid-cols-2"
                onSubmit={(e) => {
                  e.preventDefault();
                  addMovement.mutate();
                }}
              >
                <div className="space-y-1 sm:col-span-2">
                  <Label>Ürün</Label>
                  <Select
                    value={form.productId}
                    onValueChange={(v) => setForm({ ...form, productId: v })}
                  >
                    <SelectTrigger>
                      <SelectValue
                        placeholder={products.length ? "Ürün seçin" : "Önce ürün kartı ekleyin"}
                      />
                    </SelectTrigger>
                    <SelectContent>
                      {products.map((p) => (
                        <SelectItem key={p.id} value={p.id}>
                          {p.name}
                          {p.code ? ` (${p.code})` : ""}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
                <div className="space-y-1">
                  <Label>Hareket Türü</Label>
                  <Select
                    value={form.movementType}
                    onValueChange={(v) =>
                      setForm({ ...form, movementType: v as StockMovementType })
                    }
                  >
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {(Object.keys(STOCK_LABELS) as StockMovementType[])
                        .filter((k) => k !== "SAYIM")
                        .map((k) => (
                          <SelectItem key={k} value={k}>
                            {STOCK_LABELS[k]}
                          </SelectItem>
                        ))}
                    </SelectContent>
                  </Select>
                </div>
                <div className="space-y-1">
                  <Label htmlFor="qty">Miktar</Label>
                  <Input
                    id="qty"
                    type="number"
                    step="0.01"
                    required
                    value={form.quantity}
                    onChange={(e) => setForm({ ...form, quantity: e.target.value })}
                  />
                </div>
                <div className="space-y-1">
                  <Label>{form.movementType === "TRANSFER" ? "Kaynak Depo" : "Depo"}</Label>
                  <Select
                    value={form.warehouseId}
                    onValueChange={(v) => setForm({ ...form, warehouseId: v })}
                  >
                    <SelectTrigger>
                      <SelectValue
                        placeholder={warehouses.length ? "Depo seçin" : "Önce depo tanımlayın"}
                      />
                    </SelectTrigger>
                    <SelectContent>
                      {warehouses.map((w) => (
                        <SelectItem key={w.id} value={w.id}>
                          {w.name}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
                {form.movementType === "TRANSFER" ? (
                  <div className="space-y-1">
                    <Label>Hedef Depo</Label>
                    <Select
                      value={form.targetWarehouseId}
                      onValueChange={(v) => setForm({ ...form, targetWarehouseId: v })}
                    >
                      <SelectTrigger>
                        <SelectValue placeholder="Depo seçin" />
                      </SelectTrigger>
                      <SelectContent>
                        {warehouses
                          .filter((w) => w.id !== form.warehouseId)
                          .map((w) => (
                            <SelectItem key={w.id} value={w.id}>
                              {w.name}
                            </SelectItem>
                          ))}
                      </SelectContent>
                    </Select>
                  </div>
                ) : (
                  <div className="space-y-1">
                    <Label htmlFor="uprice">Birim Fiyat</Label>
                    <Input
                      id="uprice"
                      type="number"
                      step="0.01"
                      value={form.unitPrice}
                      onChange={(e) => setForm({ ...form, unitPrice: e.target.value })}
                    />
                  </div>
                )}
                <div className="space-y-1">
                  <Label htmlFor="mdate">Tarih</Label>
                  <Input
                    id="mdate"
                    type="date"
                    value={form.movementDate}
                    onChange={(e) => setForm({ ...form, movementDate: e.target.value })}
                  />
                </div>
                <div className="space-y-1">
                  <Label htmlFor="mdoc">Belge No</Label>
                  <Input
                    id="mdoc"
                    value={form.documentNo}
                    onChange={(e) => setForm({ ...form, documentNo: e.target.value })}
                  />
                </div>
                <div className="space-y-1 sm:col-span-2">
                  <Label htmlFor="mdesc">Açıklama</Label>
                  <Input
                    id="mdesc"
                    value={form.description}
                    onChange={(e) => setForm({ ...form, description: e.target.value })}
                  />
                </div>
                <div className="sm:col-span-2">
                  <Button type="submit" className="w-full" disabled={addMovement.isPending}>
                    Kaydet
                  </Button>
                </div>
              </form>
            </DialogContent>
          </Dialog>
        </>
      }
    >
      <Tabs defaultValue="hareketler" className="space-y-4">
        <TabsList>
          <TabsTrigger value="hareketler">Stok Hareketleri</TabsTrigger>
          <TabsTrigger value="durum">Stok Durumu</TabsTrigger>
          <TabsTrigger value="depolar">Depolar</TabsTrigger>
        </TabsList>

        <TabsContent value="hareketler" className="space-y-4">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Filtreler</CardTitle>
            </CardHeader>
            <CardContent className="flex flex-wrap items-end gap-3">
              <div className="space-y-1">
                <Label>Ürün</Label>
                <Select
                  value={filters.productId}
                  onValueChange={(v) => setFilters({ ...filters, productId: v })}
                >
                  <SelectTrigger className="w-56">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="ALL">Tüm ürünler</SelectItem>
                    {products.map((p) => (
                      <SelectItem key={p.id} value={p.id}>
                        {p.name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
              <div className="space-y-1">
                <Label htmlFor="ffrom">Başlangıç</Label>
                <Input
                  id="ffrom"
                  type="date"
                  value={filters.from}
                  onChange={(e) => setFilters({ ...filters, from: e.target.value })}
                />
              </div>
              <div className="space-y-1">
                <Label htmlFor="fto">Bitiş</Label>
                <Input
                  id="fto"
                  type="date"
                  value={filters.to}
                  onChange={(e) => setFilters({ ...filters, to: e.target.value })}
                />
              </div>
              <Button
                variant="outline"
                className="gap-2"
                onClick={exportMovements}
                disabled={movements.length === 0}
              >
                <Download className="size-4" />
                Excel'e Aktar
              </Button>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">Hareketler ({movements.length})</CardTitle>
            </CardHeader>
            <CardContent>
              {isLoading ? (
                <p className="text-sm text-muted-foreground">Yükleniyor…</p>
              ) : movements.length === 0 ? (
                <p className="text-sm text-muted-foreground">Seçilen aralıkta hareket yok.</p>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground">
                        <th className="py-2 pr-4">Tarih</th>
                        <th className="py-2 pr-4">Ürün</th>
                        <th className="py-2 pr-4">Tür</th>
                        <th className="py-2 pr-4">Depo</th>
                        <th className="py-2 pr-4 text-right">Miktar</th>
                        <th className="py-2 pr-4 text-right">Birim Fiyat</th>
                        <th className="py-2 pr-4">Açıklama</th>
                        <th className="py-2" />
                      </tr>
                    </thead>
                    <tbody>
                      {movements.map((m) => (
                        <tr key={m.id} className="border-b border-border/60 last:border-0">
                          <td className="py-3 pr-4 whitespace-nowrap">
                            {formatDate(m.movement_date)}
                          </td>
                          <td className="py-3 pr-4 font-medium">
                            {productMap.get(m.product_id)?.name ?? "-"}
                          </td>
                          <td className="py-3 pr-4">
                            {STOCK_LABELS[m.movement_type as StockMovementType] ?? m.movement_type}
                          </td>
                          <td className="py-3 pr-4">
                            {m.warehouse_id ? warehouseMap.get(m.warehouse_id)?.name : "-"}
                          </td>
                          <td className="py-3 pr-4 text-right">
                            {m.movement_type === "CIKIS" ? "-" : "+"}
                            {Number(m.quantity)}
                          </td>
                          <td className="py-3 pr-4 text-right">
                            {formatMoney(Number(m.unit_price))}
                          </td>
                          <td className="py-3 pr-4">{m.description || m.document_no || "-"}</td>
                          <td className="py-3 text-right">
                            <Button
                              variant="ghost"
                              size="sm"
                              onClick={() => removeMovement.mutate(m.id)}
                            >
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
        </TabsContent>

        <TabsContent value="durum">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">
                Stok Durumu ({products.length}) · Kritik: {critical.length}
              </CardTitle>
            </CardHeader>
            <CardContent>
              {products.length === 0 ? (
                <p className="text-sm text-muted-foreground">Ürün kartı bulunmuyor.</p>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground">
                        <th className="py-2 pr-4">Ürün</th>
                        <th className="py-2 pr-4">Kod</th>
                        <th className="py-2 pr-4">Birim</th>
                        <th className="py-2 pr-4 text-right">Min. Stok</th>
                        <th className="py-2 pr-4 text-right">Mevcut</th>
                      </tr>
                    </thead>
                    <tbody>
                      {products.map((p) => {
                        const qty = stockMap.get(p.id) ?? 0;
                        const isCritical =
                          Number(p.min_stock ?? 0) > 0 && qty <= Number(p.min_stock);
                        return (
                          <tr key={p.id} className="border-b border-border/60 last:border-0">
                            <td className="py-3 pr-4 font-medium">{p.name}</td>
                            <td className="py-3 pr-4">{p.code || "-"}</td>
                            <td className="py-3 pr-4">{p.unit}</td>
                            <td className="py-3 pr-4 text-right">{Number(p.min_stock ?? 0)}</td>
                            <td className="py-3 pr-4 text-right">
                              {qty}
                              {isCritical ? (
                                <Badge variant="destructive" className="ml-2">
                                  Kritik
                                </Badge>
                              ) : null}
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
        </TabsContent>

        <TabsContent value="depolar">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Depolar ({warehouses.length})</CardTitle>
            </CardHeader>
            <CardContent>
              {warehouses.length === 0 ? (
                <p className="text-sm text-muted-foreground">Henüz depo tanımlanmadı.</p>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground">
                        <th className="py-2 pr-4">Depo</th>
                        <th className="py-2 pr-4">Adres</th>
                        <th className="py-2" />
                      </tr>
                    </thead>
                    <tbody>
                      {warehouses.map((w) => (
                        <tr key={w.id} className="border-b border-border/60 last:border-0">
                          <td className="py-3 pr-4 font-medium">
                            {w.name}
                            {w.is_default ? <Badge className="ml-2">Varsayılan</Badge> : null}
                          </td>
                          <td className="py-3 pr-4">{w.address || "-"}</td>
                          <td className="py-3 text-right">
                            <Button
                              variant="ghost"
                              size="sm"
                              onClick={() => removeWarehouse.mutate(w.id)}
                            >
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
        </TabsContent>
      </Tabs>
    </AppShell>
  );
}
