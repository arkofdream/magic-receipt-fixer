import { createFileRoute } from "@tanstack/react-router";
import { validateAndCalculateInvoice, createUblTrInvoice, type UblInvoiceData } from "../../../lib/ubl.ts";
import { createPendingInvoiceRecord } from "../../../lib/invoice/repository.ts";

export const Route = createFileRoute("/api/invoices/draft")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        try {
          const body = await request.json().catch(() => null);
          const rawInvoiceData: UblInvoiceData = body?.invoice || body;

          if (!rawInvoiceData || typeof rawInvoiceData !== "object") {
            return Response.json(
              {
                success: false,
                message: "Geçersiz istek: Fatura verisi (invoice) bulunamadı.",
                data: null,
                error: {
                  code: "INVALID_PAYLOAD",
                  message: "Fatura nesnesi sunucuya ulaştırılmadı.",
                },
              },
              { status: 400 }
            );
          }

          const validatedData = validateAndCalculateInvoice(rawInvoiceData);
          const rawUblXml = createUblTrInvoice(validatedData);

          // Save as DRAFT in repository (with allowTestFallback: true)
          const record = await createPendingInvoiceRecord(
            validatedData,
            rawUblXml,
            "00000000-0000-0000-0000-000000000000",
            "EDM",
            true
          );

          return Response.json({
            success: true,
            message: "Fatura başarıyla taslak olarak kaydedildi.",
            invoiceNumber: record.invoiceNumber,
            uuid: record.ettn,
            status: "DRAFT",
            data: record,
            error: null,
          });
        } catch (error: unknown) {
          const message =
            error instanceof Error ? error.message : "Taslak kaydedilirken bir hata oluştu.";
          return Response.json(
            {
              success: false,
              message: `Taslak kayıt hatası: ${message}`,
              data: null,
              error: {
                code: "DRAFT_SAVE_ERROR",
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
