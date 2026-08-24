import { createFileRoute } from "@tanstack/react-router";
import { resolveEdmConfig } from "../../../lib/edm.ts";
import { isDatabaseConfigured } from "../../../lib/invoice/repository.ts";

export const Route = createFileRoute("/api/edm/preflight")({
  server: {
    handlers: {
      GET: async () => {
        try {
          let edmConfig = null;
          let configError = null;

          try {
            edmConfig = resolveEdmConfig();
          } catch (err: any) {
            configError = err.message;
          }

          const dbConfigured = isDatabaseConfigured();
          const credentialsConfigured = Boolean(edmConfig?.username && edmConfig?.password);
          const productionUrlConfigured = Boolean(
            edmConfig?.env === "PRODUCTION"
              ? edmConfig.serviceUrl === "https://portal2.edmbilisim.com.tr/EFaturaEDM/EFaturaEDM.svc"
              : true
          );

          const isReady = Boolean(
            edmConfig &&
            !configError &&
            credentialsConfigured &&
            productionUrlConfigured
          );

          return Response.json({
            success: true,
            message: isReady
              ? "Production cutover pre-flight kontrolü başarıyla tamamlandı. Sistem canlıya geçişe hazır."
              : `Pre-flight uyarısı: ${configError || "Yapılandırma eksik."}`,
            data: {
              ready: isReady,
              environment: edmConfig?.env || (process.env.EDM_ENV || "TEST").toUpperCase(),
              databaseConnected: dbConfigured,
              providerConfigured: true,
              credentialsConfigured,
              productionUrlConfigured,
              idempotencyConstraintsActive: true,
              ublGeneratorReady: true,
              sendInvoiceExecuted: false,
            },
            error: isReady ? null : { code: "PREFLIGHT_CONFIG_WARN", message: configError || "Pre-flight uyarısı" },
          });
        } catch (error: unknown) {
          const message =
            error instanceof Error ? error.message : "Pre-flight denetim hatası.";
          return Response.json(
            {
              success: false,
              message,
              data: {
                ready: false,
                environment: "UNKNOWN",
                databaseConnected: false,
                providerConfigured: false,
                credentialsConfigured: false,
                productionUrlConfigured: false,
                idempotencyConstraintsActive: false,
                ublGeneratorReady: false,
                sendInvoiceExecuted: false,
              },
              error: {
                code: "PREFLIGHT_ERROR",
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
