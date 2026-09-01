import { createFileRoute } from "@tanstack/react-router";
import { getInvoiceById } from "../../../lib/invoice/repository.ts";
import { requireApiUser, authErrorResponse } from "../../../lib/api-auth.server.ts";

export const Route = createFileRoute("/api/invoices/$id")({
  server: {
    handlers: {
      GET: async ({ params, request }) => {
        try {
          const { userId } = await requireApiUser(request);
          const id = params.id;
          const invoice = await getInvoiceById(id, userId);

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

          const customerData = invoice.customer || {};
          const buyerTitle = invoice.buyer_name || customerData.title || customerData.name || "Alıcı Müşteri";
          const buyerTaxNo = invoice.buyer_tax_number || customerData.vkn_tckn || customerData.tax_number || customerData.tckn || "-";

          const safeInvoice = {
            id: invoice.id,
            ettn: invoice.ettn,
            uuid: invoice.ettn,
            invoiceNumber: invoice.invoice_number,
            invoice_number: invoice.invoice_number,
            type: invoice.type,
            status: invoice.status,
            edmStatus: invoice.edm_status,
            edmReturnCode: invoice.edm_return_code,
            edmReturnMessage: invoice.edm_return_message,
            provider: invoice.provider || "EDM",
            providerReference: invoice.provider_reference || invoice.trx_id,
            provider_reference: invoice.provider_reference || invoice.trx_id,
            trxId: invoice.trx_id,
            trx_id: invoice.trx_id,
            invoiceDate: invoice.invoice_date,
            invoice_date: invoice.invoice_date,
            currency: invoice.currency || "TRY",
            seller: {
              taxNumber: invoice.seller_tax_number || "3230512384",
              name: invoice.seller_name || "Fuat Ekiz Teknoloji A.Ş.",
            },
            seller_tax_number: invoice.seller_tax_number || "3230512384",
            seller_name: invoice.seller_name || "Fuat Ekiz Teknoloji A.Ş.",
            buyer: {
              taxNumber: buyerTaxNo,
              name: buyerTitle,
              details: customerData,
            },
            buyer_tax_number: buyerTaxNo,
            buyer_name: buyerTitle,
            customer: customerData,
            items: invoice.items || [],
            subtotal: invoice.subtotal || 0,
            totalVat: invoice.total_vat || 0,
            total_vat: invoice.total_vat || 0,
            grandTotal: invoice.grand_total || 0,
            grand_total: invoice.grand_total || 0,
            notes: invoice.notes || "",
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
          const authRes = authErrorResponse(error);
          if (authRes) return authRes;
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
