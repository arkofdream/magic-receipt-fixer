import { createFileRoute } from "@tanstack/react-router";
import { getInvoiceById, updateInvoiceResultRecord } from "../../../lib/invoice/repository.ts";
import { cancelInvoiceInEdm } from "../../../lib/edm.ts";
import { requireApiUser, authErrorResponse } from "../../../lib/api-auth.server.ts";

const activeCancelLocks = new Set<string>();

export const Route = createFileRoute("/api/edm/invoice/cancel")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        let lockKey: string | null = null;

        try {
          // 0. FAIL-FAST AUTHENTICATION (Bearer token / oturum çerezi)
          const { userId: authenticatedUserId, supabase: authedSupabase } = await requireApiUser(request);

          const body = await request.json().catch(() => null);
          const invoiceId = body?.invoiceId || body?.id;
          const cancelReason = (body?.cancelReason || "").trim();

          // 1. Validate Input
          if (!invoiceId) {
            return Response.json(
              {
                success: false,
                message: "İptal edilecek fatura kimliği (invoiceId) zorunludur.",
                error: { code: "MISSING_INVOICE_ID", message: "invoiceId parametresi eksik." },
              },
              { status: 400 }
            );
          }

          if (!cancelReason || cancelReason.length < 3) {
            return Response.json(
              {
                success: false,
                message: "İptal gerekçesi en az 3 karakter olmalıdır.",
                error: { code: "INVALID_CANCEL_REASON", message: "Geçerli bir iptal gerekçesi girilmelidir." },
              },
              { status: 400 }
            );
          }

          // 2. Concurrency Lock
          lockKey = `cancel:${invoiceId}`;
          if (activeCancelLocks.has(lockKey)) {
            return Response.json(
              {
                success: false,
                message: "Bu fatura için şu anda bir iptal işlemi yürütülüyor. Lütfen bekleyin.",
                error: { code: "CONCURRENT_CANCEL_LOCKED", message: "Paralel iptal isteği engellendi." },
              },
              { status: 429 }
            );
          }
          activeCancelLocks.add(lockKey);

          // 3. Find invoice in Database & Tenant Ownership Check
          const invoice = await getInvoiceById(invoiceId, authenticatedUserId);
          if (!invoice) {
            return Response.json(
              {
                success: false,
                message: `İptal edilmek istenen fatura bulunamadı ("${invoiceId}").`,
                error: { code: "INVOICE_NOT_FOUND", message: "Veritabanında fatura kaydına ulaşılamadı." },
              },
              { status: 404 }
            );
          }

          // Strict Tenant Ownership Check
          if (invoice.user_id !== authenticatedUserId) {
            return Response.json(
              {
                success: false,
                message: "Yetkilendirme hatası: Bu faturayı iptal etme yetkiniz bulunmuyor.",
                error: {
                  code: "FORBIDDEN",
                  message: "Yalnızca kendi firmanıza/hesabınıza ait faturaları iptal edebilirsiniz.",
                },
              },
              { status: 403 }
            );
          }

          // 4. Idempotency Check: Already cancelled?
          const currentStatus = (invoice.status || "").toUpperCase();
          const currentEdmStatus = (invoice.edm_status || "").toUpperCase();
          if (currentStatus === "IPTAL" || currentStatus === "CANCELLED" || currentEdmStatus === "CANCELLED") {
            return Response.json(
              {
                success: false,
                message: `Bu fatura zaten iptal edilmiştir. Fatura No: ${invoice.invoice_number || invoice.ettn}`,
                data: { id: invoice.id, ettn: invoice.ettn, status: invoice.status },
                error: { code: "ALREADY_CANCELLED", message: "Mükerrer iptal işlemi engellendi." },
              },
              { status: 409 }
            );
          }

          // 5. Profile check for Commercial / Basic e-Invoice
          const profileId = (invoice.profile_id || invoice.profileId || "").toUpperCase();
          if (profileId === "TICARIFATURA" || profileId === "TEMELFATURA") {
            return Response.json(
              {
                success: false,
                message:
                  "GİB mevzuatı gereği alıcıya iletilmiş e-Faturalar tek taraflı iptal edilemez. Alıcının 8 gün içinde RET yanıtı vermesi veya İade Faturası düzenlemesi gerekmektedir.",
                data: { id: invoice.id, profileId, status: invoice.status },
                error: {
                  code: "UNILATERAL_CANCEL_NOT_ALLOWED",
                  message: "Ticari veya Temel e-Fatura profili için tek taraflı entegratör iptali desteklenmez.",
                },
              },
              { status: 422 }
            );
          }

          const cleanEttn = (invoice.ettn || "").trim().toLowerCase();

          // 6. If invoice was sent to EDM: Execute EDM SOAP Cancel FIRST (Saga Pattern)
          const isSentToEdm =
            currentStatus === "SENT" ||
            currentStatus === "ACCEPTED" ||
            currentStatus === "PROCESSING" ||
            currentStatus === "PENDING" ||
            Boolean(invoice.provider_reference || invoice.trx_id);

          if (isSentToEdm && cleanEttn) {
            const edmCancelResult = await cancelInvoiceInEdm(
              cleanEttn,
              invoice.invoice_number,
              cancelReason
            );

            // If EDM cancellation failed, ABORT! DO NOT touch local database accounting/stocks
            if (!edmCancelResult.success) {
              return Response.json(
                {
                  success: false,
                  message: edmCancelResult.message,
                  data: {
                    id: invoice.id,
                    ettn: cleanEttn,
                    invoiceNumber: invoice.invoice_number,
                    status: invoice.status,
                    errorCode: edmCancelResult.errorCode,
                    edmReturnMessage: edmCancelResult.returnMessage,
                  },
                  error: {
                    code: edmCancelResult.errorCode || "EDM_CANCEL_FAILED",
                    message: edmCancelResult.message,
                  },
                },
                { status: edmCancelResult.errorCode === "11049" ? 409 : 422 }
              );
            }
          }

          // 7. If EDM approved cancellation (or invoice was only local draft): Execute atomic local reversal RPC
          const isPurchase =
            invoice.type === "ALIS" ||
            invoice.type === "GELEN_FATURA" ||
            invoice.type === "GELEN_E_ARSIV";

          const rpcName = isPurchase ? "cancel_purchase_invoice" : "cancel_sales_invoice";
          const { error: rpcError } = await authedSupabase.rpc(rpcName, {
            p_invoice_id: invoice.id,
            p_cancel_reason: cancelReason,
          });

          if (rpcError) {
            console.error(`[CRITICAL] EDM cancelled invoice ${cleanEttn} but local RPC ${rpcName} failed:`, rpcError.message);
            return Response.json(
              {
                success: false,
                message: `Entegratör iptali başarılı ancak yerel muhasebe ters kaydı oluşturulurken hata alındı: ${rpcError.message}. Mutabakat gereklidir.`,
                error: {
                  code: "LOCAL_RPC_REVERSAL_FAILED",
                  message: rpcError.message,
                },
              },
              { status: 500 }
            );
          }

          // 8. Update DB metadata
          await updateInvoiceResultRecord(cleanEttn || invoice.id, {
            success: true,
            message: `Fatura iptal edildi: ${cancelReason}`,
            invoiceNumber: invoice.invoice_number,
            uuid: cleanEttn || undefined,
            status: "IPTAL",
          }, authenticatedUserId);

          return Response.json({
            success: true,
            message: "Fatura entegratör üzerinden iptal edildi ve yerel muhasebe/stok kayıtları terslendi.",
            data: {
              id: invoice.id,
              ettn: cleanEttn,
              invoiceNumber: invoice.invoice_number,
              status: "IPTAL",
              edmStatus: "CANCELLED",
              cancelReason,
            },
            error: null,
          });
        } catch (err: unknown) {
          const authRes = authErrorResponse(err);
          if (authRes) return authRes;
          const message = err instanceof Error ? err.message : "Sunucuda beklenmeyen bir iptal hatası oluştu.";
          return Response.json(
            {
              success: false,
              message: `İptal işlemi başarısız: ${message}`,
              error: { code: "INTERNAL_SERVER_ERROR", message },
            },
            { status: 500 }
          );
        } finally {
          if (lockKey) {
            activeCancelLocks.delete(lockKey);
          }
        }
      },
    },
  },
});
