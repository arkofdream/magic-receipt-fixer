import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import {
  Download,
  Calculator,
  Warehouse,
  Boxes,
  AlertTriangle,
  ArrowRightLeft,
  Copy,
  Search,
  Pencil,
  Sparkles,
  CheckCircle2,
} from "lucide-react";
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
import { isMissingColumnError, safeSoftDelete } from "@/lib/safe-supabase";
import { downloadWorkbook } from "@/lib/excel";
import { formatDate, formatMoney } from "@/lib/invoice";
import { STOCK_LABELS, addDaysISO, today, type StockMovementType } from "@/lib/cari";

export const Route = createFileRoute("/_authenticated/stok")({
  head: () => ({
    meta: [
      { title: "Stok, Depo & Değerleme Yönetimi | e-Fatura Portalı" },
      {
        name: "description",
        content:
          "Depo tanımlayın, stok hareketlerini ve değerleme fişlerini kaydedin, FIFO ve Ağırlıklı Ortalama Maliyet hesaplarını izleyin.",
      },
      { property: "og:title", content: "Stok, Depo & Değerleme Yönetimi | e-Fatura Portalı" },
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

const emptyProductEdit = {
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
};

type ValuationMethod = "WEIGHTED_AVG" | "FIFO" | "LAST_PURCHASE";

function StockPage() {
  const queryClient = useQueryClient();
  const [movementOpen, setMovementOpen] = useState(false);
  const [warehouseOpen, setWarehouseOpen] = useState(false);
  const [valuationOpen, setValuationOpen] = useState(false);
  const [editProductOpen, setEditProductOpen] = useState(false);

  const [valuationMethod, setValuationMethod] = useState<ValuationMethod>("WEIGHTED_AVG");
  const [form, setForm] = useState(emptyMovement);
  const [warehouseForm, setWarehouseForm] = useState({ name: "", address: "" });
  const [editForm, setEditForm] = useState(emptyProductEdit);

  // Stok Değerleme Formu
  const [valForm, setValForm] = useState({
    productId: "",
    warehouseId: "",
    valuationDate: today(),
    newUnitCost: "",
    adjustmentQty: "0",
    documentNo: "",
    description: "",
  });

  const [search, setSearch] = useState("");
  const [categoryFilter, setCategoryFilter] = useState("ALL");
  const [stockStatusFilter, setStockStatusFilter] = useState("ALL");
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
      if (error && isMissingColumnError(error)) {
        const fallback = await supabase.from("products").select("*").order("name");
        if (fallback.error) throw fallback.error;
        return fallback.data ?? [];
      }
      if (error) throw error;
      return data ?? [];
    },
  });

  const { data: warehouses = [] } = useQuery({
    queryKey: ["warehouses"],
    queryFn: async () => {
      const { data, error } = await supabase.from("warehouses").select("*").is("deleted_at", null).order("created_at");
      if (error && isMissingColumnError(error)) {
        const fallback = await supabase.from("warehouses").select("*").order("created_at");
        if (fallback.error) throw fallback.error;
        return fallback.data ?? [];
      }
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

  const { data: allMovements = [], isLoading } = useQuery({
    queryKey: ["all-stock-movements"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("stock_movements")
        .select("*")
        .is("deleted_at", null)
        .order("movement_date", { ascending: true })
        .order("created_at", { ascending: true });
      if (error && isMissingColumnError(error)) {
        const fallback = await supabase
          .from("stock_movements")
          .select("*")
          .order("movement_date", { ascending: true })
          .order("created_at", { ascending: true });
        if (fallback.error) throw fallback.error;
        return fallback.data ?? [];
      }
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
      totalCostValue: number;
      totalSaleValue: number;
      profitMarginPct: number;
      code: string;
      barcode: string;
      category: string;
      minStock: number;
      trackStock: boolean;
    }[] = [];

    for (const product of products) {
      const stockQty = stockMap.get(product.id) ?? 0;
      const movements = allMovements.filter((m) => m.product_id === product.id);

      // A. Ağırlıklı Ortalama Maliyet (WAC)
      let totalPurchaseQty = 0;
      let totalPurchaseCost = 0;
      let lastPurchaseCost = Number(product.purchase_price ?? 0);

      // B. FIFO Kuyruğu
      const fifoQueue: { qty: number; unitCost: number }[] = [];

      for (const m of movements) {
        const qty = Number(m.quantity) || 0;
        const unitPrice = Number(m.unit_price) || 0;

        if (m.movement_type === "GIRIS") {
          totalPurchaseQty += qty;
          totalPurchaseCost += qty * unitPrice;
          if (unitPrice > 0) lastPurchaseCost = unitPrice;
          fifoQueue.push({ qty, unitCost: unitPrice });
        } else if (m.movement_type === "CIKIS") {
          let remToDeduct = qty;
          while (remToDeduct > 0 && fifoQueue.length > 0) {
            if (fifoQueue[0].qty <= remToDeduct) {
              remToDeduct -= fifoQueue[0].qty;
              fifoQueue.shift();
            } else {
              fifoQueue[0].qty -= remToDeduct;
              remToDeduct = 0;
            }
          }
        }
      }

      const weightedAvgCost =
        totalPurchaseQty > 0
          ? totalPurchaseCost / totalPurchaseQty
          : Number(product.purchase_price ?? 0);

      let fifoTotalRemainingCost = 0;
      let fifoRemainingQty = 0;
      for (const item of fifoQueue) {
        fifoTotalRemainingCost += item.qty * item.unitCost;
        fifoRemainingQty += item.qty;
      }
      const fifoCost =
        fifoRemainingQty > 0 ? fifoTotalRemainingCost / fifoRemainingQty : weightedAvgCost;

      let activeUnitCost = weightedAvgCost;
      if (valuationMethod === "FIFO") activeUnitCost = fifoCost;
      if (valuationMethod === "LAST_PURCHASE") activeUnitCost = lastPurchaseCost;

      const salePrice = Number(product.unit_price) || 0;
      const totalCostValue = Math.max(0, stockQty) * activeUnitCost;
      const totalSaleValue = Math.max(0, stockQty) * salePrice;
      const profitMarginPct =
        salePrice > 0 ? ((salePrice - activeUnitCost) / salePrice) * 100 : 0;

      analysis.push({
        productId: product.id,
        productName: product.name,
        unit: product.unit || "Adet",
        stockQty,
        salePrice,
        weightedAvgCost,
        fifoCost,
        lastPurchaseCost,
        totalCostValue,
        totalSaleValue,
        profitMarginPct,
        code: product.code || "",
        barcode: product.barcode || "",
        category: product.category || "",
        minStock: Number(product.min_stock ?? 0),
        trackStock: product.track_stock !== false,
      });
    }

    return analysis;
  }, [products, stockMap, allMovements, valuationMethod]);

  const categories = useMemo(() => {
    const set = new Set<string>();
    for (const p of products) {
      if (p.category && p.category.trim()) set.add(p.category.trim());
    }
    return Array.from(set).sort((a, b) => a.localeCompare(b, "tr"));
  }, [products]);

  const filteredProductCostAnalysis = useMemo(() => {
    return productCostAnalysis.filter((item) => {
      if (search.trim()) {
        const q = search.trim().toLocaleLowerCase("tr");
        const matchName = item.productName.toLocaleLowerCase("tr").includes(q);
        const matchCode = item.code.toLocaleLowerCase("tr").includes(q);
        const matchBarcode = item.barcode.toLocaleLowerCase("tr").includes(q);
        const matchCategory = item.category.toLocaleLowerCase("tr").includes(q);
        if (!matchName && !matchCode && !matchBarcode && !matchCategory) return false;
      }
      if (categoryFilter !== "ALL" && item.category !== categoryFilter) return false;
      if (stockStatusFilter === "IN_STOCK" && item.stockQty <= 0) return false;
      if (stockStatusFilter === "OUT_OF_STOCK" && item.stockQty > 0) return false;
      if (stockStatusFilter === "CRITICAL") {
        const isCritical =
          item.trackStock === true && item.minStock > 0 && item.stockQty <= item.minStock;
        if (!isCritical) return false;
      }
      if (stockStatusFilter === "NO_TRACK" && item.trackStock !== false) return false;
      return true;
    });
  }, [productCostAnalysis, search, categoryFilter, stockStatusFilter]);

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
    queryClient.invalidateQueries({ queryKey: ["products"] });
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

  const addMovement = useMutation({
    mutationFn: async () => {
      const quantity = Number(form.quantity);
      if (!form.productId) throw new Error("Lütfen ürün seçin.");
      if (!quantity || quantity <= 0) throw new Error("Geçerli bir miktar girin.");
      const userId = await currentUserId();

      if (form.movementType === "TRANSFER") {
        if (
          !form.warehouseId ||
          !form.targetWarehouseId ||
          form.warehouseId === form.targetWarehouseId
        ) {
          throw new Error("Farklı kaynak ve hedef depo seçiniz.");
        }
        const { data, error } = await supabase.rpc("process_manual_stock_movement", {
          p_product_id: form.productId,
          p_movement_type: "TRANSFER",
          p_quantity: quantity,
          p_unit_price: Number(form.unitPrice) || 0,
          p_warehouse_id: form.warehouseId,
          p_target_warehouse_id: form.targetWarehouseId,
          p_movement_date: form.movementDate,
          p_document_no: form.documentNo,
          p_description: form.description || "Depo transfer hareketi"
        });
        if (error) throw error;
        if (data && !data.success) throw new Error(data.message || "Transfer basarisiz.");
        return;
      }

      const { data, error } = await supabase.rpc("process_manual_stock_movement", {
        p_product_id: form.productId,
        p_movement_type: form.movementType,
        p_quantity: quantity,
        p_unit_price: Number(form.unitPrice) || 0,
        p_warehouse_id: form.warehouseId || null,
        p_target_warehouse_id: null,
        p_movement_date: form.movementDate,
        p_document_no: form.documentNo,
        p_description: form.description
      });
      if (error) throw error;
      if (data && !data.success) throw new Error(data.message || "Stok hareketi basarisiz.");
    },
    onSuccess: () => {
      toast.success("Stok hareketi kaydedildi.");
      setForm({ ...emptyMovement, movementDate: today() });
      setMovementOpen(false);
      refresh();
    },
    onError: (e: Error) => toast.error(e.message),
  });

  // STOK DEĞERLEME FİŞİ MUTASYONU (create_stock_valuation_adjustment)
  const createValuationMutation = useMutation({
    mutationFn: async () => {
      if (!valForm.productId) throw new Error("Lütfen değerlenecek ürünü seçin.");
      if (!valForm.warehouseId) throw new Error("Lütfen ilgili depoyu seçin.");
      if (!valForm.valuationDate) throw new Error("Değerleme tarihi zorunludur.");

      const { data, error } = await supabase.rpc("create_stock_valuation_adjustment", {
        p_product_id: valForm.productId,
        p_warehouse_id: valForm.warehouseId,
        p_valuation_date: valForm.valuationDate,
        p_new_unit_cost: Number(valForm.newUnitCost) || 0,
        p_adjustment_qty: Number(valForm.adjustmentQty) || 0,
        p_description: valForm.description.trim() || undefined,
        p_document_no: valForm.documentNo.trim() || undefined,
      });

      if (error) throw error;
      return data;
    },
    onSuccess: (data: any) => {
      toast.success(
        `Stok değerleme fişi oluşturuldu. ${data?.journal_number ? `(Yevmiye: ${data.journal_number})` : ""} Maliyet Etkisi: ${formatMoney(Math.abs(data?.cost_impact || 0))} TL`,
      );
      setValuationOpen(false);
      refresh();
      queryClient.invalidateQueries({ queryKey: ["accounting-periods"] });
      queryClient.invalidateQueries({ queryKey: ["journal-entries"] });
    },
    onError: (e: Error) => toast.error(e.message || "Değerleme fişi oluşturulamadı."),
  });

  function handleOpenValuationModal(p?: any) {
    const defaultWarehouseId = warehouses[0]?.id || "";
    if (p) {
      const currentCost = p.purchase_price ? String(p.purchase_price) : "";
      setValForm({
        productId: p.id,
        warehouseId: defaultWarehouseId,
        valuationDate: today(),
        newUnitCost: currentCost,
        adjustmentQty: "0",
        documentNo: "",
        description: `Stok Değerleme & Maliyet Düzeltmesi: ${p.name}`,
      });
    } else {
      setValForm({
        productId: products[0]?.id || "",
        warehouseId: defaultWarehouseId,
        valuationDate: today(),
        newUnitCost: "",
        adjustmentQty: "0",
        documentNo: "",
        description: "Stok Değerleme ve Sayım Farkı Düzeltme Fişi",
      });
    }
    setValuationOpen(true);
  }

  // STOK KARTI GÜNCELLEME (Ana Kart Verisi)
  const updateProductCardMutation = useMutation({
    mutationFn: async () => {
      if (!editForm.id) throw new Error("Ürün kimliği bulunamadı.");
      if (!editForm.name.trim()) throw new Error("Ürün adı boş olamaz.");
      const userId = await currentUserId();

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
          min_stock: Number(editForm.minStock) || 0,
          updated_at: new Date().toISOString(),
        })
        .eq("id", editForm.id)
        .eq("user_id", userId);

      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Stok kartı ana verileri güncellendi.");
      setEditProductOpen(false);
      refresh();
    },
    onError: (e: Error) => toast.error(e.message),
  });

  function handleOpenEditProduct(p: any) {
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
    });
    setEditProductOpen(true);
  }

  const [copyOpen, setCopyOpen] = useState(false);
  const [copyForm, setCopyForm] = useState(emptyProductEdit);

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
    });
    setCopyOpen(true);
  }

  const duplicateProduct = useMutation({
    mutationFn: async () => {
      if (!copyForm.name.trim()) throw new Error("Ürün adı boş olamaz.");
      const userId = await currentUserId();
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
        min_stock: Number(copyForm.minStock) || 0,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Yeni stok kartı kopyalanarak oluşturuldu.");
      setCopyOpen(false);
      refresh();
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const removeMovement = useMutation({
    mutationFn: async (id: string) => {
      const userId = await currentUserId();
      await safeSoftDelete("stock_movements", id, userId);
    },
    onSuccess: () => {
      toast.success("Stok hareketi silindi.");
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
      filteredProductCostAnalysis.map((item) => [
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
      title="Stok, Depo & Değerleme Yönetimi"
      subtitle="Çoklu depo takibi, stok hareketleri, maliyet analizi ve resmi değerleme fişi işlemleri"
      actions={
        <div className="flex flex-wrap gap-2">
          {/* DEĞERLEME FİŞİ KES BUTONU */}
          <Button
            onClick={() => handleOpenValuationModal()}
            className="gap-1.5 bg-emerald-600 hover:bg-emerald-700 text-white text-xs h-9"
          >
            <Sparkles className="size-4" /> Değerleme Fişi Kes
          </Button>

          <Dialog open={warehouseOpen} onOpenChange={setWarehouseOpen}>
            <DialogTrigger asChild>
              <Button variant="outline" size="sm" className="gap-1.5 text-xs h-9">
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
              <Button size="sm" className="gap-1.5 text-xs h-9">
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
                  <Label htmlFor="qty">Miktar *</Label>
                  <Input
                    id="qty"
                    type="number"
                    step="0.01"
                    required
                    placeholder="1"
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
                      <SelectValue placeholder="Depo seçin" />
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
                    <Label>Hedef Depo *</Label>
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
                    <Label htmlFor="unitPrice">Birim Fiyat (TL)</Label>
                    <Input
                      id="unitPrice"
                      type="number"
                      step="0.01"
                      placeholder="0.00"
                      value={form.unitPrice}
                      onChange={(e) => setForm({ ...form, unitPrice: e.target.value })}
                    />
                  </div>
                )}

                <div className="space-y-1">
                  <Label htmlFor="mdate">Hareket Tarihi</Label>
                  <Input
                    id="mdate"
                    type="date"
                    value={form.movementDate}
                    onChange={(e) => setForm({ ...form, movementDate: e.target.value })}
                  />
                </div>
                <div className="space-y-1">
                  <Label htmlFor="docno">Belge No / İrsaliye</Label>
                  <Input
                    id="docno"
                    placeholder="İRS-2026-001"
                    value={form.documentNo}
                    onChange={(e) => setForm({ ...form, documentNo: e.target.value })}
                  />
                </div>
                <div className="space-y-1 sm:col-span-2">
                  <Label htmlFor="mdesc">Açıklama</Label>
                  <Input
                    id="mdesc"
                    placeholder="Stok hareket notu veya irsaliye açıklaması"
                    value={form.description}
                    onChange={(e) => setForm({ ...form, description: e.target.value })}
                  />
                </div>
                <div className="sm:col-span-2 pt-2">
                  <Button type="submit" className="w-full" disabled={addMovement.isPending}>
                    {addMovement.isPending ? "Kaydediliyor…" : "Hareketi Kaydet"}
                  </Button>
                </div>
              </form>
            </DialogContent>
          </Dialog>
        </div>
      }
    >
      <Tabs defaultValue="valuation" className="space-y-6">
        <TabsList className="grid w-full grid-cols-3 sm:w-[500px]">
          <TabsTrigger value="valuation" className="gap-2">
            <Calculator className="size-4" /> Maliyet Analizi & Değerleme
          </TabsTrigger>
          <TabsTrigger value="movements" className="gap-2">
            <Boxes className="size-4" /> Stok Hareketleri
          </TabsTrigger>
          <TabsTrigger value="warehouses" className="gap-2">
            <Warehouse className="size-4" /> Depolar ({warehouses.length})
          </TabsTrigger>
        </TabsList>

        {/* TAB 1: MALİYET VE DEĞERLEME PANELİ */}
        <TabsContent value="valuation" className="space-y-4">
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <Card>
              <CardContent className="pt-4">
                <p className="text-xs text-muted-foreground uppercase font-medium">Toplam Stok Adedi</p>
                <p className="text-2xl font-bold mt-1 font-mono">{costSummary.totalStockQty}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-4">
                <p className="text-xs text-muted-foreground uppercase font-medium">Toplam Stok Maliyet Değeri</p>
                <p className="text-2xl font-bold mt-1 text-primary">{formatMoney(costSummary.totalCostVal)}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-4">
                <p className="text-xs text-muted-foreground uppercase font-medium">Tahmini Satış Değeri</p>
                <p className="text-2xl font-bold mt-1">{formatMoney(costSummary.totalSaleVal)}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-4">
                <p className="text-xs text-muted-foreground uppercase font-medium">Ortalama Kâr Marjı</p>
                <p className="text-2xl font-bold mt-1 text-emerald-600">
                  %{costSummary.overallMargin.toFixed(1)}
                </p>
              </CardContent>
            </Card>
          </div>

          <Card>
            <CardHeader className="space-y-4">
              <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
                <div>
                  <CardTitle className="text-base">Maliyet Yöntemi & Stok Değerleme</CardTitle>
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
              </div>

              {/* GELİŞMİŞ FİLTRE PANELİ */}
              <div className="pt-2 flex flex-wrap items-center justify-between gap-2 border-t border-border/40">
                <div className="flex flex-wrap items-center gap-2 flex-1 min-w-[280px]">
                  <div className="relative flex-1 min-w-[180px] sm:max-w-xs">
                    <Search className="absolute left-2.5 top-2.5 size-3.5 text-muted-foreground" />
                    <Input
                      placeholder="Ara: ad, kod, barkod, kategori..."
                      value={search}
                      onChange={(e) => setSearch(e.target.value)}
                      className="pl-8 h-8 text-xs bg-background"
                    />
                  </div>

                  <Select value={categoryFilter} onValueChange={setCategoryFilter}>
                    <SelectTrigger className="h-8 text-xs w-[140px] sm:w-[160px] bg-background">
                      <SelectValue placeholder="Tüm Kategoriler" />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="ALL">Tüm Kategoriler</SelectItem>
                      {categories.map((c) => (
                        <SelectItem key={c} value={c}>
                          {c}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>

                  <Select value={stockStatusFilter} onValueChange={setStockStatusFilter}>
                    <SelectTrigger className="h-8 text-xs w-[150px] sm:w-[170px] bg-background">
                      <SelectValue placeholder="Stok Durumu" />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="ALL">Tüm Stok Durumları</SelectItem>
                      <SelectItem value="IN_STOCK">Stokta Var</SelectItem>
                      <SelectItem value="OUT_OF_STOCK">Stokta Yok / Tükenen</SelectItem>
                      <SelectItem value="CRITICAL">Kritik Stok Seviyesinde</SelectItem>
                      <SelectItem value="NO_TRACK">Stok Takibi Yok</SelectItem>
                    </SelectContent>
                  </Select>

                  {(search || categoryFilter !== "ALL" || stockStatusFilter !== "ALL") && (
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => {
                        setSearch("");
                        setCategoryFilter("ALL");
                        setStockStatusFilter("ALL");
                      }}
                      className="h-8 text-xs text-muted-foreground hover:text-foreground"
                    >
                      Temizle
                    </Button>
                  )}
                </div>

                <span className="text-xs text-muted-foreground font-mono shrink-0">
                  {filteredProductCostAnalysis.length} / {productCostAnalysis.length} ürün
                </span>
              </div>
            </CardHeader>
            <CardContent>
              {productCostAnalysis.length === 0 ? (
                <p className="text-sm text-muted-foreground py-4">Ürün kartı bulunmuyor.</p>
              ) : filteredProductCostAnalysis.length === 0 ? (
                <div className="py-12 text-center space-y-3">
                  <p className="text-sm text-muted-foreground">Filtrelere uygun ürün bulunamadı.</p>
                </div>
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
                        <th className="py-2.5 pr-4 text-right">Toplam Değer</th>
                        <th className="py-2.5 pr-4 text-right">Kar Marjı</th>
                        <th className="py-2.5 text-right">İşlemler</th>
                      </tr>
                    </thead>
                    <tbody>
                      {filteredProductCostAnalysis.map((item) => {
                        const originalProduct = products.find((p) => p.id === item.productId);
                        const isCritical =
                          item.trackStock === true &&
                          item.minStock > 0 &&
                          item.stockQty <= item.minStock;

                        return (
                          <tr key={item.productId} className="border-b border-border/60 hover:bg-muted/30 last:border-0">
                            <td className="py-3 pr-4 font-medium">
                              {item.productName}
                              <span className="ml-1 text-xs text-muted-foreground">({item.unit})</span>
                            </td>
                            <td className="py-3 pr-4 text-right font-semibold">
                              <span>{item.stockQty}</span>
                              {isCritical && (
                                <Badge variant="destructive" className="ml-1.5 text-[10px] px-1.5 py-0 leading-tight">
                                  Kritik
                                </Badge>
                              )}
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
                            <td className="py-3 pr-4 text-right">
                              <Badge variant={item.profitMarginPct >= 0 ? "secondary" : "destructive"}>
                                %{item.profitMarginPct.toFixed(1)}
                              </Badge>
                            </td>
                            <td className="py-3 text-right whitespace-nowrap space-x-1">
                              {/* DEĞERLEME FİŞİ KES BUTONU */}
                              <Button
                                variant="outline"
                                size="sm"
                                title="Bu ürüne değerleme fişi kes"
                                className="h-7 text-xs gap-1 px-2 text-emerald-700 dark:text-emerald-400 border-emerald-500/30 hover:bg-emerald-500/10"
                                onClick={() => handleOpenValuationModal(originalProduct)}
                              >
                                <Sparkles className="size-3 text-emerald-600" /> Değerle
                              </Button>

                              {/* STOK KARTI GÜNCELLE */}
                              {originalProduct && (
                                <Button
                                  variant="outline"
                                  size="sm"
                                  title="Stok Kartı Bilgilerini Güncelle"
                                  className="h-7 text-xs gap-1 px-2"
                                  onClick={() => handleOpenEditProduct(originalProduct)}
                                >
                                  <Pencil className="size-3 text-primary" /> Güncelle
                                </Button>
                              )}

                              {originalProduct && (
                                <Button
                                  variant="ghost"
                                  size="sm"
                                  title="Stok Kartını Kopyala"
                                  className="h-7 text-xs gap-1 px-2"
                                  onClick={() => handleOpenCopyModal(originalProduct)}
                                >
                                  <Copy className="size-3" /> Kopyala
                                </Button>
                              )}
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

        {/* TAB 2: STOK HAREKETLERİ */}
        <TabsContent value="movements" className="space-y-4">
          <Card>
            <CardHeader className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
              <CardTitle className="text-base">Stok Hareket Kayıtları</CardTitle>
              <div className="flex items-center gap-2">
                <Button variant="outline" size="sm" onClick={exportMovements} className="gap-1.5 text-xs">
                  <Download className="size-3.5" /> Dışa Aktar
                </Button>
              </div>
            </CardHeader>
            <CardContent>
              {filteredMovements.length === 0 ? (
                <p className="text-sm text-muted-foreground py-4">Kayıtlı stok hareketi bulunamadı.</p>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground">
                        <th className="py-2.5 pr-4">Tarih</th>
                        <th className="py-2.5 pr-4">Ürün</th>
                        <th className="py-2.5 pr-4">Tür</th>
                        <th className="py-2.5 pr-4">Depo</th>
                        <th className="py-2.5 pr-4 text-right">Miktar</th>
                        <th className="py-2.5 pr-4 text-right">Birim Maliyet</th>
                        <th className="py-2.5 pr-4">Belge No</th>
                        <th className="py-2.5 pr-4">Açıklama</th>
                        <th className="py-2.5 text-right" />
                      </tr>
                    </thead>
                    <tbody>
                      {filteredMovements.map((m) => (
                        <tr key={m.id} className="border-b border-border/60 hover:bg-muted/30 last:border-0">
                          <td className="py-3 pr-4 font-mono text-xs">{formatDate(m.movement_date)}</td>
                          <td className="py-3 pr-4 font-medium">{productMap.get(m.product_id)?.name ?? "-"}</td>
                          <td className="py-3 pr-4">
                            <Badge
                              variant={
                                m.movement_type === "GIRIS"
                                  ? "default"
                                  : m.movement_type === "CIKIS"
                                    ? "destructive"
                                    : "secondary"
                              }
                              className="text-[10px]"
                            >
                              {STOCK_LABELS[m.movement_type as StockMovementType] ?? m.movement_type}
                            </Badge>
                          </td>
                          <td className="py-3 pr-4">{warehouseMap.get(m.warehouse_id)?.name ?? "-"}</td>
                          <td className="py-3 pr-4 text-right font-mono font-semibold">
                            {m.movement_type === "CIKIS" ? "-" : "+"}
                            {m.quantity}
                          </td>
                          <td className="py-3 pr-4 text-right font-mono">
                            {formatMoney(Number(m.unit_price))}
                          </td>
                          <td className="py-3 pr-4 font-mono text-xs">{m.document_no || "-"}</td>
                          <td className="py-3 pr-4 text-xs text-muted-foreground">{m.description || "-"}</td>
                          <td className="py-3 text-right">
                            <Button
                              variant="ghost"
                              size="sm"
                              className="text-destructive text-xs h-7 px-2"
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

        {/* TAB 3: DEPOLAR */}
        <TabsContent value="warehouses" className="space-y-4">
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            {warehouses.map((w) => (
              <Card key={w.id}>
                <CardHeader className="pb-2">
                  <div className="flex items-center justify-between">
                    <CardTitle className="text-base flex items-center gap-2">
                      <Warehouse className="size-4 text-primary" /> {w.name}
                    </CardTitle>
                    {w.is_default && <Badge variant="secondary" className="text-[10px]">Varsayılan</Badge>}
                  </div>
                </CardHeader>
                <CardContent className="space-y-2">
                  <p className="text-xs text-muted-foreground">{w.address || "Adres belirtilmemiş."}</p>
                </CardContent>
              </Card>
            ))}
          </div>
        </TabsContent>
      </Tabs>

      {/* DEĞERLEME FİŞİ KES MODALI */}
      <Dialog open={valuationOpen} onOpenChange={setValuationOpen}>
        <DialogContent className="max-h-[85vh] overflow-y-auto sm:max-w-[550px]">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2">
              <Sparkles className="size-5 text-emerald-600" />
              Stok Değerleme & Maliyet Düzeltme Fişi
            </DialogTitle>
          </DialogHeader>
          <div className="p-3 bg-emerald-50 dark:bg-emerald-950/20 rounded-md text-xs space-y-1 text-emerald-800 dark:text-emerald-300 border border-emerald-200 dark:border-emerald-900 mb-2">
            <p className="font-semibold flex items-center gap-1.5">
              <CheckCircle2 className="size-4" /> Otomatik Muhasebe Entegrasyonu
            </p>
            <p>
              Değerleme fişi kesildiğinde stok hareketi oluşturulur ve oluşan fark tutarı 153 Ticari Mallar ↔ 649 Gelir / 659 Gider hesapları ile otomatik yevmiye fişine (DEGERLEME) bağlanır.
            </p>
          </div>

          <form
            onSubmit={(e) => {
              e.preventDefault();
              createValuationMutation.mutate();
            }}
            className="space-y-4 pt-2"
          >
            <div className="space-y-1">
              <Label>Değerlenecek Ürün *</Label>
              <Select
                value={valForm.productId}
                onValueChange={(v) => {
                  const p = products.find((prod) => prod.id === v);
                  setValForm({
                    ...valForm,
                    productId: v,
                    newUnitCost: p?.purchase_price ? String(p.purchase_price) : valForm.newUnitCost,
                  });
                }}
              >
                <SelectTrigger>
                  <SelectValue placeholder="Ürün seçin" />
                </SelectTrigger>
                <SelectContent>
                  {products.map((p) => (
                    <SelectItem key={p.id} value={p.id}>
                      {p.name} {p.code ? `(${p.code})` : ""} — Mevcut Alış: {formatMoney(Number(p.purchase_price ?? 0))} TL
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            <div className="grid grid-cols-2 gap-4">
              <div className="space-y-1">
                <Label>Depo *</Label>
                <Select
                  value={valForm.warehouseId}
                  onValueChange={(v) => setValForm({ ...valForm, warehouseId: v })}
                >
                  <SelectTrigger>
                    <SelectValue placeholder="Depo seçin" />
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
              <div className="space-y-1">
                <Label htmlFor="val-date">Değerleme Tarihi *</Label>
                <Input
                  id="val-date"
                  type="date"
                  required
                  value={valForm.valuationDate}
                  onChange={(e) => setValForm({ ...valForm, valuationDate: e.target.value })}
                />
              </div>
            </div>

            <div className="grid grid-cols-2 gap-4">
              <div className="space-y-1">
                <Label htmlFor="val-newCost">Yeni Birim Alış Maliyeti (TL)</Label>
                <Input
                  id="val-newCost"
                  type="number"
                  step="0.01"
                  placeholder="0.00"
                  value={valForm.newUnitCost}
                  onChange={(e) => setValForm({ ...valForm, newUnitCost: e.target.value })}
                />
                <p className="text-[10px] text-muted-foreground">Maliyet güncellemesi için girin.</p>
              </div>
              <div className="space-y-1">
                <Label htmlFor="val-adjQty">Sayım Miktar Farkı (± Adet)</Label>
                <Input
                  id="val-adjQty"
                  type="number"
                  step="0.01"
                  placeholder="0"
                  value={valForm.adjustmentQty}
                  onChange={(e) => setValForm({ ...valForm, adjustmentQty: e.target.value })}
                />
                <p className="text-[10px] text-muted-foreground">Sayım fazlası (+), sayım eksiği (-).</p>
              </div>
            </div>

            <div className="space-y-1">
              <Label htmlFor="val-docNo">Belge No / Fiş No</Label>
              <Input
                id="val-docNo"
                placeholder="Örn: SAYIM-2026-08"
                value={valForm.documentNo}
                onChange={(e) => setValForm({ ...valForm, documentNo: e.target.value })}
              />
            </div>

            <div className="space-y-1">
              <Label htmlFor="val-desc">Açıklama</Label>
              <Input
                id="val-desc"
                placeholder="Stok değerleme gerekçesi veya sayım tutanağı notu"
                value={valForm.description}
                onChange={(e) => setValForm({ ...valForm, description: e.target.value })}
              />
            </div>

            <div className="flex gap-2 pt-2">
              <Button type="button" variant="outline" className="flex-1" onClick={() => setValuationOpen(false)}>
                İptal
              </Button>
              <Button
                type="submit"
                className="flex-1 bg-emerald-600 hover:bg-emerald-700 text-white"
                disabled={createValuationMutation.isPending}
              >
                {createValuationMutation.isPending ? "Değerleme Yapılıyor…" : "Değerleme Fişini Kes"}
              </Button>
            </div>
          </form>
        </DialogContent>
      </Dialog>

      {/* STOK KARTI GÜNCELLEME (EDIT) MODALI */}
      <Dialog open={editProductOpen} onOpenChange={setEditProductOpen}>
        <DialogContent className="max-h-[85vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2">
              <Pencil className="size-4 text-primary" /> Stok Kartını Güncelle
            </DialogTitle>
          </DialogHeader>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              updateProductCardMutation.mutate();
            }}
            className="space-y-4 pt-2"
          >
            <div className="grid grid-cols-2 gap-4">
              <div>
                <Label htmlFor="stk-code">Ürün Kodu</Label>
                <Input
                  id="stk-code"
                  value={editForm.code}
                  onChange={(e) => setEditForm({ ...editForm, code: e.target.value })}
                />
              </div>
              <div>
                <Label htmlFor="stk-barcode">Barkod</Label>
                <Input
                  id="stk-barcode"
                  value={editForm.barcode}
                  onChange={(e) => setEditForm({ ...editForm, barcode: e.target.value })}
                />
              </div>
            </div>

            <div>
              <Label htmlFor="stk-name">Ürün Adı *</Label>
              <Input
                id="stk-name"
                required
                value={editForm.name}
                onChange={(e) => setEditForm({ ...editForm, name: e.target.value })}
              />
            </div>

            <div className="grid grid-cols-2 gap-4">
              <div>
                <Label htmlFor="stk-category">Kategori</Label>
                <Input
                  id="stk-category"
                  value={editForm.category}
                  onChange={(e) => setEditForm({ ...editForm, category: e.target.value })}
                />
              </div>
              <div>
                <Label htmlFor="stk-unit">Birim</Label>
                <Input
                  id="stk-unit"
                  value={editForm.unit}
                  onChange={(e) => setEditForm({ ...editForm, unit: e.target.value })}
                />
              </div>
            </div>

            <div className="grid grid-cols-2 gap-4">
              <div>
                <Label htmlFor="stk-purchasePrice">Birim Alış Fiyatı (TL)</Label>
                <Input
                  id="stk-purchasePrice"
                  type="number"
                  step="0.01"
                  value={editForm.purchasePrice}
                  onChange={(e) => setEditForm({ ...editForm, purchasePrice: e.target.value })}
                />
              </div>
              <div>
                <Label htmlFor="stk-unitPrice">Birim Satış Fiyatı (TL) *</Label>
                <Input
                  id="stk-unitPrice"
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
                <Label htmlFor="stk-vatRate">KDV Oranı (%)</Label>
                <Input
                  id="stk-vatRate"
                  type="number"
                  value={editForm.vatRate}
                  onChange={(e) => setEditForm({ ...editForm, vatRate: e.target.value })}
                />
              </div>
              <div>
                <Label htmlFor="stk-discountRate">İskonto (%)</Label>
                <Input
                  id="stk-discountRate"
                  type="number"
                  value={editForm.discountRate}
                  onChange={(e) => setEditForm({ ...editForm, discountRate: e.target.value })}
                />
              </div>
              <div>
                <Label htmlFor="stk-minStock">Asgari Stok</Label>
                <Input
                  id="stk-minStock"
                  type="number"
                  value={editForm.minStock}
                  onChange={(e) => setEditForm({ ...editForm, minStock: e.target.value })}
                />
              </div>
            </div>

            <div>
              <Label htmlFor="stk-description">Açıklama</Label>
              <Input
                id="stk-description"
                value={editForm.description}
                onChange={(e) => setEditForm({ ...editForm, description: e.target.value })}
              />
            </div>

            <div className="flex gap-2 pt-2">
              <Button type="button" variant="outline" className="flex-1" onClick={() => setEditProductOpen(false)}>
                İptal
              </Button>
              <Button type="submit" className="flex-1" disabled={updateProductCardMutation.isPending}>
                {updateProductCardMutation.isPending ? "Kaydediliyor…" : "Kaydet"}
              </Button>
            </div>
          </form>
        </DialogContent>
      </Dialog>

      {/* KOPYALAMA MODALI */}
      <Dialog open={copyOpen} onOpenChange={setCopyOpen}>
        <DialogContent className="max-h-[85vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2">
              <Copy className="size-4 text-primary" /> Stok Kartı Kopyala
            </DialogTitle>
          </DialogHeader>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              duplicateProduct.mutate();
            }}
            className="space-y-4 pt-2"
          >
            <div className="grid grid-cols-2 gap-4">
              <div>
                <Label htmlFor="cpy-code">Yeni Ürün Kodu</Label>
                <Input
                  id="cpy-code"
                  value={copyForm.code}
                  onChange={(e) => setCopyForm({ ...copyForm, code: e.target.value })}
                />
              </div>
              <div>
                <Label htmlFor="cpy-barcode">Yeni Barkod</Label>
                <Input
                  id="cpy-barcode"
                  value={copyForm.barcode}
                  onChange={(e) => setCopyForm({ ...copyForm, barcode: e.target.value })}
                />
              </div>
            </div>

            <div>
              <Label htmlFor="cpy-name">Ürün Adı *</Label>
              <Input
                id="cpy-name"
                required
                value={copyForm.name}
                onChange={(e) => setCopyForm({ ...copyForm, name: e.target.value })}
              />
            </div>

            <div className="grid grid-cols-2 gap-4">
              <div>
                <Label htmlFor="cpy-category">Kategori</Label>
                <Input
                  id="cpy-category"
                  value={copyForm.category}
                  onChange={(e) => setCopyForm({ ...copyForm, category: e.target.value })}
                />
              </div>
              <div>
                <Label htmlFor="cpy-unit">Birim</Label>
                <Input
                  id="cpy-unit"
                  value={copyForm.unit}
                  onChange={(e) => setCopyForm({ ...copyForm, unit: e.target.value })}
                />
              </div>
            </div>

            <div className="grid grid-cols-2 gap-4">
              <div>
                <Label htmlFor="cpy-purchasePrice">Birim Alış Fiyatı (TL)</Label>
                <Input
                  id="cpy-purchasePrice"
                  type="number"
                  step="0.01"
                  value={copyForm.purchasePrice}
                  onChange={(e) => setCopyForm({ ...copyForm, purchasePrice: e.target.value })}
                />
              </div>
              <div>
                <Label htmlFor="cpy-unitPrice">Birim Satış Fiyatı (TL) *</Label>
                <Input
                  id="cpy-unitPrice"
                  type="number"
                  step="0.01"
                  required
                  value={copyForm.unitPrice}
                  onChange={(e) => setCopyForm({ ...copyForm, unitPrice: e.target.value })}
                />
              </div>
            </div>

            <div className="flex gap-2 pt-2">
              <Button type="button" variant="outline" className="flex-1" onClick={() => setCopyOpen(false)}>
                İptal
              </Button>
              <Button type="submit" className="flex-1" disabled={duplicateProduct.isPending}>
                {duplicateProduct.isPending ? "Kopyalanıyor…" : "Kopyayı Kaydet"}
              </Button>
            </div>
          </form>
        </DialogContent>
      </Dialog>
    </AppShell>
  );
}
