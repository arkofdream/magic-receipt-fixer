import { createFileRoute } from "@tanstack/react-router";
import { getInvoiceById, updateInvoiceResultRecord } from "../../../lib/invoice/repository.ts";
import { getEInvoiceProvider } from "../../../lib/einvoice/provider.ts";

export const Route = createFileRoute("/api/invoices/$id/status")({
  server: {
    handlers: {
      GET: async ({ params }) => {
        try {
          const id = params.id;
          const invoice = await getInvoiceById(id);

          if (!invoice) {
            return Response.json(
              {
                success: false,
                message: `Fatura bulunamadı ("${id}").`,
                data: null,
                error: {
                  code: "NOT_FOUND",
                  message: "Durumu sorgulanmak istenen fatura veritabanında bulunamadı.",
                },
              },
              { status: 404 }
            );
          }

          const cleanEttn = (invoice.ettn || "").trim().toLowerCase();

          if (!cleanEttn) {
            return Response.json(
              {
                success: false,
                message: "Bu faturaya ait geçerli bir UUID/ETTN bulunmuyor.",
                data: null,
                error: {
                  code: "INVALID_ETTN",
                  message: "Entegratör durum sorgulaması için ETTN zorunludur.",
                },
              },
              { status: 400 }
            );
          }

          const provider = getEInvoiceProvider(invoice.provider || "EDM");
          const statusResult = await provider.getInvoiceStatus(cleanEttn);

          if (statusResult.success) {
            await updateInvoiceResultRecord(cleanEttn, {
              success: statusResult.status !== "FAILED",
              message: statusResult.message,
              invoiceNumber: statusResult.invoiceNumber || invoice.invoice_number,
              uuid: cleanEttn,
              edmReference: invoice.provider_reference || invoice.trx_id,
              status: statusResult.status || "PROCESSING",
            });
          }

          const updatedInvoice = await getInvoiceById(invoice.id || cleanEttn);

          return Response.json({
            success: statusResult.success,
            message: statusResult.message,
            data: {
              id: updatedInvoice?.id || invoice.id,
              ettn: updatedInvoice?.ettn || invoice.ettn,
              invoiceNumber: updatedInvoice?.invoice_number || invoice.invoice_number,
              status: updatedInvoice?.status || invoice.status,
              edmStatus: updatedInvoice?.edm_status || statusResult.data?.edmStatus,
              edmReturnCode: updatedInvoice?.edm_return_code || statusResult.data?.edmReturnCode,
              edmReturnMessage: updatedInvoice?.edm_return_message || statusResult.data?.edmReturnMessage,
              providerReference: updatedInvoice?.provider_reference || updatedInvoice?.trx_id,
              updatedAt: updatedInvoice?.updated_at,
            },
            error: statusResult.error || null,
          });
        } catch (error: unknown) {
          const message =
            error instanceof Error ? error.message : "Fatura durumu sorgulanırken bir sunucu hatası oluştu.";
          return Response.json(
            {
              success: false,
              message,
              data: null,
              error: {
                code: "STATUS_QUERY_ERROR",
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
