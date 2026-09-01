import { createFileRoute } from "@tanstack/react-router";
import { checkEdmUser, normalizeAliasMail } from "@/lib/edm";
import { requireApiUser, authErrorResponse } from "@/lib/api-auth.server";

/**
 * GİB e-Fatura mükellef ve posta kutusu (alias) sorgulaması.
 * Gerçek EDM servis operasyonu: CheckUserRequest.
 */
export const Route = createFileRoute("/api/edm/taxpayer")({
  server: {
    handlers: {
      GET: async ({ request }) => {
        try {
          await requireApiUser(request);

          const url = new URL(request.url);
          const identifier = (url.searchParams.get("vkn") || url.searchParams.get("identifier") || "").trim();

          if (!identifier) {
            return Response.json(
              {
                success: false,
                message: "Sorgulama için VKN/TCKN parametresi zorunludur.",
                data: null,
                error: { code: "MISSING_IDENTIFIER", message: "vkn parametresi eksik." },
              },
              { status: 400 },
            );
          }

          const result = await checkEdmUser(identifier);

          if (!result.success) {
            return Response.json(
              {
                success: false,
                message: result.message,
                data: null,
                error: result.error,
              },
              { status: 502 },
            );
          }

          return Response.json({
            success: true,
            message: result.message,
            data: {
              identifier: result.identifier,
              isEinvoiceUser: result.isEinvoiceUser,
              title: result.title ?? null,
              type: result.type ?? null,
              registerTime: result.registerTime ?? null,
              aliases: result.aliases.map((a) => ({
                alias: a.alias,
                mail: normalizeAliasMail(a.alias),
                unit: a.unit ?? "PK",
                title: a.title,
                type: a.type,
                registerTime: a.registerTime ?? null,
                aliasCreationTime: a.aliasCreationTime ?? null,
                documentType: a.documentType ?? null,
                active: a.active,
              })),
              senderAliases: result.senderAliases.map((a) => ({
                alias: a.alias,
                mail: normalizeAliasMail(a.alias),
                unit: a.unit ?? "GB",
                active: a.active,
              })),
            },
            error: null,
          });
        } catch (error: unknown) {
          const authRes = authErrorResponse(error);
          if (authRes) return authRes;
          const message =
            error instanceof Error ? error.message : "Mükellef sorgulamasında beklenmeyen hata.";
          return Response.json(
            {
              success: false,
              message: `Mükellef sorgulama hatası: ${message}`,
              data: null,
              error: { code: "TAXPAYER_QUERY_ERROR", message },
            },
            { status: 500 },
          );
        }
      },
    },
  },
});
