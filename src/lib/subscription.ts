export type SubscriptionStatus =
  "ACTIVE" | "UPCOMING_EXPIRY" | "EXPIRED" | "SUSPENDED" | "CANCELLED";

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

export type AdminSubscriptionRow = SubscriptionView & {
  userId: string;
  email: string;
  companyTitle: string;
  storedStatus: SubscriptionStatus;
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

export function formatDate(value: string | null): string {
  if (!value) return "—";
  return new Date(value).toLocaleDateString("tr-TR", {
    day: "2-digit",
    month: "long",
    year: "numeric",
  });
}
