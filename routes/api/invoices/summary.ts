import { createFileRoute } from "@tanstack/react-router";
import { getInvoiceSummaryStats } from "../../../lib/invoice/repository.ts";

export const Route = createFileRoute("/api/invoices/summary")({
  server: {
    handlers: {
      GET: async () => {
        try {
          const stats = await getInvoiceSummaryStats();
          return Response.json({
            success: true,
            message: "Fatura özet istatistikleri başarıyla getirildi.",
            data: stats,
            error: null,
          });
        } catch (error: unknown) {
          const message =
            error instanceof Error ? error.message : "Özet istatistikler alınamadı.";
          return Response.json(
            {
              success: false,
              message,
              data: {
                total: 0,
                draft: 0,
                pending: 0,
                processing: 0,
                sent: 0,
                accepted: 0,
                failed: 0,
                rejected: 0,
              },
              error: {
                code: "SUMMARY_STATS_ERROR",
                message,
              },
            },
            { status: 500 }
          );
        }
      },
    },
  },
});
