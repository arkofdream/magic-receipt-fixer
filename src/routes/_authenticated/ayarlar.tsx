import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { useServerFn } from "@tanstack/react-start";
import { toast } from "sonner";
import { CheckCircle2, CircleSlash, Loader2, ShieldCheck, XCircle } from "lucide-react";

import { AppShell } from "@/components/AppShell";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import {
  getConnectionSettings,
  saveGibSettings,
  saveIntegratorSettings,
  setActiveProvider,
  testConnection,
  type ConnectionSettingsView,
} from "@/lib/efatura-settings.functions";

export const Route = createFileRoute("/_authenticated/ayarlar")({
  head: () => ({
    meta: [
      { title: "Entegrasyon Ayarları | e-Fatura Portalı" },
      {
        name: "description",
        content: "GİB ve özel entegratör bağlantı bilgilerinizi güvenle yönetin, bağlantıyı test edin.",
      },
      { property: "og:title", content: "Entegrasyon Ayarları | e-Fatura Portalı" },
      { property: "og:description", content: "GİB ve özel entegratör e-Fatura bağlantı ayarları." },
    ],
  }),
  component: SettingsPage,
});

const INTEGRATORS = ["Foriba", "Uyumsoft", "Logo (e-Logo)", "Nes Bilgi", "Digital Planet", "İzibiz", "Diğer"];

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

  const { data: settings, isLoading } = useQuery({
    queryKey: ["efatura-connection-settings"],
    queryFn: () => fetchSettings(),
  });

  const [gibForm, setGibForm] = useState({ enabled: false, environment: "TEST", username: "", password: "" });
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
    mutationFn: (provider: "NONE" | "GIB" | "INTEGRATOR") => chooseProvider({ data: { activeProvider: provider } }),
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

  return (
    <AppShell
      title="Entegrasyon Ayarları"
      subtitle="e-Fatura gönderiminde kullanılacak GİB veya özel entegratör bağlantısını yönetin."
    >
      {isLoading ? (
        <p className="text-sm text-muted-foreground">Ayarlar yükleniyor…</p>
      ) : (
        <div className="grid gap-6">
          <Card>
            <CardHeader>
              <CardTitle>Aktif Bağlantı Yöntemi</CardTitle>
              <CardDescription>
                e-Fatura işlemlerinde aynı anda yalnızca tek bir bağlantı yöntemi kullanılabilir.
              </CardDescription>
            </CardHeader>
            <CardContent className="flex flex-wrap gap-2">
              {(
                [
                  { id: "GIB", label: "GİB Entegrasyonu" },
                  { id: "INTEGRATOR", label: "Özel Entegratör" },
                  { id: "NONE", label: "Kullanma" },
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

          <Card>
            <CardHeader className="flex flex-row flex-wrap items-start justify-between gap-3">
              <div>
                <CardTitle>GİB Entegrasyonu</CardTitle>
                <CardDescription>GİB portal kimlik bilgileriyle doğrudan bağlantı.</CardDescription>
              </div>
              <StatusBadge status={settings?.gib.status ?? "NOT_CONFIGURED"} />
            </CardHeader>
            <CardContent className="grid gap-4">
              <div className="flex items-center justify-between rounded-md border border-border p-3">
                <div>
                  <p className="text-sm font-medium">GİB bağlantısını etkinleştir</p>
                  <p className="text-xs text-muted-foreground">Kapalıyken bu bağlantı kullanılmaz.</p>
                </div>
                <Switch
                  checked={gibForm.enabled}
                  onCheckedChange={(checked) => setGibForm((f) => ({ ...f, enabled: checked }))}
                />
              </div>

              <div className="grid gap-4 md:grid-cols-2">
                <div className="grid gap-2">
                  <Label>Ortam</Label>
                  <Select
                    value={gibForm.environment}
                    onValueChange={(value) => setGibForm((f) => ({ ...f, environment: value }))}
                  >
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="TEST">Test Ortamı</SelectItem>
                      <SelectItem value="PROD">Canlı Ortam</SelectItem>
                    </SelectContent>
                  </Select>
                </div>
                <div className="grid gap-2">
                  <Label>GİB Kullanıcı Kodu</Label>
                  <Input
                    value={gibForm.username}
                    onChange={(e) => setGibForm((f) => ({ ...f, username: e.target.value }))}
                    placeholder="Örn. 1234567890"
                  />
                </div>
                <div className="grid gap-2 md:col-span-2">
                  <Label>GİB Şifresi</Label>
                  <Input
                    type="password"
                    value={gibForm.password}
                    onChange={(e) => setGibForm((f) => ({ ...f, password: e.target.value }))}
                    placeholder={settings?.gib.hasPassword ? "•••••••• (kayıtlı)" : "Şifrenizi girin"}
                  />
                  <p className="text-xs text-muted-foreground">
                    Boş bırakırsanız mevcut şifre korunur. Şifre yalnızca şifrelenmiş olarak saklanır ve hiçbir zaman
                    ekranda gösterilmez.
                  </p>
                </div>
              </div>

              {settings?.gib.lastError ? (
                <p className="text-xs text-destructive">Son hata: {settings.gib.lastError}</p>
              ) : null}
              {settings?.gib.lastTestedAt ? (
                <p className="text-xs text-muted-foreground">
                  Son test: {new Date(settings.gib.lastTestedAt).toLocaleString("tr-TR")}
                </p>
              ) : null}

              <div className="flex flex-wrap gap-2">
                <Button onClick={() => saveGibMutation.mutate()} disabled={saveGibMutation.isPending}>
                  {saveGibMutation.isPending ? <Loader2 className="size-4 animate-spin" /> : null}
                  Kaydet
                </Button>
                <Button
                  variant="outline"
                  onClick={() => testMutation.mutate("GIB")}
                  disabled={testMutation.isPending}
                >
                  Bağlantıyı Test Et
                </Button>
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardHeader className="flex flex-row flex-wrap items-start justify-between gap-3">
              <div>
                <CardTitle>Özel Entegratör</CardTitle>
                <CardDescription>Anlaşmalı özel entegratör API bilgileriyle bağlantı.</CardDescription>
              </div>
              <StatusBadge status={settings?.integrator.status ?? "NOT_CONFIGURED"} />
            </CardHeader>
            <CardContent className="grid gap-4">
              <div className="flex items-center justify-between rounded-md border border-border p-3">
                <div>
                  <p className="text-sm font-medium">Özel entegratör kullan</p>
                  <p className="text-xs text-muted-foreground">Kapalıyken bu bağlantı kullanılmaz.</p>
                </div>
                <Switch
                  checked={intForm.enabled}
                  onCheckedChange={(checked) => setIntForm((f) => ({ ...f, enabled: checked }))}
                />
              </div>

              <div className="grid gap-4 md:grid-cols-2">
                <div className="grid gap-2">
                  <Label>Entegratör</Label>
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
                  <Label>Servis Adresi (URL)</Label>
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
                    placeholder="api_kullanici"
                  />
                </div>
                <div className="grid gap-2">
                  <Label>API Anahtarı / Şifre</Label>
                  <Input
                    type="password"
                    value={intForm.apiKey}
                    onChange={(e) => setIntForm((f) => ({ ...f, apiKey: e.target.value }))}
                    placeholder={settings?.integrator.hasApiKey ? "•••••••• (kayıtlı)" : "API anahtarınızı girin"}
                  />
                </div>
              </div>

              {settings?.integrator.lastError ? (
                <p className="text-xs text-destructive">Son hata: {settings.integrator.lastError}</p>
              ) : null}
              {settings?.integrator.lastTestedAt ? (
                <p className="text-xs text-muted-foreground">
                  Son test: {new Date(settings.integrator.lastTestedAt).toLocaleString("tr-TR")}
                </p>
              ) : null}

              <div className="flex flex-wrap gap-2">
                <Button onClick={() => saveIntMutation.mutate()} disabled={saveIntMutation.isPending}>
                  {saveIntMutation.isPending ? <Loader2 className="size-4 animate-spin" /> : null}
                  Kaydet
                </Button>
                <Button
                  variant="outline"
                  onClick={() => testMutation.mutate("INTEGRATOR")}
                  disabled={testMutation.isPending}
                >
                  Bağlantıyı Test Et
                </Button>
              </div>
            </CardContent>
          </Card>

          <p className="flex items-center gap-2 text-xs text-muted-foreground">
            <ShieldCheck className="size-4" />
            Tüm kimlik bilgileri sunucu tarafında şifrelenerek saklanır; her işletmenin bilgileri yalnızca kendisine
            aittir ve başka kullanıcılar tarafından görüntülenemez.
          </p>
        </div>
      )}
    </AppShell>
  );
}
