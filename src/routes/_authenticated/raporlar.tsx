import { createFileRoute } from "@tanstack/react-router";
import { AppShell } from "@/components/AppShell";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { formatMoney } from "@/lib/invoice";
import { 
  TrendingUp, 
  TrendingDown, 
  Wallet, 
  Landmark, 
  AlertTriangle,
  Package,
  Users
} from "lucide-react";
import { useState } from "react";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

export const Route = createFileRoute("/_authenticated/raporlar")({
  component: RaporlarPage,
});

function RaporlarPage() {
  const [startDate, setStartDate] = useState(() => {
    const d = new Date();
    return new Date(d.getFullYear(), d.getMonth(), 1).toISOString().split('T')[0];
  });
  const [endDate, setEndDate] = useState(() => {
    const d = new Date();
    return new Date(d.getFullYear(), d.getMonth() + 1, 0).toISOString().split('T')[0];
  });

  const { data: invoicesData, isLoading: invLoading } = useQuery({
    queryKey: ["raporlar-invoices", startDate, endDate],
    queryFn: async () => {
      const { data: invs, error } = await supabase
        .from("invoices")
        .select("type, grand_total, status")
        .eq("status", "ONAYLANDI")
        .gte("invoice_date", startDate)
        .lte("invoice_date", endDate)
        .is("deleted_at", null);
      if (error) throw error;
      
      const { data: txns, error: txnError } = await supabase
        .from("account_transactions")
        .select("source, amount")
        .in("source", ["FATURA_TAHSILAT", "FATURA_ODEME"])
        .gte("txn_date", startDate)
        .lte("txn_date", endDate);
      if (txnError) throw txnError;

      let satis = 0;
      let alis = 0;
      for (const i of invs || []) {
        if (["SATIS", "E_ARSIV", "TEVKIFAT", "ISTISNA", "IHRAC_KAYITLI"].includes(i.type)) {
          satis += Number(i.grand_total);
        } else if (["ALIS", "GELEN_FATURA", "GELEN_E_ARSIV", "MUSTAHSIL"].includes(i.type)) {
          alis += Number(i.grand_total);
        }
      }

      let tahsilat = 0;
      let odeme = 0;
      for (const t of txns || []) {
        if (t.source === "FATURA_TAHSILAT") tahsilat += Number(t.amount);
        if (t.source === "FATURA_ODEME") odeme += Number(t.amount);
      }

      return { satis, alis, tahsilat, odeme };
    }
  });

  const { data: kasaBankaData, isLoading: kbLoading } = useQuery({
    queryKey: ["raporlar-kasa-banka", endDate],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("journal_lines")
        .select(`
          debit,
          credit,
          journal_entries!inner(entry_date),
          chart_of_accounts!inner(code)
        `)
        .lte("journal_entries.entry_date", endDate)
        .in("chart_of_accounts.code", ["100", "102"]);
      
      if (error) throw error;

      let kasaBalance = 0;
      let bankaBalance = 0;

      for (const line of data || []) {
        const code = (line.chart_of_accounts as any).code;
        const amount = Number(line.debit) - Number(line.credit);
        if (code === "100") kasaBalance += amount;
        if (code === "102") bankaBalance += amount;
      }
      return { kasaBalance, bankaBalance };
    }
  });

  const { data: cariData, isLoading: cariLoading } = useQuery({
    queryKey: ["raporlar-cariler", endDate],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("account_transactions")
        .select("txn_type, amount, customer_id")
        .lte("txn_date", endDate);
      if (error) throw error;

      let totalAlacak = 0; 
      let totalBorc = 0;   

      const balances = new Map<string, number>();
      for (const t of data || []) {
        if (!t.customer_id) continue;
        const amt = Number(t.amount);
        const sign = t.txn_type === "DEBIT" ? 1 : -1;
        balances.set(t.customer_id, (balances.get(t.customer_id) || 0) + (amt * sign));
      }

      for (const bal of Array.from(balances.values())) {
        if (bal > 0) totalAlacak += bal;
        else if (bal < 0) totalBorc += Math.abs(bal);
      }

      return { totalAlacak, totalBorc };
    }
  });

  const { data: overdueData, isLoading: overdueLoading } = useQuery({
    queryKey: ["raporlar-overdue"],
    queryFn: async () => {
      const { data: invs, error: invError } = await supabase
        .from("invoices")
        .select("id, grand_total, type")
        .eq("status", "ONAYLANDI")
        .is("deleted_at", null);
      if (invError) throw invError;

      if (!invs || invs.length === 0) return { overdueAlacak: 0, overdueBorc: 0 };

      const { data: txns, error: txnError } = await supabase
        .from("account_transactions")
        .select("source_id, source, amount, due_date")
        .in("source_id", invs.map(i => i.id));
      if (txnError) throw txnError;

      const dueDates = new Map<string, string>();
      const paidMap = new Map<string, number>();

      for (const t of txns || []) {
        if (t.due_date) dueDates.set(t.source_id, t.due_date);
        if (t.source === "FATURA_TAHSILAT" || t.source === "FATURA_ODEME") {
          paidMap.set(t.source_id, (paidMap.get(t.source_id) || 0) + Number(t.amount));
        }
      }

      const today = new Date().toISOString().split('T')[0];
      let overdueAlacak = 0;
      let overdueBorc = 0;

      for (const inv of invs) {
        const dd = dueDates.get(inv.id);
        if (!dd || dd >= today) continue; 

        const paid = paidMap.get(inv.id) || 0;
        const remaining = Number(inv.grand_total) - paid;

        if (remaining > 0.01) {
          if (["SATIS", "E_ARSIV", "TEVKIFAT", "ISTISNA", "IHRAC_KAYITLI"].includes(inv.type)) {
            overdueAlacak += remaining;
          } else {
            overdueBorc += remaining;
          }
        }
      }

      return { overdueAlacak, overdueBorc };
    }
  });

  const { data: stockData, isLoading: stockLoading } = useQuery({
    queryKey: ["raporlar-stok", endDate],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("stock_movements")
        .select("quantity, movement_type")
        .lte("movement_date", endDate);
      if (error) throw error;

      let totalStock = 0;
      let totalGiris = 0;
      let totalCikis = 0;

      for (const m of data || []) {
        if (m.movement_type === "GIRIS") {
          totalGiris += Number(m.quantity);
          totalStock += Number(m.quantity);
        } else if (m.movement_type === "CIKIS") {
          totalCikis += Number(m.quantity);
          totalStock -= Number(m.quantity);
        }
      }
      return { totalStock, totalGiris, totalCikis };
    }
  });

  return (
    <AppShell title="Finansal Raporlar" subtitle="İşletmenizin finansal durumunu özet raporlarla takip edin.">
      <div className="space-y-6">
        
        {/* Date Filter */}
        <Card>
          <CardContent className="p-4 flex flex-wrap items-end gap-4">
            <div className="space-y-1">
              <Label className="text-xs">Başlangıç Tarihi</Label>
              <Input type="date" value={startDate} onChange={e => setStartDate(e.target.value)} className="w-[160px]" />
            </div>
            <div className="space-y-1">
              <Label className="text-xs">Bitiş Tarihi</Label>
              <Input type="date" value={endDate} onChange={e => setEndDate(e.target.value)} className="w-[160px]" />
            </div>
          </CardContent>
        </Card>

        {/* 1. Gelir Gider & Tahsilat Ödeme Özeti */}
        <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-4">
          <Card>
            <CardHeader className="flex flex-row items-center justify-between pb-2">
              <CardTitle className="text-sm font-medium">Toplam Satışlar</CardTitle>
              <TrendingUp className="h-4 w-4 text-emerald-500" />
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold text-emerald-600">
                {invLoading ? "..." : formatMoney(invoicesData?.satis || 0)}
              </div>
              <p className="text-xs text-muted-foreground mt-1">Seçili dönemde onaylanan satışlar</p>
            </CardContent>
          </Card>
          <Card>
            <CardHeader className="flex flex-row items-center justify-between pb-2">
              <CardTitle className="text-sm font-medium">Toplam Alışlar</CardTitle>
              <TrendingDown className="h-4 w-4 text-rose-500" />
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold text-rose-600">
                {invLoading ? "..." : formatMoney(invoicesData?.alis || 0)}
              </div>
              <p className="text-xs text-muted-foreground mt-1">Seçili dönemde onaylanan alışlar</p>
            </CardContent>
          </Card>
          <Card>
            <CardHeader className="flex flex-row items-center justify-between pb-2">
              <CardTitle className="text-sm font-medium">Tahsilatlar</CardTitle>
              <Wallet className="h-4 w-4 text-emerald-500" />
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold text-emerald-600">
                {invLoading ? "..." : formatMoney(invoicesData?.tahsilat || 0)}
              </div>
              <p className="text-xs text-muted-foreground mt-1">Müşterilerden alınan ödemeler</p>
            </CardContent>
          </Card>
          <Card>
            <CardHeader className="flex flex-row items-center justify-between pb-2">
              <CardTitle className="text-sm font-medium">Ödemeler</CardTitle>
              <Wallet className="h-4 w-4 text-rose-500" />
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold text-rose-600">
                {invLoading ? "..." : formatMoney(invoicesData?.odeme || 0)}
              </div>
              <p className="text-xs text-muted-foreground mt-1">Tedarikçilere yapılan ödemeler</p>
            </CardContent>
          </Card>
        </div>

        {/* 2. Nakit ve Banka Durumu */}
        <div className="grid gap-4 md:grid-cols-2">
          <Card>
            <CardHeader className="pb-2">
              <CardTitle className="text-sm font-medium flex items-center gap-2">
                <Wallet className="h-4 w-4 text-primary" /> Kasa Bakiyesi (100)
              </CardTitle>
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold">
                {kbLoading ? "..." : formatMoney(kasaBankaData?.kasaBalance || 0)}
              </div>
              <p className="text-xs text-muted-foreground mt-1">Bitiş tarihine kadar net kasa mevcudu</p>
            </CardContent>
          </Card>
          <Card>
            <CardHeader className="pb-2">
              <CardTitle className="text-sm font-medium flex items-center gap-2">
                <Landmark className="h-4 w-4 text-primary" /> Banka Bakiyesi (102)
              </CardTitle>
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold">
                {kbLoading ? "..." : formatMoney(kasaBankaData?.bankaBalance || 0)}
              </div>
              <p className="text-xs text-muted-foreground mt-1">Bitiş tarihine kadar net banka mevcudu</p>
            </CardContent>
          </Card>
        </div>

        {/* 3. Cari ve Vade Durumu */}
        <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-4">
          <Card>
            <CardHeader className="pb-2">
              <CardTitle className="text-sm font-medium flex items-center gap-2">
                <Users className="h-4 w-4 text-emerald-500" /> Toplam Alacak
              </CardTitle>
            </CardHeader>
            <CardContent>
              <div className="text-xl font-bold text-emerald-600">
                {cariLoading ? "..." : formatMoney(cariData?.totalAlacak || 0)}
              </div>
              <p className="text-xs text-muted-foreground mt-1">Müşterilerden beklenen tahsilat</p>
            </CardContent>
          </Card>
          <Card>
            <CardHeader className="pb-2">
              <CardTitle className="text-sm font-medium flex items-center gap-2">
                <Users className="h-4 w-4 text-rose-500" /> Toplam Borç
              </CardTitle>
            </CardHeader>
            <CardContent>
              <div className="text-xl font-bold text-rose-600">
                {cariLoading ? "..." : formatMoney(cariData?.totalBorc || 0)}
              </div>
              <p className="text-xs text-muted-foreground mt-1">Tedarikçilere yapılacak ödemeler</p>
            </CardContent>
          </Card>
          <Card>
            <CardHeader className="pb-2">
              <CardTitle className="text-sm font-medium flex items-center gap-2">
                <AlertTriangle className="h-4 w-4 text-amber-500" /> Vadesi Geçen Alacak
              </CardTitle>
            </CardHeader>
            <CardContent>
              <div className="text-xl font-bold text-amber-600">
                {overdueLoading ? "..." : formatMoney(overdueData?.overdueAlacak || 0)}
              </div>
              <p className="text-xs text-muted-foreground mt-1">Tahsilatı geciken tutar</p>
            </CardContent>
          </Card>
          <Card>
            <CardHeader className="pb-2">
              <CardTitle className="text-sm font-medium flex items-center gap-2">
                <AlertTriangle className="h-4 w-4 text-rose-500" /> Vadesi Geçen Borç
              </CardTitle>
            </CardHeader>
            <CardContent>
              <div className="text-xl font-bold text-rose-600">
                {overdueLoading ? "..." : formatMoney(overdueData?.overdueBorc || 0)}
              </div>
              <p className="text-xs text-muted-foreground mt-1">Ödemesi geciken tutar</p>
            </CardContent>
          </Card>
        </div>

        {/* 4. Stok Durumu */}
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium flex items-center gap-2">
              <Package className="h-4 w-4 text-primary" /> Stok Durumu Özeti
            </CardTitle>
          </CardHeader>
          <CardContent className="flex items-center gap-8">
            <div>
              <div className="text-2xl font-bold">{stockLoading ? "..." : stockData?.totalStock}</div>
              <p className="text-xs text-muted-foreground mt-1">Net Stok Mevcudu (Adet)</p>
            </div>
            <div className="space-y-1 text-sm border-l pl-8 border-border">
              <div className="flex justify-between gap-4">
                <span className="text-muted-foreground">Toplam Giriş (Adet):</span>
                <span className="font-medium text-emerald-600">+{stockData?.totalGiris || 0}</span>
              </div>
              <div className="flex justify-between gap-4">
                <span className="text-muted-foreground">Toplam Çıkış (Adet):</span>
                <span className="font-medium text-rose-600">-{stockData?.totalCikis || 0}</span>
              </div>
            </div>
          </CardContent>
        </Card>

      </div>
    </AppShell>
  );
}
