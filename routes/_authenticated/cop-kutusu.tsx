import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import { Trash2, RotateCcw, ShieldAlert, History, FileText, Users, Package, ShoppingBag, Warehouse as WarehouseIcon, Activity } from "lucide-react";
import { toast } from "sonner";

import { AppShell } from "@/components/AppShell";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { supabase } from "@/integrations/supabase/client";
import { safeFetchTrash } from "@/lib/safe-supabase";
import { formatMoney } from "@/lib/invoice";

export const Route = createFileRoute("/_authenticated/cop-kutusu")({
  head: () => ({
    meta: [{ title: "Çöp Kutusu ve İşlem Geçmişi — Magic Receipt" }],
  }),
  component: TrashBinPage,
});

type TableType =
  | "invoices"
  | "customers"
  | "products"
  | "pos_sales"
  | "warehouses"
  | "stock_movements"
  | "account_transactions";

function TrashBinPage() {
  const queryClient = useQueryClient();
  const [activeTab, setActiveTab] = useState<string>("invoices");
  const [logDetail, setLogDetail] = useState<any | null>(null);

  // Soft deleted records queries
  const { data: deletedInvoices = [], isLoading: loadingInvoices } = useQuery({
    queryKey: ["trash", "invoices"],
    queryFn: () =>
      safeFetchTrash(() =>
        supabase
          .from("invoices")
          .select("*")
          .not("deleted_at", "is", null)
          .order("deleted_at", { ascending: false }),
      ),
  });

  const { data: deletedCustomers = [], isLoading: loadingCustomers } = useQuery({
    queryKey: ["trash", "customers"],
    queryFn: () =>
      safeFetchTrash(() =>
        supabase
          .from("customers")
          .select("*")
          .not("deleted_at", "is", null)
          .order("deleted_at", { ascending: false }),
      ),
  });

  const { data: deletedProducts = [], isLoading: loadingProducts } = useQuery({
    queryKey: ["trash", "products"],
    queryFn: () =>
      safeFetchTrash(() =>
        supabase
          .from("products")
          .select("*")
          .not("deleted_at", "is", null)
          .order("deleted_at", { ascending: false }),
      ),
  });

  const { data: deletedPosSales = [], isLoading: loadingPosSales } = useQuery({
    queryKey: ["trash", "pos_sales"],
    queryFn: () =>
      safeFetchTrash(() =>
        supabase
          .from("pos_sales")
          .select("*")
          .not("deleted_at", "is", null)
          .order("deleted_at", { ascending: false }),
      ),
  });

  const { data: deletedWarehouses = [], isLoading: loadingWarehouses } = useQuery({
    queryKey: ["trash", "warehouses"],
    queryFn: () =>
      safeFetchTrash(() =>
        supabase
          .from("warehouses")
          .select("*")
          .not("deleted_at", "is", null)
          .order("deleted_at", { ascending: false }),
      ),
  });

  const { data: deletedStockMovements = [], isLoading: loadingMovements } = useQuery({
    queryKey: ["trash", "stock_movements"],
    queryFn: () =>
      safeFetchTrash(() =>
        supabase
          .from("stock_movements")
          .select("*")
          .not("deleted_at", "is", null)
          .order("deleted_at", { ascending: false }),
      ),
  });

  const { data: deletedTransactions = [], isLoading: loadingTxns } = useQuery({
    queryKey: ["trash", "account_transactions"],
    queryFn: () =>
      safeFetchTrash(() =>
        supabase
          .from("account_transactions")
          .select("*")
          .not("deleted_at", "is", null)
          .order("deleted_at", { ascending: false }),
      ),
  });

  // Audit Logs Query
  const { data: auditLogs = [], isLoading: loadingAudit } = useQuery({
    queryKey: ["audit-logs"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("audit_logs")
        .select("*")
        .order("created_at", { ascending: false })
        .limit(200);
      if (error) throw error;
      return data ?? [];
    },
  });

  // Restore Mutation
  const restoreItem = useMutation({
    mutationFn: async ({ table, id }: { table: TableType; id: string }) => {
      const { error } = await supabase
        .from(table)
        .update({ deleted_at: null, deleted_by: null } as any)
        .eq("id", id);
      if (error) throw error;

      // If restoring an invoice, also restore associated account_transactions and stock_movements
      if (table === "invoices") {
        await supabase
          .from("account_transactions")
          .update({ deleted_at: null, deleted_by: null })
          .eq("source_id", id);
        await supabase
          .from("stock_movements")
          .update({ deleted_at: null, deleted_by: null })
          .eq("source_id", id);
      }
    },
    onSuccess: (_, variables) => {
      toast.success("Kayıt başarıyla geri yüklendi!");
      queryClient.invalidateQueries({ queryKey: ["trash"] });
      queryClient.invalidateQueries({ queryKey: ["invoices"] });
      queryClient.invalidateQueries({ queryKey: ["customers"] });
      queryClient.invalidateQueries({ queryKey: ["products"] });
      queryClient.invalidateQueries({ queryKey: ["pos-sales"] });
      queryClient.invalidateQueries({ queryKey: ["warehouses"] });
      queryClient.invalidateQueries({ queryKey: ["stock-movements"] });
      queryClient.invalidateQueries({ queryKey: ["all-stock-movements"] });
      queryClient.invalidateQueries({ queryKey: ["account-transactions"] });
      queryClient.invalidateQueries({ queryKey: ["customer-balances"] });
      queryClient.invalidateQueries({ queryKey: ["product-stocks"] });
      queryClient.invalidateQueries({ queryKey: ["audit-logs"] });
    },
    onError: (e: Error) => toast.error(`Geri yükleme hatası: ${e.message}`),
  });

  // Permanent Delete Mutation
  const hardDeleteItem = useMutation({
    mutationFn: async ({ table, id }: { table: TableType; id: string }) => {
      // If hard deleting an invoice, clean up associated transactions
      if (table === "invoices") {
        await supabase.from("account_transactions").delete().eq("source_id", id);
        await supabase.from("stock_movements").delete().eq("source_id", id);
      }
      const { error } = await supabase.from(table).delete().eq("id", id);
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Kayıt veritabanından kalıcı olarak silindi.");
      queryClient.invalidateQueries({ queryKey: ["trash"] });
      queryClient.invalidateQueries({ queryKey: ["audit-logs"] });
    },
    onError: (e: Error) => toast.error(`Kalıcı silme hatası: ${e.message}`),
  });

  const totalDeletedCount =
    deletedInvoices.length +
    deletedCustomers.length +
    deletedProducts.length +
    deletedPosSales.length +
    deletedWarehouses.length +
    deletedStockMovements.length +
    deletedTransactions.length;

  return (
    <AppShell activeHref="/cop-kutusu">
      <div className="space-y-6">
        <div className="flex flex-col gap-2 md:flex-row md:items-center md:justify-between">
          <div>
            <h1 className="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100 flex items-center gap-2">
              <Trash2 className="h-6 w-6 text-rose-500" />
              Çöp Kutusu ve Veri Güvenlik Merkezi
            </h1>
            <p className="text-sm text-slate-500 dark:text-slate-400">
              Silinen faturaları, carileri, ürünleri ve hareketleri geri yükleyin veya işlem geçmişini (Audit Log) inceleyin.
            </p>
          </div>
          <Badge variant="outline" className="w-fit text-sm py-1 px-3 border-amber-300 bg-amber-50 text-amber-800">
            <ShieldAlert className="w-4 h-4 mr-1 text-amber-600" />
            Toplam {totalDeletedCount} silinmiş kayıt
          </Badge>
        </div>

        <Tabs value={activeTab} onValueChange={setActiveTab} className="w-full">
          <TabsList className="grid w-full grid-cols-2 md:grid-cols-8 gap-1 h-auto p-1 bg-slate-100 dark:bg-slate-800 rounded-lg">
            <TabsTrigger value="invoices" className="flex items-center gap-1 text-xs py-2">
              <FileText className="w-3.5 h-3.5" />
              Faturalar ({deletedInvoices.length})
            </TabsTrigger>
            <TabsTrigger value="customers" className="flex items-center gap-1 text-xs py-2">
              <Users className="w-3.5 h-3.5" />
              Cariler ({deletedCustomers.length})
            </TabsTrigger>
            <TabsTrigger value="products" className="flex items-center gap-1 text-xs py-2">
              <Package className="w-3.5 h-3.5" />
              Ürünler ({deletedProducts.length})
            </TabsTrigger>
            <TabsTrigger value="pos_sales" className="flex items-center gap-1 text-xs py-2">
              <ShoppingBag className="w-3.5 h-3.5" />
              POS ({deletedPosSales.length})
            </TabsTrigger>
            <TabsTrigger value="warehouses" className="flex items-center gap-1 text-xs py-2">
              <WarehouseIcon className="w-3.5 h-3.5" />
              Depolar ({deletedWarehouses.length})
            </TabsTrigger>
            <TabsTrigger value="stock_movements" className="flex items-center gap-1 text-xs py-2">
              <Activity className="w-3.5 h-3.5" />
              Stok Har. ({deletedStockMovements.length})
            </TabsTrigger>
            <TabsTrigger value="account_transactions" className="flex items-center gap-1 text-xs py-2">
              <History className="w-3.5 h-3.5" />
              Cari Har. ({deletedTransactions.length})
            </TabsTrigger>
            <TabsTrigger value="audit_logs" className="flex items-center gap-1 text-xs py-2 font-medium text-indigo-600 dark:text-indigo-400">
              <History className="w-3.5 h-3.5" />
              Audit Log ({auditLogs.length})
            </TabsTrigger>
          </TabsList>

          {/* FATURALAR */}
          <TabsContent value="invoices" className="mt-4">
            <Card>
              <CardHeader>
                <CardTitle className="text-base font-semibold">Silinen Faturalar</CardTitle>
                <CardDescription>
                  Geri yüklenen faturalara ait cari hareketler ve stok kayıtları otomatik olarak sisteme tekrar işlenir.
                </CardDescription>
              </CardHeader>
              <CardContent>
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Silinme Tarihi</TableHead>
                      <TableHead>Fatura No</TableHead>
                      <TableHead>Tür</TableHead>
                      <TableHead>Tutar</TableHead>
                      <TableHead className="text-right">İşlemler</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {deletedInvoices.length === 0 ? (
                      <TableRow>
                        <TableCell colSpan={5} className="text-center py-6 text-slate-500">
                          Silinmiş fatura bulunmuyor.
                        </TableCell>
                      </TableRow>
                    ) : (
                      deletedInvoices.map((inv) => (
                        <TableRow key={inv.id}>
                          <TableCell className="text-xs text-slate-500">
                            {inv.deleted_at ? new Date(inv.deleted_at).toLocaleString("tr-TR") : "-"}
                          </TableCell>
                          <TableCell className="font-mono font-medium">{inv.invoice_number}</TableCell>
                          <TableCell>
                            <Badge variant="outline">{inv.type}</Badge>
                          </TableCell>
                          <TableCell className="font-semibold">{formatMoney(inv.grand_total)} TL</TableCell>
                          <TableCell className="text-right space-x-2">
                            <Button
                              size="sm"
                              variant="outline"
                              className="text-emerald-600 border-emerald-300 hover:bg-emerald-50"
                              onClick={() => restoreItem.mutate({ table: "invoices", id: inv.id })}
                            >
                              <RotateCcw className="w-3.5 h-3.5 mr-1" /> Geri Yükle
                            </Button>
                            <AlertDialog>
                              <AlertDialogTrigger asChild>
                                <Button size="sm" variant="destructive">
                                  <Trash2 className="w-3.5 h-3.5 mr-1" /> Kalıcı Sil
                                </Button>
                              </AlertDialogTrigger>
                              <AlertDialogContent>
                                <AlertDialogHeader>
                                  <AlertDialogTitle>Kalıcı Silme Onayı</AlertDialogTitle>
                                  <AlertDialogDescription>
                                    <strong>{inv.invoice_number}</strong> numaralı faturayı veritabanından kalıcı olarak silmek üzeresiniz. Bu işlem GERİ ALINAMAZ! Devam etmek istiyor musunuz?
                                  </AlertDialogDescription>
                                </AlertDialogHeader>
                                <AlertDialogFooter>
                                  <AlertDialogCancel>İptal</AlertDialogCancel>
                                  <AlertDialogAction onClick={() => hardDeleteItem.mutate({ table: "invoices", id: inv.id })}>
                                    Kalıcı Olarak Sil
                                  </AlertDialogAction>
                                </AlertDialogFooter>
                              </AlertDialogContent>
                            </AlertDialog>
                          </TableCell>
                        </TableRow>
                      ))
                    )}
                  </TableBody>
                </Table>
              </CardContent>
            </Card>
          </TabsContent>

          {/* CARİLER */}
          <TabsContent value="customers" className="mt-4">
            <Card>
              <CardHeader>
                <CardTitle className="text-base font-semibold">Silinen Cariler (Müşteri & Tedarikçiler)</CardTitle>
              </CardHeader>
              <CardContent>
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Silinme Tarihi</TableHead>
                      <TableHead>Unvan / İsim</TableHead>
                      <TableHead>VKN / TCKN</TableHead>
                      <TableHead>Tür</TableHead>
                      <TableHead className="text-right">İşlemler</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {deletedCustomers.length === 0 ? (
                      <TableRow>
                        <TableCell colSpan={5} className="text-center py-6 text-slate-500">
                          Silinmiş cari bulunmuyor.
                        </TableCell>
                      </TableRow>
                    ) : (
                      deletedCustomers.map((c) => (
                        <TableRow key={c.id}>
                          <TableCell className="text-xs text-slate-500">
                            {c.deleted_at ? new Date(c.deleted_at).toLocaleString("tr-TR") : "-"}
                          </TableCell>
                          <TableCell className="font-medium">{c.title}</TableCell>
                          <TableCell>{c.vkn_tckn || "-"}</TableCell>
                          <TableCell>
                            <Badge variant="secondary">{c.partner_type}</Badge>
                          </TableCell>
                          <TableCell className="text-right space-x-2">
                            <Button
                              size="sm"
                              variant="outline"
                              className="text-emerald-600 border-emerald-300 hover:bg-emerald-50"
                              onClick={() => restoreItem.mutate({ table: "customers", id: c.id })}
                            >
                              <RotateCcw className="w-3.5 h-3.5 mr-1" /> Geri Yükle
                            </Button>
                            <AlertDialog>
                              <AlertDialogTrigger asChild>
                                <Button size="sm" variant="destructive">
                                  <Trash2 className="w-3.5 h-3.5 mr-1" /> Kalıcı Sil
                                </Button>
                              </AlertDialogTrigger>
                              <AlertDialogContent>
                                <AlertDialogHeader>
                                  <AlertDialogTitle>Kalıcı Silme Onayı</AlertDialogTitle>
                                  <AlertDialogDescription>
                                    <strong>{c.title}</strong> cari kaydını veritabanından kalıcı olarak silmek üzeresiniz.
                                  </AlertDialogDescription>
                                </AlertDialogHeader>
                                <AlertDialogFooter>
                                  <AlertDialogCancel>İptal</AlertDialogCancel>
                                  <AlertDialogAction onClick={() => hardDeleteItem.mutate({ table: "customers", id: c.id })}>
                                    Kalıcı Olarak Sil
                                  </AlertDialogAction>
                                </AlertDialogFooter>
                              </AlertDialogContent>
                            </AlertDialog>
                          </TableCell>
                        </TableRow>
                      ))
                    )}
                  </TableBody>
                </Table>
              </CardContent>
            </Card>
          </TabsContent>

          {/* ÜRÜNLER */}
          <TabsContent value="products" className="mt-4">
            <Card>
              <CardHeader>
                <CardTitle className="text-base font-semibold">Silinen Ürünler ve Hizmetler</CardTitle>
              </CardHeader>
              <CardContent>
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Silinme Tarihi</TableHead>
                      <TableHead>Ürün Adı</TableHead>
                      <TableHead>Kod / Barkod</TableHead>
                      <TableHead>Satış Fiyatı</TableHead>
                      <TableHead className="text-right">İşlemler</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {deletedProducts.length === 0 ? (
                      <TableRow>
                        <TableCell colSpan={5} className="text-center py-6 text-slate-500">
                          Silinmiş ürün bulunmuyor.
                        </TableCell>
                      </TableRow>
                    ) : (
                      deletedProducts.map((p) => (
                        <TableRow key={p.id}>
                          <TableCell className="text-xs text-slate-500">
                            {p.deleted_at ? new Date(p.deleted_at).toLocaleString("tr-TR") : "-"}
                          </TableCell>
                          <TableCell className="font-medium">{p.name}</TableCell>
                          <TableCell className="font-mono text-xs">{p.code || p.barcode || "-"}</TableCell>
                          <TableCell className="font-semibold">{formatMoney(p.unit_price)} TL</TableCell>
                          <TableCell className="text-right space-x-2">
                            <Button
                              size="sm"
                              variant="outline"
                              className="text-emerald-600 border-emerald-300 hover:bg-emerald-50"
                              onClick={() => restoreItem.mutate({ table: "products", id: p.id })}
                            >
                              <RotateCcw className="w-3.5 h-3.5 mr-1" /> Geri Yükle
                            </Button>
                            <AlertDialog>
                              <AlertDialogTrigger asChild>
                                <Button size="sm" variant="destructive">
                                  <Trash2 className="w-3.5 h-3.5 mr-1" /> Kalıcı Sil
                                </Button>
                              </AlertDialogTrigger>
                              <AlertDialogContent>
                                <AlertDialogHeader>
                                  <AlertDialogTitle>Kalıcı Silme Onayı</AlertDialogTitle>
                                  <AlertDialogDescription>
                                    <strong>{p.name}</strong> ürün kaydını kalıcı olarak silmek üzeresiniz.
                                  </AlertDialogDescription>
                                </AlertDialogHeader>
                                <AlertDialogFooter>
                                  <AlertDialogCancel>İptal</AlertDialogCancel>
                                  <AlertDialogAction onClick={() => hardDeleteItem.mutate({ table: "products", id: p.id })}>
                                    Kalıcı Olarak Sil
                                  </AlertDialogAction>
                                </AlertDialogFooter>
                              </AlertDialogContent>
                            </AlertDialog>
                          </TableCell>
                        </TableRow>
                      ))
                    )}
                  </TableBody>
                </Table>
              </CardContent>
            </Card>
          </TabsContent>

          {/* POS SATIŞLARI */}
          <TabsContent value="pos_sales" className="mt-4">
            <Card>
              <CardHeader>
                <CardTitle className="text-base font-semibold">Silinen POS Satışları</CardTitle>
              </CardHeader>
              <CardContent>
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Silinme Tarihi</TableHead>
                      <TableHead>Satış Tarihi</TableHead>
                      <TableHead>Açıklama / Belge</TableHead>
                      <TableHead>Brüt Tutar</TableHead>
                      <TableHead className="text-right">İşlemler</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {deletedPosSales.length === 0 ? (
                      <TableRow>
                        <TableCell colSpan={5} className="text-center py-6 text-slate-500">
                          Silinmiş POS satışı bulunmuyor.
                        </TableCell>
                      </TableRow>
                    ) : (
                      deletedPosSales.map((ps) => (
                        <TableRow key={ps.id}>
                          <TableCell className="text-xs text-slate-500">
                            {ps.deleted_at ? new Date(ps.deleted_at).toLocaleString("tr-TR") : "-"}
                          </TableCell>
                          <TableCell>{ps.sale_date}</TableCell>
                          <TableCell>{ps.description || ps.document_no || "-"}</TableCell>
                          <TableCell className="font-semibold">{formatMoney(ps.gross_amount)} TL</TableCell>
                          <TableCell className="text-right space-x-2">
                            <Button
                              size="sm"
                              variant="outline"
                              className="text-emerald-600 border-emerald-300 hover:bg-emerald-50"
                              onClick={() => restoreItem.mutate({ table: "pos_sales", id: ps.id })}
                            >
                              <RotateCcw className="w-3.5 h-3.5 mr-1" /> Geri Yükle
                            </Button>
                            <AlertDialog>
                              <AlertDialogTrigger asChild>
                                <Button size="sm" variant="destructive">
                                  <Trash2 className="w-3.5 h-3.5 mr-1" /> Kalıcı Sil
                                </Button>
                              </AlertDialogTrigger>
                              <AlertDialogContent>
                                <AlertDialogHeader>
                                  <AlertDialogTitle>Kalıcı Silme Onayı</AlertDialogTitle>
                                  <AlertDialogDescription>Bu POS satışını kalıcı olarak silmek istiyor musunuz?</AlertDialogDescription>
                                </AlertDialogHeader>
                                <AlertDialogFooter>
                                  <AlertDialogCancel>İptal</AlertDialogCancel>
                                  <AlertDialogAction onClick={() => hardDeleteItem.mutate({ table: "pos_sales", id: ps.id })}>
                                    Kalıcı Olarak Sil
                                  </AlertDialogAction>
                                </AlertDialogFooter>
                              </AlertDialogContent>
                            </AlertDialog>
                          </TableCell>
                        </TableRow>
                      ))
                    )}
                  </TableBody>
                </Table>
              </CardContent>
            </Card>
          </TabsContent>

          {/* DEPOLAR */}
          <TabsContent value="warehouses" className="mt-4">
            <Card>
              <CardHeader>
                <CardTitle className="text-base font-semibold">Silinen Depolar</CardTitle>
              </CardHeader>
              <CardContent>
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Silinme Tarihi</TableHead>
                      <TableHead>Depo Adı</TableHead>
                      <TableHead>Adres</TableHead>
                      <TableHead className="text-right">İşlemler</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {deletedWarehouses.length === 0 ? (
                      <TableRow>
                        <TableCell colSpan={4} className="text-center py-6 text-slate-500">
                          Silinmiş depo bulunmuyor.
                        </TableCell>
                      </TableRow>
                    ) : (
                      deletedWarehouses.map((w) => (
                        <TableRow key={w.id}>
                          <TableCell className="text-xs text-slate-500">
                            {w.deleted_at ? new Date(w.deleted_at).toLocaleString("tr-TR") : "-"}
                          </TableCell>
                          <TableCell className="font-medium">{w.name}</TableCell>
                          <TableCell className="text-xs">{w.address || "-"}</TableCell>
                          <TableCell className="text-right space-x-2">
                            <Button
                              size="sm"
                              variant="outline"
                              className="text-emerald-600 border-emerald-300 hover:bg-emerald-50"
                              onClick={() => restoreItem.mutate({ table: "warehouses", id: w.id })}
                            >
                              <RotateCcw className="w-3.5 h-3.5 mr-1" /> Geri Yükle
                            </Button>
                            <AlertDialog>
                              <AlertDialogTrigger asChild>
                                <Button size="sm" variant="destructive">
                                  <Trash2 className="w-3.5 h-3.5 mr-1" /> Kalıcı Sil
                                </Button>
                              </AlertDialogTrigger>
                              <AlertDialogContent>
                                <AlertDialogHeader>
                                  <AlertDialogTitle>Kalıcı Silme Onayı</AlertDialogTitle>
                                  <AlertDialogDescription>Depoyu kalıcı olarak silmek istediğinizden emin misiniz?</AlertDialogDescription>
                                </AlertDialogHeader>
                                <AlertDialogFooter>
                                  <AlertDialogCancel>İptal</AlertDialogCancel>
                                  <AlertDialogAction onClick={() => hardDeleteItem.mutate({ table: "warehouses", id: w.id })}>
                                    Kalıcı Olarak Sil
                                  </AlertDialogAction>
                                </AlertDialogFooter>
                              </AlertDialogContent>
                            </AlertDialog>
                          </TableCell>
                        </TableRow>
                      ))
                    )}
                  </TableBody>
                </Table>
              </CardContent>
            </Card>
          </TabsContent>

          {/* STOK HAREKETLERİ */}
          <TabsContent value="stock_movements" className="mt-4">
            <Card>
              <CardHeader>
                <CardTitle className="text-base font-semibold">Silinen Stok Hareketleri</CardTitle>
              </CardHeader>
              <CardContent>
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Silinme Tarihi</TableHead>
                      <TableHead>Hareket Tarihi</TableHead>
                      <TableHead>Tür</TableHead>
                      <TableHead>Miktar</TableHead>
                      <TableHead>Açıklama</TableHead>
                      <TableHead className="text-right">İşlemler</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {deletedStockMovements.length === 0 ? (
                      <TableRow>
                        <TableCell colSpan={6} className="text-center py-6 text-slate-500">
                          Silinmiş stok hareketi bulunmuyor.
                        </TableCell>
                      </TableRow>
                    ) : (
                      deletedStockMovements.map((m) => (
                        <TableRow key={m.id}>
                          <TableCell className="text-xs text-slate-500">
                            {m.deleted_at ? new Date(m.deleted_at).toLocaleString("tr-TR") : "-"}
                          </TableCell>
                          <TableCell>{m.movement_date}</TableCell>
                          <TableCell><Badge variant="outline">{m.movement_type}</Badge></TableCell>
                          <TableCell className="font-semibold">{m.quantity}</TableCell>
                          <TableCell className="text-xs">{m.description || "-"}</TableCell>
                          <TableCell className="text-right space-x-2">
                            <Button
                              size="sm"
                              variant="outline"
                              className="text-emerald-600 border-emerald-300 hover:bg-emerald-50"
                              onClick={() => restoreItem.mutate({ table: "stock_movements", id: m.id })}
                            >
                              <RotateCcw className="w-3.5 h-3.5 mr-1" /> Geri Yükle
                            </Button>
                          </TableCell>
                        </TableRow>
                      ))
                    )}
                  </TableBody>
                </Table>
              </CardContent>
            </Card>
          </TabsContent>

          {/* CARİ HAREKETLERİ */}
          <TabsContent value="account_transactions" className="mt-4">
            <Card>
              <CardHeader>
                <CardTitle className="text-base font-semibold">Silinen Cari Hareketleri (Tahsilat / Ödeme / Borç / Alacak)</CardTitle>
              </CardHeader>
              <CardContent>
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Silinme Tarihi</TableHead>
                      <TableHead>İşlem Tarihi</TableHead>
                      <TableHead>İşlem Türü</TableHead>
                      <TableHead>Tutar</TableHead>
                      <TableHead>Açıklama</TableHead>
                      <TableHead className="text-right">İşlemler</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {deletedTransactions.length === 0 ? (
                      <TableRow>
                        <TableCell colSpan={6} className="text-center py-6 text-slate-500">
                          Silinmiş cari hareket bulunmuyor.
                        </TableCell>
                      </TableRow>
                    ) : (
                      deletedTransactions.map((t) => (
                        <TableRow key={t.id}>
                          <TableCell className="text-xs text-slate-500">
                            {t.deleted_at ? new Date(t.deleted_at).toLocaleString("tr-TR") : "-"}
                          </TableCell>
                          <TableCell>{t.txn_date}</TableCell>
                          <TableCell><Badge variant="outline">{t.txn_type}</Badge></TableCell>
                          <TableCell className="font-semibold">{formatMoney(t.amount)} TL</TableCell>
                          <TableCell className="text-xs">{t.description || "-"}</TableCell>
                          <TableCell className="text-right space-x-2">
                            <Button
                              size="sm"
                              variant="outline"
                              className="text-emerald-600 border-emerald-300 hover:bg-emerald-50"
                              onClick={() => restoreItem.mutate({ table: "account_transactions", id: t.id })}
                            >
                              <RotateCcw className="w-3.5 h-3.5 mr-1" /> Geri Yükle
                            </Button>
                          </TableCell>
                        </TableRow>
                      ))
                    )}
                  </TableBody>
                </Table>
              </CardContent>
            </Card>
          </TabsContent>

          {/* AUDIT LOGS */}
          <TabsContent value="audit_logs" className="mt-4">
            <Card>
              <CardHeader>
                <CardTitle className="text-base font-semibold flex items-center gap-2">
                  <History className="w-5 h-5 text-indigo-500" />
                  Sistem İşlem Geçmişi (Audit Logs)
                </CardTitle>
                <CardDescription>
                  Tüm Ekleme (CREATE), Güncelleme (UPDATE), Soft Delete (DELETE) ve Geri Yükleme (RESTORE) hareketlerinin zaman ve veri dökümü.
                </CardDescription>
              </CardHeader>
              <CardContent>
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Zaman</TableHead>
                      <TableHead>Eylem (Action)</TableHead>
                      <TableHead>Tablo</TableHead>
                      <TableHead>Kayıt ID</TableHead>
                      <TableHead className="text-right">Detay</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {auditLogs.length === 0 ? (
                      <TableRow>
                        <TableCell colSpan={5} className="text-center py-6 text-slate-500">
                          Henüz kayıtlı bir işlem geçmişi bulunmuyor.
                        </TableCell>
                      </TableRow>
                    ) : (
                      auditLogs.map((log) => (
                        <TableRow key={log.id}>
                          <TableCell className="text-xs text-slate-500 font-mono">
                            {new Date(log.created_at).toLocaleString("tr-TR")}
                          </TableCell>
                          <TableCell>
                            <Badge
                              className={
                                log.action === "CREATE"
                                  ? "bg-emerald-100 text-emerald-800 hover:bg-emerald-100"
                                  : log.action === "UPDATE"
                                    ? "bg-blue-100 text-blue-800 hover:bg-blue-100"
                                    : log.action === "DELETE"
                                      ? "bg-amber-100 text-amber-800 hover:bg-amber-100"
                                      : log.action === "RESTORE"
                                        ? "bg-indigo-100 text-indigo-800 hover:bg-indigo-100"
                                        : "bg-rose-100 text-rose-800 hover:bg-rose-100"
                              }
                            >
                              {log.action}
                            </Badge>
                          </TableCell>
                          <TableCell className="font-mono text-xs text-slate-700 dark:text-slate-300">
                            {log.table_name}
                          </TableCell>
                          <TableCell className="font-mono text-xs text-slate-500">{log.record_id}</TableCell>
                          <TableCell className="text-right">
                            <Button size="sm" variant="ghost" onClick={() => setLogDetail(log)}>
                              Veri Detayı
                            </Button>
                          </TableCell>
                        </TableRow>
                      ))
                    )}
                  </TableBody>
                </Table>
              </CardContent>
            </Card>
          </TabsContent>
        </Tabs>

        {/* Audit Log Detail Dialog */}
        <Dialog open={Boolean(logDetail)} onOpenChange={(o) => !o && setLogDetail(null)}>
          <DialogContent className="max-w-2xl max-h-[85vh] overflow-y-auto">
            <DialogHeader>
              <DialogTitle className="text-base font-bold flex items-center gap-2">
                <History className="w-5 h-5 text-indigo-500" />
                İşlem Geçmişi Detayı ({logDetail?.action} - {logDetail?.table_name})
              </DialogTitle>
            </DialogHeader>
            {logDetail && (
              <div className="space-y-4 text-xs font-mono">
                <div>
                  <span className="font-semibold text-slate-600 block mb-1">Eski Veri (Old Data):</span>
                  <pre className="p-3 bg-slate-900 text-slate-100 rounded-md overflow-x-auto max-h-48">
                    {logDetail.old_data ? JSON.stringify(logDetail.old_data, null, 2) : "Yok (Yeni Kayıt)"}
                  </pre>
                </div>
                <div>
                  <span className="font-semibold text-slate-600 block mb-1">Yeni Veri (New Data):</span>
                  <pre className="p-3 bg-slate-900 text-emerald-300 rounded-md overflow-x-auto max-h-48">
                    {logDetail.new_data ? JSON.stringify(logDetail.new_data, null, 2) : "Yok (Silindi)"}
                  </pre>
                </div>
              </div>
            )}
          </DialogContent>
        </Dialog>
      </div>
    </AppShell>
  );
}

