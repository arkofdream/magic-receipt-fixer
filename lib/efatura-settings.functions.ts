import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";

import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";

export type ConnectionStatus = "NOT_CONFIGURED" | "CONNECTED" | "FAILED";
export type ActiveProvider = "NONE" | "GIB" | "INTEGRATOR";

export type ConnectionSettingsView = {
  activeProvider: ActiveProvider;
  gib: {
    enabled: boolean;
    environment: string;
    username: string;
    hasPassword: boolean;
    status: ConnectionStatus;
    lastTestedAt: string | null;
    lastError: string;
  };
  integrator: {
    enabled: boolean;
    provider: string;
    baseUrl: string;
    apiUsername: string;
    hasApiKey: boolean;
    status: ConnectionStatus;
    lastTestedAt: string | null;
    lastError: string;
  };
};

const gibSchema = z.object({
  enabled: z.boolean(),
  environment: z.enum(["TEST", "PROD"]),
  username: z.string().trim().max(120),
  password: z.string().max(400).optional(),
});

const integratorSchema = z.object({
  enabled: z.boolean(),
  provider: z.string().trim().max(80),
  baseUrl: z.string().trim().max(300),
  apiUsername: z.string().trim().max(120).optional().default(""),
  apiKey: z.string().max(400).optional(),
});

const activeProviderSchema = z.object({ activeProvider: z.enum(["NONE", "GIB", "INTEGRATOR"]) });
const testSchema = z.object({ provider: z.enum(["GIB", "INTEGRATOR"]) });

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
      return runConnectionTest(context.userId, data.provider, context.supabase);
    },
  );
