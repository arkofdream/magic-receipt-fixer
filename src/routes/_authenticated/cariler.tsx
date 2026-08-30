import { createFileRoute, ErrorComponent } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import { Download, Clock, AlertTriangle, Calendar, ShieldAlert, Search, TrendingUp, TrendingDown, CheckCircle2 } from "lucide-react";
import { toast } from "sonner";

import { AppShell } from "@/components/AppShell";
import { AddressSelect } from "@/components/AddressSelect";
import { ExcelImportDialog } from "@/components/ExcelImportDialog";
import { CariDetailDialog } from "@/components/CariDetailDialog";
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
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { supabase } from "@/integrations/supabase/client";
import { isMissingColumnError, safeSoftDelete } from "@/lib/safe-supabase";
import { downloadWorkbook, parseNumber, pickColumn, type SheetRow } from "@/lib/excel";
import { emptyCustomer, formatMoney, type InvoiceCustomer } from "@/lib/invoice";
import { PARTNER_LABELS, type PartnerType } from "@/lib/cari";

export const Route = createFileRoute("/_authenticated/cariler")({
  errorComponent: ({ error, reset }: any) => {
    return (
      <AppShell title="Cari Hesaplar & Vade Takip" subtitle="Müşteri ve tedarikçi cari hesapları">
        <div className="p-8 text-center bg-card rounded-lg border border-border/60 max-w-lg mx-auto my-12 space-y-4 shadow-sm">
          <AlertTriangle className="size-10 text-amber-500 mx-auto" />
          <h2 className="text-lg font-bold text-foreground">Sayfa Yüklenirken Bir Sorun Oluştu</h2>
          <p className="text-xs text-muted-foreground">{error?.message || "Veriler alınırken beklenmeyen bir hata oluştu."}</p>
          <div className="flex justify-center gap-3 pt-2">
            <Button onClick={() => (reset ? reset() : window.location.reload())} size="sm">
              Yeniden Dene
            </Button>
            <Button onClick={() => (window.location.href = "/dashboard")} variant="outline" size="sm">
              Panele Dön
            </Button>
          </div>
        </div>
      </AppShell>
    );
  },
  head: () => ({
    meta: [
      { title: "Cari Hesaplar | e-Fatura Portalı" },
      {
        name: "description",
        content:
          "Müşteri ve tedarikçi cari hesaplarınızı bakiye, borç, alacak ve ekstre takibiyle yönetin.",
      },
      { property: "og:title", content: "Cari Hesaplar | e-Fatura Portalı" },
      {
        property: "og:description",
        content: "Müşteri ve tedarikçi cari hesaplarınızı tek yerden yönetin.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: CustomersPage,
});

const IMPORT_COLUMNS = [
  { header: "VKN/TCKN", aliases: ["vkn", "tckn", "vergino"], example: "1234567890" },
  { header: "Unvan", aliases: ["unvanadsoyad", "adsoyad", "musteri"], example: "Örnek Ltd. Şti." },
  { header: "Cari Kod", example: "M-001" },
  { header: "Yetkili", example: "Ayşe Yılmaz" },
  { header: "Vergi Dairesi", example: "Kadıköy" },
  { header: "Adres", example: "Örnek Cad. No:1" },
  { header: "İl", example: "İstanbul" },
  { header: "İlçe", example: "Kadıköy" },
  { header: "Mahalle", example: "Caferağa" },
  { header: "E-posta", aliases: ["eposta", "mail"], example: "info@ornek.com" },
  { header: "Telefon", example: "05001234567" },
  { header: "Grup", example: "Bayi" },
  { header: "Vade (Gün)", example: "30" },
  { header: "Risk Limiti", example: "50000" },
  { header: "Açılış Bakiyesi", example: "0" },
];

type ExtraFields = {
  code: string;
  contactName: string;
  partnerGroup: string;
  paymentTermDays: number;
  riskLimit: number;
  openingBalance: number;
  note: string;
};

type FormState = InvoiceCustomer & ExtraFields;

const emptyExtras: ExtraFields = {
  code: "",
  contactName: "",
  partnerGroup: "",
  paymentTermDays: 0,
  riskLimit: 0,
  openingBalance: 0,
  note: "",
};

type ImportedCustomer = FormState;

function CustomersPage() {
  const queryClient = useQueryClient();
  const [open, setOpen] = useState(false);
  const [tab, setTab] = useState<PartnerType>("MUSTERI");
  const [search, setSearch] = useState("");
  const [detailId, setDetailId] = useState<string | null>(null);
  const [form, setForm] = useState<FormState>({ ...emptyCustomer, ...emptyExtras });

  // Tedarikçi Ödeme Modalı Durumları
  const [paymentOpen, setPaymentOpen] = useState(false);
  const [paymentSupplier, setPaymentSupplier] = useState<any>(null);
  const [paymentAmount, setPaymentAmount] = useState("");
  const [paymentDate, setPaymentDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [paymentMethod, setPaymentMethod] = useState("BANKA");
  const [paymentDocNo, setPaymentDocNo] = useState("");
  const [paymentDesc, setPaymentDesc] = useState("");

  // FAZ 4.2 — Müşteri Tahsilat Modalı Durumları
  const [collectionOpen, setCollectionOpen] = useState(false);
  const [collectionCustomer, setCollectionCustomer] = useState<any>(null);
  const [collectionAmount, setCollectionAmount] = useState("");
  const [collectionDate, setCollectionDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [collectionMethod, setCollectionMethod] = useState("BANKA");
  const [collectionDocNo, setCollectionDocNo] = useState("");
  const [collectionDesc, setCollectionDesc] = useState("");

  // FAZ 4.2 — Cari Kart Düzenleme (Güncelle) Modalı Durumları
  const [editOpen, setEditOpen] = useState(false);
  const [editCustomer, setEditCustomer] = useState<any>(null);
  const [editForm, setEditForm] = useState<FormState>({ ...emptyCustomer, ...emptyExtras });

  function handleOpenEditModal(c: any) {
    setEditCustomer(c);
    setEditForm({
      vknTckn: c.vkn_tckn || "",
      title: c.title || "",
      taxOffice: c.tax_office || "",
      address: c.address || "",
      city: c.city || "",
      district: c.district || "",
      neighborhood: c.neighborhood || "",
      email: c.email || "",
      phone: c.phone || "",
      customPrefix: c.custom_prefix || "",
      code: c.code || "",
      contactName: c.contact_name || "",
      partnerGroup: c.partner_group || "",
      paymentTermDays: Number(c.payment_term_days ?? 0),
      riskLimit: Number(c.risk_limit ?? 0),
      openingBalance: Number(c.opening_balance ?? 0),
      note: c.note || "",
    });
    setEditOpen(true);
  }

  const { data: customers = [], isLoading } = useQuery({
    queryKey: ["customers"],
    queryFn: async () => {
      try {
        const { data, error } = await supabase
          .from("customers")
          .select("*")
          .is("deleted_at", null)
          .order("created_at", { ascending: false });
        if (error && isMissingColumnError(error)) {
          const fallback = await supabase
            .from("customers")
            .select("*")
            .order("created_at", { ascending: false });
          return fallback.data ?? [];
        }
        if (error) {
          console.warn("[CUSTOMERS FETCH ERROR]", error);
          return [];
        }
        return data ?? [];
      } catch (err) {
        console.warn("[CUSTOMERS CATCH ERROR]", err);
        return [];
      }
    },
  });

  const { data: balances = [] } = useQuery({
    queryKey: ["customer-balances"],
    queryFn: async () => {
      try {
        const { data, error } = await supabase.from("customer_balances").select("*");
        if (error) {
          console.warn("[BALANCES FETCH ERROR]", error);
          return [];
        }
        return data ?? [];
      } catch (err) {
        console.warn("[BALANCES CATCH ERROR]", err);
        return [];
      }
    },
  });

  const balanceMap = useMemo(() => {
    const map = new Map<string, { debit: number; credit: number; balance: number }>();
    for (const b of balances) {
      if (!b.customer_id) continue;
      map.set(b.customer_id, {
        debit: Number(b.total_debit ?? 0),
        credit: Number(b.total_credit ?? 0),
        balance: Number(b.balance ?? 0),
      });
    }
    return map;
  }, [balances]);

  const visible = useMemo(() => {
    const q = search.trim().toLocaleLowerCase("tr");
    return customers
      .filter((c) => (c.partner_type ?? "MUSTERI") === tab)
      .filter((c) =>
        q
          ? [c.title, c.vkn_tckn, c.code, c.phone, c.email]
              .filter(Boolean)
              .some((v) => String(v).toLocaleLowerCase("tr").includes(q))
          : true,
      );
  }, [customers, tab, search]);

  // FAZ 3.3 — CARİ YAŞLANDIRMA & VADE TAKİP DURUM STATE'LERİ
  const [mainTab, setMainTab] = useState<"list" | "aging">("list");
  const [agingFilter, setAgingFilter] = useState("ALL");
  const [agingSearch, setAgingSearch] = useState("");

  // Yaşlandırma Analizi İçin Aktif Cari Hareketler Sorgusu
  const { data: allTransactions = [], isLoading: txnsLoading } = useQuery({
    queryKey: ["all-account-transactions-aging"],
    queryFn: async () => {
      try {
        const { data, error } = await supabase
          .from("account_transactions")
          .select("*")
          .is("deleted_at", null)
          .order("txn_date", { ascending: true });
        if (error && isMissingColumnError(error)) {
          const fallback = await supabase
            .from("account_transactions")
            .select("*")
            .order("txn_date", { ascending: true });
          return fallback.data ?? [];
        }
        if (error) {
          console.warn("[AGING TXNS FETCH WARN]", error);
          return [];
        }
        return data ?? [];
      } catch (err) {
        console.warn("[AGING TXNS CATCH WARN]", err);
        return [];
      }
    },
  });

  const summary = useMemo(() => {
    let receivable = 0;
    let payable = 0;
    for (const c of customers) {
      const b = balanceMap.get(c.id)?.balance ?? 0;
      if (b > 0) receivable += b;
      else payable += Math.abs(b);
    }
    return { receivable, payable };
  }, [customers, balanceMap]);

  // FAZ 3.3 — CARİ YAŞLANDIRMA HESAPLAMA MOTORU (%100 BAKİYE MUTABAKATI İLE)
  const agingAnalysis = useMemo(() => {
    const todayStr = new Date().toISOString().slice(0, 10);
    const todayTime = new Date(todayStr).getTime();

    // 1. Cari Bazlı Yaşlandırma Kırılımı
    const customerAgingList: {
      customer: any;
      balance: number;
      openingBalance: number;
      totalDebit: number;
      totalCredit: number;
      notDue: number;
      b0_30: number;
      b31_60: number;
      b61_90: number;
      b91_180: number;
      b181_365: number;
      b365Plus: number;
      noDueDate: number;
      totalOverdue: number;
      isRiskExceeded: boolean;
    }[] = [];

    let grandNotDue = 0;
    let grand0_30 = 0;
    let grand31_60 = 0;
    let grand61_90 = 0;
    let grand91_180 = 0;
    let grand181_365 = 0;
    let grand365Plus = 0;
    let grandNoDueDate = 0;
    let grandTotalOverdue = 0;
    let riskExceededCount = 0;

    for (const c of customers) {
      const cBalances = balanceMap.get(c.id);
      const balance = cBalances?.balance ?? 0;
      const openingBalance = Number(c.opening_balance ?? 0);
      const totalDebit = cBalances?.debit ?? openingBalance;
      const totalCredit = cBalances?.credit ?? 0;

      // Cari hareketlerini filtrele
      const cTxns = allTransactions.filter((t: any) => t.customer_id === c.id);

      let notDue = 0;
      let b0_30 = 0;
      let b31_60 = 0;
      let b61_90 = 0;
      let b91_180 = 0;
      let b181_365 = 0;
      let b365Plus = 0;
      let noDueDate = 0;

      // Eğer carinin net alacağı varsa (borçlu cari), açık borç hareketlerini vadesine göre dağıt
      if (balance > 0) {
        // Borçlandıran hareketler (BORC / ODEME)
        const debitItems = cTxns.filter((t: any) => t.txn_type === "BORC" || t.txn_type === "ODEME");

        for (const item of debitItems) {
          const amt = Number(item.amount ?? 0);
          if (amt <= 0) continue;

          if (!item.due_date) {
            noDueDate += amt;
          } else {
            const itemTime = new Date(item.due_date).getTime();
            const diffDays = Math.floor((todayTime - itemTime) / (1000 * 60 * 60 * 24));

            if (diffDays <= 0) {
              notDue += amt;
            } else if (diffDays <= 30) {
              b0_30 += amt;
            } else if (diffDays <= 60) {
              b31_60 += amt;
            } else if (diffDays <= 90) {
              b61_90 += amt;
            } else if (diffDays <= 180) {
              b91_180 += amt;
            } else if (diffDays <= 365) {
              b181_365 += amt;
            } else {
              b365Plus += amt;
            }
          }
        }

        // Açılış bakiyesi varsa ve due_date yoksa noDueDate'e ekle
        if (openingBalance > 0 && debitItems.length === 0) {
          noDueDate += openingBalance;
        }
      }

      const totalOverdue = b0_30 + b31_60 + b61_90 + b91_180 + b181_365 + b365Plus;
      const isRiskExceeded = Number(c.risk_limit ?? 0) > 0 && balance > Number(c.risk_limit);
      if (isRiskExceeded) riskExceededCount++;

      grandNotDue += notDue;
      grand0_30 += b0_30;
      grand31_60 += b31_60;
      grand61_90 += b61_90;
      grand91_180 += b91_180;
      grand181_365 += b181_365;
      grand365Plus += b365Plus;
      grandNoDueDate += noDueDate;
      grandTotalOverdue += totalOverdue;

      customerAgingList.push({
        customer: c,
        balance,
        openingBalance,
        totalDebit,
        totalCredit,
        notDue,
        b0_30,
        b31_60,
        b61_90,
        b91_180,
        b181_365,
        b365Plus,
        noDueDate,
        totalOverdue,
        isRiskExceeded,
      });
    }

    return {
      customerAgingList,
      grandNotDue,
      grand0_30,
      grand31_60,
      grand61_90,
      grand91_180,
      grand181_365,
      grand365Plus,
      grandNoDueDate,
      grandTotalOverdue,
      riskExceededCount,
    };
  }, [customers, balanceMap, allTransactions]);

  // Filtrelenmiş Yaşlandırma Listesi
  const filteredAgingList = useMemo(() => {
    const q = agingSearch.trim().toLocaleLowerCase("tr");
    return agingAnalysis.customerAgingList.filter((item) => {
      const c = item.customer;

      // Arama
      if (q) {
        const match = [c.title, c.vkn_tckn, c.code, c.phone, c.email]
          .filter(Boolean)
          .some((v) => String(v).toLocaleLowerCase("tr").includes(q));
        if (!match) return false;
      }

      // Filtreler
      if (agingFilter === "MUSTERI" && c.partner_type !== "MUSTERI") return false;
      if (agingFilter === "TEDARIKCI" && c.partner_type !== "TEDARIKCI") return false;
      if (agingFilter === "DEBITORS" && item.balance <= 0) return false; // Sadece Alacaklı Olduklarımız
      if (agingFilter === "CREDITORS" && item.balance >= 0) return false; // Sadece Borçlu Olduklarımız
      if (agingFilter === "OVERDUE" && item.totalOverdue <= 0) return false; // Sadece Gecikmiş Alacağı Olanlar
      if (agingFilter === "RISK_EXCEEDED" && !item.isRiskExceeded) return false; // Sadece Risk Limiti Aşanlar

      return true;
    });
  }, [agingAnalysis, agingSearch, agingFilter]);

  function exportAgingReport() {
    downloadWorkbook(
      [
        "Cari Ünvanı",
        "Cari Kodu",
        "VKN / TCKN",
        "Tür",
        "Net Bakiye (TL)",
        "Risk Limiti (TL)",
        "Risk Durumu",
        "Vadesi Gelmemiş (TL)",
        "0-30 Gün Gecikmiş (TL)",
        "31-60 Gün Gecikmiş (TL)",
        "61-90 Gün Gecikmiş (TL)",
        "91-180 Gün Gecikmiş (TL)",
        "181-365 Gün Gecikmiş (TL)",
        "365+ Gün Gecikmiş (TL)",
        "Vade Tarihi Yok (TL)",
      ],
      filteredAgingList.map((row) => [
        row.customer.title,
        row.customer.code ?? "",
        row.customer.vkn_tckn ?? "",
        row.customer.partner_type === "MUSTERI" ? "Müşteri" : "Tedarikçi",
        row.balance,
        Number(row.customer.risk_limit ?? 0),
        row.isRiskExceeded ? "Risk Limiti Aşıldı" : "Limit Dahilinde",
        row.notDue,
        row.b0_30,
        row.b31_60,
        row.b61_90,
        row.b91_180,
        row.b181_365,
        row.b365Plus,
        row.noDueDate,
      ]),
      `cari-yaslandirma-ve-vade-takip-${new Date().toISOString().slice(0, 10)}.xlsx`,
      "Cari Yaşlandırma",
    );
  }

  async function currentUserId() {
    const { data: userData } = await supabase.auth.getUser();
    const userId = userData.user?.id;
    if (!userId) throw new Error("Oturum bulunamadı.");
    return userId;
  }

  function toRow(userId: string, values: FormState, partnerType: PartnerType) {
    return {
      user_id: userId,
      partner_type: partnerType,
      vkn_tckn: values.vknTckn,
      title: values.title,
      tax_office: values.taxOffice,
      address: values.address,
      city: values.city,
      district: values.district,
      neighborhood: values.neighborhood,
      email: values.email,
      phone: values.phone,
      code: values.code,
      contact_name: values.contactName,
      partner_group: values.partnerGroup,
      payment_term_days: Number(values.paymentTermDays) || 0,
      risk_limit: Number(values.riskLimit) || 0,
      opening_balance: Number(values.openingBalance) || 0,
      note: values.note,
    };
  }

  const createCustomer = useMutation({
    mutationFn: async (values: FormState) => {
      const userId = await currentUserId();
      const { error } = await supabase.from("customers").insert(toRow(userId, values, tab));
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success(`${PARTNER_LABELS[tab]} kaydedildi.`);
      setForm({ ...emptyCustomer, ...emptyExtras });
      setOpen(false);
      queryClient.invalidateQueries({ queryKey: ["customers"] });
      queryClient.invalidateQueries({ queryKey: ["customer-balances"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const removeCustomer = useMutation({
    mutationFn: async (id: string) => {
      const userId = await currentUserId();
      await safeSoftDelete("customers", id, userId);
    },
    onSuccess: () => {
      toast.success("Cari silindi.");
      queryClient.invalidateQueries({ queryKey: ["customers"] });
      queryClient.invalidateQueries({ queryKey: ["customer-balances"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const makeSupplierPayment = useMutation({
    mutationFn: async () => {
      if (!paymentSupplier) throw new Error("Tedarikçi seçilmedi.");
      const amount = Number(paymentAmount);
      if (!amount || amount <= 0) throw new Error("Geçerli bir ödeme tutarı giriniz.");

      const { data: _result, error } = await supabase.rpc("create_supplier_payment", {
        p_supplier_id: paymentSupplier.id,
        p_payment_date: paymentDate,
        p_amount: amount,
        p_payment_method: paymentMethod,
        p_document_no: paymentDocNo.trim(),
        p_description: paymentDesc.trim(),
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Tedarikçi ödemesi başarıyla işlendi ve muhasebe fişi (320 Borç / Kasa-Banka Alacak) kaydedildi.");
      setPaymentOpen(false);
      setPaymentSupplier(null);
      setPaymentAmount("");
      setPaymentDocNo("");
      setPaymentDesc("");
      queryClient.invalidateQueries({ queryKey: ["customers"] });
      queryClient.invalidateQueries({ queryKey: ["customer-balances"] });
      queryClient.invalidateQueries({ queryKey: ["account-transactions"] });
      queryClient.invalidateQueries({ queryKey: ["chart-of-accounts"] });
      queryClient.invalidateQueries({ queryKey: ["trial-balance"] });
      queryClient.invalidateQueries({ queryKey: ["reconciliation-summary"] });
      queryClient.invalidateQueries({ queryKey: ["accounting-audit"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  // FAZ 4.2 — MÜŞTERİ TAHSİLAT MUTASYONU
  const makeCustomerCollection = useMutation({
    mutationFn: async () => {
      if (!collectionCustomer) throw new Error("Müşteri seçilmedi.");
      const valStr = collectionAmount.replace(",", ".");
      const amt = Number(valStr);
      if (isNaN(amt) || amt <= 0) {
        throw new Error("Lütfen geçerli ve 0'dan büyük bir tahsilat tutarı girin.");
      }
      const { data, error } = await supabase.rpc("process_manual_account_transaction", {
        p_customer_id: collectionCustomer.id,
        p_txn_type: "TAHSILAT",
        p_amount: amt,
        p_txn_date: collectionDate,
        p_due_date: null,
        p_document_no: collectionDocNo.trim(),
        p_description: collectionDesc.trim() || `Müşteri Tahsilatı - ${collectionCustomer.title}`
      });
      if (error) throw error;
      if (data && !data.success) throw new Error(data.message || "Tahsilat islemi basarisiz.");
    },
    onSuccess: () => {
      toast.success("Tahsilat kaydı başarıyla oluşturuldu ve cari bakiyeden düşüldü.");
      setCollectionOpen(false);
      setCollectionCustomer(null);
      setCollectionAmount("");
      setCollectionDocNo("");
      setCollectionDesc("");
      queryClient.invalidateQueries({ queryKey: ["customers"] });
      queryClient.invalidateQueries({ queryKey: ["customer-balances"] });
      queryClient.invalidateQueries({ queryKey: ["all-account-transactions-aging"] });
      queryClient.invalidateQueries({ queryKey: ["account-transactions"] });
      queryClient.invalidateQueries({ queryKey: ["journal-entries-all"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  // FAZ 4.2 — CARİ KART GÜNCELLEME MUTASYONU
  const updateCustomer = useMutation({
    mutationFn: async () => {
      if (!editCustomer) return;
      if (!editForm.vknTckn.trim() || !editForm.title.trim()) {
        throw new Error("Unvan ve VKN/TCKN alanları zorunludur.");
      }
      const { error } = await supabase
        .from("customers")
        .update({
          title: editForm.title.trim(),
          vkn_tckn: editForm.vknTckn.trim(),
          code: editForm.code.trim() || null,
          tax_office: editForm.taxOffice.trim() || null,
          address: editForm.address.trim() || null,
          city: editForm.city.trim() || null,
          district: editForm.district.trim() || null,
          neighborhood: editForm.neighborhood.trim() || null,
          email: editForm.email.trim() || null,
          phone: editForm.phone.trim() || null,
          contact_name: editForm.contactName.trim() || null,
          partner_group: editForm.partnerGroup.trim() || null,
          payment_term_days: Number(editForm.paymentTermDays) || 0,
          risk_limit: Number(editForm.riskLimit) || 0,
          opening_balance: Number(editForm.openingBalance) || 0,
          note: editForm.note.trim() || null,
          updated_at: new Date().toISOString(),
        })
        .eq("id", editCustomer.id);
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Cari kart bilgileri başarıyla güncellendi.");
      setEditOpen(false);
      setEditCustomer(null);
      queryClient.invalidateQueries({ queryKey: ["customers"] });
      queryClient.invalidateQueries({ queryKey: ["customer-balances"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  async function importCustomers(rows: ImportedCustomer[]) {
    const userId = await currentUserId();
    const { error } = await supabase
      .from("customers")
      .insert(rows.map((r) => toRow(userId, r, tab)));
    if (error) throw error;
    toast.success(`${rows.length} cari içe aktarıldı.`);
    queryClient.invalidateQueries({ queryKey: ["customers"] });
    queryClient.invalidateQueries({ queryKey: ["customer-balances"] });
  }

  function exportCustomers() {
    downloadWorkbook(
      [...IMPORT_COLUMNS.map((c) => c.header), "Bakiye"],
      visible.map((c) => [
        c.vkn_tckn,
        c.title,
        c.code ?? "",
        c.contact_name ?? "",
        c.tax_office,
        c.address,
        c.city,
        c.district,
        c.neighborhood ?? "",
        c.email,
        c.phone,
        c.partner_group ?? "",
        Number(c.payment_term_days ?? 0),
        Number(c.risk_limit ?? 0),
        Number(c.opening_balance ?? 0),
        balanceMap.get(c.id)?.balance ?? 0,
      ]),
      `cariler-${new Date().toISOString().slice(0, 10)}.xlsx`,
      "Cariler",
    );
  }

  const textFields: { key: keyof FormState; label: string; required?: boolean; type?: string }[] = [
    { key: "code", label: "Cari Kod" },
    { key: "vknTckn", label: "VKN / TCKN", required: true },
    { key: "title", label: "Firma / Unvan", required: true },
    { key: "contactName", label: "Ad Soyad (Yetkili)" },
    { key: "taxOffice", label: "Vergi Dairesi" },
    { key: "email", label: "E-posta" },
    { key: "phone", label: "Telefon" },
    { key: "partnerGroup", label: `${PARTNER_LABELS[tab]} Grubu` },
    { key: "paymentTermDays", label: "Vade (Gün)", type: "number" },
    { key: "riskLimit", label: "Risk Limiti", type: "number" },
    { key: "openingBalance", label: "Açılış Bakiyesi (Borç +)", type: "number" },
  ];

  const detailCustomer = customers.find((c) => c.id === detailId) ?? null;

  return (
    <AppShell
      title="Cari Hesaplar"
      subtitle="Müşteri ve tedarikçi kartları, bakiye ve ekstre takibi"
      actions={
        <>
          <Button
            variant="ghost"
            className="gap-2"
            onClick={exportCustomers}
            disabled={visible.length === 0}
          >
            <Download className="size-4" />
            Excel'e Aktar
          </Button>
          <ExcelImportDialog<ImportedCustomer>
            title="Excel'den Cari İçe Aktar"
            templateName="cari-sablonu.xlsx"
            columns={IMPORT_COLUMNS}
            mapRow={(row: SheetRow) => {
              const vknTckn = pickColumn(row, ["VKN/TCKN", "VKN", "TCKN", "Vergi No", "TC"]).trim();
              const title = pickColumn(row, [
                "Unvan",
                "Unvan / Ad Soyad",
                "Ad Soyad",
                "Müşteri",
                "Firma",
              ]).trim();
              if (!vknTckn && !title) return null;
              if (!title) return { error: "Unvan / Firma Adı alanı boş olamaz." };
              if (!vknTckn) return { error: "VKN / TCKN alanı boş olamaz." };
              return {
                data: {
                  vknTckn,
                  title,
                  taxOffice: pickColumn(row, ["Vergi Dairesi"]),
                  address: pickColumn(row, ["Adres"]),
                  city: pickColumn(row, ["İl", "Şehir"]),
                  district: pickColumn(row, ["İlçe"]),
                  neighborhood: pickColumn(row, ["Mahalle", "Mahalle / Köy"]),
                  email: pickColumn(row, ["E-posta", "Email", "Mail"]),
                  phone: pickColumn(row, ["Telefon", "Tel", "GSM"]),
                  code: pickColumn(row, ["Cari Kod", "Kod"]),
                  contactName: pickColumn(row, ["Yetkili", "Ad Soyad"]),
                  partnerGroup: pickColumn(row, ["Grup", "Müşteri Grubu", "Tedarikçi Grubu"]),
                  paymentTermDays: parseNumber(pickColumn(row, ["Vade (Gün)", "Vade"])),
                  riskLimit: parseNumber(pickColumn(row, ["Risk Limiti", "Risk"])),
                  openingBalance: parseNumber(pickColumn(row, ["Açılış Bakiyesi", "Bakiye"])),
                  note: pickColumn(row, ["Açıklama", "Not"]),
                },
              };
            }}
            onImport={importCustomers}
          />
          <Dialog open={open} onOpenChange={setOpen}>
            <DialogTrigger asChild>
              <Button>Yeni {PARTNER_LABELS[tab]}</Button>
            </DialogTrigger>
            <DialogContent className="max-h-[85vh] overflow-y-auto max-w-2xl">
              <DialogHeader>
                <DialogTitle>Yeni {PARTNER_LABELS[tab]} Kartı</DialogTitle>
              </DialogHeader>
              <form
                className="space-y-4"
                onSubmit={(e) => {
                  e.preventDefault();
                  createCustomer.mutate(form);
                }}
              >
                {/* 1. Temel Firma Bilgileri */}
                <div className="rounded-lg border border-border p-3.5 space-y-3 bg-muted/20">
                  <div className="text-xs font-semibold text-primary uppercase tracking-wider">
                    Firma Bilgileri (Temel Bilgiler)
                  </div>
                  <div className="grid gap-3 sm:grid-cols-2">
                    <div className="space-y-1.5 sm:col-span-2">
                      <Label htmlFor="title">Firma / Ticari Unvan *</Label>
                      <Input
                        id="title"
                        required
                        placeholder="Örn: ABC İnşaat San. ve Tic. Ltd. Şti."
                        value={form.title}
                        onChange={(e) => setForm({ ...form, title: e.target.value })}
                      />
                    </div>
                    <div className="space-y-1.5">
                      <Label htmlFor="vknTckn">VKN / TCKN *</Label>
                      <Input
                        id="vknTckn"
                        required
                        placeholder="10 veya 11 haneli numara"
                        value={form.vknTckn}
                        onChange={(e) => setForm({ ...form, vknTckn: e.target.value })}
                      />
                    </div>
                    <div className="space-y-1.5">
                      <Label htmlFor="taxOffice">Vergi Dairesi</Label>
                      <Input
                        id="taxOffice"
                        placeholder="Örn: Kadıköy"
                        value={form.taxOffice}
                        onChange={(e) => setForm({ ...form, taxOffice: e.target.value })}
                      />
                    </div>
                    <div className="space-y-1.5">
                      <Label htmlFor="phone">Telefon</Label>
                      <Input
                        id="phone"
                        placeholder="0500 000 00 00"
                        value={form.phone}
                        onChange={(e) => setForm({ ...form, phone: e.target.value })}
                      />
                    </div>
                    <div className="space-y-1.5">
                      <Label htmlFor="email">E-posta</Label>
                      <Input
                        id="email"
                        type="email"
                        placeholder="info@firma.com"
                        value={form.email}
                        onChange={(e) => setForm({ ...form, email: e.target.value })}
                      />
                    </div>
                  </div>
                </div>

                {/* 2. Adres Bilgileri */}
                <div className="rounded-lg border border-border p-3.5 space-y-3">
                  <div className="text-xs font-semibold text-muted-foreground uppercase tracking-wider">
                    Adres Bilgileri (İl, İlçe, Açık Adres)
                  </div>
                  <div className="grid gap-3 sm:grid-cols-2">
                    <AddressSelect
                      value={{
                        city: form.city,
                        district: form.district,
                        neighborhood: form.neighborhood,
                      }}
                      onChange={(v) => setForm({ ...form, ...v })}
                    />
                    <div className="space-y-1.5 sm:col-span-2">
                      <Label htmlFor="address">Açık Adres (Cadde, Sokak, No)</Label>
                      <Input
                        id="address"
                        placeholder="Örn: Organize Sanayi Bölgesi 4. Cadde No:12"
                        value={form.address}
                        onChange={(e) => setForm({ ...form, address: e.target.value })}
                      />
                    </div>
                  </div>
                </div>

                {/* 3. İsteğe Bağlı Ek Bilgiler */}
                <div className="rounded-lg border border-border/70 p-3.5 space-y-3">
                  <div className="text-xs font-semibold text-muted-foreground uppercase tracking-wider">
                    Ticari & Bakiye Ayarları (Opsiyonel)
                  </div>
                  <div className="grid gap-3 sm:grid-cols-3">
                    <div className="space-y-1.5">
                      <Label htmlFor="code">Cari Kod</Label>
                      <Input
                        id="code"
                        placeholder="Örn: C-001"
                        value={form.code}
                        onChange={(e) => setForm({ ...form, code: e.target.value })}
                      />
                    </div>
                    <div className="space-y-1.5">
                      <Label htmlFor="partnerGroup">Grup</Label>
                      <Input
                        id="partnerGroup"
                        placeholder="Örn: Toptan, Bayi"
                        value={form.partnerGroup}
                        onChange={(e) => setForm({ ...form, partnerGroup: e.target.value })}
                      />
                    </div>
                    <div className="space-y-1.5">
                      <Label htmlFor="paymentTermDays">Vade (Gün)</Label>
                      <Input
                        id="paymentTermDays"
                        type="number"
                        min="0"
                        value={form.paymentTermDays}
                        onChange={(e) =>
                          setForm({ ...form, paymentTermDays: Number(e.target.value) || 0 })
                        }
                      />
                    </div>
                    <div className="space-y-1.5">
                      <Label htmlFor="riskLimit">Risk Limiti (₺)</Label>
                      <Input
                        id="riskLimit"
                        type="number"
                        min="0"
                        value={form.riskLimit}
                        onChange={(e) =>
                          setForm({ ...form, riskLimit: Number(e.target.value) || 0 })
                        }
                      />
                    </div>
                    <div className="space-y-1.5 sm:col-span-2">
                      <Label htmlFor="openingBalance">Açılış Bakiyesi (Borç + / Alacak -)</Label>
                      <Input
                        id="openingBalance"
                        type="number"
                        step="0.01"
                        value={form.openingBalance}
                        onChange={(e) =>
                          setForm({ ...form, openingBalance: Number(e.target.value) || 0 })
                        }
                      />
                    </div>
                    <div className="space-y-1.5 sm:col-span-3">
                      <Label htmlFor="note">Not / Açıklama</Label>
                      <Input
                        id="note"
                        placeholder="Müşteri/Tedarikçi hakkında özel not"
                        value={form.note}
                        onChange={(e) => setForm({ ...form, note: e.target.value })}
                      />
                    </div>
                  </div>
                </div>

                <div className="pt-2">
                  <Button type="submit" className="w-full" disabled={createCustomer.isPending}>
                    {createCustomer.isPending ? "Kaydediliyor…" : `${PARTNER_LABELS[tab]} Kaydet`}
                  </Button>
                </div>
              </form>
            </DialogContent>
          </Dialog>
        </>
      }
    >
      {/* FAZ 3.3 — ANA SEKME GEZİNTİSİ (CARİ KARTLAR & CARİ YAŞLANDIRMA) */}
      <div className="mb-4">
        <Tabs value={mainTab} onValueChange={(v) => setMainTab(v as any)}>
          <TabsList className="grid w-full grid-cols-2 max-w-md">
            <TabsTrigger value="list" className="gap-2">
              <CheckCircle2 className="size-4" /> Cari Kartlar & Bakiyeler
            </TabsTrigger>
            <TabsTrigger value="aging" className="gap-2">
              <Clock className="size-4 text-primary" /> Cari Yaşlandırma & Vade Takip
            </TabsTrigger>
          </TabsList>
        </Tabs>
      </div>

      {mainTab === "list" ? (
        <>
          <div className="mb-4 grid gap-3 sm:grid-cols-2">
            <Card>
              <CardContent className="pt-6">
                <p className="text-xs text-muted-foreground font-medium uppercase tracking-wider">Toplam Alacak (Müşterilerden)</p>
                <p className="text-2xl font-bold text-emerald-600 dark:text-emerald-400 mt-1">{formatMoney(summary.receivable)}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-6">
                <p className="text-xs text-muted-foreground font-medium uppercase tracking-wider">Toplam Borç (Tedarikçilere)</p>
                <p className="text-2xl font-bold text-destructive mt-1">{formatMoney(summary.payable)}</p>
              </CardContent>
            </Card>
          </div>

          <Card>
            <CardHeader className="gap-3">
              <div className="flex flex-wrap items-center justify-between gap-3">
                <CardTitle className="text-base">
                  {PARTNER_LABELS[tab]} Listesi ({visible.length})
                </CardTitle>
                <Input
                  placeholder="Ara: unvan, VKN, kod, telefon…"
                  className="w-full sm:w-72"
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                />
              </div>
              <Tabs value={tab} onValueChange={(v) => setTab(v as PartnerType)}>
                <TabsList>
                  <TabsTrigger value="MUSTERI">Müşteriler</TabsTrigger>
                  <TabsTrigger value="TEDARIKCI">Tedarikçiler</TabsTrigger>
                </TabsList>
              </Tabs>
            </CardHeader>
            <CardContent>
              {isLoading ? (
                <p className="text-sm text-muted-foreground">Yükleniyor…</p>
              ) : visible.length === 0 ? (
                <p className="text-sm text-muted-foreground">Bu listede kayıt yok.</p>
              ) : (
                <div className="overflow-x-auto max-w-full">
                  <table className="w-full min-w-[700px] text-sm">
                    <thead>
                      <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground">
                        <th className="py-2 pr-4">Kod / VKN</th>
                        <th className="py-2 pr-4">Unvan</th>
                        <th className="py-2 pr-4">İletişim</th>
                        <th className="py-2 pr-4">Vade</th>
                        <th className="py-2 pr-4 text-right">Borç</th>
                        <th className="py-2 pr-4 text-right">Alacak</th>
                        <th className="py-2 pr-4 text-right">Bakiye</th>
                        <th className="py-2" />
                      </tr>
                    </thead>
                    <tbody>
                      {visible.map((c) => {
                        const b = balanceMap.get(c.id) ?? { debit: 0, credit: 0, balance: 0 };
                        const overLimit =
                          Number(c.risk_limit ?? 0) > 0 && b.balance > Number(c.risk_limit);
                        return (
                          <tr key={c.id} className="border-b border-border/60 last:border-0">
                            <td className="py-3 pr-4">
                              <div className="font-medium">{c.code || "-"}</div>
                              <div className="text-xs text-muted-foreground">{c.vkn_tckn}</div>
                            </td>
                            <td className="py-3 pr-4">
                              <div className="font-medium">{c.title}</div>
                              {c.contact_name && (
                                <div className="text-xs text-muted-foreground">{c.contact_name}</div>
                              )}
                              {overLimit && (
                                <Badge variant="destructive" className="mt-1 text-[10px] py-0">
                                  Risk Limiti Aşıldı
                                </Badge>
                              )}
                            </td>
                            <td className="py-3 pr-4 text-xs text-muted-foreground">
                              {c.phone || c.email ? (
                                <>
                                  <div>{c.phone}</div>
                                  <div>{c.email}</div>
                                </>
                              ) : (
                                "-"
                              )}
                            </td>
                            <td className="py-3 pr-4 text-xs">
                              {Number(c.payment_term_days ?? 0) > 0
                                ? `${c.payment_term_days} gün`
                                : "Peşin"}
                            </td>
                            <td className="py-3 pr-4 text-right">{formatMoney(b.debit)}</td>
                            <td className="py-3 pr-4 text-right">{formatMoney(b.credit)}</td>
                            <td className="py-3 pr-4 text-right font-semibold">
                              <span
                                className={
                                  b.balance > 0
                                    ? "text-emerald-600 dark:text-emerald-400"
                                    : b.balance < 0
                                      ? "text-destructive"
                                      : ""
                                }
                              >
                                {formatMoney(b.balance)}
                              </span>
                            </td>
                            <td className="py-3 text-right whitespace-nowrap">
                              <div className="flex items-center justify-end gap-1.5">
                                <Button
                                  variant="outline"
                                  size="sm"
                                  className="h-7 text-xs"
                                  onClick={() => handleOpenEditModal(c)}
                                >
                                  Güncelle
                                </Button>
                                <Button
                                  variant="outline"
                                  size="sm"
                                  className="h-7 text-xs"
                                  onClick={() => setDetailId(c.id)}
                                >
                                  Ekstre
                                </Button>
                                {c.partner_type === "MUSTERI" ? (
                                  <Button
                                    variant="outline"
                                    size="sm"
                                    className="h-7 text-xs bg-emerald-500/10 text-emerald-600 border-emerald-500/30 hover:bg-emerald-500/20"
                                    onClick={() => {
                                      setCollectionCustomer(c);
                                      setCollectionAmount(b.balance > 0 ? String(b.balance) : "");
                                      setCollectionOpen(true);
                                    }}
                                  >
                                    Tahsilat
                                  </Button>
                                ) : (
                                  b.balance < 0 && (
                                    <Button
                                      variant="outline"
                                      size="sm"
                                      className="h-7 text-xs bg-amber-500/10 text-amber-600 border-amber-500/30 hover:bg-amber-500/20"
                                      onClick={() => {
                                        setPaymentSupplier(c);
                                        setPaymentAmount(String(Math.abs(b.balance)));
                                        setPaymentOpen(true);
                                      }}
                                    >
                                      Ödeme Yap
                                    </Button>
                                  )
                                )}
                              </div>
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
        </>
      ) : (
        /* FAZ 3.3 — CARİ YAŞLANDIRMA & VADE TAKİP EKRANI */
        <div className="space-y-4">
          {/* ÖZET KARTLARI */}
          <div className="grid gap-3 sm:grid-cols-2 md:grid-cols-5">
            <Card>
              <CardContent className="pt-4 pb-4">
                <p className="text-[11px] text-muted-foreground uppercase font-semibold tracking-wider">Müşteri Alacağı</p>
                <p className="text-xl font-bold text-emerald-600 dark:text-emerald-400 mt-1 font-mono">
                  {formatMoney(summary.receivable)}
                </p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-4 pb-4">
                <p className="text-[11px] text-muted-foreground uppercase font-semibold tracking-wider">Tedarikçi Borcu</p>
                <p className="text-xl font-bold text-rose-600 dark:text-rose-400 mt-1 font-mono">
                  {formatMoney(summary.payable)}
                </p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-4 pb-4">
                <p className="text-[11px] text-muted-foreground uppercase font-semibold tracking-wider">Vadesi Gelmemiş</p>
                <p className="text-xl font-bold text-blue-600 dark:text-blue-400 mt-1 font-mono">
                  {formatMoney(agingAnalysis.grandNotDue)}
                </p>
              </CardContent>
            </Card>
            <Card className="bg-amber-500/5 border-amber-500/30">
              <CardContent className="pt-4 pb-4">
                <p className="text-[11px] text-amber-700 dark:text-amber-400 uppercase font-semibold tracking-wider flex items-center gap-1">
                  <AlertTriangle className="size-3.5" /> Gecikmiş Alacak
                </p>
                <p className="text-xl font-bold text-amber-700 dark:text-amber-300 mt-1 font-mono">
                  {formatMoney(agingAnalysis.grandTotalOverdue)}
                </p>
              </CardContent>
            </Card>
            <Card className="bg-rose-500/5 border-rose-500/30">
              <CardContent className="pt-4 pb-4">
                <p className="text-[11px] text-rose-700 dark:text-rose-400 uppercase font-semibold tracking-wider flex items-center gap-1">
                  <ShieldAlert className="size-3.5" /> Risk Limiti Aşan
                </p>
                <p className="text-xl font-bold text-rose-700 dark:text-rose-300 mt-1 font-mono">
                  {agingAnalysis.riskExceededCount} Cari
                </p>
              </CardContent>
            </Card>
          </div>

          {/* GECİKME KOVALARI GENEL ÖZET TABLOSU */}
          <Card>
            <CardHeader className="py-3.5 border-b border-border/60">
              <CardTitle className="text-sm font-semibold flex items-center gap-2">
                <Clock className="size-4 text-primary" /> Sistem Geneli Vade & Gecikme Kovaları Dağılımı
              </CardTitle>
            </CardHeader>
            <CardContent className="pt-4">
              <div className="grid gap-2 sm:grid-cols-4 md:grid-cols-8 text-xs text-center">
                <div className="p-2.5 rounded-md bg-blue-500/10 border border-blue-500/20">
                  <div className="text-[10px] text-muted-foreground font-medium uppercase">Vadesi Gelmemiş</div>
                  <div className="font-bold font-mono text-blue-600 dark:text-blue-400 mt-1">
                    {formatMoney(agingAnalysis.grandNotDue)}
                  </div>
                </div>
                <div className="p-2.5 rounded-md bg-emerald-500/10 border border-emerald-500/20">
                  <div className="text-[10px] text-muted-foreground font-medium uppercase">0 - 30 Gün</div>
                  <div className="font-bold font-mono text-emerald-600 dark:text-emerald-400 mt-1">
                    {formatMoney(agingAnalysis.grand0_30)}
                  </div>
                </div>
                <div className="p-2.5 rounded-md bg-amber-500/10 border border-amber-500/20">
                  <div className="text-[10px] text-muted-foreground font-medium uppercase">31 - 60 Gün</div>
                  <div className="font-bold font-mono text-amber-600 dark:text-amber-400 mt-1">
                    {formatMoney(agingAnalysis.grand31_60)}
                  </div>
                </div>
                <div className="p-2.5 rounded-md bg-orange-500/10 border border-orange-500/20">
                  <div className="text-[10px] text-muted-foreground font-medium uppercase">61 - 90 Gün</div>
                  <div className="font-bold font-mono text-orange-600 dark:text-orange-400 mt-1">
                    {formatMoney(agingAnalysis.grand61_90)}
                  </div>
                </div>
                <div className="p-2.5 rounded-md bg-rose-500/10 border border-rose-500/20">
                  <div className="text-[10px] text-muted-foreground font-medium uppercase">91 - 180 Gün</div>
                  <div className="font-bold font-mono text-rose-600 dark:text-rose-400 mt-1">
                    {formatMoney(agingAnalysis.grand91_180)}
                  </div>
                </div>
                <div className="p-2.5 rounded-md bg-purple-500/10 border border-purple-500/20">
                  <div className="text-[10px] text-muted-foreground font-medium uppercase">181 - 365 Gün</div>
                  <div className="font-bold font-mono text-purple-600 dark:text-purple-400 mt-1">
                    {formatMoney(agingAnalysis.grand181_365)}
                  </div>
                </div>
                <div className="p-2.5 rounded-md bg-red-600/15 border border-red-600/30">
                  <div className="text-[10px] text-muted-foreground font-medium uppercase">365+ Gün</div>
                  <div className="font-bold font-mono text-red-600 dark:text-red-400 mt-1">
                    {formatMoney(agingAnalysis.grand365Plus)}
                  </div>
                </div>
                <div className="p-2.5 rounded-md bg-muted/60 border border-border/60">
                  <div className="text-[10px] text-muted-foreground font-medium uppercase">Vade Tarihi Yok</div>
                  <div className="font-bold font-mono text-foreground mt-1">
                    {formatMoney(agingAnalysis.grandNoDueDate)}
                  </div>
                </div>
              </div>
            </CardContent>
          </Card>

          {/* DETAYLI CARİ YAŞLANDIRMA TABLOSU */}
          <Card>
            <CardHeader className="space-y-3 pb-3">
              <div className="flex flex-wrap items-center justify-between gap-3">
                <CardTitle className="text-base flex items-center gap-2">
                  <span>Cari Bazlı Yaşlandırma & Risk Analizi</span>
                </CardTitle>
                <Button variant="outline" size="sm" onClick={exportAgingReport} className="gap-1.5 text-xs">
                  <Download className="size-3.5" /> Yaşlandırma Raporunu Excel'e Aktar
                </Button>
              </div>

              {/* FİLTRE VE ARAMA KONTROLLERİ */}
              <div className="pt-2 flex flex-wrap items-center justify-between gap-2 border-t border-border/40">
                <div className="flex flex-wrap items-center gap-2 flex-1 min-w-[280px]">
                  <div className="relative flex-1 min-w-[180px] sm:max-w-xs">
                    <Search className="absolute left-2.5 top-2.5 size-3.5 text-muted-foreground" />
                    <Input
                      placeholder="Cari ara: unvan, kod, VKN..."
                      value={agingSearch}
                      onChange={(e) => setAgingSearch(e.target.value)}
                      className="pl-8 h-8 text-xs bg-background"
                    />
                  </div>

                  <Select value={agingFilter} onValueChange={setAgingFilter}>
                    <SelectTrigger className="h-8 text-xs w-[180px] bg-background">
                      <SelectValue placeholder="Filtrele" />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="ALL">Tüm Cariler</SelectItem>
                      <SelectItem value="MUSTERI">Sadece Müşteriler</SelectItem>
                      <SelectItem value="TEDARIKCI">Sadece Tedarikçiler</SelectItem>
                      <SelectItem value="DEBITORS">Borçlu Cariler (Alacağımız Var)</SelectItem>
                      <SelectItem value="CREDITORS">Alacaklı Cariler (Borcumuz Var)</SelectItem>
                      <SelectItem value="OVERDUE">Gecikmiş Alacağı Olanlar</SelectItem>
                      <SelectItem value="RISK_EXCEEDED">Risk Limiti Aşanlar</SelectItem>
                    </SelectContent>
                  </Select>

                  {(agingSearch || agingFilter !== "ALL") && (
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => {
                        setAgingSearch("");
                        setAgingFilter("ALL");
                      }}
                      className="h-8 text-xs text-muted-foreground"
                    >
                      Temizle
                    </Button>
                  )}
                </div>

                <span className="text-xs text-muted-foreground font-mono shrink-0">
                  {filteredAgingList.length} / {customers.length} cari listeleniyor
                </span>
              </div>
            </CardHeader>
            <CardContent>
              {txnsLoading ? (
                <div className="py-12 text-center text-sm text-muted-foreground">Cari hareketler analiz ediliyor...</div>
              ) : filteredAgingList.length === 0 ? (
                <div className="py-12 text-center text-xs text-muted-foreground">Filtrelere uygun cari bulunamadı.</div>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full min-w-[750px] text-xs">
                    <thead>
                      <tr className="bg-muted/40 text-left font-semibold border-b border-border">
                        <th className="py-2.5 px-3">Cari Unvanı</th>
                        <th className="py-2.5 px-3">Tür</th>
                        <th className="py-2.5 px-3 text-right">Net Bakiye</th>
                        <th className="py-2.5 px-3 text-right">Vadesi Gelmemiş</th>
                        <th className="py-2.5 px-3 text-right">0-30 Gün</th>
                        <th className="py-2.5 px-3 text-right">31-60 Gün</th>
                        <th className="py-2.5 px-3 text-right">61-90 Gün</th>
                        <th className="py-2.5 px-3 text-right">91-180 Gün</th>
                        <th className="py-2.5 px-3 text-right">181-365 Gün</th>
                        <th className="py-2.5 px-3 text-right">365+ Gün</th>
                        <th className="py-2.5 px-3 text-right">Vade Yok</th>
                        <th className="py-2.5 px-3 text-center">İşlem</th>
                      </tr>
                    </thead>
                    <tbody>
                      {filteredAgingList.map((row) => {
                        const c = row.customer;
                        return (
                          <tr key={c.id} className="border-b border-border/50 hover:bg-muted/30 last:border-0 font-mono">
                            <td className="py-2.5 px-3 font-sans">
                              <div className="font-semibold text-foreground">{c.title}</div>
                              <div className="text-[10px] text-muted-foreground">
                                {c.code ? `[${c.code}] ` : ""}{c.vkn_tckn}
                              </div>
                              {row.isRiskExceeded && (
                                <Badge variant="destructive" className="mt-0.5 text-[9px] py-0 px-1">
                                  Risk Limiti Aşıldı (Max: {formatMoney(Number(c.risk_limit))} TL)
                                </Badge>
                              )}
                            </td>
                            <td className="py-2.5 px-3 font-sans">
                              <Badge variant={c.partner_type === "MUSTERI" ? "default" : "secondary"} className="text-[10px] py-0">
                                {c.partner_type === "MUSTERI" ? "Müşteri" : "Tedarikçi"}
                              </Badge>
                            </td>
                            <td className="py-2.5 px-3 text-right font-bold">
                              <span className={row.balance > 0 ? "text-emerald-600 dark:text-emerald-400" : row.balance < 0 ? "text-rose-600 dark:text-rose-400" : ""}>
                                {formatMoney(row.balance)}
                              </span>
                            </td>
                            <td className="py-2.5 px-3 text-right text-blue-600 dark:text-blue-400">
                              {row.notDue > 0 ? formatMoney(row.notDue) : "-"}
                            </td>
                            <td className="py-2.5 px-3 text-right text-emerald-600 dark:text-emerald-400">
                              {row.b0_30 > 0 ? formatMoney(row.b0_30) : "-"}
                            </td>
                            <td className="py-2.5 px-3 text-right text-amber-600 dark:text-amber-400">
                              {row.b31_60 > 0 ? formatMoney(row.b31_60) : "-"}
                            </td>
                            <td className="py-2.5 px-3 text-right text-orange-600 dark:text-orange-400">
                              {row.b61_90 > 0 ? formatMoney(row.b61_90) : "-"}
                            </td>
                            <td className="py-2.5 px-3 text-right text-rose-600 dark:text-rose-400 font-bold">
                              {row.b91_180 > 0 ? formatMoney(row.b91_180) : "-"}
                            </td>
                            <td className="py-2.5 px-3 text-right text-purple-600 dark:text-purple-400 font-bold">
                              {row.b181_365 > 0 ? formatMoney(row.b181_365) : "-"}
                            </td>
                            <td className="py-2.5 px-3 text-right text-red-600 dark:text-red-400 font-black">
                              {row.b365Plus > 0 ? formatMoney(row.b365Plus) : "-"}
                            </td>
                            <td className="py-2.5 px-3 text-right text-muted-foreground">
                              {row.noDueDate > 0 ? formatMoney(row.noDueDate) : "-"}
                            </td>
                            <td className="py-2.5 px-3 text-center font-sans">
                              <Button
                                variant="ghost"
                                size="sm"
                                className="h-6 text-[11px] px-2"
                                onClick={() => setDetailId(c.id)}
                              >
                                Ekstre
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
        </div>
      )}

      {/* TEDARİKÇİ ÖDEME DİALOGU */}
      <Dialog open={paymentOpen} onOpenChange={setPaymentOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Tedarikçiye Ödeme Yap (320 Borç Kapatma)</DialogTitle>
          </DialogHeader>
          {paymentSupplier && (
            <div className="space-y-3 pt-2 text-sm">
              <div className="rounded-md bg-muted/40 p-3 space-y-1">
                <div className="font-semibold text-foreground">{paymentSupplier.title}</div>
                <div className="text-xs text-muted-foreground">VKN/TCKN: {paymentSupplier.vkn_tckn || "-"}</div>
                <div className="text-xs font-mono text-primary pt-1">
                  Mevcut Bakiye: {formatMoney(balanceMap.get(paymentSupplier.id)?.balance ?? 0)}
                </div>
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div className="space-y-1">
                  <Label>Ödeme Tarihi *</Label>
                  <Input
                    type="date"
                    value={paymentDate}
                    onChange={(e) => setPaymentDate(e.target.value)}
                  />
                </div>
                <div className="space-y-1">
                  <Label>Ödeme Tutarı (TL) *</Label>
                  <Input
                    type="number"
                    min="0.01"
                    step="0.01"
                    placeholder="0.00"
                    value={paymentAmount}
                    onChange={(e) => setPaymentAmount(e.target.value)}
                  />
                </div>
              </div>

              <div className="space-y-1">
                <Label>Ödeme Yöntemi / Çıkış Hesabı</Label>
                <Select value={paymentMethod} onValueChange={setPaymentMethod}>
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="BANKA">Banka Hesabı (102 Bankalar)</SelectItem>
                    <SelectItem value="KASA">Nakit Kasa (100 Kasa)</SelectItem>
                  </SelectContent>
                </Select>
              </div>

              <div className="space-y-1">
                <Label>Dekont / Belge No</Label>
                <Input
                  placeholder="Örn: DEK-2026-001"
                  value={paymentDocNo}
                  onChange={(e) => setPaymentDocNo(e.target.value)}
                />
              </div>

              <div className="space-y-1">
                <Label>Açıklama</Label>
                <Input
                  placeholder="Ödeme açıklaması"
                  value={paymentDesc}
                  onChange={(e) => setPaymentDesc(e.target.value)}
                />
              </div>

              <Button
                className="w-full mt-3"
                onClick={() => makeSupplierPayment.mutate()}
                disabled={makeSupplierPayment.isPending}
              >
                {makeSupplierPayment.isPending ? "İşleniyor…" : "Ödemeyi Onayla & Fişini Oluştur"}
              </Button>
            </div>
          )}
        </DialogContent>
      </Dialog>

      {/* MÜŞTERİ TAHSİLAT DİALOGU (FAZ 4.2) */}
      <Dialog
        open={collectionOpen}
        onOpenChange={(open) => {
          setCollectionOpen(open);
          if (!open) {
            setCollectionCustomer(null);
            setCollectionAmount("");
            setCollectionDocNo("");
            setCollectionDesc("");
          }
        }}
      >
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>Müşteri Tahsilat Kaydı (120 Alacak Kapama / Kasa-Banka)</DialogTitle>
          </DialogHeader>
          {collectionCustomer ? (
            <div className="space-y-3 pt-2 text-sm">
              <div className="rounded-md bg-emerald-500/10 border border-emerald-500/20 p-3 space-y-1">
                <div className="font-semibold text-foreground">{collectionCustomer?.title || "Müşteri"}</div>
                <div className="text-xs text-muted-foreground">VKN/TCKN: {collectionCustomer?.vkn_tckn || "-"}</div>
                <div className="text-xs font-mono text-emerald-600 dark:text-emerald-400 font-bold pt-1">
                  Açık Müşteri Alacağı: {formatMoney(balanceMap.get(collectionCustomer?.id ?? "")?.balance ?? 0)}
                </div>
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div className="space-y-1">
                  <Label>Tahsilat Tarihi *</Label>
                  <Input
                    type="date"
                    value={collectionDate}
                    onChange={(e) => setCollectionDate(e.target.value)}
                  />
                </div>
                <div className="space-y-1">
                  <Label>Tahsilat Tutarı (TL) *</Label>
                  <Input
                    type="number"
                    min="0.01"
                    step="0.01"
                    placeholder="0.00"
                    value={collectionAmount}
                    onChange={(e) => setCollectionAmount(e.target.value)}
                  />
                </div>
              </div>

              <div className="space-y-1">
                <Label>Tahsilat Yöntemi / Giriş Hesabı</Label>
                <Select value={collectionMethod} onValueChange={setCollectionMethod}>
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="BANKA">Banka Hesabı (102 Bankalar)</SelectItem>
                    <SelectItem value="KASA">Nakit Kasa (100 Kasa)</SelectItem>
                  </SelectContent>
                </Select>
              </div>

              <div className="space-y-1">
                <Label>Dekont / Makbuz No</Label>
                <Input
                  placeholder="Örn: MAK-2026-001"
                  value={collectionDocNo}
                  onChange={(e) => setCollectionDocNo(e.target.value)}
                />
              </div>

              <div className="space-y-1">
                <Label>Açıklama</Label>
                <Input
                  placeholder="Müşteri tahsilatı açıklaması"
                  value={collectionDesc}
                  onChange={(e) => setCollectionDesc(e.target.value)}
                />
              </div>

              <div className="flex gap-2 pt-2">
                <Button
                  variant="outline"
                  className="w-1/2"
                  onClick={() => setCollectionOpen(false)}
                >
                  Vazgeç
                </Button>
                <Button
                  className="w-1/2 bg-emerald-600 hover:bg-emerald-700 text-white"
                  onClick={() => makeCustomerCollection.mutate()}
                  disabled={makeCustomerCollection.isPending}
                >
                  {makeCustomerCollection.isPending ? "Kaydediliyor…" : "Tahsilatı Kaydet"}
                </Button>
              </div>
            </div>
          ) : null}
        </DialogContent>
      </Dialog>

      {/* CARİ KART GÜNCELLE DİALOGU (FAZ 4.2) */}
      <Dialog open={editOpen} onOpenChange={setEditOpen}>
        <DialogContent className="max-w-2xl max-h-[90vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle>Cari Kart Düzenle / Güncelle</DialogTitle>
          </DialogHeader>
          {editCustomer && (
            <div className="grid gap-4 sm:grid-cols-2 pt-2 text-sm">
              <div className="space-y-1 sm:col-span-2">
                <Label>Unvan / Ad Soyad *</Label>
                <Input
                  value={editForm.title}
                  onChange={(e) => setEditForm({ ...editForm, title: e.target.value })}
                />
              </div>

              <div className="space-y-1">
                <Label>VKN / TCKN *</Label>
                <Input
                  value={editForm.vknTckn}
                  onChange={(e) => setEditForm({ ...editForm, vknTckn: e.target.value })}
                />
              </div>

              <div className="space-y-1">
                <Label>Cari Kodu</Label>
                <Input
                  value={editForm.code}
                  onChange={(e) => setEditForm({ ...editForm, code: e.target.value })}
                />
              </div>

              <div className="space-y-1">
                <Label>Yetkili Kişi</Label>
                <Input
                  value={editForm.contactName}
                  onChange={(e) => setEditForm({ ...editForm, contactName: e.target.value })}
                />
              </div>

              <div className="space-y-1">
                <Label>Vergi Dairesi</Label>
                <Input
                  value={editForm.taxOffice}
                  onChange={(e) => setEditForm({ ...editForm, taxOffice: e.target.value })}
                />
              </div>

              <div className="space-y-1">
                <Label>Telefon</Label>
                <Input
                  value={editForm.phone}
                  onChange={(e) => setEditForm({ ...editForm, phone: e.target.value })}
                />
              </div>

              <div className="space-y-1">
                <Label>E-posta</Label>
                <Input
                  value={editForm.email}
                  onChange={(e) => setEditForm({ ...editForm, email: e.target.value })}
                />
              </div>

              <div className="space-y-1 sm:col-span-2">
                <Label>Adres</Label>
                <Input
                  value={editForm.address}
                  onChange={(e) => setEditForm({ ...editForm, address: e.target.value })}
                />
              </div>

              <div className="sm:col-span-2">
                <AddressSelect
                  value={{
                    city: editForm.city,
                    district: editForm.district,
                    neighborhood: editForm.neighborhood,
                  }}
                  onChange={({ city, district, neighborhood }) =>
                    setEditForm({ ...editForm, city, district, neighborhood })
                  }
                />
              </div>

              <div className="space-y-1">
                <Label>Ödeme Vadesi (Gün)</Label>
                <Input
                  type="number"
                  value={editForm.paymentTermDays}
                  onChange={(e) => setEditForm({ ...editForm, paymentTermDays: Number(e.target.value) })}
                />
              </div>

              <div className="space-y-1">
                <Label>Risk Limiti (TL)</Label>
                <Input
                  type="number"
                  value={editForm.riskLimit}
                  onChange={(e) => setEditForm({ ...editForm, riskLimit: Number(e.target.value) })}
                />
              </div>

              <div className="flex justify-end gap-2 sm:col-span-2 pt-3 border-t">
                <Button variant="outline" onClick={() => setEditOpen(false)}>
                  Vazgeç
                </Button>
                <Button
                  onClick={() => updateCustomer.mutate()}
                  disabled={updateCustomer.isPending}
                >
                  {updateCustomer.isPending ? "Kaydediliyor…" : "Cari Kartı Güncelle"}
                </Button>
              </div>
            </div>
          )}
        </DialogContent>
      </Dialog>

      <CariDetailDialog
        customer={detailCustomer as never}
        partners={customers as never}
        onClose={() => setDetailId(null)}
      />
    </AppShell>
  );
}
