import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";

import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";

export type CompanyProfile = {
  id: string;
  companyTitle: string;
  vknTckn: string;
  taxOffice: string;
  address: string;
  city?: string;
  district?: string;
  neighborhood?: string;
  phone: string;
  email: string;
};

const profileSchema = z.object({
  companyTitle: z.string().trim().max(200),
  vknTckn: z.string().trim().max(20),
  taxOffice: z.string().trim().max(100),
  address: z.string().trim().max(500),
  phone: z.string().trim().max(30),
  email: z.string().trim().max(100),
});

export const getMyCompanyProfile = createServerFn({ method: "GET" })
  .middleware([requireSupabaseAuth])
  .handler(async ({ context }): Promise<CompanyProfile | null> => {
    const { data, error } = await context.supabase
      .from("profiles")
      .select("id, company_title, vkn_tckn, tax_office, address, phone, email")
      .eq("id", context.userId)
      .maybeSingle();

    if (error) throw new Error(error.message);
    if (!data) return null;

    return {
      id: data.id,
      companyTitle: data.company_title || "",
      vknTckn: data.vknTckn || "",
      taxOffice: data.tax_office || "",
      address: data.address || "",
      phone: data.phone || "",
      email: data.email || "",
    };
  });

export const updateMyCompanyProfile = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: unknown) => profileSchema.parse(data))
  .handler(async ({ data, context }): Promise<CompanyProfile> => {
    const { data: updated, error } = await context.supabase
      .from("profiles")
      .update({
        company_title: data.companyTitle,
        vkn_tckn: data.vknTckn,
        tax_office: data.taxOffice,
        address: data.address,
        phone: data.phone,
        email: data.email,
      })
      .eq("id", context.userId)
      .select("id, company_title, vkn_tckn, tax_office, address, phone, email")
      .single();

    if (error) throw new Error(error.message);

    return {
      id: updated.id,
      companyTitle: updated.company_title || "",
      vknTckn: updated.vkn_tckn || "",
      taxOffice: updated.tax_office || "",
      address: updated.address || "",
      phone: updated.phone || "",
      email: updated.email || "",
    };
  });

export type TaxpayerVerificationResult = {
  ok: boolean;
  verified: boolean;
  title?: string;
  taxOffice?: string;
  isEInvoiceUser?: boolean;
  message: string;
  titleMismatchWarning?: string;
};

const verifyVknSchema = z.object({
  vknTckn: z.string().trim(),
  companyTitle: z.string().trim().optional(),
  companyType: z.string().trim().optional(),
});

export const verifyTaxpayerVkn = createServerFn({ method: "POST" })
  .inputValidator((data: unknown) => verifyVknSchema.parse(data))
  .handler(async ({ data }): Promise<TaxpayerVerificationResult> => {
    const { validateVknTckn } = await import("./validation");
    const cleanVkn = data.vknTckn.replace(/\D/g, "");

    // 1. Algorithmic and format validation
    const localCheck = validateVknTckn(cleanVkn);
    if (!localCheck.isValid) {
      return {
        ok: false,
        verified: false,
        message: `✕ VKN doğrulanamadı: ${localCheck.message || "Geçersiz VKN/TCKN formatı."}`,
      };
    }

    // 2. Official backend inquiry via NES API
    const baseUrl = "https://apitest.nes.com.tr";
    const testEndpoints = [
      `${baseUrl}/einvoice/v1/taxpayers/${cleanVkn}`,
      `${baseUrl}/einvoice/v1/users/${cleanVkn}`,
    ];

    let officialResult: { ok: boolean; data?: any; status?: number } = { ok: false };

    for (const endpoint of testEndpoints) {
      try {
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 6000);
        const res = await fetch(endpoint, {
          method: "GET",
          headers: { "Accept": "application/json" },
          signal: controller.signal,
        }).finally(() => clearTimeout(timeout));

        if (res.ok) {
          const contentType = res.headers.get("content-type") || "";
          const text = await res.text();
          if (contentType.includes("application/json") || text.trim().startsWith("{")) {
            const json = JSON.parse(text);
            if (json && (json.vkn || json.title || json.unvan || json.identifier || json.isEInvoiceUser !== undefined)) {
              officialResult = { ok: true, data: json, status: res.status };
              break;
            }
          }
        } else if (res.status === 404) {
          officialResult = { ok: false, status: 404 };
          break;
        }
      } catch {
        // Continue trying next endpoint or fall through
      }
    }

    // If NES API verified the taxpayer
    if (officialResult.ok && officialResult.data) {
      const verifiedTitle = (
        officialResult.data.title ||
        officialResult.data.unvan ||
        officialResult.data.name ||
        ""
      ).trim();
      const verifiedTaxOffice = (
        officialResult.data.taxOffice ||
        officialResult.data.vergiDairesi ||
        ""
      ).trim();
      const isEInvoiceUser = Boolean(officialResult.data.isEInvoiceUser ?? officialResult.data.isEInvoice);

      let titleMismatchWarning: string | undefined;
      if (data.companyTitle && verifiedTitle) {
        const normUser = data.companyTitle.toLocaleLowerCase("tr").replace(/[^a-z0-9]/g, "");
        const normOfficial = verifiedTitle.toLocaleLowerCase("tr").replace(/[^a-z0-9]/g, "");
        if (normUser && normOfficial && !normOfficial.includes(normUser) && !normUser.includes(normOfficial)) {
          titleMismatchWarning = `Girilen firma adı ("${data.companyTitle}") ile doğrulanmış resmi unvan ("${verifiedTitle}") arasında uyuşmazlık var.`;
        }
      }

      return {
        ok: true,
        verified: true,
        title: verifiedTitle || undefined,
        taxOffice: verifiedTaxOffice || undefined,
        isEInvoiceUser,
        message: "✓ VKN doğrulandı. Bu VKN kayıtlı bir mükellefe aittir.",
        titleMismatchWarning,
      };
    }

    // If NES returned 404 / taxpayer not found
    if (officialResult.status === 404) {
      return {
        ok: false,
        verified: false,
        message: "✕ VKN doğrulanamadı. Girilen VKN ile eşleşen kayıtlı bir mükellef bulunamadı veya mükellef bilgisi doğrulanamadı.",
      };
    }

    // If official API could not be reached / no response
    return {
      ok: false,
      verified: false,
      message: "✕ Mükellef doğrulaması yapılamadı. Resmi NES/GİB servisine erişilemiyor veya yetki gerektiriyor.",
    };
  });
