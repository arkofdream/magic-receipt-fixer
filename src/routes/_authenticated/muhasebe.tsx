import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import {
  Landmark,
  BookOpen,
  FileSpreadsheet,
  TrendingUp,
  Receipt,
  ArrowDownLeft,
  ArrowUpRight,
  Plus,
  Download,
  Building2,
  CheckCircle2,
  Wallet,
  Coins,
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
          "Tek Düzen Hesap Planı, Yevmiye Fişleri (Tahsil, Tediye, Mahsup), Mizan Tablosu, Gelir Tablosu, KDV1 Beyannamesi ve Banka Hareketleri.",
      },
      { property: "og:title", content: "Muhasebe & Finans | e-Fatura Portalı" },
      {
        property: "og:description",
        content: "Hesap planı, mizan, gelir tablosu, KDV1 ve banka hesap takibi.",
      },
    ],
  }),
  component: AccountingPage,
});

// STANDART TEK DÜZEN HESAP PLANI
const STANDARD_ACCOUNTS = [
  { code: "100", name: "Kasa Hesabı", category: "Dönen Varlıklar", type: "AKTIF" },
  { code: "102", name: "Bankalar Hesabı", category: "Dönen Varlıklar", type: "AKTIF" },
  { code: "108", name: "Diğer Hazır Değerler / POS", category: "Dönen Varlıklar", type: "AKTIF" },
  { code: "120", name: "Alıcılar / Cari Müşteriler", category: "Dönen Varlıklar", type: "AKTIF" },
  { code: "153", name: "Ticari Mallar (Stok)", category: "Dönen Varlıklar", type: "AKTIF" },
  { code: "191", name: "İndirilecek KDV", category: "Dönen Varlıklar", type: "AKTIF" },
  { code: "320", name: "Satıcılar / Cari Tedarikçiler", category: "Kısa Vadeli Yabancı Kaynaklar", type: "PASIF" },
  { code: "360", name: "Ödenecek Vergi ve Fonlar", category: "Kısa Vadeli Yabancı Kaynaklar", type: "PASIF" },
  { code: "391", name: "Hesaplanan KDV", category: "Kısa Vadeli Yabancı Kaynaklar", type: "PASIF" },
  { code: "600", name: "Yurtiçi Satışlar Geliri", category: "Gelir Tablosu", type: "GELIR" },
  { code: "610", name: "Satıştan İadeler (-)", category: "Gelir Tablosu", type: "GIDER" },
  { code: "621", name: "Satılan Ticari Mallar Maliyeti (-)", category: "Gelir Tablosu", type: "GIDER" },
  { code: "770", name: "Genel Yönetim Giderleri (-)", category: "Gider Hesapları", type: "GIDER" },
  { code: "780", name: "Finansman / Banka Masrafları (-)", category: "Gider Hesapları", type: "GIDER" },
];

type BankAccount = {
  id: string;
  bank_name: string;
  account_name: string;
  iban: string;
  currency: string;
  balance: number;
};

type JournalEntry = {
  id: string;
  entry_number: string;
  entry_date: string;
  voucher_type: "TAHSIL" | "TEDIYE" | "MAHSUP";
  description: string;
  debit_account: string;
  credit_account: string;
  amount: number;
};

type BankMovement = {
  id: string;
  bank_id: string;
  date: string;
  movement_type: "HAVALE" | "EFT" | "BLOKE_COZUMU" | "MASRAF" | "GELEN_HAVALE";
  amount: number;
  direction: "IN" | "OUT";
  description: string;
};

const INITIAL_BANKS: BankAccount[] = [];
const INITIAL_JOURNAL: JournalEntry[] = [];
const INITIAL_BANK_MOVEMENTS: BankMovement[] = [];

function AccountingPage() {
  const queryClient = useQueryClient();

  // Yerel veriler (Storage / State)
  const [banks, setBanks] = useState<BankAccount[]>(() => {
    const saved = localStorage.getItem("muhasebe_banks");
    return saved ? JSON.parse(saved) : INITIAL_BANKS;
  });

  const [journal, setJournal] = useState<JournalEntry[]>(() => {
    const saved = localStorage.getItem("muhasebe_journal");
    return saved ? JSON.parse(saved) : INITIAL_JOURNAL;
  });

  const [bankMovements, setBankMovements] = useState<BankMovement[]>(() => {
    const saved = localStorage.getItem("muhasebe_bank_movements");
    return saved ? JSON.parse(saved) : INITIAL_BANK_MOVEMENTS;
  });

  // Dialoglar
  const [journalOpen, setJournalOpen] = useState(false);
  const [bankOpen, setBankOpen] = useState(false);
  const [movementOpen, setMovementOpen] = useState(false);

  // Form states
  const [journalForm, setJournalForm] = useState({
    voucher_type: "TAHSIL" as "TAHSIL" | "TEDIYE" | "MAHSUP",
    entry_date: new Date().toISOString().slice(0, 10),
    description: "",
    debit_account: "100",
    credit_account: "600",
    amount: "",
  });

  const [bankForm, setBankForm] = useState({
    bank_name: "Kuveyt Türk Katılım Bankası",
    account_name: "",
    iban: "TR",
    currency: "TRY",
    balance: "",
  });

  const [movementForm, setMovementForm] = useState({
    bank_id: banks[0]?.id ?? "",
    date: new Date().toISOString().slice(0, 10),
    movement_type: "HAVALE" as BankMovement["movement_type"],
    amount: "",
    description: "",
  });

  // Faturalar & Cari verileri
  const { data: invoices = [] } = useQuery({
    queryKey: ["invoices"],
    queryFn: async () => {
      const { data, error } = await supabase.from("invoices").select("*");
      if (error) throw error;
      return data ?? [];
    },
  });

  const { data: posSales = [] } = useQuery({
    queryKey: ["pos-sales-all"],
    queryFn: async () => {
      const { data, error } = await supabase.from("pos_sales").select("*");
      if (error) throw error;
      return data ?? [];
    },
  });

  // HESAPLAR VE MİZAN HESAPLAMALARI
  const trialBalance = useMemo(() => {
    // Fatura ve POS hareketlerinden otomatik matrah ve KDV hesapları
    let salesTotal = 0;
    let returnsTotal = 0;
    let vat391Total = 0;
    let vat191Total = 0;
    let customerDebt = 0;
    let posTotal = 0;

    for (const inv of invoices) {
      if (inv.status === "IPTAL") continue;
      const grand = Number(inv.grand_total) || 0;
      const vat = Number(inv.total_vat) || 0;
      const subtotal = Number(inv.taxable_amount || inv.subtotal) || grand - vat;

      if (inv.type === "IADE") {
        returnsTotal += subtotal;
        vat191Total += vat;
      } else if (inv.type === "GELEN_FATURA" || inv.type === "GELEN_E_ARSIV") {
        vat191Total += vat;
      } else {
        salesTotal += subtotal;
        vat391Total += vat;
        customerDebt += grand;
      }
    }

    for (const pos of posSales) {
      posTotal += Number(pos.gross_amount) || 0;
      vat391Total += Number(pos.vat_amount) || 0;
      salesTotal += Number(pos.net_amount) || 0;
    }

    // Yevmiye fişlerinden gelen hareketleri ekle
    const accountTotals = new Map<string, { debit: number; credit: number }>();

    STANDARD_ACCOUNTS.forEach((acc) => {
      accountTotals.set(acc.code, { debit: 0, credit: 0 });
    });

    // Otomatik ön muhasebe hesapları
    accountTotals.get("120")!.debit += customerDebt;
    accountTotals.get("108")!.debit += posTotal;
    accountTotals.get("600")!.credit += salesTotal;
    accountTotals.get("610")!.debit += returnsTotal;
    accountTotals.get("391")!.credit += vat391Total;
    accountTotals.get("191")!.debit += vat191Total;

    // Yevmiye kayıtlarını yansıt
    for (const j of journal) {
      const amt = Number(j.amount) || 0;
      if (accountTotals.has(j.debit_account)) {
        accountTotals.get(j.debit_account)!.debit += amt;
      }
      if (accountTotals.has(j.credit_account)) {
        accountTotals.get(j.credit_account)!.credit += amt;
      }
    }

    // Banka hareketlerini 102 nolu hesaba yansıt
    let bankDebit = 0;
    let bankCredit = 0;
    for (const b of banks) bankDebit += Number(b.balance) || 0;
    for (const bm of bankMovements) {
      if (bm.direction === "IN") bankDebit += Number(bm.amount) || 0;
      else bankCredit += Number(bm.amount) || 0;
    }
    accountTotals.get("102")!.debit += bankDebit;
    accountTotals.get("102")!.credit += bankCredit;

    return STANDARD_ACCOUNTS.map((acc) => {
      const t = accountTotals.get(acc.code) ?? { debit: 0, credit: 0 };
      const debitBal = Math.max(0, t.debit - t.credit);
      const creditBal = Math.max(0, t.credit - t.debit);
      return {
        ...acc,
        debit: t.debit,
        credit: t.credit,
        debitBalance: debitBal,
        creditBalance: creditBal,
      };
    });
  }, [invoices, posSales, journal, banks, bankMovements]);

  // GELİR TABLOSU (KAR / ZARAR)
  const incomeStatement = useMemo(() => {
    const getAcc = (c: string) => trialBalance.find((a) => a.code === c);
    const grossSales = getAcc("600")?.credit ?? 0;
    const salesReturns = getAcc("610")?.debit ?? 0;
    const netSales = Math.max(0, grossSales - salesReturns);
    const cogs = getAcc("621")?.debit ?? grossSales * 0.65; // Satılan Malın Maliyeti
    const grossProfit = netSales - cogs;
    const operatingExpenses = getAcc("770")?.debit ?? 0;
    const financingExpenses = getAcc("780")?.debit ?? 0;
    const netOperatingProfit = grossProfit - operatingExpenses - financingExpenses;

    return {
      grossSales,
      salesReturns,
      netSales,
      cogs,
      grossProfit,
      operatingExpenses,
      financingExpenses,
      netOperatingProfit,
    };
  }, [trialBalance]);

  // KDV1 BEYANNAME ÖZETİ
  const kdv1Summary = useMemo(() => {
    let matrah0 = 0;
    let matrah1 = 0;
    let matrah10 = 0;
    let matrah20 = 0;
    let kdv1 = 0;
    let kdv10 = 0;
    let kdv20 = 0;
    let tevkifatKdv = 0;

    for (const inv of invoices) {
      if (inv.status === "IPTAL") continue;
      const vat = Number(inv.total_vat) || 0;
      const sub = Number(inv.taxable_amount || inv.subtotal) || 0;
      tevkifatKdv += Number(inv.total_tevkifat) || 0;

      // Kırılımlar
      if (inv.type === "ISTISNA") {
        matrah0 += sub;
      } else {
        matrah20 += sub;
        kdv20 += vat;
      }
    }

    for (const pos of posSales) {
      const vrate = Number(pos.vat_rate);
      const net = Number(pos.net_amount) || 0;
      const vat = Number(pos.vat_amount) || 0;
      if (vrate === 20) {
        matrah20 += net;
        kdv20 += vat;
      } else if (vrate === 10) {
        matrah10 += net;
        kdv10 += vat;
      } else if (vrate === 1) {
        matrah1 += net;
        kdv1 += vat;
      } else {
        matrah0 += net;
      }
    }

    const totalHesaplananKdv = kdv1 + kdv10 + kdv20;
    const indirilecekKdv = (trialBalance.find((a) => a.code === "191")?.debit ?? 0) + tevkifatKdv;
    const diff = totalHesaplananKdv - indirilecekKdv;
    const odenecekKdv = diff > 0 ? diff : 0;
    const devredenKdv = diff < 0 ? Math.abs(diff) : 0;

    return {
      matrah0,
      matrah1,
      matrah10,
      matrah20,
      totalMatrah: matrah0 + matrah1 + matrah10 + matrah20,
      kdv1,
      kdv10,
      kdv20,
      totalHesaplananKdv,
      indirilecekKdv,
      tevkifatKdv,
      odenecekKdv,
      devredenKdv,
    };
  }, [invoices, posSales, trialBalance]);

  // Banka Ekleme
  function handleAddBank() {
    if (!bankForm.account_name.trim()) {
      toast.error("Lütfen hesap adı giriniz.");
      return;
    }
    const newBank: BankAccount = {
      id: `bank-${Date.now()}`,
      bank_name: bankForm.bank_name,
      account_name: bankForm.account_name,
      iban: bankForm.iban,
      currency: bankForm.currency,
      balance: Number(bankForm.balance) || 0,
    };
    const updated = [...banks, newBank];
    setBanks(updated);
    localStorage.setItem("muhasebe_banks", JSON.stringify(updated));
    toast.success("Banka hesabı eklendi.");
    setBankOpen(false);
    setBankForm({
      bank_name: "Kuveyt Türk Katılım Bankası",
      account_name: "",
      iban: "TR",
      currency: "TRY",
      balance: "",
    });
  }

  // Banka Hareketi Ekleme (Havale, EFT, Bloke Çözümü, Masraf)
  function handleAddBankMovement() {
    const amount = Number(movementForm.amount);
    if (!amount || amount <= 0) {
      toast.error("Geçerli bir tutar giriniz.");
      return;
    }
    const direction: "IN" | "OUT" =
      movementForm.movement_type === "GELEN_HAVALE" || movementForm.movement_type === "BLOKE_COZUMU"
        ? "IN"
        : "OUT";

    const newMov: BankMovement = {
      id: `bm-${Date.now()}`,
      bank_id: movementForm.bank_id,
      date: movementForm.date,
      movement_type: movementForm.movement_type,
      amount,
      direction,
      description: movementForm.description || `${movementForm.movement_type} işlemi`,
    };

    const updatedMovs = [newMov, ...bankMovements];
    setBankMovements(updatedMovs);
    localStorage.setItem("muhasebe_bank_movements", JSON.stringify(updatedMovs));

    // Banka bakiyesini güncelle
    const updatedBanks = banks.map((b) => {
      if (b.id === movementForm.bank_id) {
        return {
          ...b,
          balance: direction === "IN" ? b.balance + amount : Math.max(0, b.balance - amount),
        };
      }
      return b;
    });
    setBanks(updatedBanks);
    localStorage.setItem("muhasebe_banks", JSON.stringify(updatedBanks));

    toast.success("Banka hareketi işlendi ve bakiye güncellendi.");
    setMovementOpen(false);
    setMovementForm({
      bank_id: banks[0]?.id ?? "",
      date: new Date().toISOString().slice(0, 10),
      movement_type: "HAVALE",
      amount: "",
      description: "",
    });
  }

  // Yevmiye Fişi Ekleme (Tahsil, Tediye, Mahsup)
  function handleAddJournal() {
    const amt = Number(journalForm.amount);
    if (!amt || amt <= 0) {
      toast.error("Lütfen geçerli bir fiş tutarı giriniz.");
      return;
    }
    if (journalForm.debit_account === journalForm.credit_account) {
      toast.error("Borç ve Alacak hesabı aynı olamaz.");
      return;
    }
    const newEntry: JournalEntry = {
      id: `j-${Date.now()}`,
      entry_number: `YEV-${new Date().getFullYear()}-${String(journal.length + 1).padStart(3, "0")}`,
      entry_date: journalForm.entry_date,
      voucher_type: journalForm.voucher_type,
      description: journalForm.description || `${journalForm.voucher_type} Fişi Kaydı`,
      debit_account: journalForm.debit_account,
      credit_account: journalForm.credit_account,
      amount: amt,
    };
    const updated = [newEntry, ...journal];
    setJournal(updated);
    localStorage.setItem("muhasebe_journal", JSON.stringify(updated));
    toast.success(`${journalForm.voucher_type} fişi yevmiyeye işlendi.`);
    setJournalOpen(false);
    setJournalForm({
      voucher_type: "TAHSIL",
      entry_date: new Date().toISOString().slice(0, 10),
      description: "",
      debit_account: "100",
      credit_account: "600",
      amount: "",
    });
  }

  function exportMizan() {
    downloadWorkbook(
      ["Hesap Kodu", "Hesap Adı", "Kategori", "Borç Toplamı", "Alacak Toplamı", "Borç Bakiye", "Alacak Bakiye"],
      trialBalance.map((a) => [
        a.code,
        a.name,
        a.category,
        a.debit,
        a.credit,
        a.debitBalance,
        a.creditBalance,
      ]),
      `mizan-tablosu-${new Date().toISOString().slice(0, 10)}.xlsx`,
      "Mizan",
    );
  }

  return (
    <AppShell
      title="Muhasebe & Finans Yönetimi"
      subtitle="Tek Düzen Hesap Planı, Yevmiye Fişleri, Mizan, Gelir Tablosu, KDV1 ve Banka Hareketleri"
    >
      <Tabs defaultValue="hesap-plani" className="space-y-4">
        <TabsList className="grid grid-cols-3 sm:flex sm:flex-wrap gap-1 h-auto p-1">
          <TabsTrigger value="hesap-plani" className="gap-1.5">
            <BookOpen className="size-4" /> Hesap Planı
          </TabsTrigger>
          <TabsTrigger value="yevmiye" className="gap-1.5">
            <Receipt className="size-4" /> Yevmiye Kayıtları & Fişler
          </TabsTrigger>
          <TabsTrigger value="mizan" className="gap-1.5">
            <FileSpreadsheet className="size-4" /> Mizan Tablosu
          </TabsTrigger>
          <TabsTrigger value="gelir-tablosu" className="gap-1.5">
            <TrendingUp className="size-4" /> Gelir Tablosu (Kar / Zarar)
          </TabsTrigger>
          <TabsTrigger value="kdv1" className="gap-1.5">
            <Coins className="size-4" /> KDV1 Beyanname
          </TabsTrigger>
          <TabsTrigger value="bankalar" className="gap-1.5">
            <Landmark className="size-4" /> Banka Hesapları & Ekstre
          </TabsTrigger>
        </TabsList>

        {/* 1. HESAP PLANI */}
        <TabsContent value="hesap-plani" className="space-y-4">
          <Card>
            <CardHeader className="pb-3">
              <CardTitle className="text-base flex items-center justify-between">
                <span>Tek Düzen Hesap Planı (TDHP)</span>
                <Badge variant="secondary">Standart Muhasebe Sistemi</Badge>
              </CardTitle>
              <CardDescription>
                Aktif, pasif, gelir ve gider ana hesaplarının dökümü ve güncel bakiye durumları
              </CardDescription>
            </CardHeader>
            <CardContent>
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground">
                      <th className="py-2.5 pr-4">Hesap Kodu</th>
                      <th className="py-2.5 pr-4">Hesap Adı</th>
                      <th className="py-2.5 pr-4">Kategori / Grup</th>
                      <th className="py-2.5 pr-4">Hesap Türü</th>
                      <th className="py-2.5 pr-4 text-right">Borç Toplamı</th>
                      <th className="py-2.5 pr-4 text-right">Alacak Toplamı</th>
                      <th className="py-2.5 text-right font-bold">Kalan Bakiye</th>
                    </tr>
                  </thead>
                  <tbody>
                    {trialBalance.map((acc) => {
                      const bal = acc.debitBalance > 0 ? acc.debitBalance : acc.creditBalance;
                      const balSide = acc.debitBalance > 0 ? "(B)" : acc.creditBalance > 0 ? "(A)" : "";
                      return (
                        <tr key={acc.code} className="border-b border-border/60 hover:bg-muted/30 last:border-0">
                          <td className="py-3 pr-4 font-mono font-bold text-primary">{acc.code}</td>
                          <td className="py-3 pr-4 font-medium">{acc.name}</td>
                          <td className="py-3 pr-4 text-xs text-muted-foreground">{acc.category}</td>
                          <td className="py-3 pr-4">
                            <Badge variant={acc.type === "AKTIF" ? "default" : acc.type === "PASIF" ? "secondary" : "outline"}>
                              {acc.type}
                            </Badge>
                          </td>
                          <td className="py-3 pr-4 text-right font-mono">{formatMoney(acc.debit)}</td>
                          <td className="py-3 pr-4 text-right font-mono">{formatMoney(acc.credit)}</td>
                          <td className="py-3 text-right font-mono font-semibold">
                            {formatMoney(bal)} <span className="text-xs text-muted-foreground">{balSide}</span>
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            </CardContent>
          </Card>
        </TabsContent>

        {/* 2. YEVMİYE KAYITLARI & FİŞLER */}
        <TabsContent value="yevmiye" className="space-y-4">
          <Card>
            <CardHeader className="flex flex-wrap items-center justify-between gap-3 py-4">
              <div>
                <CardTitle className="text-base">Yevmiye Kayıtları & Muhasebe Fişleri</CardTitle>
                <CardDescription>Tahsil fişi, tediye fişi ve mahsup fişi kayıtları</CardDescription>
              </div>
              <Dialog open={journalOpen} onOpenChange={setJournalOpen}>
                <DialogTrigger asChild>
                  <Button className="gap-1.5">
                    <Plus className="size-4" /> Yeni Fiş Kaydı
                  </Button>
                </DialogTrigger>
                <DialogContent>
                  <DialogHeader>
                    <DialogTitle>Yeni Muhasebe Fişi Ekle</DialogTitle>
                  </DialogHeader>
                  <div className="space-y-3 pt-2">
                    <div className="space-y-1">
                      <Label>Fiş Türü</Label>
                      <Select
                        value={journalForm.voucher_type}
                        onValueChange={(v) =>
                          setJournalForm({
                            ...journalForm,
                            voucher_type: v as "TAHSIL" | "TEDIYE" | "MAHSUP",
                            debit_account: v === "TAHSIL" ? "100" : v === "TEDIYE" ? "770" : "120",
                            credit_account: v === "TAHSIL" ? "120" : v === "TEDIYE" ? "100" : "391",
                          })
                        }
                      >
                        <SelectTrigger>
                          <SelectValue />
                        </SelectTrigger>
                        <SelectContent>
                          <SelectItem value="TAHSIL">Tahsil Fişi (Kasaya/Bankaya Para Girişi)</SelectItem>
                          <SelectItem value="TEDIYE">Tediye Fişi (Kasadan/Bankadan Para Çıkışı)</SelectItem>
                          <SelectItem value="MAHSUP">Mahsup Fişi (Nakit Harici Mahsuplaşma)</SelectItem>
                        </SelectContent>
                      </Select>
                    </div>
                    <div className="grid grid-cols-2 gap-3">
                      <div className="space-y-1">
                        <Label>Tarih</Label>
                        <Input
                          type="date"
                          value={journalForm.entry_date}
                          onChange={(e) => setJournalForm({ ...journalForm, entry_date: e.target.value })}
                        />
                      </div>
                      <div className="space-y-1">
                        <Label>Fiş Tutarı (₺)</Label>
                        <Input
                          placeholder="0.00"
                          value={journalForm.amount}
                          onChange={(e) => setJournalForm({ ...journalForm, amount: e.target.value })}
                        />
                      </div>
                    </div>
                    <div className="grid grid-cols-2 gap-3">
                      <div className="space-y-1">
                        <Label>Borçlu Hesap (Borç +)</Label>
                        <Select
                          value={journalForm.debit_account}
                          onValueChange={(v) => setJournalForm({ ...journalForm, debit_account: v })}
                        >
                          <SelectTrigger>
                            <SelectValue />
                          </SelectTrigger>
                          <SelectContent>
                            {STANDARD_ACCOUNTS.map((a) => (
                              <SelectItem key={a.code} value={a.code}>
                                {a.code} - {a.name}
                              </SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                      </div>
                      <div className="space-y-1">
                        <Label>Alacaklı Hesap (Alacak -)</Label>
                        <Select
                          value={journalForm.credit_account}
                          onValueChange={(v) => setJournalForm({ ...journalForm, credit_account: v })}
                        >
                          <SelectTrigger>
                            <SelectValue />
                          </SelectTrigger>
                          <SelectContent>
                            {STANDARD_ACCOUNTS.map((a) => (
                              <SelectItem key={a.code} value={a.code}>
                                {a.code} - {a.name}
                              </SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                      </div>
                    </div>
                    <div className="space-y-1">
                      <Label>Açıklama</Label>
                      <Input
                        placeholder="Fiş açıklama metni"
                        value={journalForm.description}
                        onChange={(e) => setJournalForm({ ...journalForm, description: e.target.value })}
                      />
                    </div>
                    <Button className="w-full mt-2" onClick={handleAddJournal}>
                      Fişi Kaydet & Yevmiyeye İşle
                    </Button>
                  </div>
                </DialogContent>
              </Dialog>
            </CardHeader>
            <CardContent>
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground">
                      <th className="py-2.5 pr-4">Yevmiye No</th>
                      <th className="py-2.5 pr-4">Tarih</th>
                      <th className="py-2.5 pr-4">Fiş Türü</th>
                      <th className="py-2.5 pr-4">Borçlu Hesap</th>
                      <th className="py-2.5 pr-4">Alacaklı Hesap</th>
                      <th className="py-2.5 pr-4 text-right">Tutar</th>
                      <th className="py-2.5">Açıklama</th>
                    </tr>
                  </thead>
                  <tbody>
                    {journal.length === 0 ? (
                      <tr>
                        <td colSpan={7} className="py-8 text-center text-muted-foreground text-xs">
                          Henüz yevmiye fişi kaydı bulunmuyor. "Yeni Fiş Kaydı" butonuyla ekleyebilirsiniz.
                        </td>
                      </tr>
                    ) : (
                      journal.map((j) => (
                        <tr key={j.id} className="border-b border-border/60 hover:bg-muted/30 last:border-0">
                          <td className="py-3 pr-4 font-mono font-semibold text-xs">{j.entry_number}</td>
                          <td className="py-3 pr-4 whitespace-nowrap">{formatDate(j.entry_date)}</td>
                          <td className="py-3 pr-4">
                            <Badge
                              variant={
                                j.voucher_type === "TAHSIL"
                                  ? "default"
                                  : j.voucher_type === "TEDIYE"
                                    ? "destructive"
                                    : "secondary"
                              }
                            >
                              {j.voucher_type === "TAHSIL"
                                ? "Tahsil Fişi"
                                : j.voucher_type === "TEDIYE"
                                  ? "Tediye Fişi"
                                  : "Mahsup Fişi"}
                            </Badge>
                          </td>
                          <td className="py-3 pr-4 font-mono text-xs text-primary font-semibold">{j.debit_account}</td>
                          <td className="py-3 pr-4 font-mono text-xs text-muted-foreground">{j.credit_account}</td>
                          <td className="py-3 pr-4 text-right font-mono font-bold">{formatMoney(j.amount)}</td>
                          <td className="py-3 text-xs text-muted-foreground">{j.description}</td>
                        </tr>
                      ))
                    )}
                  </tbody>
                </table>
              </div>
            </CardContent>
          </Card>
        </TabsContent>

        {/* 3. MİZAN TABLOSU */}
        <TabsContent value="mizan" className="space-y-4">
          <Card>
            <CardHeader className="flex flex-wrap items-center justify-between gap-3 py-4">
              <div>
                <CardTitle className="text-base">Mizan Tablosu (Aylık / Genel Mizan)</CardTitle>
                <CardDescription>Hesap bazında borç-alacak toplamları ve bakiye dökümü</CardDescription>
              </div>
              <Button variant="outline" size="sm" onClick={exportMizan} className="gap-1.5">
                <Download className="size-4" /> Excel Olarak İndir
              </Button>
            </CardHeader>
            <CardContent>
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground bg-muted/40">
                      <th className="py-2.5 px-3">Kod</th>
                      <th className="py-2.5 px-3">Hesap Adı</th>
                      <th className="py-2.5 px-3 text-right">Borç Tutarı</th>
                      <th className="py-2.5 px-3 text-right">Alacak Tutarı</th>
                      <th className="py-2.5 px-3 text-right">Borç Bakiye</th>
                      <th className="py-2.5 px-3 text-right">Alacak Bakiye</th>
                    </tr>
                  </thead>
                  <tbody>
                    {trialBalance.map((a) => (
                      <tr key={a.code} className="border-b border-border/60 hover:bg-muted/30 last:border-0">
                        <td className="py-2.5 px-3 font-mono font-bold">{a.code}</td>
                        <td className="py-2.5 px-3 font-medium">{a.name}</td>
                        <td className="py-2.5 px-3 text-right font-mono">{formatMoney(a.debit)}</td>
                        <td className="py-2.5 px-3 text-right font-mono">{formatMoney(a.credit)}</td>
                        <td className="py-2.5 px-3 text-right font-mono font-semibold text-emerald-600">
                          {a.debitBalance > 0 ? formatMoney(a.debitBalance) : "-"}
                        </td>
                        <td className="py-2.5 px-3 text-right font-mono font-semibold text-primary">
                          {a.creditBalance > 0 ? formatMoney(a.creditBalance) : "-"}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                  <tfoot>
                    <tr className="border-t-2 border-primary font-bold text-sm bg-muted/20">
                      <td colSpan={2} className="py-3 px-3">MİZAN GENEL TOPLAMI</td>
                      <td className="py-3 px-3 text-right font-mono">
                        {formatMoney(trialBalance.reduce((s, a) => s + a.debit, 0))}
                      </td>
                      <td className="py-3 px-3 text-right font-mono">
                        {formatMoney(trialBalance.reduce((s, a) => s + a.credit, 0))}
                      </td>
                      <td className="py-3 px-3 text-right font-mono text-emerald-600">
                        {formatMoney(trialBalance.reduce((s, a) => s + a.debitBalance, 0))}
                      </td>
                      <td className="py-3 px-3 text-right font-mono text-primary">
                        {formatMoney(trialBalance.reduce((s, a) => s + a.creditBalance, 0))}
                      </td>
                    </tr>
                  </tfoot>
                </table>
              </div>
            </CardContent>
          </Card>
        </TabsContent>

        {/* 4. GELİR TABLOSU */}
        <TabsContent value="gelir-tablosu" className="space-y-4">
          <Card className="max-w-3xl mx-auto">
            <CardHeader className="text-center pb-4 border-b border-border">
              <CardTitle className="text-lg">Ayrıntılı Gelir Tablosu (Kar / Zarar)</CardTitle>
              <CardDescription>Resmi mali tablo standardında kar/zarar hesaplaması</CardDescription>
            </CardHeader>
            <CardContent className="pt-6 space-y-4">
              <div className="space-y-2">
                <div className="flex justify-between py-2 border-b border-border text-sm font-medium">
                  <span>A. BRÜT SATIŞ GELİRLERİ (600)</span>
                  <span className="font-mono">{formatMoney(incomeStatement.grossSales)}</span>
                </div>
                <div className="flex justify-between py-2 border-b border-border text-sm text-muted-foreground">
                  <span>B. SATIŞ İNDİRİMLERİ VE İADELERİ (-) (610)</span>
                  <span className="font-mono text-destructive">- {formatMoney(incomeStatement.salesReturns)}</span>
                </div>
                <div className="flex justify-between py-2.5 border-b border-border text-base font-bold bg-muted/30 px-2 rounded">
                  <span>C. NET SATIŞLAR</span>
                  <span className="font-mono text-primary">{formatMoney(incomeStatement.netSales)}</span>
                </div>
                <div className="flex justify-between py-2 border-b border-border text-sm text-muted-foreground">
                  <span>D. SATILAN TİCARİ MALLAR MALİYETİ (-) (621)</span>
                  <span className="font-mono text-destructive">- {formatMoney(incomeStatement.cogs)}</span>
                </div>
                <div className="flex justify-between py-2.5 border-b border-border text-base font-bold bg-emerald-500/10 px-2 rounded text-emerald-700 dark:text-emerald-400">
                  <span>BRÜT SATIŞ KARI / (ZARARI)</span>
                  <span className="font-mono">{formatMoney(incomeStatement.grossProfit)}</span>
                </div>
                <div className="flex justify-between py-2 border-b border-border text-sm text-muted-foreground">
                  <span>E. FAALİYET GİDERLERİ (-) (770)</span>
                  <span className="font-mono text-destructive">- {formatMoney(incomeStatement.operatingExpenses)}</span>
                </div>
                <div className="flex justify-between py-2 border-b border-border text-sm text-muted-foreground">
                  <span>F. FİNANSMAN / BANKA GİDERLERİ (-) (780)</span>
                  <span className="font-mono text-destructive">- {formatMoney(incomeStatement.financingExpenses)}</span>
                </div>
                <div className="flex justify-between py-3 border-t-2 border-primary text-lg font-extrabold bg-primary/10 px-3 rounded text-primary">
                  <span>DÖNEM NET FAALİYET KARI / (ZARARI)</span>
                  <span className="font-mono">{formatMoney(incomeStatement.netOperatingProfit)}</span>
                </div>
              </div>
            </CardContent>
          </Card>
        </TabsContent>

        {/* 5. KDV1 BEYANNAME ÖZETİ */}
        <TabsContent value="kdv1" className="space-y-4">
          <div className="grid gap-4 sm:grid-cols-4">
            <Card>
              <CardContent className="pt-5">
                <p className="text-xs text-muted-foreground uppercase font-medium">Toplam KDV Matrahı</p>
                <p className="text-2xl font-bold mt-1">{formatMoney(kdv1Summary.totalMatrah)}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-5">
                <p className="text-xs text-muted-foreground uppercase font-medium">Hesaplanan KDV (391)</p>
                <p className="text-2xl font-bold mt-1 text-primary">{formatMoney(kdv1Summary.totalHesaplananKdv)}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-5">
                <p className="text-xs text-muted-foreground uppercase font-medium">İndirilecek KDV (191)</p>
                <p className="text-2xl font-bold mt-1 text-emerald-600">{formatMoney(kdv1Summary.indirilecekKdv)}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-5">
                <p className="text-xs text-muted-foreground uppercase font-medium">
                  {kdv1Summary.odenecekKdv > 0 ? "Ödenecek KDV" : "Sonraki Döneme Devreden KDV"}
                </p>
                <p className={`text-2xl font-bold mt-1 ${kdv1Summary.odenecekKdv > 0 ? "text-destructive" : "text-emerald-600"}`}>
                  {formatMoney(kdv1Summary.odenecekKdv > 0 ? kdv1Summary.odenecekKdv : kdv1Summary.devredenKdv)}
                </p>
              </CardContent>
            </Card>
          </div>

          <Card>
            <CardHeader className="pb-3">
              <CardTitle className="text-base">KDV1 Beyannamesi Matrah & Vergi Dağılımı</CardTitle>
              <CardDescription>Aylık e-fatura, e-arşiv ve POS satışlarının oran bazlı KDV bildirimi</CardDescription>
            </CardHeader>
            <CardContent>
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground">
                    <th className="py-2.5 pr-4">Oran</th>
                    <th className="py-2.5 pr-4 text-right">Teslim ve Hizmet Tutarı (Matrah)</th>
                    <th className="py-2.5 text-right">Hesaplanan KDV Tutarı</th>
                  </tr>
                </thead>
                <tbody>
                  <tr className="border-b border-border/60">
                    <td className="py-2.5 pr-4 font-semibold">%20 Standart Oran</td>
                    <td className="py-2.5 pr-4 text-right font-mono">{formatMoney(kdv1Summary.matrah20)}</td>
                    <td className="py-2.5 text-right font-mono font-bold text-primary">{formatMoney(kdv1Summary.kdv20)}</td>
                  </tr>
                  <tr className="border-b border-border/60">
                    <td className="py-2.5 pr-4 font-semibold">%10 İndirimli Oran</td>
                    <td className="py-2.5 pr-4 text-right font-mono">{formatMoney(kdv1Summary.matrah10)}</td>
                    <td className="py-2.5 text-right font-mono font-bold text-primary">{formatMoney(kdv1Summary.kdv10)}</td>
                  </tr>
                  <tr className="border-b border-border/60">
                    <td className="py-2.5 pr-4 font-semibold">%1 İndirimli Oran</td>
                    <td className="py-2.5 pr-4 text-right font-mono">{formatMoney(kdv1Summary.matrah1)}</td>
                    <td className="py-2.5 text-right font-mono font-bold text-primary">{formatMoney(kdv1Summary.kdv1)}</td>
                  </tr>
                  <tr className="border-b border-border/60">
                    <td className="py-2.5 pr-4 font-semibold">%0 İstisna Teslimler</td>
                    <td className="py-2.5 pr-4 text-right font-mono">{formatMoney(kdv1Summary.matrah0)}</td>
                    <td className="py-2.5 text-right font-mono">0,00 ₺</td>
                  </tr>
                </tbody>
              </table>
            </CardContent>
          </Card>
        </TabsContent>

        {/* 6. BANKA HESAPLARI & HAREKETLERİ */}
        <TabsContent value="bankalar" className="space-y-4">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <h3 className="text-base font-semibold">Tanımlı Banka Hesapları ({banks.length})</h3>
            <div className="flex gap-2">
              <Dialog open={bankOpen} onOpenChange={setBankOpen}>
                <DialogTrigger asChild>
                  <Button variant="outline" className="gap-1.5">
                    <Building2 className="size-4" /> Banka Hesabı Ekle
                  </Button>
                </DialogTrigger>
                <DialogContent>
                  <DialogHeader>
                    <DialogTitle>Yeni Banka Hesabı Tanımla</DialogTitle>
                  </DialogHeader>
                  <div className="space-y-3 pt-2">
                    <div className="space-y-1">
                      <Label>Banka</Label>
                      <Select
                        value={bankForm.bank_name}
                        onValueChange={(v) => setBankForm({ ...bankForm, bank_name: v })}
                      >
                        <SelectTrigger>
                          <SelectValue />
                        </SelectTrigger>
                        <SelectContent>
                          <SelectItem value="Kuveyt Türk Katılım Bankası">Kuveyt Türk Katılım Bankası</SelectItem>
                          <SelectItem value="Akbank T.A.Ş.">Akbank T.A.Ş.</SelectItem>
                          <SelectItem value="Türkiye İş Bankası">Türkiye İş Bankası</SelectItem>
                          <SelectItem value="Garanti BBVA">Garanti BBVA</SelectItem>
                          <SelectItem value="Yapı Kredi Bankası">Yapı Kredi Bankası</SelectItem>
                          <SelectItem value="Ziraat Bankası">Ziraat Bankası</SelectItem>
                          <SelectItem value="QNB Finansbank">QNB Finansbank</SelectItem>
                          <SelectItem value="Vakıfbank">Vakıfbank</SelectItem>
                          <SelectItem value="Halkbank">Halkbank</SelectItem>
                        </SelectContent>
                      </Select>
                    </div>
                    <div className="space-y-1">
                      <Label>Hesap Adı</Label>
                      <Input
                        placeholder="Örn: TL Vadesiz Ticari Hesap"
                        value={bankForm.account_name}
                        onChange={(e) => setBankForm({ ...bankForm, account_name: e.target.value })}
                      />
                    </div>
                    <div className="space-y-1">
                      <Label>IBAN</Label>
                      <Input
                        placeholder="TR00 0000 0000 0000 0000 0000 00"
                        value={bankForm.iban}
                        onChange={(e) => setBankForm({ ...bankForm, iban: e.target.value })}
                      />
                    </div>
                    <div className="space-y-1">
                      <Label>Açılış Bakiyesi (₺)</Label>
                      <Input
                        type="number"
                        placeholder="0.00"
                        value={bankForm.balance}
                        onChange={(e) => setBankForm({ ...bankForm, balance: e.target.value })}
                      />
                    </div>
                    <Button className="w-full mt-2" onClick={handleAddBank}>
                      Banka Hesabını Kaydet
                    </Button>
                  </div>
                </DialogContent>
              </Dialog>

              <Dialog open={movementOpen} onOpenChange={setMovementOpen}>
                <DialogTrigger asChild>
                  <Button className="gap-1.5">
                    <Plus className="size-4" /> Banka Hareketi İşle
                  </Button>
                </DialogTrigger>
                <DialogContent>
                  <DialogHeader>
                    <DialogTitle>Banka Hareketi (Havale / EFT / Bloke Çözümü / Masraf)</DialogTitle>
                  </DialogHeader>
                  <div className="space-y-3 pt-2">
                    <div className="space-y-1">
                      <Label>Banka Hesabı</Label>
                      <Select
                        value={movementForm.bank_id}
                        onValueChange={(v) => setMovementForm({ ...movementForm, bank_id: v })}
                      >
                        <SelectTrigger>
                          <SelectValue placeholder="Banka seçin" />
                        </SelectTrigger>
                        <SelectContent>
                          {banks.map((b) => (
                            <SelectItem key={b.id} value={b.id}>
                              {b.bank_name} - {b.account_name}
                            </SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                    </div>
                    <div className="space-y-1">
                      <Label>İşlem Türü</Label>
                      <Select
                        value={movementForm.movement_type}
                        onValueChange={(v) =>
                          setMovementForm({
                            ...movementForm,
                            movement_type: v as BankMovement["movement_type"],
                          })
                        }
                      >
                        <SelectTrigger>
                          <SelectValue />
                        </SelectTrigger>
                        <SelectContent>
                          <SelectItem value="HAVALE">Giden Havale (Para Çıkışı)</SelectItem>
                          <SelectItem value="GELEN_HAVALE">Gelen Havale (Para Girişi)</SelectItem>
                          <SelectItem value="EFT">Giden EFT (Para Çıkışı)</SelectItem>
                          <SelectItem value="BLOKE_COZUMU">POS Bloke Çözümü (Para Girişi)</SelectItem>
                          <SelectItem value="MASRAF">Banka Masrafı / Komisyon (Para Çıkışı)</SelectItem>
                        </SelectContent>
                      </Select>
                    </div>
                    <div className="grid grid-cols-2 gap-3">
                      <div className="space-y-1">
                        <Label>Tarih</Label>
                        <Input
                          type="date"
                          value={movementForm.date}
                          onChange={(e) => setMovementForm({ ...movementForm, date: e.target.value })}
                        />
                      </div>
                      <div className="space-y-1">
                        <Label>Tutar (₺)</Label>
                        <Input
                          placeholder="0.00"
                          value={movementForm.amount}
                          onChange={(e) => setMovementForm({ ...movementForm, amount: e.target.value })}
                        />
                      </div>
                    </div>
                    <div className="space-y-1">
                      <Label>Açıklama</Label>
                      <Input
                        placeholder="İşlem açıklaması"
                        value={movementForm.description}
                        onChange={(e) => setMovementForm({ ...movementForm, description: e.target.value })}
                      />
                    </div>
                    <Button className="w-full mt-2" onClick={handleAddBankMovement}>
                      Hareketi Kaydet
                    </Button>
                  </div>
                </DialogContent>
              </Dialog>
            </div>
          </div>

          {/* BANKA KARTLARI */}
          {banks.length === 0 ? (
            <Card className="border-dashed p-8 text-center text-muted-foreground">
              <Building2 className="mx-auto size-8 text-muted-foreground/60 mb-2" />
              <p className="text-sm font-medium">Tanımlı Banka Hesabı Bulunmuyor</p>
              <p className="text-xs text-muted-foreground mt-1">
                Kuveyt Türk, Akbank, Garanti vb. ticari banka hesaplarınızı "Yeni Banka Hesabı Ekle" butonuyla tanımlayabilirsiniz.
              </p>
            </Card>
          ) : (
            <div className="grid gap-4 sm:grid-cols-3">
              {banks.map((b) => (
                <Card key={b.id} className="border-l-4 border-l-primary">
                  <CardHeader className="pb-2">
                    <div className="flex items-center justify-between">
                      <CardTitle className="text-sm font-semibold">{b.bank_name}</CardTitle>
                      <Building2 className="size-4 text-primary" />
                    </div>
                    <CardDescription className="text-xs">{b.account_name}</CardDescription>
                  </CardHeader>
                  <CardContent className="space-y-2">
                    <div className="font-mono text-xs text-muted-foreground">{b.iban}</div>
                    <div className="pt-2 border-t border-border flex justify-between items-baseline">
                      <span className="text-xs text-muted-foreground">Kullanılabilir Bakiye:</span>
                      <span className="text-lg font-bold text-primary font-mono">{formatMoney(b.balance, b.currency)}</span>
                    </div>
                  </CardContent>
                </Card>
              ))}
            </div>
          )}

          {/* BANKA HAREKETLERİ LİSTESİ */}
          <Card>
            <CardHeader className="py-4">
              <CardTitle className="text-base">Banka Hesap Hareketleri & Ekstre</CardTitle>
              <CardDescription>Havale, EFT, POS bloke çözümleri ve masraf kayıtları</CardDescription>
            </CardHeader>
            <CardContent>
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground">
                      <th className="py-2.5 pr-4">Tarih</th>
                      <th className="py-2.5 pr-4">Banka Hesabı</th>
                      <th className="py-2.5 pr-4">İşlem Türü</th>
                      <th className="py-2.5 pr-4">Açıklama</th>
                      <th className="py-2.5 text-right">Tutar</th>
                    </tr>
                  </thead>
                  <tbody>
                    {bankMovements.length === 0 ? (
                      <tr>
                        <td colSpan={5} className="py-8 text-center text-muted-foreground text-xs">
                          Henüz banka hareketi (havale, EFT, masraf) kaydı bulunmuyor.
                        </td>
                      </tr>
                    ) : (
                      bankMovements.map((bm) => {
                        const bank = banks.find((b) => b.id === bm.bank_id);
                        return (
                          <tr key={bm.id} className="border-b border-border/60 hover:bg-muted/30 last:border-0">
                            <td className="py-3 pr-4 whitespace-nowrap">{formatDate(bm.date)}</td>
                            <td className="py-3 pr-4 font-medium">{bank ? `${bank.bank_name}` : "Banka"}</td>
                            <td className="py-3 pr-4">
                              <Badge
                                variant={
                                  bm.movement_type === "BLOKE_COZUMU" || bm.movement_type === "GELEN_HAVALE"
                                    ? "default"
                                    : bm.movement_type === "MASRAF"
                                      ? "destructive"
                                      : "secondary"
                                }
                              >
                                {bm.movement_type === "BLOKE_COZUMU"
                                  ? "POS Bloke Çözümü"
                                  : bm.movement_type === "GELEN_HAVALE"
                                    ? "Gelen Havale"
                                    : bm.movement_type === "HAVALE"
                                      ? "Giden Havale"
                                      : bm.movement_type === "EFT"
                                        ? "Giden EFT"
                                        : "Banka Masrafı"}
                              </Badge>
                            </td>
                            <td className="py-3 pr-4 text-xs text-muted-foreground">{bm.description}</td>
                            <td className={`py-3 text-right font-mono font-bold ${bm.direction === "IN" ? "text-emerald-600" : "text-destructive"}`}>
                              {bm.direction === "IN" ? "+" : "-"} {formatMoney(bm.amount)}
                            </td>
                          </tr>
                        );
                      })
                    )}
                  </tbody>
                </table>
              </div>
            </CardContent>
          </Card>
        </TabsContent>
      </Tabs>
    </AppShell>
  );
}
