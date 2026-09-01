import { createFileRoute } from "@tanstack/react-router";
import { listInvoices } from "../../lib/invoice/repository.ts";
import { requireApiUser, authErrorResponse } from "../../lib/api-auth.server.ts";

export const Route = createFileRoute("/api/invoices")({
  server: {
    handlers: {
      GET: async ({ request }) => {
        try {
          const { userId } = await requireApiUser(request);
          const url = new URL(request.url);
          const page = parseInt(url.searchParams.get("page") || "1", 10);
          const pageSize = parseInt(url.searchParams.get("pageSize") || "20", 10);
          const status = url.searchParams.get("status") || undefined;
          const search = url.searchParams.get("search") || undefined;

          const result = await listInvoices({ userId, page, pageSize, status, search });

          return Response.json({
            success: true,
            message: "Faturalar başarıyla getirildi.",
            data: result,
            error: null,
          });
        } catch (error: unknown) {
          const authRes = authErrorResponse(error);
          if (authRes) return authRes;
          const message =
            error instanceof Error ? error.message : "Faturalar listelenirken bir hata oluştu.";
          return Response.json(
            {
              success: false,
              message,
              data: {
                items: [],
                page: 1,
                pageSize: 20,
                total: 0,
              },
              error: {
                code: "LIST_ERROR",
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
