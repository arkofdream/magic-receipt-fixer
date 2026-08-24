import { createFileRoute } from "@tanstack/react-router";
import { getInvoiceById } from "../../../lib/invoice/repository.ts";

export const Route = createFileRoute("/api/invoices/$id/xml")({
  server: {
    handlers: {
      GET: async ({ params }) => {
        try {
          const id = params.id;
          const invoice = await getInvoiceById(id);

          if (!invoice || !invoice.raw_ubl_xml) {
            return Response.json(
              {
                success: false,
                message: "Bu faturaya ait UBL-TR XML verisi bulunamadı.",
                data: null,
                error: {
                  code: "XML_NOT_FOUND",
                  message: "UBL-TR XML içeriği bulunamadı.",
                },
              },
              { status: 404 }
            );
          }

          return new Response(invoice.raw_ubl_xml, {
            status: 200,
            headers: {
              "Content-Type": "application/xml; charset=utf-8",
              "Content-Disposition": `inline; filename="ubl-${invoice.invoice_number || invoice.ettn}.xml"`,
            },
          });
        } catch (error: unknown) {
          const message =
            error instanceof Error ? error.message : "XML verisi alınamadı.";
          return Response.json(
            {
              success: false,
              message,
              data: null,
              error: {
                code: "GET_XML_ERROR",
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
