import type { IEInvoiceProvider, EInvoiceData, EInvoiceResult } from "../types.ts";
import { testEdmConnection, sendInvoiceToEdm, getInvoiceStatusFromEdm, cancelInvoiceInEdm } from "../../edm.ts";

export class EdmEInvoiceProvider implements IEInvoiceProvider {
  readonly providerId = "EDM";
  readonly providerName = "EDM Bilişim e-Fatura TEST Web Service";

  async testConnection(): Promise<{ success: boolean; message: string }> {
    const res = await testEdmConnection();
    return {
      success: res.success,
      message: res.message,
    };
  }

  async sendInvoice(data: EInvoiceData): Promise<EInvoiceResult> {
    const res = await sendInvoiceToEdm(data);
    return {
      success: res.success,
      message: res.message,
      invoiceNumber: res.invoiceNumber,
      uuid: res.uuid,
      providerReference: res.edmReference,
      status: res.status,
      data: res.success
        ? {
            invoiceNumber: res.invoiceNumber,
            uuid: res.uuid,
            edmReference: res.edmReference,
            status: res.status,
          }
        : null,
      error: !res.success
        ? {
            code: "EDM_SEND_ERROR",
            message: res.message,
          }
        : null,
    };
  }

  async getInvoiceStatus(uuid: string): Promise<EInvoiceResult> {
    const res = await getInvoiceStatusFromEdm(uuid);
    return {
      success: res.success,
      message: res.message,
      invoiceNumber: res.invoiceNumber,
      uuid: res.uuid,
      status: res.status,
      data: res.success
        ? {
            uuid: res.uuid,
            invoiceNumber: res.invoiceNumber,
            status: res.status,
            edmStatus: res.edmStatus,
            edmReturnCode: res.edmReturnCode,
            edmReturnMessage: res.edmReturnMessage,
          }
        : null,
      error: !res.success
        ? {
            code: "EDM_STATUS_ERROR",
            message: res.message,
          }
        : null,
    };
  }

  async cancelInvoice(uuid: string, invoiceNumber?: string, reason?: string): Promise<EInvoiceResult> {
    const res = await cancelInvoiceInEdm(uuid, invoiceNumber, reason);
    return {
      success: res.success,
      message: res.message,
      invoiceNumber: res.invoiceNumber,
      uuid: res.uuid,
      status: res.success ? "CANCELLED" : undefined,
      data: res.success
        ? {
            uuid: res.uuid,
            invoiceNumber: res.invoiceNumber,
            returnCode: res.returnCode,
            returnMessage: res.returnMessage,
          }
        : null,
      error: !res.success
        ? {
            code: res.errorCode || "EDM_CANCEL_ERROR",
            message: res.message,
          }
        : null,
    };
  }
}
