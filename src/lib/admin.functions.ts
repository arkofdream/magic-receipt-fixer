import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";

import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import {
  daysBetween,
  effectiveStatus,
  type AdminSubscriptionRow,
  type SubscriptionStatus,
} from "@/lib/subscription";
import { assertAdmin, adminClient } from "@/lib/admin.server";

export type AdminLegalVersion = {
  id: string;
  docType: "membership_terms" | "kvkk_notice";
  version: string;
  title: string;
  content: string;
  publishedAt: string;
  isPublished: boolean;
  requiresReacceptance: boolean;
};

export type AdminAuditEntry = {
  id: string;
  action: string;
  targetUserId: string | null;
  details: Record<string, unknown>;
  createdAt: string;
};

export const adminListSubscriptions = createServerFn({ method: "GET" })
  .middleware([requireSupabaseAuth])
  .handler(async ({ context }): Promise<AdminSubscriptionRow[]> => {
    await assertAdmin(context.supabase, context.userId);
    const admin = await adminClient();

    const [{ data: subs, error }, { data: profiles }] = await Promise.all([
      admin
        .from("subscriptions")
        .select("user_id, plan, status, start_date, end_date, renewal_price, last_payment_date")
        .order("end_date", { ascending: true }),
      admin.from("profiles").select("id, email, company_title"),
    ]);
    if (error) throw new Error(error.message);

    return (subs ?? []).map((s) => {
      const profile = (profiles ?? []).find((p) => p.id === s.user_id);
      const status = effectiveStatus(s.status as SubscriptionStatus, s.end_date);
      return {
        userId: s.user_id,
        email: profile?.email ?? "",
        companyTitle: profile?.company_title ?? "",
        plan: s.plan,
        storedStatus: s.status as SubscriptionStatus,
        status,
        startDate: s.start_date,
        endDate: s.end_date,
        renewalPrice: s.renewal_price,
        lastPaymentDate: s.last_payment_date,
        daysRemaining: daysBetween(s.end_date),
        isPaidAccessAllowed: status === "ACTIVE" || status === "UPCOMING_EXPIRY",
      };
    });
  });

export const adminUpdateSubscription = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: unknown) =>
    z
      .object({
        targetUserId: z.string().uuid(),
        action: z.enum(["RENEW", "SUSPEND", "REACTIVATE", "CANCEL"]),
        period: z.enum(["1_MONTH", "1_YEAR"]).optional(),
        renewalPrice: z.number().min(0).max(1_000_000).nullable().optional(),
        paymentVerified: z.boolean().optional(),
      })
      .parse(data),
  )
  .handler(async ({ data, context }) => {
    await assertAdmin(context.supabase, context.userId);
    const admin = await adminClient();

    const { data: current, error: readError } = await admin
      .from("subscriptions")
      .select("plan, status, start_date, end_date, renewal_price, last_payment_date")
      .eq("user_id", data.targetUserId)
      .maybeSingle();
    if (readError) throw new Error(readError.message);
    if (!current) throw new Error("Abonelik kaydı bulunamadı.");

    const patch: Record<string, unknown> = {};
    const today = new Date();
    const todayIso = today.toISOString().slice(0, 10);

    if (data.action === "RENEW") {
      const period = data.period ?? "1_MONTH";
      const base = new Date(`${current.end_date}T00:00:00Z`);
      const from = base.getTime() >= Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate())
        ? base
        : new Date(`${todayIso}T00:00:00Z`);
      const next = new Date(from);
      if (period === "1_YEAR") next.setUTCFullYear(next.getUTCFullYear() + 1);
      else next.setUTCMonth(next.getUTCMonth() + 1);

      patch["plan"] = period === "1_YEAR" ? "YEARLY" : "MONTHLY";
      patch["status"] = "ACTIVE";
      patch["end_date"] = next.toISOString().slice(0, 10);
      if (current.status === "EXPIRED" || current.plan === "TRIAL") patch["start_date"] = todayIso;
      if (data.paymentVerified) patch["last_payment_date"] = todayIso;
      if (data.renewalPrice !== undefined) patch["renewal_price"] = data.renewalPrice;
    } else if (data.action === "SUSPEND") {
      patch["status"] = "SUSPENDED";
    } else if (data.action === "REACTIVATE") {
      patch["status"] = daysBetween(current.end_date) < 0 ? "EXPIRED" : "ACTIVE";
    } else {
      patch["status"] = "CANCELLED";
    }

    const { error: updateError } = await admin
      .from("subscriptions")
      .update(patch)
      .eq("user_id", data.targetUserId);
    if (updateError) throw new Error(updateError.message);

    await admin.from("admin_audit_log").insert({
      admin_user_id: context.userId,
      action: `SUBSCRIPTION_${data.action}`,
      target_user_id: data.targetUserId,
      details: { before: current, patch },
    });

    return { ok: true };
  });

export const adminListLegalVersions = createServerFn({ method: "GET" })
  .middleware([requireSupabaseAuth])
  .handler(async ({ context }): Promise<AdminLegalVersion[]> => {
    await assertAdmin(context.supabase, context.userId);
    const { data, error } = await context.supabase
      .from("legal_documents")
      .select("id, doc_type, version, title, content, published_at, is_published, requires_reacceptance")
      .order("published_at", { ascending: false });
    if (error) throw new Error(error.message);
    return (data ?? []).map((d) => ({
      id: d.id,
      docType: d.doc_type as AdminLegalVersion["docType"],
      version: d.version,
      title: d.title,
      content: d.content,
      publishedAt: d.published_at,
      isPublished: d.is_published,
      requiresReacceptance: d.requires_reacceptance,
    }));
  });

export const adminCreateLegalVersion = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: unknown) =>
    z
      .object({
        docType: z.enum(["membership_terms", "kvkk_notice"]),
        version: z.string().trim().min(1).max(20),
        title: z.string().trim().min(3).max(200),
        content: z.string().trim().min(50).max(200_000),
        requiresReacceptance: z.boolean().default(false),
      })
      .parse(data),
  )
  .handler(async ({ data, context }) => {
    await assertAdmin(context.supabase, context.userId);
    const { error } = await context.supabase.from("legal_documents").insert({
      doc_type: data.docType,
      version: data.version,
      title: data.title,
      content: data.content,
      requires_reacceptance: data.requiresReacceptance,
      created_by: context.userId,
    });
    if (error) throw new Error(error.message);

    const admin = await adminClient();
    await admin.from("admin_audit_log").insert({
      admin_user_id: context.userId,
      action: "LEGAL_VERSION_CREATED",
      details: { docType: data.docType, version: data.version },
    });
    return { ok: true };
  });

export const adminListConsents = createServerFn({ method: "GET" })
  .middleware([requireSupabaseAuth])
  .handler(async ({ context }) => {
    await assertAdmin(context.supabase, context.userId);
    const { data, error } = await context.supabase
      .from("user_consents")
      .select("id, user_id, consent_type, document_version, accepted, accepted_at")
      .order("accepted_at", { ascending: false })
      .limit(300);
    if (error) throw new Error(error.message);
    return data ?? [];
  });

export const adminListAuditLog = createServerFn({ method: "GET" })
  .middleware([requireSupabaseAuth])
  .handler(async ({ context }): Promise<AdminAuditEntry[]> => {
    await assertAdmin(context.supabase, context.userId);
    const { data, error } = await context.supabase
      .from("admin_audit_log")
      .select("id, action, target_user_id, details, created_at")
      .order("created_at", { ascending: false })
      .limit(100);
    if (error) throw new Error(error.message);
    return (data ?? []).map((e) => ({
      id: e.id,
      action: e.action,
      targetUserId: e.target_user_id,
      details: (e.details ?? {}) as Record<string, unknown>,
      createdAt: e.created_at,
    }));
  });
