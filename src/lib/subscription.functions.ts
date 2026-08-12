import { createServerFn } from "@tanstack/react-start";

import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";

export type SubscriptionStatus =
  | "ACTIVE"
  | "UPCOMING_EXPIRY"
  | "EXPIRED"
  | "SUSPENDED"
  | "CANCELLED";

export type SubscriptionView = {
  plan: string;
  status: SubscriptionStatus;
  startDate: string;
  endDate: string;
  renewalPrice: number | null;
  lastPaymentDate: string | null;
  daysRemaining: number;
  isPaidAccessAllowed: boolean;
};

export function daysBetween(endDate: string): number {
  const end = new Date(`${endDate}T00:00:00Z`).getTime();
  const today = new Date();
  const start = Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate());
  return Math.round((end - start) / 86_400_000);
}

/** Derives the effective status: a stored ACTIVE row whose period has ended is EXPIRED. */
export function effectiveStatus(stored: SubscriptionStatus, endDate: string): SubscriptionStatus {
  if (stored === "SUSPENDED" || stored === "CANCELLED") return stored;
  const remaining = daysBetween(endDate);
  if (remaining < 0) return "EXPIRED";
  if (remaining <= 30) return "UPCOMING_EXPIRY";
  return "ACTIVE";
}

export const STATUS_LABELS: Record<SubscriptionStatus, string> = {
  ACTIVE: "Aktif",
  UPCOMING_EXPIRY: "Yakında sona eriyor",
  EXPIRED: "Süresi doldu",
  SUSPENDED: "Askıya alındı",
  CANCELLED: "İptal edildi",
};

export const PLAN_LABELS: Record<string, string> = {
  TRIAL: "Deneme",
  MONTHLY: "Aylık",
  YEARLY: "Yıllık",
};

/** Subscription of the signed-in user only (user id comes from the bearer token). */
export const getMySubscription = createServerFn({ method: "GET" })
  .middleware([requireSupabaseAuth])
  .handler(async ({ context }): Promise<SubscriptionView | null> => {
    const { data, error } = await context.supabase
      .from("subscriptions")
      .select("plan, status, start_date, end_date, renewal_price, last_payment_date")
      .eq("user_id", context.userId)
      .maybeSingle();
    if (error) throw new Error(error.message);
    if (!data) return null;

    const status = effectiveStatus(data.status as SubscriptionStatus, data.end_date);
    return {
      plan: data.plan,
      status,
      startDate: data.start_date,
      endDate: data.end_date,
      renewalPrice: data.renewal_price,
      lastPaymentDate: data.last_payment_date,
      daysRemaining: daysBetween(data.end_date),
      isPaidAccessAllowed: status === "ACTIVE" || status === "UPCOMING_EXPIRY",
    };
  });

/** Whether the signed-in user has the admin role. */
export const getMyAccountFlags = createServerFn({ method: "GET" })
  .middleware([requireSupabaseAuth])
  .handler(async ({ context }) => {
    const { data, error } = await context.supabase
      .from("user_roles")
      .select("role")
      .eq("user_id", context.userId);
    if (error) throw new Error(error.message);
    return { isAdmin: (data ?? []).some((r) => r.role === "admin") };
  });
