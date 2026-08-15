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
  Loader2,
  Radio,
  Save,
  ShieldCheck,
  XCircle,
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
  saveGibSettings,
  saveIntegratorSettings,
  setActiveProvider,
  testConnection,
  type ConnectionSettingsView,
} from "@/lib/efatura-settings.functions";
import { getMyCompanyProfile, updateMyCompanyProfile } from "@/lib/profile.functions";

export const Route = createFileRoute("/_authenticated/ayarlar")({
  head: () => ({
    meta: [
      { title: "Ayarlar ve Entegrasyon | e-Fatura Portalı" },
      {
        name: "description",
        content:
          "Firma profil bilgilerinizi, GİB ve özel entegratör e-fatura bağlantı ayarlarınızı yönetin.",
      },
      { property: "og:title", content: "Ayarlar ve Entegrasyon | e-Fatura Portalı" },
      { property: "og:description", content: "Firma ve e-Fatura entegrasyon ayarları." },
    ],
  }),
  component: SettingsPage,
});

const INTEGRATORS = [
  "Uyumsoft",
  "Foriba (Sovos)",
  "QNB e-Finans",
  "Logo (e-Logo)",
  "Nes Bilgi",
  "Digital Planet",
  "İzibiz",
  "Diğer (Özel Entegratör)",
];

function StatusBadge({ status }: { status: ConnectionSettingsView["gib"]["status"] }) {
  if (status === "CONNECTED") {
    return (
      <Badge className="gap-1 bg-emerald-600 text-emerald-50 hover:bg-emerald-600">
        <CheckCircle2 className="size-3.5" /> Bağlı
      </Badge>
    );
  }
  if (status === "FAILED") {
    return (
      <Badge variant="destructive" className="gap-1">
        <XCircle className="size-3.5" /> Bağlantı başarısız
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
  const saveGib = useServerFn(saveGibSettings);
  const saveIntegrator = useServerFn(saveIntegratorSettings);
  const chooseProvider = useServerFn(setActiveProvider);
  const runTest = useServerFn(testConnection);

  const fetchProfile = useServerFn(getMyCompanyProfile);
  const saveProfileFn = useServerFn(updateMyCompanyProfile);

  const { data: settings, isLoading: settingsLoading } = useQuery({
    queryKey: ["efatura-connection-settings"],
    queryFn: () => fetchSettings(),
  });

  const { data: profile, isLoading: profileLoading } = useQuery({
    queryKey: ["my-company-profile"],
    queryFn: () => fetchProfile(),
  });

  // Profile Form State
  const [profileForm, setProfileForm] = useState({
    companyTitle: "",
    vknTckn: "",
    taxOffice: "",
    address: "",
    phone: "",
    email: "",
  });

  useEffect(() => {
    if (profile) {
      setProfileForm({
        companyTitle: profile.companyTitle || "",
        vknTckn: profile.vknTckn || "",
        taxOffice: profile.taxOffice || "",
        address: profile.address || "",
        phone: profile.phone || "",
        email: profile.email || "",
      });
    }
  }, [profile]);

  // Integration Form State
  const [gibForm, setGibForm] = useState({
    enabled: false,
    environment: "TEST",
    username: "",
    password: "",
  });
  const [intForm, setIntForm] = useState({
    enabled: false,
    provider: "",
    baseUrl: "",
    apiUsername: "",
    apiKey: "",
  });

  useEffect(() => {
    if (!settings) return;
    setGibForm({
      enabled: settings.gib.enabled,
      environment: settings.gib.environment,
      username: settings.gib.username,
      password: "",
    });
    setIntForm({
      enabled: settings.integrator.enabled,
      provider: settings.integrator.provider,
      baseUrl: settings.integrator.baseUrl,
      apiUsername: settings.integrator.apiUsername,
      apiKey: "",
    });
  }, [settings]);

  function applySettings(next: ConnectionSettingsView) {
    queryClient.setQueryData(["efatura-connection-settings"], next);
  }

  const saveProfileMutation = useMutation({
    mutationFn: () => saveProfileFn({ data: profileForm }),
    onSuccess: (updated) => {
      queryClient.setQueryData(["my-company-profile"], updated);
      queryClient.invalidateQueries({ queryKey: ["profile"] });
      toast.success("Firma profil bilgileri başarıyla kaydedildi.");
    },
    onError: (error: Error) => toast.error(`Kayıt başarısız: ${error.message}`),
  });

  const saveGibMutation = useMutation({
    mutationFn: () =>
      saveGib({
        data: {
          enabled: gibForm.enabled,
          environment: gibForm.environment === "PROD" ? ("PROD" as const) : ("TEST" as const),
          username: gibForm.username,
          password: gibForm.password || undefined,
        },
      }),
    onSuccess: (next) => {
      applySettings(next);
      toast.success("GİB bağlantı bilgileri kaydedildi.");
    },
    onError: (error: Error) => toast.error(error.message),
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

  return (
    <AppShell
      title="Ayarlar & Entegrasyon"
      subtitle="Firma bilgilerinizi düzenleyin ve e-Fatura sağlayıcı bağlantılarınızı yönetin."
    >
      {isLoading ? (
        <div className="flex items-center justify-center p-12">
          <Loader2 className="size-6 animate-spin text-muted-foreground" />
          <span className="ml-2 text-sm text-muted-foreground">Ayarlar yükleniyor…</span>
        </div>
      ) : (
        <Tabs defaultValue="company" className="space-y-6">
          <TabsList className="grid w-full grid-cols-2 sm:w-80">
            <TabsTrigger value="company" className="gap-2">
              <Building2 className="size-4" /> Firma Bilgileri
            </TabsTrigger>
            <TabsTrigger value="efatura" className="gap-2">
              <Radio className="size-4" /> e-Fatura Entegrasyonu
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
                      value={profileForm.companyTitle}
                      onChange={(e) =>
                        setProfileForm((f) => ({ ...f, companyTitle: e.target.value }))
                      }
                    />
                  </div>

                  <div className="grid gap-2">
                    <Label htmlFor="vknTckn">VKN veya TCKN *</Label>
                    <Input
                      id="vknTckn"
                      placeholder="10 haneli VKN veya 11 haneli TCKN"
                      value={profileForm.vknTckn}
                      onChange={(e) => setProfileForm((f) => ({ ...f, vknTckn: e.target.value }))}
                    />
                  </div>

                  <div className="grid gap-2">
                    <Label htmlFor="taxOffice">Vergi Dairesi</Label>
                    <Input
                      id="taxOffice"
                      placeholder="Örn: Kadıköy V.D."
                      value={profileForm.taxOffice}
                      onChange={(e) => setProfileForm((f) => ({ ...f, taxOffice: e.target.value }))}
                    />
                  </div>

                  <div className="grid gap-2 md:col-span-2">
                    <Label htmlFor="address">Firma Adresi</Label>
                    <Textarea
                      id="address"
                      rows={3}
                      placeholder="Örn: Atatürk Cad. No:123 Kat:4 Kadıköy / İstanbul"
                      value={profileForm.address}
                      onChange={(e) => setProfileForm((f) => ({ ...f, address: e.target.value }))}
                    />
                  </div>

                  <div className="grid gap-2">
                    <Label htmlFor="phone">Telefon</Label>
                    <Input
                      id="phone"
                      placeholder="Örn: 0216 123 45 67"
                      value={profileForm.phone}
                      onChange={(e) => setProfileForm((f) => ({ ...f, phone: e.target.value }))}
                    />
                  </div>

                  <div className="grid gap-2">
                    <Label htmlFor="email">E-posta</Label>
                    <Input
                      id="email"
                      type="email"
                      placeholder="Örn: muhasebe@firma.com"
                      value={profileForm.email}
                      onChange={(e) => setProfileForm((f) => ({ ...f, email: e.target.value }))}
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
                    { id: "GIB", label: "GİB Portalı (Doğrudan)" },
                    { id: "INTEGRATOR", label: "Özel Entegratör" },
                    { id: "NONE", label: "Entegrasyon Kullanma (Yalnızca Taslak / PDF)" },
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

            {/* GİB INTEGRATION CARD */}
            <Card>
              <CardHeader className="flex flex-row flex-wrap items-start justify-between gap-3">
                <div>
                  <CardTitle className="text-lg">GİB Portal Entegrasyonu</CardTitle>
                  <CardDescription>
                    Gelir İdaresi Başkanlığı e-Arşiv / e-Fatura portalı bağlantısı.
                  </CardDescription>
                </div>
                <StatusBadge status={settings?.gib.status ?? "NOT_CONFIGURED"} />
              </CardHeader>
              <CardContent className="grid gap-4">
                <div className="flex items-center justify-between rounded-md border border-border p-3">
                  <div>
                    <p className="text-sm font-medium">GİB bağlantısını etkinleştir</p>
                    <p className="text-xs text-muted-foreground">
                      Aktif edildiğinde GİB portal kimlik bilgileri kullanılır.
                    </p>
                  </div>
                  <Switch
                    checked={gibForm.enabled}
                    onCheckedChange={(checked) => setGibForm((f) => ({ ...f, enabled: checked }))}
                  />
                </div>

                <div className="grid gap-4 md:grid-cols-2">
                  <div className="grid gap-2">
                    <Label>Çalışma Ortamı</Label>
                    <Select
                      value={gibForm.environment}
                      onValueChange={(value) => setGibForm((f) => ({ ...f, environment: value }))}
                    >
                      <SelectTrigger>
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="TEST">Test Ortamı (GİB Test Portalı)</SelectItem>
                        <SelectItem value="PROD">Canlı Ortam (GİB Canlı Portalı)</SelectItem>
                      </SelectContent>
                    </Select>
                  </div>
                  <div className="grid gap-2">
                    <Label>GİB Kullanıcı Kodu / VKN</Label>
                    <Input
                      value={gibForm.username}
                      onChange={(e) => setGibForm((f) => ({ ...f, username: e.target.value }))}
                      placeholder="Örn: 1234567890"
                    />
                  </div>
                  <div className="grid gap-2 md:col-span-2">
                    <Label>GİB Portal Şifresi</Label>
                    <Input
                      type="password"
                      value={gibForm.password}
                      onChange={(e) => setGibForm((f) => ({ ...f, password: e.target.value }))}
                      placeholder={
                        settings?.gib.hasPassword
                          ? "•••••••• (kayıtlı şifre korunuyor)"
                          : "Şifrenizi girin"
                      }
                    />
                    <p className="text-xs text-muted-foreground">
                      Şifreniz sunucu tarafında AES-256-GCM ile şifrelenir ve asla tarayıcıya
                      gönderilmez.
                    </p>
                  </div>
                </div>

                {settings?.gib.lastError ? (
                  <p className="text-xs text-destructive">
                    Son test hatası: {settings.gib.lastError}
                  </p>
                ) : null}
                {settings?.gib.lastTestedAt ? (
                  <p className="text-xs text-muted-foreground">
                    Son test tarihi: {new Date(settings.gib.lastTestedAt).toLocaleString("tr-TR")}
                  </p>
                ) : null}

                <div className="flex flex-wrap gap-2 pt-2">
                  <Button
                    onClick={() => saveGibMutation.mutate()}
                    disabled={saveGibMutation.isPending}
                  >
                    {saveGibMutation.isPending ? <Loader2 className="size-4 animate-spin" /> : null}
                    GİB Ayarlarını Kaydet
                  </Button>
                  <Button
                    variant="outline"
                    onClick={() => testMutation.mutate("GIB")}
                    disabled={testMutation.isPending}
                  >
                    {testMutation.isPending ? <Loader2 className="size-4 animate-spin" /> : null}
                    Bağlantıyı Test Et
                  </Button>
                </div>
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
        </Tabs>
      )}
    </AppShell>
  );
}
