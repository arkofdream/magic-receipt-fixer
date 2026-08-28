import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";

import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";

const periodParamsSchema = z.object({
  year: z.number().int().min(2000).max(2100),
  month: z.number().int().min(1).max(12),
});

export type ClosePeriodResult = {
  ok: boolean;
  periodId?: string;
  year?: number;
  month?: number;
  status?: string;
  isAlreadyClosed?: boolean;
  message?: string;
  error?: string;
};

/**
 * Muhasebe Dönemi Kapatma Server Function (TanStack Start + Supabase Auth)
 */
export const closeAccountingPeriodServerFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: unknown) => periodParamsSchema.parse(data))
  .handler(async ({ data, context }): Promise<ClosePeriodResult> => {
    const { year, month } = data;

    const { data: rpcRes, error } = await context.supabase.rpc("close_accounting_period", {
      p_year: year,
      p_month: month,
    });

    if (error) {
      console.error(`[CLOSE_PERIOD_ERROR] ${year}/${month}:`, error);
      const rawMsg = error.message || "";
      let userFriendlyMsg = rawMsg;

      if (
        rawMsg.includes("permission denied") ||
        rawMsg.includes("yetki") ||
        rawMsg.includes("42501")
      ) {
        userFriendlyMsg =
          "Dönem kapatma yetkiniz bulunmamaktadır. Lütfen yönetici hesabıyla işlem yapın.";
      } else if (rawMsg.includes("kritik muhasebe/mutabakat hatası")) {
        userFriendlyMsg = rawMsg;
      } else if (rawMsg.includes("kilitlidir")) {
        userFriendlyMsg = "Bu dönem kilitlidir (LOCKED) ve yeniden kapatılamaz.";
      }

      return {
        ok: false,
        error: userFriendlyMsg,
      };
    }

    const resObj =
      typeof rpcRes === "object" && rpcRes !== null ? (rpcRes as Record<string, any>) : {};
    const isAlreadyClosed = resObj.message?.includes("zaten kapalı") || false;

    return {
      ok: true,
      periodId: resObj.period_id,
      year: resObj.period_year || year,
      month: resObj.period_month || month,
      status: resObj.status || "CLOSED",
      isAlreadyClosed,
      message: resObj.message || `${month}/${year} dönemi başarıyla kapatıldı.`,
    };
  });

/**
 * Muhasebe Dönemi Yeniden Açma Server Function
 */
export const reopenAccountingPeriodServerFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: unknown) => periodParamsSchema.parse(data))
  .handler(async ({ data, context }): Promise<ClosePeriodResult> => {
    const { year, month } = data;

    const { data: rpcRes, error } = await context.supabase.rpc("reopen_accounting_period", {
      p_year: year,
      p_month: month,
    });

    if (error) {
      console.error(`[REOPEN_PERIOD_ERROR] ${year}/${month}:`, error);
      const rawMsg = error.message || "";
      let userFriendlyMsg = rawMsg;

      if (
        rawMsg.includes("permission denied") ||
        rawMsg.includes("yetki") ||
        rawMsg.includes("42501")
      ) {
        userFriendlyMsg =
          "Dönem açma yetkiniz bulunmamaktadır. Lütfen yönetici hesabıyla işlem yapın.";
      }

      return {
        ok: false,
        error: userFriendlyMsg,
      };
    }

    const resObj =
      typeof rpcRes === "object" && rpcRes !== null ? (rpcRes as Record<string, any>) : {};

    return {
      ok: true,
      periodId: resObj.period_id,
      year: resObj.period_year || year,
      month: resObj.period_month || month,
      status: resObj.status || "OPEN",
      message: resObj.message || `${month}/${year} dönemi yeniden açıldı.`,
    };
  });
