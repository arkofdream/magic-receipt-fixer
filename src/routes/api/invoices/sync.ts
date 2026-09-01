import { createFileRoute } from "@tanstack/react-router";
import { getPendingOrProcessingInvoices, updateInvoiceResultRecord } from "../../../lib/invoice/repository.ts";
import { getEInvoiceProvider } from "../../../lib/einvoice/provider.ts";
import { requireApiUser, authErrorResponse } from "../../../lib/api-auth.server.ts";

export const Route = createFileRoute("/api/invoices/sync")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        try {
          const { userId } = await requireApiUser(request);
          // Fetch active invoices needing status update
          const activeInvoices = await getPendingOrProcessingInvoices(userId, 20);

          if (activeInvoices.length === 0) {
            return Response.json({
              success: true,
              message: "Senkronize edilecek işlenen (PROCESSING/SENT) fatura bulunmuyor.",
              data: {
                processedCount: 0,
                updatedCount: 0,
                items: [],
              },
              error: null,
            });
          }

          let updatedCount = 0;
          const syncResults = [];

          for (const inv of activeInvoices) {
            if (!inv.ettn) continue;

            try {
              const provider = getEInvoiceProvider(inv.provider || "EDM");
              const statusResult = await provider.getInvoiceStatus(inv.ettn);

              if (statusResult.success) {
                await updateInvoiceResultRecord(inv.ettn, {
                  success: statusResult.status !== "FAILED",
                  message: statusResult.message,
                  invoiceNumber: statusResult.invoiceNumber || inv.invoice_number,
                  uuid: inv.ettn,
                  edmReference: inv.provider_reference || inv.trx_id,
                  status: statusResult.status || "SENT",
                }, userId);

                updatedCount++;
                syncResults.push({
                  ettn: inv.ettn,
                  invoiceNumber: inv.invoice_number,
                  previousStatus: inv.status,
                  newStatus: statusResult.status,
                  edmStatus: statusResult.data?.edmStatus,
                });
              }
            } catch (singleErr: any) {
              console.warn(`[InvoiceSync] Fatura ${inv.ettn} status sync hatası:`, singleErr.message);
            }
          }

          return Response.json({
            success: true,
            message: `${activeInvoices.length} fatura incelendi, ${updatedCount} faturanın EDM durumu güncellendi.`,
            data: {
              processedCount: activeInvoices.length,
              updatedCount,
              items: syncResults,
            },
            error: null,
          });
        } catch (error: unknown) {
          const authRes = authErrorResponse(error);
          if (authRes) return authRes;
          const message =
            error instanceof Error ? error.message : "Toplu durum senkronizasyonunda hata oluştu.";
          return Response.json(
            {
              success: false,
              message,
              data: null,
              error: {
                code: "BATCH_SYNC_ERROR",
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
