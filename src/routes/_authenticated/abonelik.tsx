import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";

import { AppShell } from "@/components/AppShell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Separator } from "@/components/ui/separator";
import { getMyConsents } from "@/lib/legal.functions";
import { getMySubscription } from "@/lib/subscription.functions";
import { PLAN_LABELS, STATUS_LABELS, formatDate } from "@/lib/subscription";

export const Route = createFileRoute("/_authenticated/abonelik")({
  head: () => ({
    meta: [
      { title: "Aboneliğim, Sözleşmeler ve Onaylar | e-Fatura Portalı" },
      {
        name: "description",
        content:
          "Abonelik planınızı, başlangıç ve bitiş tarihlerinizi, yenileme ücretinizi ve kabul ettiğiniz sözleşme onaylarını görüntüleyin.",
      },
      { property: "og:title", content: "Aboneliğim ve Onaylarım" },
      { property: "og:description", content: "Abonelik durumu, yenileme bilgisi ve sözleşme onay kayıtları." },
    ],
  }),
  component: SubscriptionPage,
});

const CONSENT_LABELS: Record<string, string> = {
  membership_terms: "Üyelik ve Yazılım Hizmeti Kullanım Sözleşmesi",
  kvkk_notice: "KVKK Aydınlatma Metni",
  marketing_consent: "Pazarlama İzni",
};

function SubscriptionPage() {
  const fetchSubscription = useServerFn(getMySubscription);
  const fetchConsents = useServerFn(getMyConsents);

  const subscription = useQuery({ queryKey: ["my-subscription"], queryFn: () => fetchSubscription() });
  const consents = useQuery({ queryKey: ["my-consents"], queryFn: () => fetchConsents() });

  const sub = subscription.data;

  return (
    <AppShell title="Aboneliğim" subtitle="Abonelik durumunuz, yenileme bilgileri ve onay kayıtlarınız">
      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle className="flex flex-wrap items-center gap-2">
              Abonelik Bilgileri
              {sub ? (
                <Badge variant={sub.isPaidAccessAllowed ? "secondary" : "destructive"}>
                  {STATUS_LABELS[sub.status]}
                </Badge>
              ) : null}
            </CardTitle>
            <CardDescription>Bu bilgiler yalnızca sizin hesabınıza aittir.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3 text-sm">
            {subscription.isLoading ? (
              <p className="text-muted-foreground">Yükleniyor…</p>
            ) : !sub ? (
              <p className="text-muted-foreground">Hesabınıza tanımlı bir abonelik bulunamadı.</p>
            ) : (
              <>
                <Row label="Abonelik planı" value={PLAN_LABELS[sub.plan] ?? sub.plan} />
                <Row label="Başlangıç tarihi" value={formatDate(sub.startDate)} />
                <Row label="Bitiş tarihi" value={formatDate(sub.endDate)} />
                <Row label="Abonelik durumu" value={STATUS_LABELS[sub.status]} />
                <Row
                  label="Yenileme ücreti"
                  value={
                    sub.renewalPrice === null
                      ? "Yenileme ücreti için bizimle iletişime geçin"
                      : `${sub.renewalPrice.toLocaleString("tr-TR", { minimumFractionDigits: 2 })} TL`
                  }
                />
                <Row label="Son ödeme tarihi" value={formatDate(sub.lastPaymentDate)} />

                <Separator />
                {sub.isPaidAccessAllowed ? null : (
                  <p className="rounded-md bg-destructive/10 p-3 text-destructive">
                    Aboneliğiniz sona ermiştir. Hizmeti kullanmaya devam etmek için aboneliğinizi yenileyin.
                    Kayıtlı verileriniz silinmez.
                  </p>
                )}
                <div className="rounded-md bg-muted p-3 text-muted-foreground">
                  <p className="font-medium text-foreground">Aboneliğimi Yenile</p>
                  <p className="mt-1">
                    Platformda otomatik tahsilat bulunmamaktadır. Yenileme işlemi için bizimle iletişime
                    geçin: [E-POSTA] · [TELEFON]. Ödemeniz doğrulandıktan sonra aboneliğiniz yetkili
                    yönetici tarafından yenilenir.
                  </p>
                </div>
              </>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Sözleşmeler ve Onaylar</CardTitle>
            <CardDescription>Kabul ettiğiniz belgeler, versiyonları ve tarihleri</CardDescription>
          </CardHeader>
          <CardContent className="space-y-4 text-sm">
            <div className="flex flex-wrap gap-2">
              <Button asChild variant="outline" size="sm">
                <Link to="/uyelik-sozlesmesi">Üyelik Sözleşmesi</Link>
              </Button>
              <Button asChild variant="outline" size="sm">
                <Link to="/kvkk-aydinlatma">KVKK Aydınlatma Metni</Link>
              </Button>
            </div>
            <Separator />
            {consents.isLoading ? (
              <p className="text-muted-foreground">Yükleniyor…</p>
            ) : (consents.data ?? []).length === 0 ? (
              <p className="text-muted-foreground">Henüz kayıtlı bir onay bulunmuyor.</p>
            ) : (
              <ul className="space-y-3">
                {(consents.data ?? []).map((c) => (
                  <li key={c.id} className="rounded-md border border-border p-3">
                    <p className="font-medium text-foreground">
                      {CONSENT_LABELS[c.consentType] ?? c.consentType}
                    </p>
                    <p className="mt-1 text-muted-foreground">
                      Versiyon: {c.documentVersion} · Tarih: {formatDate(c.acceptedAt)}
                    </p>
                    <p className="text-muted-foreground">
                      Durum: {c.accepted ? "Verildi" : "Verilmedi"}
                    </p>
                  </li>
                ))}
              </ul>
            )}
          </CardContent>
        </Card>
      </div>
    </AppShell>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex flex-wrap justify-between gap-2 border-b border-border pb-2 last:border-0">
      <span className="text-muted-foreground">{label}</span>
      <span className="font-medium text-foreground">{value}</span>
    </div>
  );
}
