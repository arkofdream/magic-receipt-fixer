import { createFileRoute } from "@tanstack/react-router";
import { testEdmConnection } from "@/lib/edm";
import { requireApiUser, authErrorResponse } from "@/lib/api-auth.server";

export const Route = createFileRoute("/api/edm/test")({
  server: {
    handlers: {
      GET: async ({ request }) => {
        try {
          await requireApiUser(request);
          const result = await testEdmConnection();
          return Response.json({
            success: result.success,
            message: result.message,
            sessionIdPresent: result.sessionIdPresent,
            data: result.success
              ? {
                  provider: "EDM",
                  connected: true,
                  sessionIdPresent: result.sessionIdPresent,
                }
              : null,
            error: !result.success
              ? {
                  code: "EDM_TEST_FAILED",
                  message: result.message,
                }
              : null,
          });
        } catch (error: unknown) {
          const authRes = authErrorResponse(error);
          if (authRes) return authRes;
          const message =
            error instanceof Error
              ? error.message
              : "EDM servisine bağlanırken beklenmeyen bir hata oluştu.";
          return Response.json(
            {
              success: false,
              message: `Sunucu hatası: ${message}`,
              sessionIdPresent: false,
              data: null,
              error: {
                code: "SERVER_ERROR",
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
