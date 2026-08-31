import { createFileRoute } from "@tanstack/react-router";
import { AppShell } from "@/components/AppShell";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { formatMoney, formatDate } from "@/lib/invoice";
import { Banknote, ArrowDownLeft, ArrowUpRight, Wallet, Search, Filter } from "lucide-react";
import { useState, useMemo } from "react";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Badge } from "@/components/ui/badge";

export const Route = createFileRoute("/_authenticated/kasa")({
  component: KasaPage,
});

function KasaPage() {
  const [search, setSearch] = useState("");
  const [typeFilter, setTypeFilter] = useState("ALL");

  const { data: lines = [], isLoading } = useQuery({
    queryKey: ["kasa-hareketleri"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("journal_lines")
        .select(`
          id,
          debit,
          credit,
          description,
          created_at,
          journal_entries (
            id,
            entry_date,
            entry_number,
            description,
            source_type,
            source_id
          ),
          chart_of_accounts!inner (
            id,
            code,
            name,
            system_tag
          )
        `)
        .eq('chart_of_accounts.code', '100')
        .order("created_at", { ascending: false });

      if (error) throw error;
      return data || [];
    }
  });

  const processedData = useMemo(() => {
    return lines.map(line => {
      const isGiris = Number(line.debit) > 0;
      const isCikis = Number(line.credit) > 0;
      const amount = isGiris ? Number(line.debit) : Number(line.credit);
      const type = isGiris ? "GIRIS" : "CIKIS";

      return {
        ...line,
        amount,
        type,
        date: (line.journal_entries as any)?.entry_date || line.created_at,
        sourceDescription: (line.journal_entries as any)?.description || "Bilinmiyor",
        sourceType: (line.journal_entries as any)?.source_type || "-",
      };
    });
  }, [lines]);

  const filteredData = useMemo(() => {
    return processedData.filter(item => {
      if (typeFilter !== "ALL" && item.type !== typeFilter) return false;
      
      if (search) {
        const q = search.toLowerCase();
        const desc1 = item.description?.toLowerCase() || "";
        const desc2 = item.sourceDescription?.toLowerCase() || "";
        if (!desc1.includes(q) && !desc2.includes(q)) return false;
      }
      
      return true;
    });
  }, [processedData, typeFilter, search]);

  const stats = useMemo(() => {
    let totalGiris = 0;
    let totalCikis = 0;
    
    for (const item of processedData) {
      if (item.type === "GIRIS") totalGiris += item.amount;
      if (item.type === "CIKIS") totalCikis += item.amount;
    }
    
    const balance = totalGiris - totalCikis;
    
    return { totalGiris, totalCikis, balance };
  }, [processedData]);

  return (
    <AppShell title="Kasa Hareketleri" subtitle="Nakit giriş ve çıkışlarınızı (100 Kasa Hesabı) takip edin.">
      <div className="space-y-4">
        {/* Özet Kartları */}
        <div className="grid gap-4 md:grid-cols-3">
          <Card>
            <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
              <CardTitle className="text-sm font-medium">Toplam Kasa Bakiyesi</CardTitle>
              <Wallet className="h-4 w-4 text-primary" />
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold text-primary">
                {formatMoney(stats.balance)}
              </div>
              <p className="text-xs text-muted-foreground mt-1">Mevcut net bakiye (Toplam Giriş - Çıkış)</p>
            </CardContent>
          </Card>
          
          <Card>
            <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
              <CardTitle className="text-sm font-medium">Toplam Nakit Girişi</CardTitle>
              <ArrowDownLeft className="h-4 w-4 text-emerald-500" />
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold text-emerald-600 dark:text-emerald-400">
                {formatMoney(stats.totalGiris)}
              </div>
              <p className="text-xs text-muted-foreground mt-1">Gerçekleşen tüm tahsilatlar / girişler</p>
            </CardContent>
          </Card>

          <Card>
            <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
              <CardTitle className="text-sm font-medium">Toplam Nakit Çıkışı</CardTitle>
              <ArrowUpRight className="h-4 w-4 text-rose-500" />
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold text-rose-600 dark:text-rose-400">
                {formatMoney(stats.totalCikis)}
              </div>
              <p className="text-xs text-muted-foreground mt-1">Gerçekleşen tüm ödemeler / çıkışlar</p>
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
            <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
              <div className="space-y-1">
                <label className="text-xs font-medium text-muted-foreground">İşlem Yönü</label>
                <Select value={typeFilter} onValueChange={setTypeFilter}>
                  <SelectTrigger className="h-8 text-xs">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="ALL">Tümü (Giriş + Çıkış)</SelectItem>
                    <SelectItem value="GIRIS">Sadece Girişler</SelectItem>
                    <SelectItem value="CIKIS">Sadece Çıkışlar</SelectItem>
                  </SelectContent>
                </Select>
              </div>

              <div className="space-y-1 lg:col-span-2">
                <label className="text-xs font-medium text-muted-foreground">Arama</label>
                <div className="relative">
                  <Search className="absolute left-2 top-2 h-4 w-4 text-muted-foreground" />
                  <Input
                    placeholder="Açıklama, fiş no veya kaynak fişi ara..."
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
              <div className="p-8 text-center text-sm text-muted-foreground">Kasa hareketleri yükleniyor...</div>
            ) : filteredData.length === 0 ? (
              <div className="p-12 text-center text-sm text-muted-foreground space-y-3">
                <Wallet className="size-10 mx-auto text-muted-foreground/50" />
                <p>Kasa hareketi bulunamadı.</p>
              </div>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b bg-muted/50 text-left text-xs uppercase text-muted-foreground">
                      <th className="px-4 py-3 font-medium">Tarih</th>
                      <th className="px-4 py-3 font-medium">İşlem Yönü</th>
                      <th className="px-4 py-3 font-medium">Satır Açıklaması</th>
                      <th className="px-4 py-3 font-medium">Fiş / Kaynak Açıklaması</th>
                      <th className="px-4 py-3 font-medium text-right">Tutar</th>
                    </tr>
                  </thead>
                  <tbody>
                    {filteredData.map((item) => (
                      <tr key={item.id} className="border-b last:border-0 hover:bg-muted/30">
                        <td className="px-4 py-3 whitespace-nowrap text-muted-foreground">
                          {formatDate(item.date)}
                        </td>
                        <td className="px-4 py-3">
                          <Badge 
                            variant="outline" 
                            className={item.type === "GIRIS" 
                              ? "bg-emerald-100 text-emerald-700 border-emerald-200 dark:bg-emerald-900/30 dark:text-emerald-400 dark:border-emerald-900" 
                              : "bg-rose-100 text-rose-700 border-rose-200 dark:bg-rose-900/30 dark:text-rose-400 dark:border-rose-900"}
                          >
                            {item.type === "GIRIS" ? "GİRİŞ (Tahsilat)" : "ÇIKIŞ (Ödeme)"}
                          </Badge>
                        </td>
                        <td className="px-4 py-3">
                          <span className="font-medium">{item.description || "-"}</span>
                        </td>
                        <td className="px-4 py-3 max-w-[300px] truncate" title={item.sourceDescription}>
                          <div className="truncate">{item.sourceDescription}</div>
                          <div className="text-xs text-muted-foreground font-mono">
                            {(item.journal_entries as any)?.entry_number} 
                            {(item.sourceType && item.sourceType !== "-") && ` • ${item.sourceType}`}
                          </div>
                        </td>
                        <td className={`px-4 py-3 text-right font-bold ${item.type === "GIRIS" ? "text-emerald-600 dark:text-emerald-400" : "text-rose-600 dark:text-rose-400"}`}>
                          {item.type === "GIRIS" ? "+" : "-"}{formatMoney(item.amount)}
                        </td>
                      </tr>
                    ))}
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
