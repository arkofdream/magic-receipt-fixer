import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { AppShell } from "@/components/AppShell";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { formatMoney, formatDate } from "@/lib/invoice";
import { CalendarClock, Filter, Search, ArrowUpRight, ArrowDownLeft, CheckCircle2, Clock, AlertCircle } from "lucide-react";
import { differenceInDays, startOfDay } from "date-fns";

export const Route = createFileRoute("/_authenticated/vade-takip")({
  component: VadeTakipPage,
});

function VadeTakipPage() {
  const [search, setSearch] = useState("");
  const [typeFilter, setTypeFilter] = useState("ALL");
  const [statusFilter, setStatusFilter] = useState("ALL");

  const { data: transactions = [], isLoading } = useQuery({
    queryKey: ["vade-takip-transactions"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("account_transactions")
        .select(`
          id,
          txn_date,
          due_date,
          amount,
          txn_type,
          source,
          source_id,
          document_no,
          description,
          customer:customers(id, title)
        `)
        .not("due_date", "is", null)
        .order("due_date", { ascending: true });
        
      if (error) throw error;
      return data || [];
    }
  });

  const { data: payments = [] } = useQuery({
    queryKey: ["vade-takip-payments"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("account_transactions")
        .select("source_id, amount, source")
        .in("source", ["FATURA_TAHSILAT", "FATURA_ODEME"]);
        
      if (error) throw error;
      return data || [];
    }
  });

  const paymentMap = useMemo(() => {
    const map = new Map<string, number>();
    for (const p of payments) {
      if (p.source_id) {
        map.set(p.source_id, (map.get(p.source_id) || 0) + Number(p.amount));
      }
    }
    return map;
  }, [payments]);

  const processedData = useMemo(() => {
    const today = startOfDay(new Date());
    
    return transactions.map(txn => {
      const paid = txn.source_id ? (paymentMap.get(txn.source_id) || 0) : 0;
      const remaining = Math.max(0, Number(txn.amount) - paid);
      const isPaid = remaining < 0.01;
      
      const dueDate = new Date(txn.due_date!);
      const diffDays = differenceInDays(dueDate, today);
      
      let status = "YAKLASAN";
      if (isPaid) status = "ODENDI";
      else if (diffDays < 0) status = "GECIKMIS";
      else if (diffDays === 0) status = "BUGUN";

      // İşletme açısından yön
      // Müşteriye BORC yazılmışsa, bu bizim ALACAGIMIZDIR (Tahsilat Bekleyen)
      const direction = txn.txn_type === "BORC" ? "ALACAK" : "BORC";

      return {
        ...txn,
        paidAmount: paid,
        remainingAmount: remaining,
        status,
        diffDays,
        direction
      };
    });
  }, [transactions, paymentMap]);

  const filteredData = useMemo(() => {
    return processedData.filter(item => {
      if (typeFilter !== "ALL" && item.direction !== typeFilter) return false;
      if (statusFilter !== "ALL" && item.status !== statusFilter) return false;
      
      if (search) {
        const q = search.toLowerCase();
        const title = (item.customer as any)?.title?.toLowerCase() || "";
        const docNo = item.document_no?.toLowerCase() || "";
        if (!title.includes(q) && !docNo.includes(q)) return false;
      }
      
      return true;
    });
  }, [processedData, typeFilter, statusFilter, search]);

  const stats = useMemo(() => {
    let totalReceivables = 0; // Bekleyen Tahsilatlar
    let totalPayables = 0; // Bekleyen Ödemeler
    let totalOverdue = 0;
    let totalUpcoming = 0;

    for (const item of processedData) {
      if (item.status === "ODENDI") continue;
      
      if (item.direction === "ALACAK") {
        totalReceivables += item.remainingAmount;
      } else {
        totalPayables += item.remainingAmount;
      }

      if (item.status === "GECIKMIS") {
        totalOverdue += item.remainingAmount;
      } else if (item.status === "YAKLASAN" || item.status === "BUGUN") {
        totalUpcoming += item.remainingAmount;
      }
    }

    return { totalReceivables, totalPayables, totalOverdue, totalUpcoming };
  }, [processedData]);

  return (
    <AppShell
      title="Vade Takibi"
      subtitle="Yaklaşan ödemeleriniz ve bekleyen tahsilatlarınızın takibi"
    >
      <div className="space-y-4">
        {/* Özet Kartları */}
        <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-4">
          <Card>
            <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
              <CardTitle className="text-sm font-medium">Toplam Alacak (Tahsilat)</CardTitle>
              <ArrowDownLeft className="h-4 w-4 text-emerald-500" />
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold text-emerald-600 dark:text-emerald-400">
                {formatMoney(stats.totalReceivables)}
              </div>
              <p className="text-xs text-muted-foreground mt-1">Müşterilerden beklenen tahsilatlar</p>
            </CardContent>
          </Card>
          
          <Card>
            <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
              <CardTitle className="text-sm font-medium">Toplam Borç (Ödeme)</CardTitle>
              <ArrowUpRight className="h-4 w-4 text-rose-500" />
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold text-rose-600 dark:text-rose-400">
                {formatMoney(stats.totalPayables)}
              </div>
              <p className="text-xs text-muted-foreground mt-1">Tedarikçilere yapılacak ödemeler</p>
            </CardContent>
          </Card>

          <Card>
            <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
              <CardTitle className="text-sm font-medium">Vadesi Geçmiş Toplam</CardTitle>
              <AlertCircle className="h-4 w-4 text-destructive" />
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold text-destructive">
                {formatMoney(stats.totalOverdue)}
              </div>
              <p className="text-xs text-muted-foreground mt-1">Gecikmedeki toplam bakiye</p>
            </CardContent>
          </Card>

          <Card>
            <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
              <CardTitle className="text-sm font-medium">Yaklaşan Toplam</CardTitle>
              <Clock className="h-4 w-4 text-blue-500" />
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold text-blue-600 dark:text-blue-400">
                {formatMoney(stats.totalUpcoming)}
              </div>
              <p className="text-xs text-muted-foreground mt-1">Vadesi henüz gelmemiş / Bugün</p>
            </CardContent>
          </Card>
        </div>

        {/* Filtreler */}
        <Card>
          <CardHeader className="py-3 px-4">
            <CardTitle className="text-sm font-semibold flex items-center gap-2">
              <Filter className="size-4 text-primary" /> Filtreler
            </CardTitle>
          </CardHeader>
          <CardContent className="px-4 pb-4 pt-0">
            <div className="grid gap-3 sm:grid-cols-3">
              <div className="space-y-1">
                <label className="text-xs font-medium text-muted-foreground">İşlem Yönü</label>
                <Select value={typeFilter} onValueChange={setTypeFilter}>
                  <SelectTrigger className="h-8 text-xs">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="ALL">Tümü</SelectItem>
                    <SelectItem value="ALACAK">Tahsilat Bekleyen (Alacaklarımız)</SelectItem>
                    <SelectItem value="BORC">Ödeme Bekleyen (Borçlarımız)</SelectItem>
                  </SelectContent>
                </Select>
              </div>

              <div className="space-y-1">
                <label className="text-xs font-medium text-muted-foreground">Durum</label>
                <Select value={statusFilter} onValueChange={setStatusFilter}>
                  <SelectTrigger className="h-8 text-xs">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="ALL">Tüm Durumlar</SelectItem>
                    <SelectItem value="GECIKMIS">Vadesi Geçenler</SelectItem>
                    <SelectItem value="BUGUN">Bugün</SelectItem>
                    <SelectItem value="YAKLASAN">Yaklaşanlar</SelectItem>
                    <SelectItem value="ODENDI">Ödendi / Kapandı</SelectItem>
                  </SelectContent>
                </Select>
              </div>

              <div className="space-y-1">
                <label className="text-xs font-medium text-muted-foreground">Arama</label>
                <div className="relative">
                  <Search className="absolute left-2 top-2 h-4 w-4 text-muted-foreground" />
                  <Input
                    placeholder="Cari unvanı veya Belge No..."
                    className="h-8 pl-8 text-xs"
                    value={search}
                    onChange={(e) => setSearch(e.target.value)}
                  />
                </div>
              </div>
            </div>
          </CardContent>
        </Card>

        {/* Tablo */}
        <Card>
          <CardContent className="p-0">
            {isLoading ? (
              <div className="p-8 text-center text-sm text-muted-foreground">Yükleniyor...</div>
            ) : filteredData.length === 0 ? (
              <div className="p-12 text-center text-sm text-muted-foreground space-y-3">
                <CalendarClock className="size-10 mx-auto text-muted-foreground/50" />
                <p>Bu filtrelere uygun vade kaydı bulunamadı.</p>
              </div>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b bg-muted/50 text-left text-xs uppercase text-muted-foreground">
                      <th className="px-4 py-3 font-medium">Vade Tarihi</th>
                      <th className="px-4 py-3 font-medium">Durum</th>
                      <th className="px-4 py-3 font-medium">Cari / Belge No</th>
                      <th className="px-4 py-3 font-medium">Yön</th>
                      <th className="px-4 py-3 font-medium text-right">Toplam Tutar</th>
                      <th className="px-4 py-3 font-medium text-right">Ödenen</th>
                      <th className="px-4 py-3 font-medium text-right">Kalan</th>
                    </tr>
                  </thead>
                  <tbody>
                    {filteredData.map((item) => {
                      const customerName = (item.customer as any)?.title || "Bilinmeyen Cari";
                      return (
                        <tr key={item.id} className="border-b last:border-0 hover:bg-muted/30">
                          <td className="px-4 py-3 whitespace-nowrap">
                            <div className="font-medium">{formatDate(item.due_date!)}</div>
                            <div className="text-xs text-muted-foreground">
                              {item.diffDays < 0 ? (
                                <span className="text-destructive font-medium">{Math.abs(item.diffDays)} gün gecikti</span>
                              ) : item.diffDays === 0 ? (
                                <span className="text-amber-500 font-medium">Bugün</span>
                              ) : (
                                <span>{item.diffDays} gün kaldı</span>
                              )}
                            </div>
                          </td>
                          <td className="px-4 py-3">
                            <Badge
                              variant={
                                item.status === "ODENDI" ? "default" :
                                item.status === "GECIKMIS" ? "destructive" :
                                item.status === "BUGUN" ? "secondary" : "outline"
                              }
                            >
                              {item.status === "GECIKMIS" ? "Gecikmiş" :
                               item.status === "BUGUN" ? "Bugün" :
                               item.status === "YAKLASAN" ? "Yaklaşan" : "Ödendi"}
                            </Badge>
                          </td>
                          <td className="px-4 py-3 max-w-[250px] truncate">
                            <div className="font-medium truncate" title={customerName}>{customerName}</div>
                            <div className="text-xs text-muted-foreground truncate">
                              Belge: {item.document_no || "-"}
                            </div>
                          </td>
                          <td className="px-4 py-3">
                            <Badge variant={item.direction === "ALACAK" ? "secondary" : "outline"} className={item.direction === "ALACAK" ? "bg-emerald-100 text-emerald-700 hover:bg-emerald-100 dark:bg-emerald-900/30 dark:text-emerald-400" : "bg-rose-100 text-rose-700 border-rose-200 hover:bg-rose-100 dark:bg-rose-900/30 dark:text-rose-400 dark:border-rose-900"}>
                              {item.direction === "ALACAK" ? "Tahsilat" : "Ödeme"}
                            </Badge>
                          </td>
                          <td className="px-4 py-3 text-right font-medium">
                            {formatMoney(Number(item.amount))}
                          </td>
                          <td className="px-4 py-3 text-right text-muted-foreground">
                            {formatMoney(item.paidAmount)}
                          </td>
                          <td className="px-4 py-3 text-right font-semibold">
                            {item.remainingAmount > 0.01 ? (
                              <span className={item.status === "GECIKMIS" ? "text-destructive" : ""}>
                                {formatMoney(item.remainingAmount)}
                              </span>
                            ) : (
                              <span className="text-muted-foreground flex items-center justify-end gap-1">
                                <CheckCircle2 className="size-3.5" /> 0,00
                              </span>
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
      </div>
    </AppShell>
  );
}
