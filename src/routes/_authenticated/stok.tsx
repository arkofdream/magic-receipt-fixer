import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import { Download, Calculator, Warehouse, Boxes, AlertTriangle, ArrowRightLeft } from "lucide-react";
import { toast } from "sonner";

import { AppShell } from "@/components/AppShell";
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
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { supabase } from "@/integrations/supabase/client";
import { downloadWorkbook } from "@/lib/excel";
import { formatDate, formatMoney } from "@/lib/invoice";
import { STOCK_LABELS, addDaysISO, today, type StockMovementType } from "@/lib/cari";

export const Route = createFileRoute("/_authenticated/stok")({
  head: () => ({
    meta: [
      { title: "Stok & Depo Yönetimi ve Maliyet Hesabı | e-Fatura Portalı" },
      {
        name: "description",
        content:
          "Depo tanımlayın, stok giriş-çıkış ve transfer hareketlerini kaydedin, FIFO ve Ağırlıklı Ortalama Maliyet hesaplarını izleyin.",
      },
      { property: "og:title", content: "Stok & Depo Yönetimi ve Maliyet Hesabı | e-Fatura Portalı" },
      { property: "og:description", content: "Depo takibi, stok hareketi ve maliyet yöntemleri." },
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

type ValuationMethod = "WEIGHTED_AVG" | "FIFO" | "LAST_PURCHASE";

function StockPage() {
  const queryClient = useQueryClient();
  const [movementOpen, setMovementOpen] = useState(false);
  const [warehouseOpen, setWarehouseOpen] = useState(false);
  const [valuationMethod, setValuationMethod] = useState<ValuationMethod>("WEIGHTED_AVG");
  const [form, setForm] = useState(emptyMovement);
  const [warehouseForm, setWarehouseForm] = useState({ name: "", address: "" });
  const [filters, setFilters] = useState({
    productId: "ALL",
    warehouseId: "ALL",
    from: addDaysISO(today(), -180),
    to: today(),
  });

  const { data: products = [] } = useQuery({
    queryKey: ["products", "stock"],
    queryFn: async () => {
      const { data, error } = await supabase.from("products").select("*").is("deleted_at", null).order("name");
      if (error) throw error;
      return data ?? [];
    },
  });

  const { data: warehouses = [] } = useQuery({
    queryKey: ["warehouses"],
    queryFn: async () => {
      const { data, error } = await supabase.from("warehouses").select("*").is("deleted_at", null).order("created_at");
      if (error) throw error;
      return data ?? [];
    },
  });

  const { data: stocks = [] } = useQuery({
    queryKey: ["product-stocks"],
    queryFn: async () => {
      const { data, error } = await supabase.from("product_stocks").select("*");
      if (error) throw error;
      return data ?? [];
    },
  });

  // Tüm hareketleri maliyet hesabı ve filtreler için çek
  const { data: allMovements = [], isLoading } = useQuery({
    queryKey: ["all-stock-movements"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("stock_movements")
        .select("*")
        .is("deleted_at", null)
        .order("movement_date", { ascending: true })
        .order("created_at", { ascending: true });
      if (error) throw error;
      return data ?? [];
    },
  });

  const productMap = useMemo(() => new Map(products.map((p) => [p.id, p])), [products]);
  const warehouseMap = useMemo(() => new Map(warehouses.map((w) => [w.id, w])), [warehouses]);

  const stockMap = useMemo(() => {
    const map = new Map<string, number>();
    for (const s of stocks) if (s.product_id) map.set(s.product_id, Number(s.quantity ?? 0));
    return map;
  }, [stocks]);

  // Depo bazında stok haritası: `productId:warehouseId` -> quantity
  const warehouseStockMap = useMemo(() => {
    const map = new Map<string, number>();
    for (const m of allMovements) {
      if (!m.product_id || !m.warehouse_id) continue;
      const key = `${m.product_id}:${m.warehouse_id}`;
      const curr = map.get(key) ?? 0;
      const qty = Number(m.quantity) || 0;
      if (m.movement_type === "GIRIS") {
        map.set(key, curr + qty);
      } else if (m.movement_type === "CIKIS") {
        map.set(key, Math.max(0, curr - qty));
      }
    }
    return map;
  }, [allMovements]);

  // MALİYET HESAPLAMA MOTORU (FIFO, Ağırlıklı Ortalama, Son Alış)
  const productCostAnalysis = useMemo(() => {
    const analysis: {
      productId: string;
      productName: string;
      unit: string;
      stockQty: number;
      salePrice: number;
      weightedAvgCost: number;
      fifoCost: number;
      lastPurchaseCost: number;
      activeUnitCost: number;
      totalCostValue: number;
      totalSaleValue: number;
      profitMarginPct: number;
    }[] = [];

    for (const p of products) {
      const currentStock = stockMap.get(p.id) ?? 0;
      const pMovements = allMovements.filter((m) => m.product_id === p.id);
      const incoming = pMovements.filter((m) => m.movement_type === "GIRIS" && Number(m.quantity) > 0);

      // 1. Ağırlıklı Ortalama Maliyet (Weighted Average Cost)
      let totalInQty = 0;
      let totalInVal = 0;
      for (const inc of incoming) {
        const q = Number(inc.quantity) || 0;
        const pr = Number(inc.unit_price) || 0;
        totalInQty += q;
        totalInVal += q * pr;
      }
      const weightedAvgCost =
        totalInQty > 0 ? totalInVal / totalInQty : Number(p.purchase_price || p.unit_price) || 0;

      // 2. Son Alış Fiyatı (Last Purchase Price)
      const lastPurchase = incoming.length > 0 ? incoming[incoming.length - 1] : null;
      const lastPurchaseCost = lastPurchase
        ? Number(lastPurchase.unit_price) || 0
        : Number(p.purchase_price || p.unit_price) || 0;

      // 3. FIFO (İlk Giren İlk Çıkar) Maliyeti
      let totalOutQty = pMovements
        .filter((m) => m.movement_type === "CIKIS")
        .reduce((sum, m) => sum + (Number(m.quantity) || 0), 0);

      const fifoBatches: { qty: number; price: number }[] = [];
      for (const inc of incoming) {
        const q = Number(inc.quantity) || 0;
        const pr = Number(inc.unit_price) || 0;
        if (totalOutQty >= q) {
          totalOutQty -= q;
        } else {
          const rem = q - totalOutQty;
          totalOutQty = 0;
          fifoBatches.push({ qty: rem, price: pr });
        }
      }

      let fifoTotalVal = 0;
      let fifoTotalQty = 0;
      for (const b of fifoBatches) {
        fifoTotalQty += b.qty;
        fifoTotalVal += b.qty * b.price;
      }
      const fifoCost =
        fifoTotalQty > 0 ? fifoTotalVal / fifoTotalQty : weightedAvgCost;

      // Seçili aktif yönteme göre birim maliyet
      let activeUnitCost = weightedAvgCost;
      if (valuationMethod === "FIFO") activeUnitCost = fifoCost;
      if (valuationMethod === "LAST_PURCHASE") activeUnitCost = lastPurchaseCost;

      const salePrice = Number(p.unit_price) || 0;
      const totalCostValue = currentStock * activeUnitCost;
      const totalSaleValue = currentStock * salePrice;
      const profitMarginPct =
        salePrice > 0 ? ((salePrice - activeUnitCost) / salePrice) * 100 : 0;

      analysis.push({
        productId: p.id,
        productName: p.name,
        unit: p.unit || "Adet",
        stockQty: currentStock,
        salePrice,
        weightedAvgCost,
        fifoCost,
        lastPurchaseCost,
        activeUnitCost,
        totalCostValue,
        totalSaleValue,
        profitMarginPct,
      });
    }

    return analysis;
  }, [products, stockMap, allMovements, valuationMethod]);

  const costSummary = useMemo(() => {
    let totalStockQty = 0;
    let totalCostVal = 0;
    let totalSaleVal = 0;
    for (const item of productCostAnalysis) {
      totalStockQty += item.stockQty;
      totalCostVal += item.totalCostValue;
      totalSaleVal += item.totalSaleValue;
    }
    const overallMargin =
      totalSaleVal > 0 ? ((totalSaleVal - totalCostVal) / totalSaleVal) * 100 : 0;
    return { totalStockQty, totalCostVal, totalSaleVal, overallMargin };
  }, [productCostAnalysis]);

  const critical = useMemo(
    () =>
      products.filter(
        (p) => Number(p.min_stock ?? 0) > 0 && (stockMap.get(p.id) ?? 0) <= Number(p.min_stock),
      ),
    [products, stockMap],
  );

  const filteredMovements = useMemo(() => {
    return allMovements
      .filter((m) => {
        if (filters.productId !== "ALL" && m.product_id !== filters.productId) return false;
        if (filters.warehouseId !== "ALL" && m.warehouse_id !== filters.warehouseId) return false;
        if (filters.from && m.movement_date < filters.from) return false;
        if (filters.to && m.movement_date > filters.to) return false;
        return true;
      })
      .slice()
      .reverse();
  }, [allMovements, filters]);

  async function currentUserId() {
    const { data } = await supabase.auth.getUser();
    const id = data.user?.id;
    if (!id) throw new Error("Oturum bulunamadı.");
    return id;
  }

  function refresh() {
    queryClient.invalidateQueries({ queryKey: ["all-stock-movements"] });
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
      toast.success("Depo başarıyla eklendi.");
      setWarehouseForm({ name: "", address: "" });
      setWarehouseOpen(false);
      queryClient.invalidateQueries({ queryKey: ["warehouses"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const removeWarehouse = useMutation({
    mutationFn: async (id: string) => {
      const userId = await currentUserId();
      const { error } = await supabase
        .from("warehouses")
        .update({
          deleted_at: new Date().toISOString(),
          deleted_by: userId,
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
      if (!form.productId) throw new Error("Lütfen ürün seçin.");
      if (!quantity || quantity <= 0) throw new Error("Geçerli bir miktar girin.");
      const userId = await currentUserId();

      // Depo Transferi
      if (form.movementType === "TRANSFER") {
        if (
          !form.warehouseId ||
          !form.targetWarehouseId ||
          form.warehouseId === form.targetWarehouseId
        ) {
          throw new Error("Farklı kaynak ve hedef depo seçiniz.");
        }
        const base = {
          user_id: userId,
          product_id: form.productId,
          quantity,
          unit_price: Number(form.unitPrice) || 0,
          movement_date: form.movementDate,
          document_no: form.documentNo,
          description: form.description || "Depo transfer hareketi",
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
      const userId = await currentUserId();
      const { error } = await supabase
        .from("stock_movements")
        .update({
          deleted_at: new Date().toISOString(),
          deleted_by: userId,
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
      filteredMovements.map((m) => [
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

  function exportCostAnalysis() {
    downloadWorkbook(
      [
        "Ürün Adı",
        "Birim",
        "Mevcut Stok",
        "Ağırlıklı Ort. Maliyet",
        "FIFO Maliyeti",
        "Son Alış Fiyatı",
        "Satış Fiyatı",
        "Toplam Stok Maliyet Değeri",
        "Tahmini Satış Değeri",
        "Kar Marjı (%)",
      ],
      productCostAnalysis.map((item) => [
        item.productName,
        item.unit,
        item.stockQty,
        item.weightedAvgCost,
        item.fifoCost,
        item.lastPurchaseCost,
        item.salePrice,
        item.totalCostValue,
        item.totalSaleValue,
        `%${item.profitMarginPct.toFixed(1)}`,
      ]),
      `stok-maliyet-analizi-${today()}.xlsx`,
      "Maliyet Analizi",
    );
  }

  return (
    <AppShell
      title="Stok & Depo Yönetimi"
      subtitle="Çoklu depo takibi, stok hareketleri ve FIFO / Ortalama maliyet analizleri"
      actions={
        <div className="flex gap-2">
          <Dialog open={warehouseOpen} onOpenChange={setWarehouseOpen}>
            <DialogTrigger asChild>
              <Button variant="outline" className="gap-1.5">
                <Warehouse className="size-4" /> Yeni Depo
              </Button>
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
                  <Label htmlFor="wname">Depo Adı *</Label>
                  <Input
                    id="wname"
                    required
                    placeholder="Örn: Ana Depo, Kadıköy Şube Deposu"
                    value={warehouseForm.name}
                    onChange={(e) => setWarehouseForm({ ...warehouseForm, name: e.target.value })}
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="waddress">Depo Adresi</Label>
                  <Input
                    id="waddress"
                    placeholder="Depo açık adresi veya lokasyon"
                    value={warehouseForm.address}
                    onChange={(e) =>
                      setWarehouseForm({ ...warehouseForm, address: e.target.value })
                    }
                  />
                </div>
                <Button type="submit" className="w-full" disabled={addWarehouse.isPending}>
                  Depoyu Kaydet
                </Button>
              </form>
            </DialogContent>
          </Dialog>

          <Dialog open={movementOpen} onOpenChange={setMovementOpen}>
            <DialogTrigger asChild>
              <Button className="gap-1.5">
                <ArrowRightLeft className="size-4" /> Stok Hareketi
              </Button>
            </DialogTrigger>
            <DialogContent className="max-h-[85vh] overflow-y-auto">
              <DialogHeader>
                <DialogTitle>Yeni Stok Giriş / Çıkış / Transfer</DialogTitle>
              </DialogHeader>
              <form
                className="grid gap-3 sm:grid-cols-2"
                onSubmit={(e) => {
                  e.preventDefault();
                  addMovement.mutate();
                }}
              >
                <div className="space-y-1 sm:col-span-2">
                  <Label>Ürün / Malzeme *</Label>
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
                          {p.name} {p.code ? `(${p.code})` : ""}
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
                        <SelectValue placeholder="Hedef depo seçin" />
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
                    <Label htmlFor="uprice">Birim Alış / Giriş Fiyatı (₺)</Label>
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
                  <Label htmlFor="mdoc">Belge No / İrsaliye</Label>
                  <Input
                    id="mdoc"
                    placeholder="İrsaliye veya fiş no"
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
                <div className="sm:col-span-2 pt-2">
                  <Button type="submit" className="w-full" disabled={addMovement.isPending}>
                    Kaydet
                  </Button>
                </div>
              </form>
            </DialogContent>
          </Dialog>
        </div>
      }
    >
      <Tabs defaultValue="maliyet" className="space-y-4">
        <TabsList className="grid grid-cols-2 sm:flex sm:flex-wrap gap-1 h-auto p-1">
          <TabsTrigger value="maliyet" className="gap-1.5">
            <Calculator className="size-4" /> Maliyet Hesabı & Yöntemleri
          </TabsTrigger>
          <TabsTrigger value="depo-takip" className="gap-1.5">
            <Warehouse className="size-4" /> Depo Takibi & Miktarlar
          </TabsTrigger>
          <TabsTrigger value="hareketler" className="gap-1.5">
            <ArrowRightLeft className="size-4" /> Stok Hareketleri
          </TabsTrigger>
          <TabsTrigger value="depolar" className="gap-1.5">
            <Boxes className="size-4" /> Depolar
          </TabsTrigger>
        </TabsList>

        {/* TAB 1: MALİYET HESABI VE YÖNTEMLERİ */}
        <TabsContent value="maliyet" className="space-y-4">
          <div className="grid gap-3 sm:grid-cols-4">
            <Card>
              <CardContent className="pt-5">
                <p className="text-xs text-muted-foreground uppercase font-medium">Toplam Stok Adedi</p>
                <p className="text-2xl font-bold mt-1">{costSummary.totalStockQty.toLocaleString("tr-TR")}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-5">
                <p className="text-xs text-muted-foreground uppercase font-medium">Toplam Stok Maliyet Değeri</p>
                <p className="text-2xl font-bold mt-1 text-primary">{formatMoney(costSummary.totalCostVal)}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-5">
                <p className="text-xs text-muted-foreground uppercase font-medium">Tahmini Satış Değeri</p>
                <p className="text-2xl font-bold mt-1">{formatMoney(costSummary.totalSaleVal)}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-5">
                <p className="text-xs text-muted-foreground uppercase font-medium">Genel Brüt Kar Potansiyeli</p>
                <p className="text-2xl font-bold mt-1 text-emerald-600">%{costSummary.overallMargin.toFixed(1)}</p>
              </CardContent>
            </Card>
          </div>

          <Card>
            <CardHeader className="flex flex-wrap items-center justify-between gap-3 pb-3">
              <div>
                <CardTitle className="text-base">Maliyet Hesaplama Yöntemi</CardTitle>
                <CardDescription>
                  Seçilen yönteme göre tüm ürünlerin birim maliyetleri ve toplam stok değerleri hesaplanır.
                </CardDescription>
              </div>
              <div className="flex items-center gap-3">
                <Select
                  value={valuationMethod}
                  onValueChange={(v) => setValuationMethod(v as ValuationMethod)}
                >
                  <SelectTrigger className="w-64 h-9 text-xs font-semibold">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="WEIGHTED_AVG">Ağırlıklı Ortalama Maliyet</SelectItem>
                    <SelectItem value="FIFO">FIFO (İlk Giren İlk Çıkar)</SelectItem>
                    <SelectItem value="LAST_PURCHASE">Son Alış Fiyatı Yöntemi</SelectItem>
                  </SelectContent>
                </Select>
                <Button variant="outline" size="sm" onClick={exportCostAnalysis} className="gap-1.5 text-xs">
                  <Download className="size-3.5" /> Excel Raporu
                </Button>
              </div>
            </CardHeader>
            <CardContent>
              {productCostAnalysis.length === 0 ? (
                <p className="text-sm text-muted-foreground py-4">Ürün kartı bulunmuyor.</p>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground">
                        <th className="py-2.5 pr-4">Ürün Adı</th>
                        <th className="py-2.5 pr-4 text-right">Mevcut Stok</th>
                        <th className="py-2.5 pr-4 text-right">Ağ. Ort. Maliyet</th>
                        <th className="py-2.5 pr-4 text-right">FIFO Maliyeti</th>
                        <th className="py-2.5 pr-4 text-right">Son Alış Fiyatı</th>
                        <th className="py-2.5 pr-4 text-right">Satış Fiyatı</th>
                        <th className="py-2.5 pr-4 text-right">Toplam Stok Değeri</th>
                        <th className="py-2.5 text-right">Kar Marjı</th>
                      </tr>
                    </thead>
                    <tbody>
                      {productCostAnalysis.map((item) => (
                        <tr key={item.productId} className="border-b border-border/60 hover:bg-muted/30 last:border-0">
                          <td className="py-3 pr-4 font-medium">
                            {item.productName}
                            <span className="ml-1 text-xs text-muted-foreground">({item.unit})</span>
                          </td>
                          <td className="py-3 pr-4 text-right font-semibold">
                            {item.stockQty}
                          </td>
                          <td className={`py-3 pr-4 text-right ${valuationMethod === "WEIGHTED_AVG" ? "font-bold text-primary" : ""}`}>
                            {formatMoney(item.weightedAvgCost)}
                          </td>
                          <td className={`py-3 pr-4 text-right ${valuationMethod === "FIFO" ? "font-bold text-primary" : ""}`}>
                            {formatMoney(item.fifoCost)}
                          </td>
                          <td className={`py-3 pr-4 text-right ${valuationMethod === "LAST_PURCHASE" ? "font-bold text-primary" : ""}`}>
                            {formatMoney(item.lastPurchaseCost)}
                          </td>
                          <td className="py-3 pr-4 text-right">
                            {formatMoney(item.salePrice)}
                          </td>
                          <td className="py-3 pr-4 text-right font-semibold text-primary">
                            {formatMoney(item.totalCostValue)}
                          </td>
                          <td className="py-3 text-right">
                            <Badge variant={item.profitMarginPct >= 0 ? "secondary" : "destructive"}>
                              %{item.profitMarginPct.toFixed(1)}
                            </Badge>
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

        {/* TAB 2: DEPO TAKİBİ & DEPO BAZLI MİKTARLAR */}
        <TabsContent value="depo-takip" className="space-y-4">
          <Card>
            <CardHeader className="pb-3">
              <CardTitle className="text-base">Depo Bazlı Stok Dağılımı</CardTitle>
              <CardDescription>Her bir ürünün hangi depoda ne kadar bulunduğu</CardDescription>
            </CardHeader>
            <CardContent>
              {products.length === 0 ? (
                <p className="text-sm text-muted-foreground py-4">Ürün bulunamadı.</p>
              ) : warehouses.length === 0 ? (
                <p className="text-sm text-muted-foreground py-4">Henüz kayıtlı depo yok. Yukarıdan 'Yeni Depo' ekleyin.</p>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground">
                        <th className="py-2.5 pr-4">Ürün</th>
                        <th className="py-2.5 pr-4">Birim</th>
                        {warehouses.map((w) => (
                          <th key={w.id} className="py-2.5 pr-4 text-right">{w.name}</th>
                        ))}
                        <th className="py-2.5 text-right font-bold">Toplam Stok</th>
                      </tr>
                    </thead>
                    <tbody>
                      {products.map((p) => {
                        const total = stockMap.get(p.id) ?? 0;
                        return (
                          <tr key={p.id} className="border-b border-border/60 hover:bg-muted/30 last:border-0">
                            <td className="py-3 pr-4 font-medium">{p.name}</td>
                            <td className="py-3 pr-4 text-muted-foreground text-xs">{p.unit}</td>
                            {warehouses.map((w) => {
                              const qty = warehouseStockMap.get(`${p.id}:${w.id}`) ?? 0;
                              return (
                                <td key={w.id} className="py-3 pr-4 text-right">
                                  {qty > 0 ? <span className="font-semibold">{qty}</span> : <span className="text-muted-foreground">-</span>}
                                </td>
                              );
                            })}
                            <td className="py-3 text-right font-bold text-primary">
                              {total}
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

        {/* TAB 3: STOK HAREKETLERİ LİSTESİ */}
        <TabsContent value="hareketler" className="space-y-4">
          <Card>
            <CardHeader className="py-3">
              <CardTitle className="text-sm font-semibold">Hareket Filtreleri</CardTitle>
            </CardHeader>
            <CardContent className="flex flex-wrap items-end gap-3 pt-0">
              <div className="space-y-1">
                <Label className="text-xs">Ürün</Label>
                <Select
                  value={filters.productId}
                  onValueChange={(v) => setFilters({ ...filters, productId: v })}
                >
                  <SelectTrigger className="w-48 h-8 text-xs">
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
                <Label className="text-xs">Depo</Label>
                <Select
                  value={filters.warehouseId}
                  onValueChange={(v) => setFilters({ ...filters, warehouseId: v })}
                >
                  <SelectTrigger className="w-44 h-8 text-xs">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="ALL">Tüm depolar</SelectItem>
                    {warehouses.map((w) => (
                      <SelectItem key={w.id} value={w.id}>
                        {w.name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>

              <div className="space-y-1">
                <Label className="text-xs">Başlangıç</Label>
                <Input
                  className="h-8 text-xs"
                  type="date"
                  value={filters.from}
                  onChange={(e) => setFilters({ ...filters, from: e.target.value })}
                />
              </div>

              <div className="space-y-1">
                <Label className="text-xs">Bitiş</Label>
                <Input
                  className="h-8 text-xs"
                  type="date"
                  value={filters.to}
                  onChange={(e) => setFilters({ ...filters, to: e.target.value })}
                />
              </div>

              <Button
                variant="outline"
                size="sm"
                className="gap-2 h-8 text-xs"
                onClick={exportMovements}
                disabled={filteredMovements.length === 0}
              >
                <Download className="size-3.5" />
                Excel'e Aktar
              </Button>
            </CardContent>
          </Card>

          <Card>
            <CardHeader className="py-4">
              <CardTitle className="text-base">Hareketler ({filteredMovements.length})</CardTitle>
            </CardHeader>
            <CardContent>
              {isLoading ? (
                <p className="text-sm text-muted-foreground py-4">Yükleniyor…</p>
              ) : filteredMovements.length === 0 ? (
                <p className="text-sm text-muted-foreground py-4">Seçilen aralıkta hareket yok.</p>
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
                        <th className="py-2 pr-4">Açıklama / Belge</th>
                        <th className="py-2 text-right" />
                      </tr>
                    </thead>
                    <tbody>
                      {filteredMovements.map((m) => (
                        <tr key={m.id} className="border-b border-border/60 hover:bg-muted/30 last:border-0">
                          <td className="py-3 pr-4 whitespace-nowrap">
                            {formatDate(m.movement_date)}
                          </td>
                          <td className="py-3 pr-4 font-medium">
                            {productMap.get(m.product_id)?.name ?? "-"}
                          </td>
                          <td className="py-3 pr-4">
                            <Badge variant={m.movement_type === "GIRIS" ? "default" : "secondary"}>
                              {STOCK_LABELS[m.movement_type as StockMovementType] ?? m.movement_type}
                            </Badge>
                          </td>
                          <td className="py-3 pr-4">
                            {m.warehouse_id ? warehouseMap.get(m.warehouse_id)?.name : "-"}
                          </td>
                          <td className="py-3 pr-4 text-right font-semibold">
                            {m.movement_type === "CIKIS" ? "-" : "+"}
                            {Number(m.quantity)}
                          </td>
                          <td className="py-3 pr-4 text-right">
                            {formatMoney(Number(m.unit_price))}
                          </td>
                          <td className="py-3 pr-4 text-xs text-muted-foreground">{m.description || m.document_no || "-"}</td>
                          <td className="py-3 text-right">
                            <Button
                              variant="ghost"
                              size="sm"
                              className="h-7 text-xs text-destructive"
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

        {/* TAB 4: DEPO TANIMLARI */}
        <TabsContent value="depolar">
          <Card>
            <CardHeader className="py-4">
              <CardTitle className="text-base">Depolar ({warehouses.length})</CardTitle>
            </CardHeader>
            <CardContent>
              {warehouses.length === 0 ? (
                <p className="text-sm text-muted-foreground py-4">Henüz depo tanımlanmadı.</p>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground">
                        <th className="py-2 pr-4">Depo Adı</th>
                        <th className="py-2 pr-4">Adres / Lokasyon</th>
                        <th className="py-2 text-right" />
                      </tr>
                    </thead>
                    <tbody>
                      {warehouses.map((w) => (
                        <tr key={w.id} className="border-b border-border/60 last:border-0">
                          <td className="py-3 pr-4 font-medium">
                            {w.name}
                            {w.is_default ? <Badge className="ml-2">Varsayılan</Badge> : null}
                          </td>
                          <td className="py-3 pr-4 text-muted-foreground">{w.address || "-"}</td>
                          <td className="py-3 text-right">
                            <Button
                              variant="ghost"
                              size="sm"
                              className="h-7 text-xs text-destructive"
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

