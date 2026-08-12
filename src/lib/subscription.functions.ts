import { createServerFn } from "@tanstack/react-start";

import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import { daysBetween, effectiveStatus, type SubscriptionStatus, type SubscriptionView } from "@/lib/subscription";

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
