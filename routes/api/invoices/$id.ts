import { createFileRoute } from "@tanstack/react-router";
import { getInvoiceById } from "../../../lib/invoice/repository.ts";

export const Route = createFileRoute("/api/invoices/$id")({
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
                  message: "Belirtilen ID veya UUID değerine ait fatura kaydı bulunamadı.",
                },
              },
              { status: 404 }
            );
          }

          // Ensure no passwords or SESSION_ID values are exposed
          const safeInvoice = {
            id: invoice.id,
            ettn: invoice.ettn,
            uuid: invoice.ettn,
            invoiceNumber: invoice.invoice_number,
            type: invoice.type,
            status: invoice.status,
            edmStatus: invoice.edm_status,
            edmReturnCode: invoice.edm_return_code,
            edmReturnMessage: invoice.edm_return_message,
            provider: invoice.provider || "EDM",
            providerReference: invoice.provider_reference || invoice.trx_id,
            trxId: invoice.trx_id,
            invoiceDate: invoice.invoice_date,
            currency: invoice.currency,
            seller: {
              taxNumber: invoice.seller_tax_number,
              name: invoice.seller_name,
            },
            buyer: {
              taxNumber: invoice.buyer_tax_number,
              name: invoice.buyer_name,
              details: invoice.customer,
            },
            items: invoice.items,
            subtotal: invoice.subtotal,
            totalVat: invoice.total_vat,
            grandTotal: invoice.grand_total,
            notes: invoice.notes,
            sentAt: invoice.sent_at,
            processedAt: invoice.processed_at,
            createdAt: invoice.created_at,
            updatedAt: invoice.updated_at,
            errorCode: invoice.error_code,
            errorMessage: invoice.error_message,
          };

          return Response.json({
            success: true,
            message: "Fatura detayları getirildi.",
            data: safeInvoice,
            error: null,
          });
        } catch (error: unknown) {
          const message =
            error instanceof Error ? error.message : "Fatura detayı alınırken bir hata oluştu.";
          return Response.json(
            {
              success: false,
              message,
              data: null,
              error: {
                code: "GET_DETAIL_ERROR",
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
