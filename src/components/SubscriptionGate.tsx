import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { useServerFn } from "@tanstack/react-start";
import { AlertTriangle } from "lucide-react";
import type { ReactNode } from "react";

import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { getMySubscription } from "@/lib/subscription.functions";
import { STATUS_LABELS, formatDate } from "@/lib/subscription";

export function useMySubscription() {
  const fetchSubscription = useServerFn(getMySubscription);
  return useQuery({
    queryKey: ["my-subscription"],
    queryFn: () => fetchSubscription(),
    staleTime: 60_000,
  });
}

/** Non-blocking reminder shown when the subscription is close to its end date. */
export function SubscriptionNotice() {
  const { data } = useMySubscription();
  if (!data) return null;
  if (data.status === "ACTIVE") return null;

  const expired = !data.isPaidAccessAllowed;
  return (
    <div
      className={`flex flex-col gap-2 border-b px-4 py-3 text-sm sm:flex-row sm:items-center sm:justify-between sm:px-6 ${
        expired
          ? "border-destructive/30 bg-destructive/10 text-destructive"
          : "border-border bg-accent text-accent-foreground"
      }`}
    >
      <span>
        {expired
          ? "Aboneliğiniz sona ermiştir. Hizmeti kullanmaya devam etmek için aboneliğinizi yenileyin."
          : `Aboneliğiniz ${formatDate(data.endDate)} tarihinde sona eriyor (${data.daysRemaining} gün kaldı).`}
      </span>
      <Button asChild size="sm" variant={expired ? "destructive" : "outline"} className="w-full sm:w-auto">
        <Link to="/abonelik">Aboneliğimi Yenile</Link>
      </Button>
    </div>
  );
}

/** Blocks paid features when the subscription period is not valid. Data is never deleted. */
export function PaidFeatureGate({ children }: { children: ReactNode }) {
  const { data, isLoading } = useMySubscription();

  if (isLoading) {
    return <p className="text-sm text-muted-foreground">Abonelik durumu kontrol ediliyor…</p>;
  }
  if (data && data.isPaidAccessAllowed) return <>{children}</>;

  return (
    <Card className="mx-auto max-w-xl">
      <CardContent className="space-y-4 p-6 text-center">
        <AlertTriangle className="mx-auto size-8 text-destructive" />
        <h2 className="text-lg font-semibold">Bu özellik için aktif abonelik gerekiyor</h2>
        <p className="text-sm text-muted-foreground">
          {data
            ? `Abonelik durumunuz: ${STATUS_LABELS[data.status]}. Kayıtlı verileriniz silinmez; yeniden aktif olduğunuzda kaldığınız yerden devam edersiniz.`
            : "Hesabınıza tanımlı bir abonelik bulunamadı."}
        </p>
        <Button asChild className="w-full sm:w-auto">
          <Link to="/abonelik">Abonelik Detayları</Link>
        </Button>
      </CardContent>
    </Card>
  );
}
