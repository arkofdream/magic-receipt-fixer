import { createFileRoute, useNavigate, Link } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { Download, Building2, CheckCircle2, AlertCircle } from "lucide-react";
import { toast } from "sonner";

import { DESKTOP_DOWNLOAD_URL } from "@/lib/download";
import { supabase } from "@/integrations/supabase/client";
import { Checkbox } from "@/components/ui/checkbox";
import { getCurrentLegalVersions, recordSignupConsents } from "@/lib/legal.functions";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { validateVknTckn, validatePhone } from "@/lib/validation";

export const Route = createFileRoute("/auth")({
  head: () => ({
    meta: [
      { title: "Giriş Yap / Kayıt Ol | e-Fatura Portalı" },
      {
        name: "description",
        content: "e-Fatura Portalı'na kurumsal firma bilgilerinizle kayıt olun, e-Fatura ve ön muhasebenizi yönetin.",
      },
      { property: "og:title", content: "Giriş Yap / Kayıt Ol | e-Fatura Portalı" },
      {
        property: "og:description",
        content: "e-Fatura Portalı kurumsal giriş ve firma kayıt ekranı.",
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
  
  // Firma Kayıt Bilgileri
  const [companyTitle, setCompanyTitle] = useState("");
  const [vknTckn, setVknTckn] = useState("");
  const [taxOffice, setTaxOffice] = useState("");
  const [phone, setPhone] = useState("");
  const [address, setAddress] = useState("");

  const [pendingConfirm, setPendingConfirm] = useState(false);
  const [acceptTerms, setAcceptTerms] = useState(false);
  const [marketing, setMarketing] = useState(false);
  const [versions, setVersions] = useState({ membership_terms: "v1.1", kvkk_notice: "v1.0" });

  // Canlı VKN/TCKN doğrulama sonucu
  const vknValidation = vknTckn.trim().length >= 10 ? validateVknTckn(vknTckn) : null;

  useEffect(() => {
    getCurrentLegalVersions()
      .then(setVersions)
      .catch(() => undefined);
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

    const cleanCompany = companyTitle.trim();
    const cleanVkn = vknTckn.trim();
    const cleanTaxOffice = taxOffice.trim();
    const cleanAddress = address.trim();
    const cleanPhone = phone.trim();

    if (!cleanCompany || cleanCompany.length < 3) {
      toast.error("Lütfen geçerli bir resmi firma unvanı giriniz.");
      return;
    }

    const vknCheck = validateVknTckn(cleanVkn);
    if (!vknCheck.isValid) {
      toast.error(vknCheck.message || "Geçersiz VKN / TCKN. Gerçek firma vergi kimlik numarası girmelisiniz.");
      return;
    }

    if (!cleanTaxOffice) {
      toast.error("Lütfen bağlı olduğunuz Vergi Dairesini giriniz.");
      return;
    }

    if (!cleanAddress || cleanAddress.length < 5) {
      toast.error("Lütfen firmanızın tam yasal adresini giriniz.");
      return;
    }

    const phoneCheck = validatePhone(cleanPhone);
    if (!phoneCheck.isValid) {
      toast.error(phoneCheck.message || "Lütfen geçerli bir telefon numarası giriniz.");
      return;
    }

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
          company_title: cleanCompany,
          vkn_tckn: cleanVkn,
          tax_office: cleanTaxOffice,
          address: cleanAddress,
          phone: cleanPhone,
          membership_terms_version: versions.membership_terms,
          kvkk_notice_version: versions.kvkk_notice,
          marketing_consent: marketing,
        },
      },
    });

    if (error) {
      setLoading(false);
      toast.error(error.message);
      return;
    }

    // Kullanıcı anında oturum aldıysa profil tablosunu güncelle ve onay kaydet
    if (data.session) {
      try {
        await supabase.from("profiles").upsert({
          id: data.session.user.id,
          company_title: cleanCompany,
          vkn_tckn: cleanVkn,
          tax_office: cleanTaxOffice,
          address: cleanAddress,
          phone: cleanPhone,
          email: email,
        });

        await recordSignupConsents({
          data: {
            membershipTermsVersion: versions.membership_terms,
            kvkkVersion: versions.kvkk_notice,
            marketingConsent: marketing,
            userAgent: navigator.userAgent.slice(0, 400),
          },
        });
      } catch (err) {
        console.error("Profil güncelleme hatası:", err);
      }
      setLoading(false);
      toast.success("Firma kaydınız başarıyla tamamlandı.");
      navigate({ to: "/dashboard", replace: true });
      return;
    }

    setLoading(false);
    setPendingConfirm(true);
    toast.success("Firma kaydınız alındı. Hesabınızı doğrulamak için lütfen e-postanızı kontrol edin.");
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-secondary/50 px-4 py-10">
      <div className="w-full max-w-xl">
        <Link
          to="/"
          className="mb-6 block text-center text-sm text-muted-foreground hover:text-foreground"
        >
          ← Ana sayfaya dön
        </Link>
        <Card className="shadow-lg border-border">
          <CardHeader className="text-center pb-4">
            <div className="mx-auto mb-2 flex size-12 items-center justify-center rounded-xl bg-primary/10 text-primary">
              <Building2 className="size-6" />
            </div>
            <CardTitle className="text-2xl font-bold tracking-tight">e-Fatura & Ön Muhasebe</CardTitle>
            <CardDescription>
              Resmi firma bilgilerinizle güvenle giriş yapın veya işletmenizi kaydedin
            </CardDescription>
          </CardHeader>
          <CardContent>
            {pendingConfirm ? (
              <div className="mb-6 rounded-lg border border-primary/20 bg-primary/5 p-4 text-sm text-primary">
                <strong>{email}</strong> adresine doğrulama bağlantısı gönderdik. E-postanızdaki bağlantıya
                tıkladıktan sonra giriş yapabilirsiniz. Firma profiliniz otomatik olarak hazırlanmıştır.
              </div>
            ) : null}

            <Tabs defaultValue="signin">
              <TabsList className="grid w-full grid-cols-2 mb-4">
                <TabsTrigger value="signin">Giriş Yap</TabsTrigger>
                <TabsTrigger value="signup">Firma Kaydı Oluştur</TabsTrigger>
              </TabsList>

              <TabsContent value="signin">
                <form className="space-y-4 pt-1" onSubmit={signIn}>
                  <div className="space-y-2">
                    <Label htmlFor="email">Kayıtlı E-posta</Label>
                    <Input
                      id="email"
                      type="email"
                      required
                      placeholder="adiniz@sirketiniz.com"
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
                      placeholder="••••••••"
                      value={password}
                      onChange={(e) => setPassword(e.target.value)}
                    />
                  </div>
                  <Button type="submit" className="w-full" disabled={loading}>
                    {loading ? "Giriş Yapılıyor..." : "Giriş Yap"}
                  </Button>
                </form>
              </TabsContent>

              <TabsContent value="signup">
                <form className="space-y-4 pt-1" onSubmit={signUp}>
                  <div className="rounded-md bg-muted/60 p-3 text-xs text-muted-foreground">
                    <p className="font-medium text-foreground">Kurumsal Kayıt & Firma Doğrulaması</p>
                    <p className="mt-0.5">
                      GİB e-Fatura ve muhasebe mevzuatı gereği kayıtlar resmi firma bilgileriyle yapılmaktadır.
                      Girilen bilgiler otomatik olarak profilinize ve sözleşmenize işlenecektir.
                    </p>
                  </div>

                  <div className="space-y-2">
                    <Label htmlFor="company">Firma / Şirket Unvanı *</Label>
                    <Input
                      id="company"
                      required
                      value={companyTitle}
                      onChange={(e) => setCompanyTitle(e.target.value)}
                      placeholder="Örn: ABC Bilişim Danışmanlık San. ve Tic. Ltd. Şti."
                    />
                  </div>

                  <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
                    <div className="space-y-2">
                      <div className="flex items-center justify-between">
                        <Label htmlFor="vknTckn">VKN veya TCKN *</Label>
                        {vknValidation && (
                          <span
                            className={`flex items-center gap-1 text-[11px] font-medium ${
                              vknValidation.isValid ? "text-emerald-600" : "text-destructive"
                            }`}
                          >
                            {vknValidation.isValid ? (
                              <>
                                <CheckCircle2 className="size-3" /> {vknValidation.type} Doğrulandı
                              </>
                            ) : (
                              <>
                                <AlertCircle className="size-3" /> Geçersiz
                              </>
                            )}
                          </span>
                        )}
                      </div>
                      <Input
                        id="vknTckn"
                        required
                        maxLength={11}
                        value={vknTckn}
                        onChange={(e) => setVknTckn(e.target.value.replace(/\D/g, ""))}
                        placeholder="10 haneli VKN veya 11 haneli TCKN"
                      />
                    </div>

                    <div className="space-y-2">
                      <Label htmlFor="taxOffice">Vergi Dairesi *</Label>
                      <Input
                        id="taxOffice"
                        required
                        value={taxOffice}
                        onChange={(e) => setTaxOffice(e.target.value)}
                        placeholder="Örn: Beşiktaş Vergi Dairesi"
                      />
                    </div>
                  </div>

                  <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
                    <div className="space-y-2">
                      <Label htmlFor="phone">Firma / Yetkili Telefonu *</Label>
                      <Input
                        id="phone"
                        required
                        type="tel"
                        value={phone}
                        onChange={(e) => setPhone(e.target.value)}
                        placeholder="05XX XXX XX XX"
                      />
                    </div>

                    <div className="space-y-2">
                      <Label htmlFor="email-up">Yetkili E-posta *</Label>
                      <Input
                        id="email-up"
                        type="email"
                        required
                        value={email}
                        onChange={(e) => setEmail(e.target.value)}
                        placeholder="muhasebe@sirketiniz.com"
                      />
                    </div>
                  </div>

                  <div className="space-y-2">
                    <Label htmlFor="address">Firma Resmi Adresi *</Label>
                    <Textarea
                      id="address"
                      required
                      rows={2}
                      value={address}
                      onChange={(e) => setAddress(e.target.value)}
                      placeholder="Cadde, sokak, bina no, ilçe ve şehir bilgisi..."
                    />
                  </div>

                  <div className="space-y-2">
                    <Label htmlFor="password-up">Şifre Belirleyin * (En az 6 karakter)</Label>
                    <Input
                      id="password-up"
                      type="password"
                      required
                      minLength={6}
                      value={password}
                      onChange={(e) => setPassword(e.target.value)}
                      placeholder="••••••••"
                    />
                  </div>

                  <div className="space-y-3 rounded-lg border border-border bg-card p-3.5">
                    <label className="flex items-start gap-3 text-xs leading-relaxed cursor-pointer">
                      <Checkbox
                        className="mt-0.5 size-4"
                        checked={acceptTerms}
                        onCheckedChange={(c) => setAcceptTerms(c === true)}
                      />
                      <span>
                        <Link
                          to="/uyelik-sozlesmesi"
                          target="_blank"
                          className="font-medium text-primary underline hover:text-primary/80"
                        >
                          Üyelik ve Yazılım Hizmeti Kullanım Sözleşmesi
                        </Link>
                        'ni (Aylık 6.000 TL lisans ücreti ve taahhütsüz iptal şartları dahil) okudum ve kabul ediyorum.{" "}
                        <Link
                          to="/kvkk-aydinlatma"
                          target="_blank"
                          className="font-medium text-primary underline hover:text-primary/80"
                        >
                          KVKK Aydınlatma Metni
                        </Link>
                        'ni inceledim.
                      </span>
                    </label>

                    <label className="flex items-start gap-3 text-xs leading-relaxed cursor-pointer">
                      <Checkbox
                        className="mt-0.5 size-4"
                        checked={marketing}
                        onCheckedChange={(c) => setMarketing(c === true)}
                      />
                      <span className="text-muted-foreground">
                        Mevzuat güncellemeleri, kampanya ve yeni sürüm duyurularından haberdar olmak istiyorum. (İsteğe bağlı)
                      </span>
                    </label>
                  </div>

                  <Button
                    type="submit"
                    className="w-full font-medium"
                    disabled={loading || !acceptTerms}
                  >
                    {loading ? "Firma Kaydı Yapılıyor..." : "Firma Kaydını Tamamla"}
                  </Button>
                </form>
              </TabsContent>
            </Tabs>
          </CardContent>
        </Card>

        <div className="mt-4 rounded-lg border border-border bg-card/60 p-4 text-center">
          <p className="text-xs text-muted-foreground">
            Windows masaüstü uygulamasını bilgisayarınıza kurmak ister misiniz?
          </p>
          <Button asChild variant="outline" size="sm" className="mt-2.5 w-full gap-2">
            <a href={DESKTOP_DOWNLOAD_URL} target="_blank" rel="noopener noreferrer">
              <Download className="size-4" />
              Windows Masaüstü Sürümünü İndir (.exe)
            </a>
          </Button>
        </div>
      </div>
    </div>
  );
}
