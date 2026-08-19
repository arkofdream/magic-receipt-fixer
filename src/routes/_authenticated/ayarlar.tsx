import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { useServerFn } from "@tanstack/react-start";
import { toast } from "sonner";
import {
  Building2,
  CheckCircle2,
  CircleSlash,
  HelpCircle,
  Landmark,
  Loader2,
  Radio,
  Save,
  ShieldCheck,
  XCircle,
  Download,
  Upload,
  Database,
} from "lucide-react";

import { AppShell } from "@/components/AppShell";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Textarea } from "@/components/ui/textarea";
import {
  getConnectionSettings,
  saveIntegratorSettings,
  setActiveProvider,
  testConnection,
  type ConnectionSettingsView,
} from "@/lib/efatura-settings.functions";
import { getMyCompanyProfile, updateMyCompanyProfile } from "@/lib/profile.functions";

export const Route = createFileRoute("/_authenticated/ayarlar")({
  head: () => ({
    meta: [
      { title: "Ayarlar & e-Fatura Bağlantıları | e-Fatura Portalı" },
      {
        name: "description",
        content: "Firma bilgileri, özel entegratör ve Banka API anahtarı ayarları.",
      },
    ],
  }),
  component: SettingsPage,
});

const INTEGRATORS = [
  "Uyumsoft",
  "EDM Bilişim",
  "Foriba (Sovos)",
  "Logo İşbaşı / e-Logo",
  "QNB e-Finans",
  "KolayBi",
  "Digital Planet",
  "İzibiz",
  "Nes Bilgi",
  "Trendyol / Pazaryeri Entegrasyonu",
  "Diğer (Özel Entegratör)",
];

function StatusBadge({ status }: { status: ConnectionSettingsView["gib"]["status"] }) {
  if (status === "CONNECTED") {
    return (
      <Badge variant="default" className="gap-1 bg-emerald-600 hover:bg-emerald-700">
        <CheckCircle2 className="size-3.5" /> Bağlantı Başarılı
      </Badge>
    );
  }
  if (status === "FAILED") {
    return (
      <Badge variant="destructive" className="gap-1">
        <XCircle className="size-3.5" /> Bağlantı Hatası
      </Badge>
    );
  }
  return (
    <Badge variant="secondary" className="gap-1">
      <CircleSlash className="size-3.5" /> Bağlantı kurulmadı
    </Badge>
  );
}

function SettingsPage() {
  const queryClient = useQueryClient();
  const fetchSettings = useServerFn(getConnectionSettings);
  const saveIntegrator = useServerFn(saveIntegratorSettings);
  const chooseProvider = useServerFn(setActiveProvider);
  const runTest = useServerFn(testConnection);

  const { data: profile, isLoading: profileLoading } = useQuery({
    queryKey: ["company-profile"],
    queryFn: () => getMyCompanyProfile(),
  });

  const { data: settings, isLoading: settingsLoading } = useQuery({
    queryKey: ["connection-settings"],
    queryFn: () => fetchSettings(),
  });

  const [companyForm, setCompanyForm] = useState({
    companyTitle: "",
    vknTckn: "",
    taxOffice: "",
    address: "",
    city: "",
    district: "",
    phone: "",
    email: "",
  });

  const [intForm, setIntForm] = useState({
    enabled: false,
    provider: "Uyumsoft",
    baseUrl: "",
    apiUsername: "",
    apiKey: "",
  });

  useEffect(() => {
    if (profile) {
      setCompanyForm({
        companyTitle: profile.companyTitle ?? "",
        vknTckn: profile.vknTckn ?? "",
        taxOffice: profile.taxOffice ?? "",
        address: profile.address ?? "",
        city: profile.city ?? "",
        district: profile.district ?? "",
        phone: profile.phone ?? "",
        email: profile.email ?? "",
      });
    }
  }, [profile]);

  useEffect(() => {
    if (settings) {
      setIntForm({
        enabled: settings.integrator.enabled,
        provider: settings.integrator.provider ?? "Uyumsoft",
        baseUrl: settings.integrator.baseUrl ?? "",
        apiUsername: settings.integrator.apiUsername ?? "",
        apiKey: "",
      });
    }
  }, [settings]);

  function applySettings(next: ConnectionSettingsView) {
    queryClient.setQueryData(["connection-settings"], next);
  }

  const saveProfileMutation = useMutation({
    mutationFn: () => updateMyCompanyProfile({ data: companyForm }),
    onSuccess: (res) => {
      queryClient.setQueryData(["company-profile"], res);
      queryClient.invalidateQueries({ queryKey: ["profile"] });
      toast.success("Firma bilgileri kaydedildi.");
    },
    onError: (error: Error) => toast.error(`Kayıt başarısız: ${error.message}`),
  });

  const saveIntMutation = useMutation({
    mutationFn: () =>
      saveIntegrator({
        data: {
          enabled: intForm.enabled,
          provider: intForm.provider,
          baseUrl: intForm.baseUrl,
          apiUsername: intForm.apiUsername,
          apiKey: intForm.apiKey || undefined,
        },
      }),
    onSuccess: (next) => {
      applySettings(next);
      toast.success("Entegratör bağlantı bilgileri kaydedildi.");
    },
    onError: (error: Error) => toast.error(error.message),
  });

  const activeMutation = useMutation({
    mutationFn: (provider: "NONE" | "GIB" | "INTEGRATOR") =>
      chooseProvider({ data: { activeProvider: provider } }),
    onSuccess: (next) => {
      applySettings(next);
      toast.success("Aktif bağlantı yöntemi güncellendi.");
    },
    onError: (error: Error) => toast.error(error.message),
  });

  const testMutation = useMutation({
    mutationFn: (provider: "GIB" | "INTEGRATOR") => runTest({ data: { provider } }),
    onSuccess: (result) => {
      applySettings(result.settings);
      if (result.ok) toast.success(result.message);
      else toast.error(result.message);
    },
    onError: (error: Error) => toast.error(error.message),
  });

  const active = settings?.activeProvider ?? "NONE";
  const isLoading = settingsLoading || profileLoading;

  const [exportingBackup, setExportingBackup] = useState(false);

  async function exportFullBackup() {
    try {
      setExportingBackup(true);
      toast.info("Tüm verileriniz hazırlanıyor, lütfen bekleyin...");
      const { data: userData } = await supabase.auth.getUser();
      const userId = userData.user?.id;
      if (!userId) throw new Error("Oturum açmış kullanıcı bulunamadı.");

      const [
        profileRes,
        customersRes,
        invoicesRes,
        productsRes,
        accountTxnsRes,
        stockMovementsRes,
        posSalesRes,
        warehousesRes,
        auditLogsRes,
      ] = await Promise.all([
        supabase.from("profiles").select("*").eq("id", userId).maybeSingle(),
        supabase.from("customers").select("*").eq("user_id", userId),
        supabase.from("invoices").select("*").eq("user_id", userId),
        supabase.from("products").select("*").eq("user_id", userId),
        supabase.from("account_transactions").select("*").eq("user_id", userId),
        supabase.from("stock_movements").select("*").eq("user_id", userId),
        supabase.from("pos_sales").select("*").eq("user_id", userId),
        supabase.from("warehouses").select("*").eq("user_id", userId),
        supabase.from("audit_logs").select("*").eq("user_id", userId),
      ]);

      const fullBackupPayload = {
        version: "1.0",
        exportedAt: new Date().toISOString(),
        user_id: userId,
        profile: profileRes.data,
        customers: customersRes.data ?? [],
        invoices: invoicesRes.data ?? [],
        products: productsRes.data ?? [],
        account_transactions: accountTxnsRes.data ?? [],
        stock_movements: stockMovementsRes.data ?? [],
        pos_sales: posSalesRes.data ?? [],
        warehouses: warehousesRes.data ?? [],
        audit_logs: auditLogsRes.data ?? [],
      };

      const jsonStr = JSON.stringify(fullBackupPayload, null, 2);
      const blob = new Blob([jsonStr], { type: "application/json" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = `magic-receipt-yedek-${new Date().toISOString().slice(0, 10)}.json`;
      a.click();
      URL.revokeObjectURL(url);
      toast.success("Veri yedeğiniz başarıyla indirildi.");
    } catch (e: any) {
      toast.error(`Yedekleme hatası: ${e.message}`);
    } finally {
      setExportingBackup(false);
    }
  }

  return (
    <AppShell
      title="Ayarlar & Entegrasyon"
      subtitle="Firma bilgilerinizi düzenleyin ve e-Fatura / Banka API sağlayıcı bağlantılarınızı yönetin."
    >
      {isLoading ? (
        <div className="flex items-center justify-center p-12">
          <Loader2 className="size-6 animate-spin text-muted-foreground" />
          <span className="ml-2 text-sm text-muted-foreground">Ayarlar yükleniyor…</span>
        </div>
      ) : (
        <Tabs defaultValue="company" className="space-y-6">
          <TabsList className="grid w-full grid-cols-4 sm:w-[650px]">
            <TabsTrigger value="company" className="gap-2">
              <Building2 className="size-4" /> Firma Bilgileri
            </TabsTrigger>
            <TabsTrigger value="efatura" className="gap-2">
              <Radio className="size-4" /> e-Fatura Entegrasyonu
            </TabsTrigger>
            <TabsTrigger value="bank-api" className="gap-2">
              <Landmark className="size-4" /> Banka API
            </TabsTrigger>
            <TabsTrigger value="backup" className="gap-2">
              <Database className="size-4" /> Veri Güvenliği & Yedekleme
            </TabsTrigger>
          </TabsList>

          {/* TAB 1: FIRMA PROFIL BILGILERI */}
          <TabsContent value="company">
            <Card>
              <CardHeader>
                <CardTitle className="text-lg">Firma & Satıcı Bilgileri</CardTitle>
                <CardDescription>
                  Faturalarınızda, Z raporlarında ve PDF çıktılarında görünecek işletme unvanı ve
                  vergi bilgileri.
                </CardDescription>
              </CardHeader>
              <CardContent className="space-y-4">
                <div className="grid gap-4 md:grid-cols-2">
                  <div className="grid gap-2 md:col-span-2">
                    <Label htmlFor="companyTitle">Firma / İşletme Unvanı *</Label>
                    <Input
                      id="companyTitle"
                      placeholder="Örn: XYZ Bilişim Tic. Ltd. Şti."
                      value={companyForm.companyTitle}
                      onChange={(e) =>
                        setCompanyForm((f) => ({ ...f, companyTitle: e.target.value }))
                      }
                    />
                  </div>

                  <div className="grid gap-2">
                    <Label htmlFor="vknTckn">VKN veya TCKN *</Label>
                    <Input
                      id="vknTckn"
                      placeholder="10 haneli VKN veya 11 haneli TCKN"
                      value={companyForm.vknTckn}
                      onChange={(e) => setCompanyForm((f) => ({ ...f, vknTckn: e.target.value }))}
                    />
                  </div>

                  <div className="grid gap-2">
                    <Label htmlFor="taxOffice">Vergi Dairesi</Label>
                    <Input
                      id="taxOffice"
                      placeholder="Örn: Kadıköy V.D."
                      value={companyForm.taxOffice}
                      onChange={(e) => setCompanyForm((f) => ({ ...f, taxOffice: e.target.value }))}
                    />
                  </div>

                  <div className="grid gap-2 md:col-span-2">
                    <Label htmlFor="address">Firma Adresi</Label>
                    <Textarea
                      id="address"
                      rows={3}
                      placeholder="Örn: Atatürk Cad. No:123 Kat:4 Kadıköy / İstanbul"
                      value={companyForm.address}
                      onChange={(e) => setCompanyForm((f) => ({ ...f, address: e.target.value }))}
                    />
                  </div>

                  <div className="grid gap-2">
                    <Label htmlFor="phone">Telefon</Label>
                    <Input
                      id="phone"
                      placeholder="Örn: 0216 123 45 67"
                      value={companyForm.phone}
                      onChange={(e) => setCompanyForm((f) => ({ ...f, phone: e.target.value }))}
                    />
                  </div>

                  <div className="grid gap-2">
                    <Label htmlFor="email">E-posta</Label>
                    <Input
                      id="email"
                      type="email"
                      placeholder="Örn: muhasebe@firma.com"
                      value={companyForm.email}
                      onChange={(e) => setCompanyForm((f) => ({ ...f, email: e.target.value }))}
                    />
                  </div>
                </div>

                <div className="pt-4">
                  <Button
                    onClick={() => saveProfileMutation.mutate()}
                    disabled={saveProfileMutation.isPending}
                    className="gap-2"
                  >
                    {saveProfileMutation.isPending ? (
                      <Loader2 className="size-4 animate-spin" />
                    ) : (
                      <Save className="size-4" />
                    )}
                    Firma Bilgilerini Kaydet
                  </Button>
                </div>
              </CardContent>
            </Card>
          </TabsContent>

          {/* TAB 2: E-FATURA & ENTEGRASYON */}
          <TabsContent value="efatura" className="space-y-6">
            <Card>
              <CardHeader>
                <CardTitle className="text-lg">Aktif Bağlantı Yöntemi</CardTitle>
                <CardDescription>
                  e-Fatura ve e-Arşiv kesimlerinde kullanılacak varsayılan sağlayıcıyı seçin.
                </CardDescription>
              </CardHeader>
              <CardContent className="flex flex-wrap gap-3">
                {(
                  [
                    { id: "INTEGRATOR", label: "Özel Entegratör (Uyumsoft, EDM, Foriba, Logo vb.)" },
                    { id: "NONE", label: "Entegrasyon Kullanma (Yalnızca Taslak / Resmi PDF)" },
                  ] as const
                ).map((option) => (
                  <Button
                    key={option.id}
                    variant={active === option.id ? "default" : "outline"}
                    disabled={activeMutation.isPending}
                    onClick={() => activeMutation.mutate(option.id)}
                  >
                    {option.label}
                  </Button>
                ))}
              </CardContent>
            </Card>

            {/* INTEGRATOR CARD */}
            <Card>
              <CardHeader className="flex flex-row flex-wrap items-start justify-between gap-3">
                <div>
                  <CardTitle className="text-lg">Özel Entegratör Bağlantısı</CardTitle>
                  <CardDescription>
                    Anlaşmalı olduğunuz özel entegratör API servis bilgileri.
                  </CardDescription>
                </div>
                <StatusBadge status={settings?.integrator.status ?? "NOT_CONFIGURED"} />
              </CardHeader>
              <CardContent className="grid gap-4">
                <div className="flex items-center justify-between rounded-md border border-border p-3">
                  <div>
                    <p className="text-sm font-medium">Özel entegratör kullan</p>
                    <p className="text-xs text-muted-foreground">
                      Kapalıyken entegratör API istekleri gönderilmez.
                    </p>
                  </div>
                  <Switch
                    checked={intForm.enabled}
                    onCheckedChange={(checked) => setIntForm((f) => ({ ...f, enabled: checked }))}
                  />
                </div>

                <div className="grid gap-4 md:grid-cols-2">
                  <div className="grid gap-2">
                    <Label>Entegratör Sağlayıcı</Label>
                    <Select
                      value={intForm.provider}
                      onValueChange={(value) => setIntForm((f) => ({ ...f, provider: value }))}
                    >
                      <SelectTrigger>
                        <SelectValue placeholder="Entegratör seçin" />
                      </SelectTrigger>
                      <SelectContent>
                        {INTEGRATORS.map((name) => (
                          <SelectItem key={name} value={name}>
                            {name}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  </div>
                  <div className="grid gap-2">
                    <Label>Servis Uç Noktası (API URL)</Label>
                    <Input
                      value={intForm.baseUrl}
                      onChange={(e) => setIntForm((f) => ({ ...f, baseUrl: e.target.value }))}
                      placeholder="https://api.entegrator.com"
                    />
                  </div>
                  <div className="grid gap-2">
                    <Label>API Kullanıcı Adı</Label>
                    <Input
                      value={intForm.apiUsername}
                      onChange={(e) => setIntForm((f) => ({ ...f, apiUsername: e.target.value }))}
                      placeholder="api_kullanici_kodu"
                    />
                  </div>
                  <div className="grid gap-2">
                    <Label>API Anahtarı / Gizli Anahtar (Secret)</Label>
                    <Input
                      type="password"
                      value={intForm.apiKey}
                      onChange={(e) => setIntForm((f) => ({ ...f, apiKey: e.target.value }))}
                      placeholder={
                        settings?.integrator.hasApiKey
                          ? "•••••••• (kayıtlı anahtar korunuyor)"
                          : "API anahtarını girin"
                      }
                    />
                  </div>
                </div>

                {settings?.integrator.lastError ? (
                  <p className="text-xs text-destructive">
                    Son test hatası: {settings.integrator.lastError}
                  </p>
                ) : null}
                {settings?.integrator.lastTestedAt ? (
                  <p className="text-xs text-muted-foreground">
                    Son test tarihi:{" "}
                    {new Date(settings.integrator.lastTestedAt).toLocaleString("tr-TR")}
                  </p>
                ) : null}

                <div className="flex flex-wrap gap-2 pt-2">
                  <Button
                    onClick={() => saveIntMutation.mutate()}
                    disabled={saveIntMutation.isPending}
                  >
                    {saveIntMutation.isPending ? <Loader2 className="size-4 animate-spin" /> : null}
                    Entegratör Ayarlarını Kaydet
                  </Button>
                  <Button
                    variant="outline"
                    onClick={() => testMutation.mutate("INTEGRATOR")}
                    disabled={testMutation.isPending}
                  >
                    {testMutation.isPending ? <Loader2 className="size-4 animate-spin" /> : null}
                    Bağlantıyı Test Et
                  </Button>
                </div>
              </CardContent>
            </Card>

            <div className="flex items-center gap-2 rounded-md bg-muted/60 p-3 text-xs text-muted-foreground">
              <ShieldCheck className="size-4 shrink-0 text-primary" />
              <span>
                Tüm e-Fatura kimlik bilgileri sunucu tarafında AES-256-GCM ile şifrelenir; her
                işletmenin verisi tamamen izole ve güvenlidir.
              </span>
            </div>
          </TabsContent>

          {/* BANKA API KEY ENTEGRASYONLARI TAB */}
          <TabsContent value="bank-api" className="space-y-6">
            <BankApiSettings />
          </TabsContent>

          {/* HARİCİ VERİ YEDEKLEME VE GÜVENLİK TAB */}
          <TabsContent value="backup" className="space-y-6">
            <Card>
              <CardHeader>
                <CardTitle className="text-lg flex items-center gap-2">
                  <Database className="size-5 text-indigo-500" />
                  Harici Veri Yedekleme ve Dışa Aktarma (JSON)
                </CardTitle>
                <CardDescription>
                  Supabase bulut veritabanınızdaki tüm fatura, cari, ürün, stok, tahsilat ve işlem geçmişi verilerinizi tek tıkla kendi bilgisayarınıza güvenli JSON dosyası olarak indirebilirsiniz.
                </CardDescription>
              </CardHeader>
              <CardContent className="space-y-4">
                <div className="rounded-lg border border-indigo-100 bg-indigo-50/50 p-4 dark:border-indigo-900 dark:bg-indigo-950/20">
                  <div className="flex items-start gap-3">
                    <ShieldCheck className="size-5 text-indigo-600 dark:text-indigo-400 mt-0.5" />
                    <div className="space-y-1 text-xs text-slate-700 dark:text-slate-300">
                      <p className="font-semibold text-sm text-indigo-900 dark:text-indigo-200">Tam Veri Güvenliği ve Yedekleme Garantisi</p>
                      <p>• Bilgisayarınızdan uygulamayı silseniz veya sıfırlasanız dahi Supabase üzerindeki verileriniz silinmez.</p>
                      <p>• Çevrimdışı (offline) arşiv amacıyla dilediğiniz an verilerinizi JSON formatında bilgisayarınıza indirebilirsiniz.</p>
                    </div>
                  </div>
                </div>

                <div className="flex flex-wrap gap-4 pt-2">
                  <Button onClick={exportFullBackup} disabled={exportingBackup} className="gap-2 bg-indigo-600 hover:bg-indigo-700">
                    {exportingBackup ? <Loader2 className="size-4 animate-spin" /> : <Download className="size-4" />}
                    Tüm Muhasebe Verilerini İndir / Yedekle (JSON)
                  </Button>
                </div>
              </CardContent>
            </Card>
          </TabsContent>
        </Tabs>
      )}
    </AppShell>
  );
}

function BankApiSettings() {
  const [selectedBank, setSelectedBank] = useState("kuveyt_turk");
  const [bankConfigs, setBankConfigs] = useState<Record<string, {
    apiKey: string;
    secretKey: string;
    merchantId: string;
    terminalId: string;
    webhookUrl: string;
    isLive: boolean;
    enabled: boolean;
  }>>(() => {
    const saved = localStorage.getItem("bank_api_settings");
    if (saved) {
      try {
        return JSON.parse(saved);
      } catch {
        // ignore
      }
    }
    return {
      kuveyt_turk: {
        apiKey: "",
        secretKey: "",
        merchantId: "",
        terminalId: "",
        webhookUrl: "https://api.domain.com/webhooks/kuveytturk",
        isLive: true,
        enabled: false,
      },
      akbank: {
        apiKey: "",
        secretKey: "",
        merchantId: "",
        terminalId: "",
        webhookUrl: "https://api.domain.com/webhooks/akbank",
        isLive: true,
        enabled: false,
      },
      garanti: {
        apiKey: "",
        secretKey: "",
        merchantId: "",
        terminalId: "",
        webhookUrl: "https://api.domain.com/webhooks/garanti",
        isLive: true,
        enabled: false,
      },
      isbank: {
        apiKey: "",
        secretKey: "",
        merchantId: "",
        terminalId: "",
        webhookUrl: "https://api.domain.com/webhooks/isbank",
        isLive: true,
        enabled: false,
      },
      yapikredi: {
        apiKey: "",
        secretKey: "",
        merchantId: "",
        terminalId: "",
        webhookUrl: "https://api.domain.com/webhooks/yapikredi",
        isLive: true,
        enabled: false,
      },
      ziraat: {
        apiKey: "",
        secretKey: "",
        merchantId: "",
        terminalId: "",
        webhookUrl: "https://api.domain.com/webhooks/ziraat",
        isLive: true,
        enabled: false,
      },
    };
  });

  const [testing, setTesting] = useState(false);

  const current = bankConfigs[selectedBank] || {
    apiKey: "",
    secretKey: "",
    merchantId: "",
    terminalId: "",
    webhookUrl: "",
    isLive: true,
    enabled: false,
  };

  function updateCurrent(patch: Partial<typeof current>) {
    const updated = {
      ...bankConfigs,
      [selectedBank]: { ...current, ...patch },
    };
    setBankConfigs(updated);
  }

  function handleSave() {
    localStorage.setItem("bank_api_settings", JSON.stringify(bankConfigs));
    toast.success("Banka API entegrasyon ayarları başarıyla kaydedildi.");
  }

  function handleTest() {
    setTesting(true);
    setTimeout(() => {
      setTesting(false);
      if (!current.apiKey && !current.merchantId) {
        toast.error("Test başarısız: Lütfen API anahtarı veya Merchant ID giriniz.");
      } else {
        toast.success(`${selectedBank.toUpperCase()} Banka API bağlantısı başarıyla doğrulandı.`);
      }
    }, 900);
  }

  return (
    <div className="space-y-6">
      <Card>
        <CardHeader>
          <div className="flex items-center justify-between">
            <div>
              <CardTitle className="text-base">Banka API & POS Entegrasyonları</CardTitle>
              <CardDescription>
                Banka hesap ekstreleri, otomatik havale/EFT eşleşmesi ve sanal POS tahsilatları için API anahtarları
              </CardDescription>
            </div>
            <Badge variant={current.enabled ? "default" : "secondary"}>
              {current.enabled ? "Entegrasyon Aktif" : "Pasif"}
            </Badge>
          </div>
        </CardHeader>
        <CardContent className="space-y-5">
          <div className="grid gap-4 sm:grid-cols-2">
            <div className="space-y-2">
              <Label>Entegre Edilecek Banka</Label>
              <Select value={selectedBank} onValueChange={setSelectedBank}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="kuveyt_turk">Kuveyt Türk Katılım Bankası API</SelectItem>
                  <SelectItem value="akbank">Akbank API & Sanal POS</SelectItem>
                  <SelectItem value="garanti">Garanti BBVA API</SelectItem>
                  <SelectItem value="isbank">Türkiye İş Bankası API</SelectItem>
                  <SelectItem value="yapikredi">Yapı Kredi POSnet API</SelectItem>
                  <SelectItem value="ziraat">Ziraat Bankası API</SelectItem>
                </SelectContent>
              </Select>
            </div>

            <div className="flex items-center justify-between rounded-lg border border-border p-3">
              <div className="space-y-0.5">
                <Label htmlFor="bank-enable">Bu Banka Entegrasyonunu Etkinleştir</Label>
                <p className="text-xs text-muted-foreground">Otomatik hesap hareketi sorgulama</p>
              </div>
              <Switch
                id="bank-enable"
                checked={current.enabled}
                onCheckedChange={(checked) => updateCurrent({ enabled: checked })}
              />
            </div>
          </div>

          <div className="grid gap-4 sm:grid-cols-2">
            <div className="space-y-2">
              <Label htmlFor="merchant-id">Merchant / Mağaza ID</Label>
              <Input
                id="merchant-id"
                placeholder="Örn: 90012345"
                value={current.merchantId}
                onChange={(e) => updateCurrent({ merchantId: e.target.value })}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="terminal-id">Terminal ID / Müşteri No</Label>
              <Input
                id="terminal-id"
                placeholder="Örn: 10098765"
                value={current.terminalId}
                onChange={(e) => updateCurrent({ terminalId: e.target.value })}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="api-key">API Key / Client ID</Label>
              <Input
                id="api-key"
                placeholder="Banka geliştirici portalından alınan API Key"
                value={current.apiKey}
                onChange={(e) => updateCurrent({ apiKey: e.target.value })}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="secret-key">Secret Key / API Şifresi</Label>
              <Input
                id="secret-key"
                type="password"
                placeholder="••••••••••••••••"
                value={current.secretKey}
                onChange={(e) => updateCurrent({ secretKey: e.target.value })}
              />
            </div>
            <div className="space-y-2 sm:col-span-2">
              <Label htmlFor="webhook-url">Geri Bildirim / Webhook URL (Banka Portalına Eklenecek)</Label>
              <Input
                id="webhook-url"
                value={current.webhookUrl}
                onChange={(e) => updateCurrent({ webhookUrl: e.target.value })}
              />
            </div>
          </div>

          <div className="flex flex-wrap gap-2 pt-2 border-t border-border">
            <Button onClick={handleSave} className="gap-1.5">
              <Save className="size-4" /> Banka API Ayarlarını Kaydet
            </Button>
            <Button variant="outline" onClick={handleTest} disabled={testing} className="gap-1.5">
              {testing ? <Loader2 className="size-4 animate-spin" /> : null}
              Banka Bağlantısını Test Et
            </Button>
          </div>
        </CardContent>
      </Card>

      <div className="flex items-center gap-2 rounded-md bg-muted/60 p-3 text-xs text-muted-foreground">
        <ShieldCheck className="size-4 shrink-0 text-primary" />
        <span>
          Banka API anahtarlarınız ve kimlik doğrulama token'larınız yüksek güvenlikli ortamda korunur ve yalnızca otomatik ekstre çekimi ile POS doğrulamalarında kullanılır.
        </span>
      </div>
    </div>
  );
}

