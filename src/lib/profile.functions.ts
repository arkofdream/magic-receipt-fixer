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
      vknTckn: data.vkn_tckn || "",
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
