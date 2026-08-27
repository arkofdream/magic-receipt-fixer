import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import {
  BookOpen,
  FileSpreadsheet,
  TrendingUp,
  Receipt,
  Download,
  CheckCircle2,
  AlertTriangle,
  XCircle,
  Lock,
  Unlock,
  ShieldAlert,
  Calendar,
  Layers,
  Search,
  RotateCcw,
  Sparkles,
} from "lucide-react";
import { toast } from "sonner";

import { AppShell } from "@/components/AppShell";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { supabase } from "@/integrations/supabase/client";
import { downloadWorkbook } from "@/lib/excel";
import { formatDate, formatMoney } from "@/lib/invoice";

export const Route = createFileRoute("/_authenticated/muhasebe")({
  head: () => ({
    meta: [
      { title: "Muhasebe & Finans | e-Fatura Portalı" },
      {
        name: "description",
        content:
          "Tek Düzen Hesap Planı, Mizan Tablosu, Muavin Defter, Gelir Tablosu, Dönem Kapanışı ve Muhasebe Denetim Motoru.",
      },
      { property: "og:title", content: "Muhasebe & Finans | e-Fatura Portalı" },
      {
        property: "og:description",
        content: "Mizan, Muavin, Gelir Tablosu, Dönem Yönetimi ve Muhasebe Denetim Mutabakatı.",
      },
    ],
  }),
  component: AccountingPage,
});

export function AccountingPage() {
  const queryClient = useQueryClient();
  const currentYear = new Date().getFullYear();
  const currentMonth = new Date().getMonth() + 1;

  // --- Filtre Durumları ---
  const [mizanStartDate, setMizanStartDate] = useState(`${currentYear}-01-01`);
  const [mizanEndDate, setMizanEndDate] = useState(new Date().toISOString().slice(0, 10));

  const [selectedAccountId, setSelectedAccountId] = useState<string>("");
  const [ledgerStartDate, setLedgerStartDate] = useState(`${currentYear}-01-01`);
  const [ledgerEndDate, setLedgerEndDate] = useState(new Date().toISOString().slice(0, 10));

  const [incomeStartDate, setIncomeStartDate] = useState(`${currentYear}-01-01`);
  const [incomeEndDate, setIncomeEndDate] = useState(new Date().toISOString().slice(0, 10));

  const [auditYear, setAuditYear] = useState<string>(String(currentYear));
  const [auditMonth, setAuditMonth] = useState<string>(String(currentMonth));
  const [auditFilterSeverity, setAuditFilterSeverity] = useState<string>("ALL");

  const [taxYear, setTaxYear] = useState<string>(String(currentYear));
  const [taxMonth, setTaxMonth] = useState<string>(String(currentMonth));

  // --- BEYANNAME VE KDV SORGULARI (get_vat_declaration_summary & get_withholding_tax_summary) ---
  const parsedTaxYear = taxYear ? Number(taxYear) : null;
  const parsedTaxMonth = taxMonth ? Number(taxMonth) : null;

  const {
    data: vatDeclaration,
    isLoading: vatLoading,
    refetch: refetchVat,
  } = useQuery({
    queryKey: ["vat-declaration", parsedTaxYear, parsedTaxMonth],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("get_vat_declaration_summary", {
        p_year: parsedTaxYear,
        p_month: parsedTaxMonth,
      });
      if (error) throw error;
      return (data as any) ?? null;
    },
  });

  const {
    data: withholdingTax,
    isLoading: withholdingLoading,
    refetch: refetchWithholding,
  } = useQuery({
    queryKey: ["withholding-tax", parsedTaxYear, parsedTaxMonth],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("get_withholding_tax_summary", {
        p_year: parsedTaxYear,
        p_month: parsedTaxMonth,
      });
      if (error) throw error;
      return (data as any) ?? null;
    },
  });

  // --- KUR DEĞERLEME SORGULARI VE DURUMU ---
  const [revalDate, setRevalDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [usdRate, setUsdRate] = useState("35.00");
  const [eurRate, setEurRate] = useState("38.00");
  const [gbpRate, setGbpRate] = useState("45.00");
  const [revalDesc, setRevalDesc] = useState("");

  const {
    data: fxBalances = [],
    isLoading: fxLoading,
    refetch: refetchFx,
  } = useQuery({
    queryKey: ["fx-balances"],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("get_foreign_currency_balances");
      if (error) throw error;
      return (data as any) ?? [];
    },
  });

  const runFxRevaluationMutation = useMutation({
    mutationFn: async () => {
      const rates: Record<string, number> = {
        USD: Number(usdRate) || 0,
        EUR: Number(eurRate) || 0,
        GBP: Number(gbpRate) || 0,
      };

      const { data, error } = await supabase.rpc("run_fx_revaluation", {
        p_revaluation_date: revalDate,
        p_rates: rates,
        p_description: revalDesc.trim(),
      });
      if (error) throw error;
      return data as any;
    },
    onSuccess: (data) => {
      if (data?.revalued_count === 0) {
        toast.info(data.message || "Değerlenecek kur farkı bulunamadı.");
      } else {
        toast.success(`Kur değerleme fişi (${data.journal_number}) başarıyla oluşturuldu. Net Kur Etkisi: ${formatMoney(data.net_fx_impact)} TL`);
      }
      queryClient.invalidateQueries({ queryKey: ["trial-balance"] });
      queryClient.invalidateQueries({ queryKey: ["income-statement"] });
      queryClient.invalidateQueries({ queryKey: ["journal-entries-all"] });
      queryClient.invalidateQueries({ queryKey: ["customers"] });
      queryClient.invalidateQueries({ queryKey: ["customer-balances"] });
      queryClient.invalidateQueries({ queryKey: ["account-transactions"] });
      refetchFx();
    },
    onError: (err: any) => {
      toast.error(err.message || "Kur değerleme işlemi başarısız.");
    },
  });

  // --- 1. HESAP PLANI SORGUSU ---
  const { data: accounts = [], isLoading: accountsLoading } = useQuery({
    queryKey: ["chart-of-accounts"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("chart_of_accounts")
        .select("*")
        .eq("is_active", true)
        .order("code", { ascending: true });
      if (error) throw error;
      return data ?? [];
    },
  });

  // --- 2. MİZAN TABLOSU (get_trial_balance RPC) ---
  const {
    data: trialBalance = [],
    isLoading: mizanLoading,
    error: mizanError,
    refetch: refetchMizan,
  } = useQuery({
    queryKey: ["trial-balance", mizanStartDate, mizanEndDate],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("get_trial_balance", {
        p_start_date: mizanStartDate || null,
        p_end_date: mizanEndDate || null,
      });
      if (error) throw error;
      return data ?? [];
    },
  });

  // Mizan Genel Toplamları
  const mizanTotals = useMemo(() => {
    let totalOpDebit = 0;
    let totalOpCredit = 0;
    let totalPerDebit = 0;
    let totalPerCredit = 0;
    let totalClDebit = 0;
    let totalClCredit = 0;
    let totalDebitBal = 0;
    let totalCreditBal = 0;

    for (const r of trialBalance) {
      totalOpDebit += Number(r.opening_debit) || 0;
      totalOpCredit += Number(r.opening_credit) || 0;
      totalPerDebit += Number(r.period_debit) || 0;
      totalPerCredit += Number(r.period_credit) || 0;
      totalClDebit += Number(r.closing_debit) || 0;
      totalClCredit += Number(r.closing_credit) || 0;
      totalDebitBal += Number(r.debit_balance) || 0;
      totalCreditBal += Number(r.credit_balance) || 0;
    }

    const isBalanced = Math.abs(totalClDebit - totalClCredit) < 0.05 && Math.abs(totalDebitBal - totalCreditBal) < 0.05;

    return {
      totalOpDebit,
      totalOpCredit,
      totalPerDebit,
      totalPerCredit,
      totalClDebit,
      totalClCredit,
      totalDebitBal,
      totalCreditBal,
      isBalanced,
    };
  }, [trialBalance]);

  // --- 3. MUAVİN DEFTER / HESAP EKSTRESİ (get_account_ledger RPC) ---
  // Varsayılan olarak 120 veya 100 nolu hesabı seç
  const activeAccountId = useMemo(() => {
    if (selectedAccountId) return selectedAccountId;
    const defaultAcc = accounts.find((a) => a.code === "120") || accounts.find((a) => a.code === "100") || accounts[0];
    return defaultAcc?.id || "";
  }, [selectedAccountId, accounts]);

  const {
    data: accountLedger = [],
    isLoading: ledgerLoading,
    error: ledgerError,
  } = useQuery({
    queryKey: ["account-ledger", activeAccountId, ledgerStartDate, ledgerEndDate],
    enabled: Boolean(activeAccountId),
    queryFn: async () => {
      if (!activeAccountId) return [];
      const { data, error } = await supabase.rpc("get_account_ledger", {
        p_account_id: activeAccountId,
        p_start_date: ledgerStartDate || null,
        p_end_date: ledgerEndDate || null,
      });
      if (error) throw error;
      return data ?? [];
    },
  });

  const selectedAccountInfo = useMemo(() => {
    return accounts.find((a) => a.id === activeAccountId);
  }, [accounts, activeAccountId]);

  // --- 4. GELİR TABLOSU (get_income_statement RPC) ---
  const {
    data: incomeStatement,
    isLoading: incomeLoading,
    error: incomeError,
    refetch: refetchIncome,
  } = useQuery({
    queryKey: ["income-statement", incomeStartDate, incomeEndDate],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("get_income_statement", {
        p_start_date: incomeStartDate || null,
        p_end_date: incomeEndDate || null,
      });
      if (error) throw error;
      return (data as any) ?? null;
    },
  });

  // --- 5. DÖNEM YÖNETİMİ (accounting_periods) ---
  const {
    data: periods = [],
    isLoading: periodsLoading,
    refetch: refetchPeriods,
  } = useQuery({
    queryKey: ["accounting-periods"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("accounting_periods")
        .select("*")
        .order("period_year", { ascending: false })
        .order("period_month", { ascending: false });
      if (error) throw error;
      return data ?? [];
    },
  });

  // Dönem Kapatma Mutasyonu
  const closePeriodMutation = useMutation({
    mutationFn: async ({ year, month }: { year: number; month: number }) => {
      const { data, error } = await supabase.rpc("close_accounting_period", {
        p_year: year,
        p_month: month,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: (_, variables) => {
      toast.success(`${variables.month}/${variables.year} muhasebe dönemi başarıyla kapatıldı.`);
      queryClient.invalidateQueries({ queryKey: ["accounting-periods"] });
      queryClient.invalidateQueries({ queryKey: ["reconciliation-summary"] });
      queryClient.invalidateQueries({ queryKey: ["accounting-audit"] });
    },
    onError: (err: any) => {
      toast.error(err.message || "Dönem kapatılırken hata oluştu.");
    },
  });

  // Dönem Yeniden Açma Mutasyonu
  const reopenPeriodMutation = useMutation({
    mutationFn: async ({ year, month }: { year: number; month: number }) => {
      const { data, error } = await supabase.rpc("reopen_accounting_period", {
        p_year: year,
        p_month: month,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: (_, variables) => {
      toast.success(`${variables.month}/${variables.year} muhasebe dönemi yeniden açıldı.`);
      queryClient.invalidateQueries({ queryKey: ["accounting-periods"] });
      queryClient.invalidateQueries({ queryKey: ["reconciliation-summary"] });
      queryClient.invalidateQueries({ queryKey: ["accounting-audit"] });
    },
    onError: (err: any) => {
      toast.error(err.message || "Dönem açılırken hata oluştu.");
    },
  });

  // --- 6. MUTABAKAT VE MUHASEBE DENETİMİ ---
  const parsedAuditYear = auditYear ? Number(auditYear) : null;
  const parsedAuditMonth = auditMonth ? Number(auditMonth) : null;

  const {
    data: reconSummary,
    isLoading: reconLoading,
    refetch: refetchRecon,
  } = useQuery({
    queryKey: ["reconciliation-summary", parsedAuditYear, parsedAuditMonth],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("get_reconciliation_summary", {
        p_year: parsedAuditYear,
        p_month: parsedAuditMonth,
      });
      if (error) throw error;
      return (data as any) ?? null;
    },
  });

  const {
    data: auditResults = [],
    isLoading: auditLoading,
    refetch: refetchAudit,
  } = useQuery({
    queryKey: ["accounting-audit", parsedAuditYear, parsedAuditMonth],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("run_accounting_audit", {
        p_year: parsedAuditYear,
        p_month: parsedAuditMonth,
      });
      if (error) throw error;
      return data ?? [];
    },
  });

  const filteredAuditResults = useMemo(() => {
    if (auditFilterSeverity === "ALL") return auditResults;
    return auditResults.filter((r) => r.severity === auditFilterSeverity);
  }, [auditResults, auditFilterSeverity]);

  // --- 7. GERÇEK YEVMİYE FİŞLERİ (journal_entries + lines) ---
  const { data: journalEntries = [], isLoading: journalLoading } = useQuery({
    queryKey: ["journal-entries-all"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("journal_entries")
        .select("*, journal_lines(*, chart_of_accounts(*))")
        .order("entry_date", { ascending: false })
        .order("entry_number", { ascending: false });
      if (error) throw error;
      return data ?? [];
    },
  });

  // --- 8. EXCEL İNDİRME FONKSİYONLARI ---
  function handleExportMizan() {
    if (!trialBalance || trialBalance.length === 0) {
      toast.error("İndirilecek mizan verisi bulunamadı.");
      return;
    }
    downloadWorkbook(
      [
        "Hesap Kodu",
        "Hesap Adı",
        "Hesap Türü",
        "Açılış Borç",
        "Açılış Alacak",
        "Dönem Borç",
        "Dönem Alacak",
        "Kapanış Borç",
        "Kapanış Alacak",
        "Borç Bakiye",
        "Alacak Bakiye",
      ],
      trialBalance.map((a) => [
        a.account_code,
        a.account_name,
        a.account_type,
        a.opening_debit,
        a.opening_credit,
        a.period_debit,
        a.period_credit,
        a.closing_debit,
        a.closing_credit,
        a.debit_balance,
        a.credit_balance,
      ]),
      `mizan-${mizanStartDate}-${mizanEndDate}.xlsx`,
      "Mizan",
    );
  }

  function handleExportLedger() {
    if (!accountLedger || accountLedger.length === 0) {
      toast.error("İndirilecek muavin defter verisi bulunamadı.");
      return;
    }
    downloadWorkbook(
      ["Tarih", "Yevmiye No", "Kaynak", "Açıklama", "Borç (TL)", "Alacak (TL)", "Yürüyen Bakiye (TL)"],
      accountLedger.map((l) => [
        l.entry_date,
        l.entry_number,
        l.source_type,
        l.description,
        l.debit,
        l.credit,
        l.running_balance,
      ]),
      `muavin-${selectedAccountInfo?.code || "hesap"}-${ledgerStartDate}-${ledgerEndDate}.xlsx`,
      "Muavin Defter",
    );
  }

  function handleExportJournal() {
    if (!journalEntries || journalEntries.length === 0) {
      toast.error("İndirilecek yevmiye verisi bulunamadı.");
      return;
    }
    const rows: any[] = [];
    journalEntries.forEach((je: any) => {
      (je.journal_lines || []).forEach((jl: any) => {
        rows.push([
          je.entry_number,
          je.entry_date,
          je.status,
          je.source_type,
          jl.chart_of_accounts?.code || "",
          jl.chart_of_accounts?.name || "",
          jl.description || je.description,
          jl.debit,
          jl.credit,
        ]);
      });
    });

    downloadWorkbook(
      ["Fiş No", "Tarih", "Durum", "Kaynak", "Hesap Kodu", "Hesap Adı", "Açıklama", "Borç", "Alacak"],
      rows,
      `yevmiye-defteri-${new Date().toISOString().slice(0, 10)}.xlsx`,
      "Yevmiye Defteri",
    );
  }

  function handleExportVatDeclaration() {
    if (!vatDeclaration) {
      toast.error("İndirilecek beyanname verisi bulunamadı.");
      return;
    }
    const sales = vatDeclaration.sales_section || {};
    const deductions = vatDeclaration.deductions_section || {};
    const res = vatDeclaration.result_section || {};

    const rows: any[] = [
      ["--- MATRAH VE HESAPLANAN KDV (SATIŞLAR) ---", "", ""],
      ["Toplam Satış Matrahı", sales.total_taxable_amount, "TL"],
      ["Toplam Hesaplanan KDV", sales.total_calculated_vat, "TL"],
      ["Alıcı Tevkifatı (Kesilen KDV)", sales.total_withheld_vat, "TL"],
      ["Beyan Edilen KDV (Satıcı Payı)", sales.declared_vat, "TL"],
      ["", "", ""],
      ["--- İNDİRİMLER (ALIŞLAR VE İADELER) ---", "", ""],
      ["Alış Faturaları KDV Matrahı (153)", deductions.total_purchase_taxable, "TL"],
      ["Alış Faturaları İndirilecek KDV (191)", deductions.purchase_vat, "TL"],
      ["Satış İadeleri KDV İndirimi", deductions.sales_return_vat, "TL"],
      ["Toplam İndirilecek KDV", deductions.total_deductible_vat, "TL"],
      ["", "", ""],
      ["--- DÖNEM SONU KDV SONUCU ---", "", ""],
      ["Ödenmesi Gereken KDV", res.payable_vat, "TL"],
      ["Sonraki Döneme Devreden KDV", res.transferred_vat, "TL"],
      ["Durum", res.status, ""],
    ];

    downloadWorkbook(
      ["Beyanname Kalemi", "Tutar (TL)", "Birim"],
      rows,
      `kdv-beyanname-${taxYear}-${taxMonth}.xlsx`,
      "KDV Beyannamesi",
    );
  }

  return (
    <AppShell
      title="Muhasebe & Finans Yönetimi"
      subtitle="Tek Düzen Hesap Planı, Mizan, Muavin, Gelir Tablosu, Dönem Kapanışı, Beyannameler ve Denetim Mutabakatı"
    >
      <Tabs defaultValue="mizan" className="space-y-4">
        <TabsList className="grid grid-cols-2 sm:flex sm:flex-wrap gap-1 h-auto p-1 bg-muted/70">
          <TabsTrigger value="mizan" className="gap-1.5 font-medium">
            <FileSpreadsheet className="size-4" /> Mizan Tablosu
          </TabsTrigger>
          <TabsTrigger value="muavin" className="gap-1.5 font-medium">
            <Layers className="size-4" /> Muavin Defter
          </TabsTrigger>
          <TabsTrigger value="gelir-tablosu" className="gap-1.5 font-medium">
            <TrendingUp className="size-4" /> Gelir Tablosu
          </TabsTrigger>
          <TabsTrigger value="beyannameler" className="gap-1.5 font-medium">
            <Receipt className="size-4" /> Beyannameler & KDV
          </TabsTrigger>
          <TabsTrigger value="kur-degerleme" className="gap-1.5 font-medium">
            <Sparkles className="size-4" /> Kur Değerleme & Döviz
          </TabsTrigger>
          <TabsTrigger value="denetim" className="gap-1.5 font-medium">
            <ShieldAlert className="size-4" /> Denetim & Mutabakat
          </TabsTrigger>
          <TabsTrigger value="donemler" className="gap-1.5 font-medium">
            <Calendar className="size-4" /> Dönem Kapanışı
          </TabsTrigger>
          <TabsTrigger value="yevmiye" className="gap-1.5 font-medium">
            <Receipt className="size-4" /> Yevmiye Fişleri
          </TabsTrigger>
          <TabsTrigger value="hesap-plani" className="gap-1.5 font-medium">
            <BookOpen className="size-4" /> Hesap Planı
          </TabsTrigger>
        </TabsList>

        {/* ======================================================== */}
        {/* 1. MİZAN TABLOSU                                         */}
        {/* ======================================================== */}
        <TabsContent value="mizan" className="space-y-4">
          <Card>
            <CardHeader className="flex flex-wrap items-center justify-between gap-3 pb-4">
              <div>
                <CardTitle className="text-base flex items-center gap-2">
                  <span>Mizan Tablosu</span>
                  {mizanTotals.isBalanced ? (
                    <Badge variant="outline" className="bg-emerald-500/10 text-emerald-600 border-emerald-500/30 gap-1">
                      <CheckCircle2 className="size-3.5" /> Mizan Denk
                    </Badge>
                  ) : (
                    <Badge variant="destructive" className="gap-1">
                      <AlertTriangle className="size-3.5" /> Dengesizlik Var!
                    </Badge>
                  )}
                </CardTitle>
                <CardDescription>
                  Hesap bazında açılış, dönem içi borç-alacak hareketleri ve kapanış bakiyeleri
                </CardDescription>
              </div>

              <div className="flex flex-wrap items-center gap-2">
                <div className="flex items-center gap-1.5 text-xs">
                  <Label className="text-xs">Başlangıç:</Label>
                  <Input
                    type="date"
                    className="h-8 w-36 text-xs"
                    value={mizanStartDate}
                    onChange={(e) => setMizanStartDate(e.target.value)}
                  />
                </div>
                <div className="flex items-center gap-1.5 text-xs">
                  <Label className="text-xs">Bitiş:</Label>
                  <Input
                    type="date"
                    className="h-8 w-36 text-xs"
                    value={mizanEndDate}
                    onChange={(e) => setMizanEndDate(e.target.value)}
                  />
                </div>
                <Button variant="outline" size="sm" onClick={handleExportMizan} className="gap-1.5 h-8 text-xs">
                  <Download className="size-3.5" /> Excel İndir
                </Button>
              </div>
            </CardHeader>
            <CardContent>
              {mizanLoading ? (
                <div className="py-12 text-center text-sm text-muted-foreground">Mizan verileri hesaplanıyor...</div>
              ) : mizanError ? (
                <div className="py-8 text-center text-sm text-destructive font-medium">
                  Mizan yüklenirken hata oluştu: {(mizanError as any).message}
                </div>
              ) : trialBalance.length === 0 ? (
                <div className="py-12 text-center text-sm text-muted-foreground">
                  Seçilen tarih aralığında onaylanmış (POSTED) muhasebe kaydı bulunamadı.
                </div>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full text-xs">
                    <thead>
                      <tr className="border-b border-border text-left font-semibold text-muted-foreground bg-muted/40">
                        <th className="py-2.5 px-3">Kod</th>
                        <th className="py-2.5 px-3">Hesap Adı</th>
                        <th className="py-2.5 px-2 text-right">Açılış (B)</th>
                        <th className="py-2.5 px-2 text-right">Açılış (A)</th>
                        <th className="py-2.5 px-2 text-right">Dönem Borç</th>
                        <th className="py-2.5 px-2 text-right">Dönem Alacak</th>
                        <th className="py-2.5 px-2 text-right">Kapanış (B)</th>
                        <th className="py-2.5 px-2 text-right">Kapanış (A)</th>
                        <th className="py-2.5 px-3 text-right font-bold text-emerald-700 dark:text-emerald-400">
                          Borç Bakiye
                        </th>
                        <th className="py-2.5 px-3 text-right font-bold text-primary">Alacak Bakiye</th>
                      </tr>
                    </thead>
                    <tbody>
                      {trialBalance.map((r) => (
                        <tr key={r.account_id} className="border-b border-border/60 hover:bg-muted/30 last:border-0 font-mono">
                          <td className="py-2 px-3 font-bold text-primary">{r.account_code}</td>
                          <td className="py-2 px-3 font-sans font-medium text-foreground">{r.account_name}</td>
                          <td className="py-2 px-2 text-right text-muted-foreground">{Number(r.opening_debit) > 0 ? formatMoney(r.opening_debit) : "-"}</td>
                          <td className="py-2 px-2 text-right text-muted-foreground">{Number(r.opening_credit) > 0 ? formatMoney(r.opening_credit) : "-"}</td>
                          <td className="py-2 px-2 text-right">{Number(r.period_debit) > 0 ? formatMoney(r.period_debit) : "-"}</td>
                          <td className="py-2 px-2 text-right">{Number(r.period_credit) > 0 ? formatMoney(r.period_credit) : "-"}</td>
                          <td className="py-2 px-2 text-right">{Number(r.closing_debit) > 0 ? formatMoney(r.closing_debit) : "-"}</td>
                          <td className="py-2 px-2 text-right">{Number(r.closing_credit) > 0 ? formatMoney(r.closing_credit) : "-"}</td>
                          <td className="py-2 px-3 text-right font-bold text-emerald-600">
                            {Number(r.debit_balance) > 0 ? formatMoney(r.debit_balance) : "-"}
                          </td>
                          <td className="py-2 px-3 text-right font-bold text-primary">
                            {Number(r.credit_balance) > 0 ? formatMoney(r.credit_balance) : "-"}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                    <tfoot>
                      <tr className="border-t-2 border-primary font-bold text-xs bg-muted/40 font-mono">
                        <td colSpan={2} className="py-3 px-3 font-sans">
                          MİZAN GENEL TOPLAMI
                        </td>
                        <td className="py-3 px-2 text-right">{formatMoney(mizanTotals.totalOpDebit)}</td>
                        <td className="py-3 px-2 text-right">{formatMoney(mizanTotals.totalOpCredit)}</td>
                        <td className="py-3 px-2 text-right">{formatMoney(mizanTotals.totalPerDebit)}</td>
                        <td className="py-3 px-2 text-right">{formatMoney(mizanTotals.totalPerCredit)}</td>
                        <td className="py-3 px-2 text-right">{formatMoney(mizanTotals.totalClDebit)}</td>
                        <td className="py-3 px-2 text-right">{formatMoney(mizanTotals.totalClCredit)}</td>
                        <td className="py-3 px-3 text-right text-emerald-600 font-extrabold">
                          {formatMoney(mizanTotals.totalDebitBal)}
                        </td>
                        <td className="py-3 px-3 text-right text-primary font-extrabold">
                          {formatMoney(mizanTotals.totalCreditBal)}
                        </td>
                      </tr>
                    </tfoot>
                  </table>
                </div>
              )}
            </CardContent>
          </Card>
        </TabsContent>

        {/* ======================================================== */}
        {/* 2. MUAVİN DEFTER / HESAP EKSTRESİ                        */}
        {/* ======================================================== */}
        <TabsContent value="muavin" className="space-y-4">
          <Card>
            <CardHeader className="flex flex-wrap items-center justify-between gap-3 pb-4">
              <div>
                <CardTitle className="text-base flex items-center gap-2">
                  <span>Muavin Defter (Hesap Ekstresi)</span>
                  {selectedAccountInfo && (
                    <Badge variant="outline" className="font-mono">
                      {selectedAccountInfo.code} - {selectedAccountInfo.name}
                    </Badge>
                  )}
                </CardTitle>
                <CardDescription>
                  Seçilen hesabın tarih sırasına göre tüm fiş hareketleri ve yürüyen bakiye dökümü
                </CardDescription>
              </div>

              <div className="flex flex-wrap items-center gap-2">
                <div className="w-64">
                  <Select value={activeAccountId} onValueChange={setSelectedAccountId}>
                    <SelectTrigger className="h-8 text-xs">
                      <SelectValue placeholder="Hesap seçiniz..." />
                    </SelectTrigger>
                    <SelectContent>
                      {accounts.map((a) => (
                        <SelectItem key={a.id} value={a.id} className="text-xs">
                          {a.code} - {a.name}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
                <div className="flex items-center gap-1.5 text-xs">
                  <Input
                    type="date"
                    className="h-8 w-32 text-xs"
                    value={ledgerStartDate}
                    onChange={(e) => setLedgerStartDate(e.target.value)}
                  />
                </div>
                <div className="flex items-center gap-1.5 text-xs">
                  <Input
                    type="date"
                    className="h-8 w-32 text-xs"
                    value={ledgerEndDate}
                    onChange={(e) => setLedgerEndDate(e.target.value)}
                  />
                </div>
                <Button variant="outline" size="sm" onClick={handleExportLedger} className="gap-1.5 h-8 text-xs">
                  <Download className="size-3.5" /> Excel İndir
                </Button>
              </div>
            </CardHeader>
            <CardContent>
              {ledgerLoading ? (
                <div className="py-12 text-center text-sm text-muted-foreground">Muavin kayıtları yükleniyor...</div>
              ) : ledgerError ? (
                <div className="py-8 text-center text-sm text-destructive font-medium">
                  Muavin yüklenirken hata oluştu: {(ledgerError as any).message}
                </div>
              ) : accountLedger.length === 0 ? (
                <div className="py-12 text-center text-sm text-muted-foreground">
                  Bu hesaba ait seçilen tarih aralığında onaylı hareket bulunamadı.
                </div>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full text-xs">
                    <thead>
                      <tr className="border-b border-border text-left font-semibold text-muted-foreground bg-muted/40">
                        <th className="py-2.5 px-3">Tarih</th>
                        <th className="py-2.5 px-3">Yevmiye No</th>
                        <th className="py-2.5 px-3">Kaynak</th>
                        <th className="py-2.5 px-3">Açıklama</th>
                        <th className="py-2.5 px-3 text-right">Borç (TL)</th>
                        <th className="py-2.5 px-3 text-right">Alacak (TL)</th>
                        <th className="py-2.5 px-3 text-right font-bold">Yürüyen Bakiye</th>
                      </tr>
                    </thead>
                    <tbody>
                      {accountLedger.map((l) => (
                        <tr key={l.journal_line_id} className="border-b border-border/60 hover:bg-muted/30 last:border-0 font-mono">
                          <td className="py-2 px-3 whitespace-nowrap font-sans">{formatDate(l.entry_date)}</td>
                          <td className="py-2 px-3 font-semibold text-primary">{l.entry_number}</td>
                          <td className="py-2 px-3 font-sans">
                            <Badge variant="outline" className="text-[10px] py-0 px-1">
                              {l.source_type}
                            </Badge>
                          </td>
                          <td className="py-2 px-3 font-sans text-muted-foreground max-w-xs truncate">{l.description}</td>
                          <td className="py-2 px-3 text-right text-emerald-600 font-medium">
                            {Number(l.debit) > 0 ? formatMoney(l.debit) : "-"}
                          </td>
                          <td className="py-2 px-3 text-right text-destructive font-medium">
                            {Number(l.credit) > 0 ? formatMoney(l.credit) : "-"}
                          </td>
                          <td className="py-2 px-3 text-right font-bold font-mono">
                            {formatMoney(l.running_balance)}
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

        {/* ======================================================== */}
        {/* 3. GELİR TABLOSU                                         */}
        {/* ======================================================== */}
        <TabsContent value="gelir-tablosu" className="space-y-4">
          <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3 max-w-3xl mx-auto w-full">
            <h3 className="text-xs sm:text-sm font-semibold whitespace-nowrap">Gelir Tablosu Dönem Filtresi:</h3>
            <div className="flex flex-wrap items-center gap-2 w-full sm:w-auto">
              <Input
                type="date"
                className="h-8 w-full sm:w-36 text-xs"
                value={incomeStartDate}
                onChange={(e) => setIncomeStartDate(e.target.value)}
              />
              <Input
                type="date"
                className="h-8 w-full sm:w-36 text-xs"
                value={incomeEndDate}
                onChange={(e) => setIncomeEndDate(e.target.value)}
              />
              <Button size="sm" variant="outline" onClick={() => refetchIncome()} className="h-8 text-xs gap-1 w-full sm:w-auto shrink-0">
                <RotateCcw className="size-3" /> Yenile
              </Button>
            </div>
          </div>

          <Card className="w-full max-w-3xl mx-auto">
            <CardHeader className="text-center pb-4 border-b border-border px-4 sm:px-6">
              <CardTitle className="text-base sm:text-lg">Ayrıntılı Gelir Tablosu (Kâr / Zarar)</CardTitle>
              <CardDescription className="text-xs sm:text-sm">
                600 Net Satışlar, 621 STMM (Ağırlıklı Ortalama Maliyet) ve Dönem Kâr/Zarar Özeti
              </CardDescription>
            </CardHeader>
            <CardContent className="pt-4 sm:pt-6 space-y-4 px-4 sm:px-6">
              {incomeLoading ? (
                <div className="py-12 text-center text-sm text-muted-foreground">Gelir tablosu hesaplanıyor...</div>
              ) : incomeError ? (
                <div className="py-8 text-center text-sm text-destructive bg-destructive/10 rounded-lg border border-destructive/20 p-3">
                  Hata: {(incomeError as any).message || "Gelir tablosu hesaplanırken beklenmeyen bir hata oluştu."}
                </div>
              ) : !incomeStatement ? (
                <div className="py-12 text-center text-sm text-muted-foreground">Gelir tablosu verisi bulunamadı.</div>
              ) : (
                <div className="space-y-2.5">
                  <div className="flex justify-between py-2 border-b border-border text-xs sm:text-sm font-medium">
                    <span>A. BRÜT SATIŞ GELİRLERİ (600)</span>
                    <span className="font-mono">{formatMoney(incomeStatement.gross_sales)}</span>
                  </div>
                  <div className="flex justify-between py-2 border-b border-border text-xs sm:text-sm text-muted-foreground">
                    <span>B. SATIŞ İNDİRİMLERİ VE İADELERİ (-) (610)</span>
                    <span className="font-mono text-destructive">- {formatMoney(incomeStatement.sales_returns)}</span>
                  </div>
                  <div className="flex justify-between py-2.5 border-b border-border text-xs sm:text-sm font-bold bg-muted/40 px-2 rounded">
                    <span>C. NET SATIŞLAR</span>
                    <span className="font-mono text-primary">{formatMoney(incomeStatement.net_sales)}</span>
                  </div>
                  <div className="flex justify-between py-2 border-b border-border text-xs sm:text-sm text-muted-foreground">
                    <span>D. SATILAN TİCARİ MALLAR MALİYETİ (-) (621 STMM)</span>
                    <span className="font-mono text-destructive">- {formatMoney(incomeStatement.cogs)}</span>
                  </div>
                  <div className="flex justify-between py-2.5 border-b border-border text-sm sm:text-base font-bold bg-emerald-500/10 px-2 rounded text-emerald-700 dark:text-emerald-400">
                    <span>BRÜT SATIŞ KÂRI / (ZARARI)</span>
                    <div className="text-right">
                      <span className="font-mono">{formatMoney(incomeStatement.gross_profit)}</span>
                      <span className="text-xs font-normal text-muted-foreground ml-2">
                        (%{incomeStatement.gross_margin_pct})
                      </span>
                    </div>
                  </div>
                  <div className="flex justify-between py-2 border-b border-border text-xs sm:text-sm text-muted-foreground">
                    <span>E. FAALİYET GİDERLERİ (-) (770)</span>
                    <span className="font-mono text-destructive">- {formatMoney(incomeStatement.operating_expenses)}</span>
                  </div>
                  {Number(incomeStatement.fx_gains) > 0 && (
                    <div className="flex justify-between py-2 border-b border-border text-xs sm:text-sm text-emerald-600 font-medium">
                      <span>F. DİĞER FAALİYET GELİRLERİ (646 KAMBİYO KÂRLARI (+))</span>
                      <span className="font-mono">+ {formatMoney(incomeStatement.fx_gains)}</span>
                    </div>
                  )}
                  {Number(incomeStatement.fx_losses) > 0 && (
                    <div className="flex justify-between py-2 border-b border-border text-xs sm:text-sm text-destructive font-medium">
                      <span>G. DİĞER FAALİYET GİDERLERİ (656 KAMBİYO ZARARLARI (-))</span>
                      <span className="font-mono">- {formatMoney(incomeStatement.fx_losses)}</span>
                    </div>
                  )}
                  <div className="flex justify-between py-2 border-b border-border text-xs sm:text-sm text-muted-foreground">
                    <span>H. FİNANSMAN GİDERLERİ (-) (780)</span>
                    <span className="font-mono text-destructive">- {formatMoney(incomeStatement.financing_expenses)}</span>
                  </div>
                  <div className="flex justify-between py-3 border-t-2 border-primary text-sm sm:text-base font-extrabold bg-primary/10 px-3 rounded text-primary">
                    <span>DÖNEM NET KÂRI / (ZARARI)</span>
                    <span className="font-mono">{formatMoney(incomeStatement.net_profit)}</span>
                  </div>

                  {/* STMM Mutabakat Kartı */}
                  <div className="mt-4 pt-3 border-t border-border/80 flex flex-col sm:flex-row sm:items-center justify-between gap-1.5 text-xs text-muted-foreground">
                    <span className="flex items-center gap-1.5 min-w-0">
                      <CheckCircle2 className="size-3.5 text-emerald-500 shrink-0" />
                      <span className="truncate">STMM Mutabakatı: Fiili Stok Çıkış Maliyeti ({formatMoney(incomeStatement.stock_movements_cogs)})</span>
                    </span>
                    <span className="font-mono whitespace-nowrap">
                      Fark: {formatMoney(incomeStatement.cogs_reconciliation_difference)} (
                      {Math.abs(Number(incomeStatement.cogs_reconciliation_difference)) < 0.05 ? "TAM UYUMLU" : "UYUMSUZ"}
                      )
                    </span>
                  </div>
                </div>
              )}
            </CardContent>
          </Card>
        </TabsContent>

        {/* ======================================================== */}
        {/* 4. VERGİ & BEYANNAMELER (KDV-1, KDV-2, MUHTASAR)         */}
        {/* ======================================================== */}
        <TabsContent value="beyannameler" className="space-y-4">
          <Card>
            <CardHeader className="flex flex-wrap items-center justify-between gap-3 pb-4">
              <div>
                <CardTitle className="text-base flex items-center gap-2">
                  <Receipt className="size-4 text-primary" />
                  <span>KDV-1 & KDV-2 Beyanname Özeti</span>
                </CardTitle>
                <CardDescription>
                  Hesaplanan KDV (391), İndirilecek KDV (191), Tevkifatlar ve Dönem Sonu Ödenecek / Devreden KDV Hesabı
                </CardDescription>
              </div>
              <div className="flex items-center gap-2">
                <Select value={taxYear} onValueChange={setTaxYear}>
                  <SelectTrigger className="h-8 w-24 text-xs">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {[currentYear, currentYear - 1, currentYear - 2].map((y) => (
                      <SelectItem key={y} value={String(y)} className="text-xs">{y}</SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <Select value={taxMonth} onValueChange={setTaxMonth}>
                  <SelectTrigger className="h-8 w-28 text-xs">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {Array.from({ length: 12 }, (_, i) => i + 1).map((m) => (
                      <SelectItem key={m} value={String(m)} className="text-xs">{m}. Ay</SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <Button variant="outline" size="sm" onClick={() => { refetchVat(); refetchWithholding(); }} className="h-8 text-xs gap-1">
                  <RotateCcw className="size-3" /> Yenile
                </Button>
                <Button variant="outline" size="sm" onClick={handleExportVatDeclaration} className="gap-1.5 h-8 text-xs">
                  <Download className="size-3.5" /> Excel İndir
                </Button>
              </div>
            </CardHeader>
            <CardContent>
              {vatLoading ? (
                <div className="py-12 text-center text-sm text-muted-foreground">Beyanname verileri hesaplanıyor...</div>
              ) : !vatDeclaration ? (
                <div className="py-12 text-center text-sm text-muted-foreground">Bu dönem için beyanname verisi bulunamadı.</div>
              ) : (
                <div className="space-y-6">
                  {/* ÖZET KARTLARI */}
                  <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
                    <Card className="bg-muted/20 border-border/70">
                      <CardContent className="p-3.5">
                        <span className="text-xs text-muted-foreground">Toplam Satış Matrahı</span>
                        <div className="text-lg font-bold font-mono text-foreground mt-0.5">
                          {formatMoney(vatDeclaration.sales_section?.total_taxable_amount || 0)} TL
                        </div>
                      </CardContent>
                    </Card>

                    <Card className="bg-muted/20 border-border/70">
                      <CardContent className="p-3.5">
                        <span className="text-xs text-muted-foreground">Beyan Edilen Hesaplanan KDV</span>
                        <div className="text-lg font-bold font-mono text-primary mt-0.5">
                          {formatMoney(vatDeclaration.sales_section?.declared_vat || 0)} TL
                        </div>
                        <div className="text-[10px] text-muted-foreground">
                          Toplam KDV: {formatMoney(vatDeclaration.sales_section?.total_calculated_vat || 0)} TL
                        </div>
                      </CardContent>
                    </Card>

                    <Card className="bg-muted/20 border-border/70">
                      <CardContent className="p-3.5">
                        <span className="text-xs text-muted-foreground">Toplam İndirilecek KDV (191)</span>
                        <div className="text-lg font-bold font-mono text-emerald-600 dark:text-emerald-400 mt-0.5">
                          {formatMoney(vatDeclaration.deductions_section?.total_deductible_vat || 0)} TL
                        </div>
                        <div className="text-[10px] text-muted-foreground">
                          Alış Matrahı: {formatMoney(vatDeclaration.deductions_section?.total_purchase_taxable || 0)} TL
                        </div>
                      </CardContent>
                    </Card>

                    <Card
                      className={
                        vatDeclaration.result_section?.status === "ODENECEK_KDV"
                          ? "bg-amber-500/10 border-amber-500/30"
                          : "bg-blue-500/10 border-blue-500/30"
                      }
                    >
                      <CardContent className="p-3.5">
                        <div className="flex items-center justify-between">
                          <span className="text-xs font-semibold text-foreground">Dönem Sonu Durumu</span>
                          <Badge
                            variant={vatDeclaration.result_section?.status === "ODENECEK_KDV" ? "destructive" : "default"}
                            className="text-[10px] py-0"
                          >
                            {vatDeclaration.result_section?.status === "ODENECEK_KDV" ? "ÖDENECEK KDV" : "DEVREDEN KDV"}
                          </Badge>
                        </div>
                        <div className="text-xl font-black font-mono mt-1 text-foreground">
                          {vatDeclaration.result_section?.status === "ODENECEK_KDV"
                            ? `${formatMoney(vatDeclaration.result_section?.payable_vat || 0)} TL`
                            : `${formatMoney(vatDeclaration.result_section?.transferred_vat || 0)} TL`}
                        </div>
                      </CardContent>
                    </Card>
                  </div>

                  {/* TABLOLAR: SATIŞLAR VE İNDİRİMLER */}
                  <div className="grid gap-6 lg:grid-cols-2">
                    {/* SOL TABLO: TESLİM VE HİZMETLER (SATIŞ MATRAH VE HESAPLANAN KDV) */}
                    <div className="space-y-4">
                      <h4 className="text-xs font-bold uppercase tracking-wider text-muted-foreground flex items-center gap-1.5">
                        <span>1. Teslim ve Hizmetlerin Karşılığını Teşkil Eden Bedel (Matrah)</span>
                      </h4>

                      <div className="rounded-lg border border-border overflow-hidden">
                        <table className="w-full text-xs">
                          <thead>
                            <tr className="bg-muted/40 text-left font-semibold border-b border-border">
                              <th className="py-2 px-3">KDV Oranı</th>
                              <th className="py-2 px-3 text-right">Matrah (TL)</th>
                              <th className="py-2 px-3 text-right">Hesaplanan KDV (TL)</th>
                            </tr>
                          </thead>
                          <tbody>
                            {(vatDeclaration.sales_section?.normal_sales_breakdown || []).length === 0 ? (
                              <tr>
                                <td colSpan={3} className="py-4 text-center text-muted-foreground">Tevkifatsız satış kaydı yok.</td>
                              </tr>
                            ) : (
                              (vatDeclaration.sales_section?.normal_sales_breakdown || []).map((row: any) => (
                                <tr key={row.vat_rate} className="border-b border-border/50 last:border-0 font-mono">
                                  <td className="py-2 px-3 font-sans font-medium">%{row.vat_rate} KDV</td>
                                  <td className="py-2 px-3 text-right">{formatMoney(row.taxable_amount)}</td>
                                  <td className="py-2 px-3 text-right font-bold text-primary">{formatMoney(row.vat_amount)}</td>
                                </tr>
                              ))
                            )}
                          </tbody>
                        </table>
                      </div>

                      {/* Kısmi Tevkifatlı Satışlar Varsa */}
                      {(vatDeclaration.sales_section?.withholding_sales_breakdown || []).length > 0 && (
                        <div className="space-y-2">
                          <h5 className="text-xs font-semibold text-muted-foreground">Kısmi Tevkifat Uygulanan İşlemler</h5>
                          <div className="rounded-lg border border-border overflow-hidden">
                            <table className="w-full text-xs">
                              <thead>
                                <tr className="bg-muted/40 text-left font-semibold border-b border-border">
                                  <th className="py-1.5 px-3">Oran / Tevkifat</th>
                                  <th className="py-1.5 px-3 text-right">Matrah</th>
                                  <th className="py-1.5 px-3 text-right">Alıcı Payı</th>
                                  <th className="py-1.5 px-3 text-right">Beyan Edilen</th>
                                </tr>
                              </thead>
                              <tbody>
                                {(vatDeclaration.sales_section?.withholding_sales_breakdown || []).map((row: any, idx: number) => (
                                  <tr key={idx} className="border-b border-border/50 last:border-0 font-mono">
                                    <td className="py-1.5 px-3 font-sans">%{row.vat_rate} (%{row.withholding_rate})</td>
                                    <td className="py-1.5 px-3 text-right">{formatMoney(row.taxable_amount)}</td>
                                    <td className="py-1.5 px-3 text-right text-amber-600">{formatMoney(row.withheld_vat)}</td>
                                    <td className="py-1.5 px-3 text-right font-bold text-primary">{formatMoney(row.declared_vat)}</td>
                                  </tr>
                                ))}
                              </tbody>
                            </table>
                          </div>
                        </div>
                      )}
                    </div>

                    {/* SAĞ TABLO: İNDİRİMLER (191 ALIŞ KDV VE İADELER) */}
                    <div className="space-y-4">
                      <h4 className="text-xs font-bold uppercase tracking-wider text-muted-foreground flex items-center gap-1.5">
                        <span>2. Bu Döneme Ait İndirilecek KDV (191)</span>
                      </h4>

                      <div className="rounded-lg border border-border overflow-hidden">
                        <table className="w-full text-xs">
                          <thead>
                            <tr className="bg-muted/40 text-left font-semibold border-b border-border">
                              <th className="py-2 px-3">Alış KDV Oranı</th>
                              <th className="py-2 px-3 text-right">Alış Matrahı (153)</th>
                              <th className="py-2 px-3 text-right">İndirilecek KDV (191)</th>
                            </tr>
                          </thead>
                          <tbody>
                            {(vatDeclaration.deductions_section?.purchase_tax_breakdown || []).length === 0 ? (
                              <tr>
                                <td colSpan={3} className="py-4 text-center text-muted-foreground">Alış faturası KDV kaydı yok.</td>
                              </tr>
                            ) : (
                              (vatDeclaration.deductions_section?.purchase_tax_breakdown || []).map((row: any) => (
                                <tr key={row.vat_rate} className="border-b border-border/50 last:border-0 font-mono">
                                  <td className="py-2 px-3 font-sans font-medium">%{row.vat_rate} KDV</td>
                                  <td className="py-2 px-3 text-right">{formatMoney(row.taxable_amount)}</td>
                                  <td className="py-2 px-3 text-right font-bold text-emerald-600 dark:text-emerald-400">
                                    {formatMoney(row.vat_amount)}
                                  </td>
                                </tr>
                              ))
                            )}
                          </tbody>
                        </table>
                      </div>

                      {/* Muhtasar & Stopaj Özeti */}
                      {withholdingTax && (
                        <div className="rounded-lg border border-border/80 bg-muted/20 p-3 space-y-2">
                          <div className="flex items-center justify-between text-xs font-semibold">
                            <span>Muhtasar / Stopaj Özeti (360 Hesabı)</span>
                            <span className="font-mono text-primary">
                              {formatMoney(withholdingTax.total_withholding_payable)} TL
                            </span>
                          </div>
                          <div className="grid grid-cols-2 gap-2 text-[11px] text-muted-foreground font-mono">
                            <div>Ödenecek Stopaj (360): {formatMoney(withholdingTax.withholding_tax_360)} TL</div>
                            <div>KDV-2 Alıcı Tevkifatı: {formatMoney(withholdingTax.kdv2_withholding_total)} TL</div>
                          </div>
                        </div>
                      )}
                    </div>
                  </div>
                </div>
              )}
            </CardContent>
          </Card>
        </TabsContent>

        {/* ======================================================== */}
        {/* 5. KUR DEĞERLEME & KAMBİYO MOTORU (646 / 656)            */}
        {/* ======================================================== */}
        <TabsContent value="kur-degerleme" className="space-y-4">
          <Card>
            <CardHeader className="flex flex-wrap items-center justify-between gap-3 pb-4">
              <div>
                <CardTitle className="text-base flex items-center gap-2">
                  <Sparkles className="size-4 text-primary" />
                  <span>Dövizli Cari & Kur Değerleme Sihirbazı</span>
                </CardTitle>
                <CardDescription>
                  Dövizli müşteri ve tedarikçi hesaplarının güncel kurlarla değerlenerek 646 Kambiyo Kârları / 656 Kambiyo Zararları yevmiye fişlerinin oluşturulması
                </CardDescription>
              </div>
              <Button variant="outline" size="sm" onClick={() => refetchFx()} className="h-8 text-xs gap-1">
                <RotateCcw className="size-3" /> Bakiyeleri Yenile
              </Button>
            </CardHeader>
            <CardContent className="space-y-6">
              {/* KUR GİRİŞ VE DEĞERLEME FORMU */}
              <div className="rounded-lg border border-border bg-muted/20 p-4 space-y-4">
                <div className="grid gap-3 sm:grid-cols-2 md:grid-cols-5 items-end">
                  <div className="space-y-1">
                    <Label className="text-xs">Değerleme Tarihi</Label>
                    <Input
                      type="date"
                      className="h-8 text-xs bg-background"
                      value={revalDate}
                      onChange={(e) => setRevalDate(e.target.value)}
                    />
                  </div>

                  <div className="space-y-1">
                    <Label className="text-xs">USD Kuru (TL)</Label>
                    <Input
                      type="number"
                      step="0.01"
                      className="h-8 text-xs font-mono bg-background"
                      value={usdRate}
                      onChange={(e) => setUsdRate(e.target.value)}
                      placeholder="35.00"
                    />
                  </div>

                  <div className="space-y-1">
                    <Label className="text-xs">EUR Kuru (TL)</Label>
                    <Input
                      type="number"
                      step="0.01"
                      className="h-8 text-xs font-mono bg-background"
                      value={eurRate}
                      onChange={(e) => setEurRate(e.target.value)}
                      placeholder="38.00"
                    />
                  </div>

                  <div className="space-y-1">
                    <Label className="text-xs">GBP Kuru (TL)</Label>
                    <Input
                      type="number"
                      step="0.01"
                      className="h-8 text-xs font-mono bg-background"
                      value={gbpRate}
                      onChange={(e) => setGbpRate(e.target.value)}
                      placeholder="45.00"
                    />
                  </div>

                  <div>
                    <Button
                      size="sm"
                      className="w-full h-8 text-xs gap-1.5"
                      onClick={() => runFxRevaluationMutation.mutate()}
                      disabled={runFxRevaluationMutation.isPending || fxBalances.length === 0}
                    >
                      <Sparkles className="size-3.5" />
                      {runFxRevaluationMutation.isPending ? "Değerleniyor..." : "Değerleme Fişi Kes"}
                    </Button>
                  </div>
                </div>

                <div className="space-y-1">
                  <Label className="text-xs text-muted-foreground">İsteğe Bağlı Fiş Açıklaması</Label>
                  <Input
                    className="h-8 text-xs bg-background"
                    placeholder="Örn: 2026/08 Ay Sonu Kur Değerleme Kaydı"
                    value={revalDesc}
                    onChange={(e) => setRevalDesc(e.target.value)}
                  />
                </div>
              </div>

              {/* DÖVİZLİ CARİLER VE SİMÜLASYON TABLOSU */}
              <div className="space-y-2">
                <div className="flex items-center justify-between">
                  <h4 className="text-xs font-bold uppercase tracking-wider text-muted-foreground">
                    Dövizli Cari Bakiyeleri & Tahmini Kur Farkı Önizlemesi
                  </h4>
                  <span className="text-xs text-muted-foreground font-mono">
                    Toplam {fxBalances.length} dövizli cari bulundu
                  </span>
                </div>

                {fxLoading ? (
                  <div className="py-12 text-center text-sm text-muted-foreground">Dövizli bakiyeler taranıyor...</div>
                ) : fxBalances.length === 0 ? (
                  <div className="py-12 text-center text-xs text-muted-foreground border rounded-lg">
                    Sistemde dövizli (USD/EUR/GBP) bakiye veren aktif cari hesap bulunmuyor.
                  </div>
                ) : (
                  <div className="rounded-lg border border-border overflow-x-auto">
                    <table className="w-full text-xs">
                      <thead>
                        <tr className="bg-muted/40 text-left font-semibold border-b border-border">
                          <th className="py-2 px-3">Cari Ünvanı</th>
                          <th className="py-2 px-3">Tür</th>
                          <th className="py-2 px-3">Döviz</th>
                          <th className="py-2 px-3 text-right">Döviz Bakiyesi</th>
                          <th className="py-2 px-3 text-right">Kayıtlı TRY Değeri</th>
                          <th className="py-2 px-3 text-right">Ort. Fatura Kuru</th>
                          <th className="py-2 px-3 text-right">Güncel Kur</th>
                          <th className="py-2 px-3 text-right">Değerlenmiş TRY</th>
                          <th className="py-2 px-3 text-right">Tahmini Kur Farkı</th>
                        </tr>
                      </thead>
                      <tbody>
                        {fxBalances.map((item: any) => {
                          const currentRate =
                            item.currency === "USD"
                              ? Number(usdRate) || 0
                              : item.currency === "EUR"
                                ? Number(eurRate) || 0
                                : item.currency === "GBP"
                                  ? Number(gbpRate) || 0
                                  : 1;

                          const revaluedTry = Math.round(Number(item.foreign_balance) * currentRate * 100) / 100;
                          const rawDiff = Math.round((revaluedTry - Number(item.try_cost_balance)) * 100) / 100;

                          // Müşteri için kur artışı kâr (+), tedarikçi için kur artışı zarar (-)
                          const isGain =
                            item.partner_type === "MUSTERI"
                              ? rawDiff >= 0
                              : rawDiff <= 0;

                          return (
                            <tr key={`${item.partner_id}-${item.currency}`} className="border-b border-border/50 last:border-0 font-mono">
                              <td className="py-2 px-3 font-sans font-medium text-foreground">{item.partner_title}</td>
                              <td className="py-2 px-3">
                                <Badge variant={item.partner_type === "MUSTERI" ? "default" : "secondary"} className="text-[10px] py-0">
                                  {item.partner_type}
                                </Badge>
                              </td>
                              <td className="py-2 px-3 font-bold text-primary">{item.currency}</td>
                              <td className="py-2 px-3 text-right font-bold">{formatMoney(item.foreign_balance)}</td>
                              <td className="py-2 px-3 text-right text-muted-foreground">{formatMoney(item.try_cost_balance)} TL</td>
                              <td className="py-2 px-3 text-right text-muted-foreground">{item.average_rate}</td>
                              <td className="py-2 px-3 text-right font-bold text-foreground">{currentRate.toFixed(2)}</td>
                              <td className="py-2 px-3 text-right font-bold">{formatMoney(revaluedTry)} TL</td>
                              <td className={`py-2 px-3 text-right font-black ${isGain ? "text-emerald-600 dark:text-emerald-400" : "text-destructive"}`}>
                                {isGain ? "+" : "-"}{formatMoney(Math.abs(rawDiff))} TL
                                <span className="text-[10px] block font-sans font-normal text-muted-foreground">
                                  {isGain ? "(646 Kâr)" : "(656 Zarar)"}
                                </span>
                              </td>
                            </tr>
                          );
                        })}
                      </tbody>
                    </table>
                  </div>
                )}
              </div>
            </CardContent>
          </Card>
        </TabsContent>

        {/* ======================================================== */}
        {/* 6. DENETİM VE MUTABAKAT PANELİ                           */}
        {/* ======================================================== */}
        <TabsContent value="denetim" className="space-y-4">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div className="flex items-center gap-2">
              <h3 className="text-sm font-semibold">Denetim Dönemi:</h3>
              <Select value={auditYear} onValueChange={setAuditYear}>
                <SelectTrigger className="h-8 w-24 text-xs">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {[currentYear, currentYear - 1, currentYear - 2].map((y) => (
                    <SelectItem key={y} value={String(y)} className="text-xs">
                      {y}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <Select value={auditMonth} onValueChange={setAuditMonth}>
                <SelectTrigger className="h-8 w-28 text-xs">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {Array.from({ length: 12 }, (_, i) => i + 1).map((m) => (
                    <SelectItem key={m} value={String(m)} className="text-xs">
                      {m}. Ay
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <Button size="sm" variant="outline" onClick={() => { refetchRecon(); refetchAudit(); }} className="h-8 text-xs gap-1">
                <RotateCcw className="size-3" /> Denetimi Yeniden Çalıştır
              </Button>
            </div>

            <div className="flex items-center gap-2">
              <Select value={auditFilterSeverity} onValueChange={setAuditFilterSeverity}>
                <SelectTrigger className="h-8 w-36 text-xs">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="ALL" className="text-xs">Tüm Seviyeler</SelectItem>
                  <SelectItem value="CRITICAL" className="text-xs text-destructive">Kritik Hatalar</SelectItem>
                  <SelectItem value="WARNING" className="text-xs text-amber-600">Uyarılar</SelectItem>
                  <SelectItem value="INFO" className="text-xs text-emerald-600">Bilgi / Uyumlu</SelectItem>
                </SelectContent>
              </Select>
            </div>
          </div>

          {/* Özet Kartları */}
          {reconSummary && (
            <div className="grid gap-4 sm:grid-cols-4">
              <Card className="border-l-4 border-l-destructive">
                <CardContent className="pt-4">
                  <div className="flex items-center justify-between">
                    <p className="text-xs text-muted-foreground font-medium uppercase">Kritik Hatalar</p>
                    <XCircle className="size-4 text-destructive" />
                  </div>
                  <p className="text-2xl font-bold font-mono mt-1 text-destructive">
                    {reconSummary.critical_errors_count}
                  </p>
                </CardContent>
              </Card>

              <Card className="border-l-4 border-l-amber-500">
                <CardContent className="pt-4">
                  <div className="flex items-center justify-between">
                    <p className="text-xs text-muted-foreground font-medium uppercase">Uyarılar</p>
                    <AlertTriangle className="size-4 text-amber-500" />
                  </div>
                  <p className="text-2xl font-bold font-mono mt-1 text-amber-600">
                    {reconSummary.warnings_count}
                  </p>
                </CardContent>
              </Card>

              <Card className="border-l-4 border-l-emerald-500">
                <CardContent className="pt-4">
                  <div className="flex items-center justify-between">
                    <p className="text-xs text-muted-foreground font-medium uppercase">Başarılı Kontroller</p>
                    <CheckCircle2 className="size-4 text-emerald-500" />
                  </div>
                  <p className="text-2xl font-bold font-mono mt-1 text-emerald-600">
                    {reconSummary.passed_checks_count}
                  </p>
                </CardContent>
              </Card>

              <Card className={`border-l-4 ${reconSummary.is_ready_for_close ? "border-l-emerald-500" : "border-l-destructive"}`}>
                <CardContent className="pt-4">
                  <div className="flex items-center justify-between">
                    <p className="text-xs text-muted-foreground font-medium uppercase">Kapanış Uygunluğu</p>
                    {reconSummary.is_ready_for_close ? (
                      <CheckCircle2 className="size-4 text-emerald-500" />
                    ) : (
                      <Lock className="size-4 text-destructive" />
                    )}
                  </div>
                  <p className={`text-sm font-bold mt-2 ${reconSummary.is_ready_for_close ? "text-emerald-600" : "text-destructive"}`}>
                    {reconSummary.is_ready_for_close ? "KAPANIŞA HAZIR" : "KAPATILAMAZ"}
                  </p>
                </CardContent>
              </Card>
            </div>
          )}

          {/* Detaylı Denetim Tablosu */}
          <Card>
            <CardHeader className="py-4">
              <CardTitle className="text-base">Muhasebe & Mutabakat Denetim Kontrolleri</CardTitle>
              <CardDescription>
                STMM ↔ 621, Satış ↔ 600, KDV ↔ 391, Cari ↔ 120 ve yevmiye denklik kontrolleri
              </CardDescription>
            </CardHeader>
            <CardContent>
              {auditLoading ? (
                <div className="py-12 text-center text-sm text-muted-foreground">Denetim kontrolleri çalıştırılıyor...</div>
              ) : filteredAuditResults.length === 0 ? (
                <div className="py-12 text-center text-sm text-muted-foreground">
                  Bu dönem için gösterilecek denetim kaydı bulunamadı.
                </div>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full text-xs">
                    <thead>
                      <tr className="border-b border-border text-left font-semibold text-muted-foreground bg-muted/40">
                        <th className="py-2.5 px-3">Kontrol Adı</th>
                        <th className="py-2.5 px-3">Seviye</th>
                        <th className="py-2.5 px-3">Durum</th>
                        <th className="py-2.5 px-3 text-right">Beklenen</th>
                        <th className="py-2.5 px-3 text-right">Gerçekleşen</th>
                        <th className="py-2.5 px-3 text-right">Fark</th>
                        <th className="py-2.5 px-3">Açıklama / Detay</th>
                      </tr>
                    </thead>
                    <tbody>
                      {filteredAuditResults.map((r, idx) => (
                        <tr key={idx} className="border-b border-border/60 hover:bg-muted/30 last:border-0">
                          <td className="py-2.5 px-3 font-mono font-bold">{r.check_name}</td>
                          <td className="py-2.5 px-3">
                            <Badge
                              variant={
                                r.severity === "CRITICAL"
                                  ? "destructive"
                                  : r.severity === "WARNING"
                                    ? "secondary"
                                    : "outline"
                              }
                              className="text-[10px] py-0"
                            >
                              {r.severity}
                            </Badge>
                          </td>
                          <td className="py-2.5 px-3">
                            <Badge
                              variant={r.status === "PASS" ? "outline" : "destructive"}
                              className={`text-[10px] py-0 ${r.status === "PASS" ? "text-emerald-600 border-emerald-500/40" : ""}`}
                            >
                              {r.status}
                            </Badge>
                          </td>
                          <td className="py-2.5 px-3 text-right font-mono">{formatMoney(r.expected_value)}</td>
                          <td className="py-2.5 px-3 text-right font-mono">{formatMoney(r.actual_value)}</td>
                          <td className={`py-2.5 px-3 text-right font-mono font-semibold ${Math.abs(Number(r.difference)) > 0.05 ? "text-destructive" : "text-emerald-600"}`}>
                            {formatMoney(r.difference)}
                          </td>
                          <td className="py-2.5 px-3 text-muted-foreground max-w-xs">{r.detail}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </CardContent>
          </Card>
        </TabsContent>

        {/* ======================================================== */}
        {/* 5. DÖNEM YÖNETİMİ & KAPANIŞ                              */}
        {/* ======================================================== */}
        <TabsContent value="donemler" className="space-y-4">
          <Card>
            <CardHeader className="flex flex-wrap items-center justify-between gap-3 pb-4">
              <div>
                <CardTitle className="text-base flex items-center gap-2">
                  <Calendar className="size-4 text-primary" />
                  <span>Mali Dönem Yönetimi & Kapanış</span>
                </CardTitle>
                <CardDescription>
                  Aylık dönemlerin kapatılması, kilitlenmesi ve kapalı döneme kayıt girişinin engellenmesi
                </CardDescription>
              </div>
            </CardHeader>
            <CardContent>
              {periodsLoading ? (
                <div className="py-12 text-center text-sm text-muted-foreground">Dönem kayıtları yükleniyor...</div>
              ) : (
                <div className="space-y-4">
                  <div className="grid gap-3 sm:grid-cols-3">
                    {/* Hızlı Dönem Kapatma / Açma Kartı */}
                    <Card className="border-dashed p-4 sm:col-span-3 bg-muted/20">
                      <div className="flex flex-wrap items-center justify-between gap-3">
                        <div>
                          <p className="text-xs font-semibold">Aktif Dönem Kapatma / Açma Paneli</p>
                          <p className="text-xs text-muted-foreground">
                            Kapatılan döneme yeni fatura veya yevmiye kaydı yapılamaz.
                          </p>
                        </div>
                        <div className="flex items-center gap-2">
                          <Select value={auditYear} onValueChange={setAuditYear}>
                            <SelectTrigger className="h-8 w-24 text-xs">
                              <SelectValue />
                            </SelectTrigger>
                            <SelectContent>
                              {[currentYear, currentYear - 1].map((y) => (
                                <SelectItem key={y} value={String(y)} className="text-xs">{y}</SelectItem>
                              ))}
                            </SelectContent>
                          </Select>
                          <Select value={auditMonth} onValueChange={setAuditMonth}>
                            <SelectTrigger className="h-8 w-28 text-xs">
                              <SelectValue />
                            </SelectTrigger>
                            <SelectContent>
                              {Array.from({ length: 12 }, (_, i) => i + 1).map((m) => (
                                <SelectItem key={m} value={String(m)} className="text-xs">{m}. Ay</SelectItem>
                              ))}
                            </SelectContent>
                          </Select>
                          <Button
                            size="sm"
                            variant="destructive"
                            className="h-8 text-xs gap-1.5"
                            onClick={() => closePeriodMutation.mutate({ year: Number(auditYear), month: Number(auditMonth) })}
                            disabled={closePeriodMutation.isPending}
                          >
                            <Lock className="size-3.5" /> Dönemi Kapat
                          </Button>
                          <Button
                            size="sm"
                            variant="outline"
                            className="h-8 text-xs gap-1.5"
                            onClick={() => reopenPeriodMutation.mutate({ year: Number(auditYear), month: Number(auditMonth) })}
                            disabled={reopenPeriodMutation.isPending}
                          >
                            <Unlock className="size-3.5" /> Yeniden Aç
                          </Button>
                        </div>
                      </div>
                    </Card>
                  </div>

                  <div className="overflow-x-auto">
                    <table className="w-full text-xs">
                      <thead>
                        <tr className="border-b border-border text-left font-semibold text-muted-foreground bg-muted/40">
                          <th className="py-2.5 px-3">Dönem Yılı</th>
                          <th className="py-2.5 px-3">Dönem Ayı</th>
                          <th className="py-2.5 px-3">Durum</th>
                          <th className="py-2.5 px-3">Açılış Tarihi</th>
                          <th className="py-2.5 px-3">Kapanış Tarihi</th>
                          <th className="py-2.5 px-3 text-right">İşlemler</th>
                        </tr>
                      </thead>
                      <tbody>
                        {periods.length === 0 ? (
                          <tr>
                            <td colSpan={6} className="py-8 text-center text-muted-foreground text-xs">
                              Henüz kapatılmış mali dönem bulunmuyor. Tüm dönemler açık durumdadır.
                            </td>
                          </tr>
                        ) : (
                          periods.map((p) => (
                            <tr key={p.id} className="border-b border-border/60 hover:bg-muted/30 last:border-0 font-mono">
                              <td className="py-2.5 px-3 font-bold">{p.period_year}</td>
                              <td className="py-2.5 px-3 font-semibold">{p.period_month}. Ay</td>
                              <td className="py-2.5 px-3">
                                <Badge
                                  variant={
                                    p.status === "CLOSED"
                                      ? "destructive"
                                      : p.status === "LOCKED"
                                        ? "secondary"
                                        : "outline"
                                  }
                                  className="text-[10px] py-0"
                                >
                                  {p.status}
                                </Badge>
                              </td>
                              <td className="py-2.5 px-3 font-sans text-muted-foreground">{p.opened_at ? formatDate(p.opened_at) : "-"}</td>
                              <td className="py-2.5 px-3 font-sans text-muted-foreground">{p.closed_at ? formatDate(p.closed_at) : "-"}</td>
                              <td className="py-2.5 px-3 text-right">
                                {p.status === "CLOSED" ? (
                                  <Button
                                    size="sm"
                                    variant="outline"
                                    className="h-7 text-[10px] gap-1"
                                    onClick={() => reopenPeriodMutation.mutate({ year: p.period_year, month: p.period_month })}
                                    disabled={reopenPeriodMutation.isPending}
                                  >
                                    <Unlock className="size-3" /> Yeniden Aç
                                  </Button>
                                ) : (
                                  <Button
                                    size="sm"
                                    variant="destructive"
                                    className="h-7 text-[10px] gap-1"
                                    onClick={() => closePeriodMutation.mutate({ year: p.period_year, month: p.period_month })}
                                    disabled={closePeriodMutation.isPending}
                                  >
                                    <Lock className="size-3" /> Kapat
                                  </Button>
                                )}
                              </td>
                            </tr>
                          ))
                        )}
                      </tbody>
                    </table>
                  </div>
                </div>
              )}
            </CardContent>
          </Card>
        </TabsContent>

        {/* ======================================================== */}
        {/* 6. YEVMİYE KAYITLARI & FİŞLER                            */}
        {/* ======================================================== */}
        <TabsContent value="yevmiye" className="space-y-4">
          <Card>
            <CardHeader className="flex flex-wrap items-center justify-between gap-3 py-4">
              <div>
                <CardTitle className="text-base">Yevmiye Kayıtları & Muhasebe Fişleri</CardTitle>
                <CardDescription>Onaylı satış faturaları ve otomatik muhasebe fişleri dökümü</CardDescription>
              </div>
              <Button variant="outline" size="sm" onClick={handleExportJournal} className="gap-1.5 h-8 text-xs">
                <Download className="size-3.5" /> Excel İndir
              </Button>
            </CardHeader>
            <CardContent>
              {journalLoading ? (
                <div className="py-12 text-center text-sm text-muted-foreground">Yevmiye kayıtları yükleniyor...</div>
              ) : journalEntries.length === 0 ? (
                <div className="py-12 text-center text-sm text-muted-foreground">
                  Henüz onaylanmış yevmiye fişi kaydı bulunmuyor. Satış faturası oluşturulduğunda otomatik yevmiye fişi açılır.
                </div>
              ) : (
                <div className="space-y-4">
                  {journalEntries.map((je: any) => (
                    <Card key={je.id} className="border border-border/80 shadow-none">
                      <CardHeader className="py-2.5 px-4 bg-muted/30 border-b border-border/60 flex flex-row items-center justify-between">
                        <div className="flex items-center gap-2">
                          <span className="font-mono font-bold text-xs text-primary">{je.entry_number}</span>
                          <span className="text-xs text-muted-foreground font-sans">({formatDate(je.entry_date)})</span>
                          <Badge variant="outline" className="text-[10px] py-0">
                            {je.source_type}
                          </Badge>
                          <Badge
                            variant={
                              je.status === "POSTED"
                                ? "default"
                                : je.status === "CANCELLED"
                                  ? "destructive"
                                  : "secondary"
                            }
                            className="text-[10px] py-0"
                          >
                            {je.status}
                          </Badge>
                        </div>
                        <div className="font-mono text-xs font-bold">
                          Toplam: {formatMoney(je.total_debit)} TL
                        </div>
                      </CardHeader>
                      <CardContent className="p-0">
                        <table className="w-full text-xs">
                          <thead>
                            <tr className="border-b border-border/40 text-left text-muted-foreground bg-muted/10 font-semibold">
                              <th className="py-1.5 px-4">Hesap Kodu</th>
                              <th className="py-1.5 px-3">Hesap Adı</th>
                              <th className="py-1.5 px-3">Satır Açıklaması</th>
                              <th className="py-1.5 px-3 text-right">Borç (TL)</th>
                              <th className="py-1.5 px-4 text-right">Alacak (TL)</th>
                            </tr>
                          </thead>
                          <tbody>
                            {(je.journal_lines || []).map((jl: any) => (
                              <tr key={jl.id} className="border-b border-border/30 last:border-0 font-mono">
                                <td className="py-1.5 px-4 font-bold text-primary">{jl.chart_of_accounts?.code}</td>
                                <td className="py-1.5 px-3 font-sans">{jl.chart_of_accounts?.name}</td>
                                <td className="py-1.5 px-3 font-sans text-muted-foreground truncate max-w-xs">{jl.description}</td>
                                <td className="py-1.5 px-3 text-right text-emerald-600 font-medium">
                                  {Number(jl.debit) > 0 ? formatMoney(jl.debit) : "-"}
                                </td>
                                <td className="py-1.5 px-4 text-right text-primary font-medium">
                                  {Number(jl.credit) > 0 ? formatMoney(jl.credit) : "-"}
                                </td>
                              </tr>
                            ))}
                          </tbody>
                        </table>
                      </CardContent>
                    </Card>
                  ))}
                </div>
              )}
            </CardContent>
          </Card>
        </TabsContent>

        {/* ======================================================== */}
        {/* 7. HESAP PLANI (TDHP)                                    */}
        {/* ======================================================== */}
        <TabsContent value="hesap-plani" className="space-y-4">
          <Card>
            <CardHeader className="pb-3">
              <CardTitle className="text-base flex items-center justify-between">
                <span>Tek Düzen Hesap Planı (TDHP)</span>
                <Badge variant="secondary">Standart Muhasebe Sistemi</Badge>
              </CardTitle>
              <CardDescription>
                Veritabanında tanımlı aktif hesap planı kartları
              </CardDescription>
            </CardHeader>
            <CardContent>
              {accountsLoading ? (
                <div className="py-12 text-center text-sm text-muted-foreground">Hesap planı yükleniyor...</div>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full text-xs">
                    <thead>
                      <tr className="border-b border-border text-left font-semibold text-muted-foreground bg-muted/40">
                        <th className="py-2.5 px-3">Hesap Kodu</th>
                        <th className="py-2.5 px-3">Hesap Adı</th>
                        <th className="py-2.5 px-3">Hesap Türü</th>
                        <th className="py-2.5 px-3">Normal Bakiye</th>
                        <th className="py-2.5 px-3">Sistem Etiketi</th>
                      </tr>
                    </thead>
                    <tbody>
                      {accounts.map((acc) => (
                        <tr key={acc.id} className="border-b border-border/60 hover:bg-muted/30 last:border-0">
                          <td className="py-2 px-3 font-mono font-bold text-primary">{acc.code}</td>
                          <td className="py-2 px-3 font-medium">{acc.name}</td>
                          <td className="py-2 px-3">
                            <Badge variant={acc.account_type === "ASSET" ? "default" : acc.account_type === "LIABILITY" ? "secondary" : "outline"} className="text-[10px] py-0">
                              {acc.account_type}
                            </Badge>
                          </td>
                          <td className="py-2 px-3 font-mono text-muted-foreground">{acc.normal_balance}</td>
                          <td className="py-2 px-3 font-mono text-[10px] text-muted-foreground">{acc.system_tag || "-"}</td>
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
