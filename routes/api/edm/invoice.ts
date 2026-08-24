import { createFileRoute } from "@tanstack/react-router";
import { getEInvoiceProvider } from "../../../lib/einvoice/provider.ts";
import { validateAndCalculateInvoice, createUblTrInvoice, type UblInvoiceData } from "../../../lib/ubl.ts";
import {
  isDatabaseConfigured,
  findInvoiceByEttnOrNumber,
  createPendingInvoiceRecord,
  updateInvoiceResultRecord,
} from "../../../lib/invoice/repository.ts";

// Active in-flight request lock set for local concurrent double-click protection
const activeRequestLocks = new Set<string>();

export const Route = createFileRoute("/api/edm/invoice")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        let lockKey: string | null = null;

        try {
          // 1. Mandatory Rule: NO DATABASE = NO EDM SEND
          if (!isDatabaseConfigured() && process.env.NODE_ENV === "production") {
            return Response.json(
              {
                success: false,
                message: "Veritabanı bağlantısı kurulamadı. Veritabanı olmadan dış sisteme (EDM) e-Fatura gönderilemez.",
                data: null,
                error: {
                  code: "SERVICE_UNAVAILABLE",
                  message: "Veritabanı erişilemez durumda. Mükerrer gönderim riski nedeniyle işlem durduruldu.",
                },
              },
              { status: 503 }
            );
          }

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
                  message: "Fatura nesnesi sunucuya ulaştırılmadı veya biçimi hatalı.",
                },
              },
              { status: 400 }
            );
          }

          // 2. Validate & calculate invoice payload
          const validatedData = validateAndCalculateInvoice(rawInvoiceData);
          const ettn = validatedData.uuid;
          const invoiceNumber = validatedData.invoiceNumber;

          // 3. Lock active in-flight request to prevent rapid double-clicks
          lockKey = `lock:${ettn.toLowerCase()}`;
          if (activeRequestLocks.has(lockKey)) {
            return Response.json(
              {
                success: false,
                message: "Bu fatura şu anda gönderiliyor. Lütfen işlemin tamamlanmasını bekleyin.",
                data: null,
                error: {
                  code: "CONCURRENT_REQUEST_LOCKED",
                  message: "Aynı fatura için paralel gönderim isteği engellendi.",
                },
              },
              { status: 429 }
            );
          }
          activeRequestLocks.add(lockKey);

          // 4. Database Idempotency Check (Server restart & Multi-instance safe)
          const existingRecord = await findInvoiceByEttnOrNumber(ettn, invoiceNumber, "EDM");
          if (existingRecord) {
            const status = (existingRecord.status || "").toUpperCase();
            if (status === "SENT" || status === "ACCEPTED" || status === "PROCESSING" || status === "PENDING") {
              return Response.json(
                {
                  success: false,
                  message: `Bu fatura (UUID: ${existingRecord.ettn}, No: ${existingRecord.invoice_number}) veritabanında "${existingRecord.status}" durumundadır. Mükerrer gönderim engellendi.`,
                  invoiceNumber: existingRecord.invoice_number,
                  uuid: existingRecord.ettn,
                  edmReference: existingRecord.provider_reference || existingRecord.trx_id,
                  status: existingRecord.status,
                  data: existingRecord,
                  error: {
                    code: "DUPLICATE_PERSISTED_INVOICE",
                    message: "Veritabanında kayıtlı mükerrer fatura gönderimi engellendi.",
                  },
                },
                { status: 409 }
              );
            }
          }

          // 5. Generate UBL-TR XML
          const rawUblXml = createUblTrInvoice(validatedData);

          // 6. Atomic PENDING Record Creation in Database BEFORE EDM SOAP call
          try {
            await createPendingInvoiceRecord(validatedData, rawUblXml, "00000000-0000-0000-0000-000000000000", "EDM");
          } catch (dbErr: any) {
            if (dbErr.statusCode === 409 || dbErr.message?.includes("[409]")) {
              return Response.json(
                {
                  success: false,
                  message: dbErr.message,
                  data: null,
                  error: {
                    code: "DUPLICATE_DB_CONSTRAINT",
                    message: "Veritabanı unique kısıtlaması nedeniyle mükerrer fatura engellendi.",
                  },
                },
                { status: 409 }
              );
            }
            if (dbErr.statusCode === 503) {
              return Response.json(
                {
                  success: false,
                  message: dbErr.message,
                  data: null,
                  error: {
                    code: "SERVICE_UNAVAILABLE",
                    message: "Veritabanı bağlantısı bulunmadığı için EDM'ye istek gönderilmedi.",
                  },
                },
                { status: 503 }
              );
            }
            throw dbErr;
          }

          // 7. Execute EDM TEST SendInvoice Request
          const provider = getEInvoiceProvider("EDM");
          const sendResult = await provider.sendInvoice(validatedData);

          // 8. Update Database record with EDM execution result
          await updateInvoiceResultRecord(ettn, {
            success: sendResult.success,
            message: sendResult.message,
            invoiceNumber: sendResult.invoiceNumber,
            uuid: sendResult.uuid,
            edmReference: sendResult.providerReference,
            status: sendResult.status,
          });

          return Response.json({
            success: sendResult.success,
            message: sendResult.message,
            invoiceNumber: sendResult.invoiceNumber || invoiceNumber,
            uuid: sendResult.uuid || ettn,
            edmReference: sendResult.providerReference,
            status: sendResult.status,
            data: sendResult.data || {
              invoiceNumber: sendResult.invoiceNumber || invoiceNumber,
              uuid: sendResult.uuid || ettn,
              edmReference: sendResult.providerReference,
              status: sendResult.status,
            },
            error: sendResult.error || null,
          });
        } catch (error: unknown) {
          const message =
            error instanceof Error ? error.message : "Sunucuda beklenmeyen bir fatura hatası oluştu.";
          return Response.json(
            {
              success: false,
              message: `EDM API Handler hatası: ${message}`,
              data: null,
              error: {
                code: "INTERNAL_SERVER_ERROR",
                message,
              },
            },
            { status: 500 }
          );
        } finally {
          if (lockKey) {
            activeRequestLocks.delete(lockKey);
          }
        }
      },
    },
  },
});
