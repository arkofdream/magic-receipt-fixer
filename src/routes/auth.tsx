import { createFileRoute, useNavigate, Link } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { toast } from "sonner";

import { supabase } from "@/integrations/supabase/client";
import { Checkbox } from "@/components/ui/checkbox";
import { getCurrentLegalVersions, recordSignupConsents } from "@/lib/legal.functions";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";

export const Route = createFileRoute("/auth")({
  head: () => ({
    meta: [
      { title: "Giriş Yap | e-Fatura Portalı" },
      {
        name: "description",
        content: "e-Fatura Portalı'na e-posta veya Google hesabınızla giriş yapın, faturalarınızı yönetin.",
      },
      { property: "og:title", content: "Giriş Yap | e-Fatura Portalı" },
      {
        property: "og:description",
        content: "e-Fatura Portalı'na e-posta veya Google hesabınızla giriş yapın.",
      },
    ],
  }),
  component: AuthPage,
});

function AuthPage() {
  const navigate = useNavigate();
  const [loading, setLoading] = useState(false);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [company, setCompany] = useState("");
  const [pendingConfirm, setPendingConfirm] = useState(false);
  const [acceptTerms, setAcceptTerms] = useState(false);
  const [marketing, setMarketing] = useState(false);
  const [versions, setVersions] = useState({ membership_terms: "v1.0", kvkk_notice: "v1.0" });

  useEffect(() => {
    getCurrentLegalVersions().then(setVersions).catch(() => undefined);
  }, []);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      if (data.session) navigate({ to: "/dashboard", replace: true });
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_event, session) => {
      if (session) navigate({ to: "/dashboard", replace: true });
    });
    return () => sub.subscription.unsubscribe();
  }, [navigate]);

  async function signIn(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    setLoading(false);
    if (error) {
      toast.error(error.message);
      return;
    }
    navigate({ to: "/dashboard", replace: true });
  }

  async function signUp(e: React.FormEvent) {
    e.preventDefault();
    if (!acceptTerms) {
      toast.error("Kaydı tamamlamak için Üyelik ve Kullanım Sözleşmesi'ni kabul etmelisiniz.");
      return;
    }
    setLoading(true);
    const { data, error } = await supabase.auth.signUp({
      email,
      password,
      options: {
        emailRedirectTo: window.location.origin,
        data: {
          company_title: company,
          membership_terms_version: versions.membership_terms,
          kvkk_notice_version: versions.kvkk_notice,
          marketing_consent: marketing,
        },
      },
    });
    setLoading(false);
    if (error) {
      toast.error(error.message);
      return;
    }
    if (!data.session) {
      setPendingConfirm(true);
      toast.success("Hesabınızı doğrulamak için e-postanızı kontrol edin.");
      return;
    }
    try {
      await recordSignupConsents({
        data: {
          membershipTermsVersion: versions.membership_terms,
          kvkkVersion: versions.kvkk_notice,
          marketingConsent: marketing,
          userAgent: navigator.userAgent.slice(0, 400),
        },
      });
    } catch {
      toast.error("Onay kaydınız oluşturulamadı. Lütfen destek ile iletişime geçin.");
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-secondary px-4 py-10">
      <div className="w-full max-w-md">
        <Link to="/" className="mb-6 block text-center text-sm text-muted-foreground hover:text-foreground">
          ← Ana sayfaya dön
        </Link>
        <Card>
          <CardHeader className="text-center">
            <CardTitle className="text-2xl">e-Fatura Portalı</CardTitle>
            <CardDescription>GİB E-Fatura & E-Arşiv işlemleri için hesabınıza girin</CardDescription>
          </CardHeader>
          <CardContent>
            {pendingConfirm ? (
              <p className="rounded-md bg-accent p-4 text-sm text-accent-foreground">
                <strong>{email}</strong> adresine doğrulama bağlantısı gönderdik. Bağlantıya tıkladıktan
                sonra buradan giriş yapabilirsiniz.
              </p>
            ) : null}

            <Tabs defaultValue="signin">
              <TabsList className="grid w-full grid-cols-2">
                <TabsTrigger value="signin">Giriş Yap</TabsTrigger>
                <TabsTrigger value="signup">Kayıt Ol</TabsTrigger>
              </TabsList>

              <TabsContent value="signin">
                <form className="space-y-4 pt-4" onSubmit={signIn}>
                  <div className="space-y-2">
                    <Label htmlFor="email">E-posta</Label>
                    <Input
                      id="email"
                      type="email"
                      required
                      value={email}
                      onChange={(e) => setEmail(e.target.value)}
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="password">Şifre</Label>
                    <Input
                      id="password"
                      type="password"
                      required
                      value={password}
                      onChange={(e) => setPassword(e.target.value)}
                    />
                  </div>
                  <Button type="submit" className="w-full" disabled={loading}>
                    Giriş Yap
                  </Button>
                </form>
              </TabsContent>

              <TabsContent value="signup">
                <form className="space-y-4 pt-4" onSubmit={signUp}>
                  <div className="space-y-2">
                    <Label htmlFor="company">Firma Unvanı</Label>
                    <Input
                      id="company"
                      value={company}
                      onChange={(e) => setCompany(e.target.value)}
                      placeholder="Örnek Ticaret Ltd. Şti."
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="email-up">E-posta</Label>
                    <Input
                      id="email-up"
                      type="email"
                      required
                      value={email}
                      onChange={(e) => setEmail(e.target.value)}
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="password-up">Şifre</Label>
                    <Input
                      id="password-up"
                      type="password"
                      required
                      minLength={6}
                      value={password}
                      onChange={(e) => setPassword(e.target.value)}
                    />
                  </div>
                  <div className="space-y-3 rounded-md border border-border p-3">
                    <label className="flex items-start gap-3 text-sm leading-relaxed">
                      <Checkbox
                        className="mt-0.5 size-5"
                        checked={acceptTerms}
                        onCheckedChange={(c) => setAcceptTerms(c === true)}
                      />
                      <span>
                        <Link to="/uyelik-sozlesmesi" target="_blank" className="font-medium underline">
                          Üyelik ve Kullanım Sözleşmesi
                        </Link>
                        'ni okudum ve kabul ediyorum. Kişisel verilerime ilişkin{" "}
                        <Link to="/kvkk-aydinlatma" target="_blank" className="font-medium underline">
                          KVKK Aydınlatma Metni
                        </Link>
                        'ni okudum.
                      </span>
                    </label>
                    <label className="flex items-start gap-3 text-sm leading-relaxed">
                      <Checkbox
                        className="mt-0.5 size-5"
                        checked={marketing}
                        onCheckedChange={(c) => setMarketing(c === true)}
                      />
                      <span>
                        Kampanya, duyuru ve fırsatlardan haberdar olmak istiyorum. (İsteğe bağlı)
                      </span>
                    </label>
                  </div>
                  <Button type="submit" className="w-full" disabled={loading || !acceptTerms}>
                    Hesap Oluştur
                  </Button>
                </form>
              </TabsContent>
            </Tabs>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
