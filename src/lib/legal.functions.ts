import { createServerFn } from "@tanstack/react-start";
import { createClient } from "@supabase/supabase-js";
import { z } from "zod";

import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import type { Database } from "@/integrations/supabase/types";

export type LegalDocType = "membership_terms" | "kvkk_notice";

export type LegalDocument = {
  id: string;
  docType: LegalDocType;
  version: string;
  title: string;
  content: string;
  publishedAt: string;
  requiresReacceptance: boolean;
};

export type ConsentRecord = {
  id: string;
  consentType: "membership_terms" | "kvkk_notice" | "marketing_consent";
  documentVersion: string;
  accepted: boolean;
  acceptedAt: string;
};

function publicClient() {
  return createClient<Database>(
    process.env["SUPABASE_URL"]!,
    process.env["SUPABASE_PUBLISHABLE_KEY"]!,
    { auth: { storage: undefined, persistSession: false, autoRefreshToken: false } },
  );
}

const docTypeSchema = z.object({
  docType: z.enum(["membership_terms", "kvkk_notice"]),
});

/** Public: latest published version of a legal document. */
export const getActiveLegalDocument = createServerFn({ method: "GET" })
  .inputValidator((data: unknown) => docTypeSchema.parse(data))
  .handler(async ({ data }): Promise<LegalDocument | null> => {
    const { data: rows, error } = await publicClient()
      .from("legal_documents")
      .select("id, doc_type, version, title, content, published_at, requires_reacceptance")
      .eq("doc_type", data.docType)
      .eq("is_published", true)
      .order("published_at", { ascending: false })
      .limit(1);

    if (error) throw new Error(error.message);
    const row = rows?.[0];
    if (!row) return null;
    return {
      id: row.id,
      docType: row.doc_type as LegalDocType,
      version: row.version,
      title: row.title,
      content: row.content,
      publishedAt: row.published_at,
      requiresReacceptance: row.requires_reacceptance,
    };
  });

/** Public: current versions of both documents, used by the signup form. */
export const getCurrentLegalVersions = createServerFn({ method: "GET" }).handler(async () => {
  const { data, error } = await publicClient()
    .from("legal_documents")
    .select("doc_type, version, published_at")
    .eq("is_published", true)
    .order("published_at", { ascending: false });

  if (error) throw new Error(error.message);
  const pick = (t: LegalDocType) => data?.find((d) => d.doc_type === t)?.version ?? "v1.0";
  return { membership_terms: pick("membership_terms"), kvkk_notice: pick("kvkk_notice") };
});

/**
 * Records the consents the user gave at signup. The user id always comes from the
 * validated bearer token, never from the client payload. Idempotent per version.
 */
export const recordSignupConsents = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: unknown) =>
    z
      .object({
        membershipTermsVersion: z.string().trim().min(1).max(20),
        kvkkVersion: z.string().trim().min(1).max(20),
        marketingConsent: z.boolean(),
        userAgent: z.string().max(400).default(""),
      })
      .parse(data),
  )
  .handler(async ({ data, context }) => {
    const { data: existing, error: readError } = await context.supabase
      .from("user_consents")
      .select("consent_type, document_version")
      .eq("user_id", context.userId);
    if (readError) throw new Error(readError.message);

    const has = (type: string, version: string) =>
      (existing ?? []).some((r) => r.consent_type === type && r.document_version === version);

    const rows: Database["public"]["Tables"]["user_consents"]["Insert"][] = [];
    if (!has("membership_terms", data.membershipTermsVersion)) {
      rows.push({
        user_id: context.userId,
        consent_type: "membership_terms",
        document_version: data.membershipTermsVersion,
        accepted: true,
        user_agent: data.userAgent,
      });
    }
    if (!has("kvkk_notice", data.kvkkVersion)) {
      rows.push({
        user_id: context.userId,
        consent_type: "kvkk_notice",
        document_version: data.kvkkVersion,
        accepted: true,
        user_agent: data.userAgent,
      });
    }
    if (!has("marketing_consent", data.membershipTermsVersion)) {
      rows.push({
        user_id: context.userId,
        consent_type: "marketing_consent",
        document_version: data.membershipTermsVersion,
        accepted: data.marketingConsent,
        user_agent: data.userAgent,
      });
    }

    if (rows.length > 0) {
      const { error } = await context.supabase.from("user_consents").insert(rows);
      if (error) throw new Error(error.message);
    }
    return { recorded: rows.length };
  });

/** The signed-in user's own consent history. */
export const getMyConsents = createServerFn({ method: "GET" })
  .middleware([requireSupabaseAuth])
  .handler(async ({ context }): Promise<ConsentRecord[]> => {
    const { data, error } = await context.supabase
      .from("user_consents")
      .select("id, consent_type, document_version, accepted, accepted_at")
      .eq("user_id", context.userId)
      .order("accepted_at", { ascending: false });
    if (error) throw new Error(error.message);
    return (data ?? []).map((r) => ({
      id: r.id,
      consentType: r.consent_type as ConsentRecord["consentType"],
      documentVersion: r.document_version,
      accepted: r.accepted,
      acceptedAt: r.accepted_at,
    }));
  });
