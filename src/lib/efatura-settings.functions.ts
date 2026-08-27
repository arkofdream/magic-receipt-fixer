import { z } from "zod";
import { createServerFn } from "@tanstack/react-start";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import type { ConnectionSettingsView } from "@/lib/efatura/settings.server";

const gibSchema = z.object({
  enabled: z.boolean(),
  environment: z.enum(["TEST", "PROD"]),
  username: z.string().trim().min(1, "GİB kullanıcı kodu zorunludur."),
  password: z.string().trim().optional(),
});

const integratorSchema = z.object({
  enabled: z.boolean(),
  provider: z.string().trim().min(1, "Sağlayıcı seçimi zorunludur."),
  baseUrl: z
    .string()
    .trim()
    .min(1, "Servis adresi zorunludur.")
    .url("Geçerli bir URL girmelisiniz (örn: https://apitest.nes.com.tr)."),
  apiUsername: z.string().trim().optional().default(""),
  apiKey: z.string().trim().optional(),
  senderAlias: z.string().trim().optional().default(""),
});

const activeProviderSchema = z.object({
  activeProvider: z.enum(["NONE", "GIB", "INTEGRATOR"]),
});

const testSchema = z.object({
  provider: z.enum(["GIB", "INTEGRATOR"]),
  apiKey: z.string().trim().optional(),
  baseUrl: z.string().trim().optional(),
  apiUsername: z.string().trim().optional(),
  integratorName: z.string().trim().optional(),
});

export const getConnectionSettings = createServerFn({ method: "GET" })
  .middleware([requireSupabaseAuth])
  .handler(async ({ context }): Promise<ConnectionSettingsView> => {
    const { loadSettings, toView } = await import("@/lib/efatura/settings.server");
    return toView(await loadSettings(context.userId, context.supabase));
  });

export const saveGibSettings = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: unknown) => gibSchema.parse(data))
  .handler(async ({ data, context }): Promise<ConnectionSettingsView> => {
    const { saveGib } = await import("@/lib/efatura/settings.server");
    return saveGib(context.userId, data, context.supabase);
  });

export const saveIntegratorSettings = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: unknown) => integratorSchema.parse(data))
  .handler(async ({ data, context }): Promise<ConnectionSettingsView> => {
    const { saveIntegrator } = await import("@/lib/efatura/settings.server");
    return saveIntegrator(context.userId, data, context.supabase);
  });

export const setActiveProvider = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: unknown) => activeProviderSchema.parse(data))
  .handler(async ({ data, context }): Promise<ConnectionSettingsView> => {
    const { setActive } = await import("@/lib/efatura/settings.server");
    return setActive(context.userId, data.activeProvider, context.supabase);
  });

export const testConnection = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: unknown) => testSchema.parse(data))
  .handler(
    async ({
      data,
      context,
    }): Promise<{ ok: boolean; message: string; settings: ConnectionSettingsView }> => {
      const { runConnectionTest } = await import("@/lib/efatura/settings.server");
      return runConnectionTest(context.userId, data.provider, context.supabase, {
        apiKey: data.apiKey,
        baseUrl: data.baseUrl,
        apiUsername: data.apiUsername,
        integratorName: data.integratorName,
      });
    },
  );

const sendInvoiceSchema = z.object({
  ettn: z.string().optional(),
  invoiceNumber: z.string().optional(),
  customerName: z.string().optional(),
  customerTaxNumber: z.string().optional(),
  grandTotal: z.number().optional(),
  type: z.string().optional(),
  items: z.array(z.record(z.unknown())).optional(),
});

export const sendInvoiceToProvider = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: unknown) => sendInvoiceSchema.parse(data))
  .handler(async ({ data, context }) => {
    const { sendInvoiceToActiveProvider } = await import("@/lib/efatura/settings.server");
    return sendInvoiceToActiveProvider(context.userId, data, context.supabase);
  });
