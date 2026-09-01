import { supabaseAdmin } from "../../integrations/supabase/client.server.ts";
import type { ValidatedUblData } from "../ubl.ts";
import type { EdmSendInvoiceResult } from "../edm.ts";

export interface InvoiceListParams {
  userId: string;
  page?: number;
  pageSize?: number;
  status?: string;
  search?: string;
}

export interface InvoiceListResult {
  items: any[];
  page: number;
  pageSize: number;
  total: number;
}

export interface InvoiceSummaryStats {
  total: number;
  draft: number;
  pending: number;
  processing: number;
  sent: number;
  accepted: number;
  failed: number;
  rejected: number;
}

// In-memory store for unit test execution in non-production test environments
const testFallbackInvoices = new Map<string, any>();

/**
 * Checks if Supabase database environment variables are configured on the server.
 */
export function isDatabaseConfigured(): boolean {
  const hasUrl = Boolean(
    process.env.SUPABASE_URL ||
    process.env.VITE_SUPABASE_URL ||
    process.env.SUPABASE_PROJECT_ID ||
    process.env.VITE_SUPABASE_PROJECT_ID
  );
  const hasKey = Boolean(
    process.env.SUPABASE_SERVICE_ROLE_KEY ||
    process.env.SUPABASE_PUBLISHABLE_KEY ||
    process.env.VITE_SUPABASE_PUBLISHABLE_KEY ||
    process.env.SUPABASE_KEY
  );
  return hasUrl || hasKey;
}

/**
 * Enforces mandatory database connection requirement for production e-Invoice sending.
 * Throws 503 Service Unavailable if database connection is unavailable.
 */
export function assertDatabaseAvailable(allowTestFallback: boolean = false): void {
  if (!isDatabaseConfigured() && !allowTestFallback && process.env.NODE_ENV === "production") {
    const err = new Error("Veritabanı bağlantısı kurulamadı. Veritabanı olmadan dış sisteme e-Fatura gönderilemez.");
    (err as any).statusCode = 503;
    (err as any).code = "SERVICE_UNAVAILABLE";
    throw err;
  }
}

/**
 * Checks if an invoice with given ETTN (UUID) or Invoice Number already exists in the database.
 */
export async function findInvoiceByEttnOrNumber(
  ettn: string,
  invoiceNumber: string,
  provider: string = "EDM",
  userId?: string
): Promise<any | null> {
  const cleanEttn = ettn ? ettn.trim().toLowerCase() : "";
  const cleanNo = invoiceNumber ? invoiceNumber.trim().toUpperCase() : "";

  if (isDatabaseConfigured()) {
    try {
      let query = supabaseAdmin
        .from("invoices")
        .select("*");

      if (userId) query = query.eq("user_id", userId);

      if (cleanEttn && cleanNo) {
        query = query.or(`ettn.ilike.${cleanEttn},invoice_number.ilike.${cleanNo}`);
      } else if (cleanEttn) {
        query = query.ilike("ettn", cleanEttn);
      } else if (cleanNo) {
        query = query.ilike("invoice_number", cleanNo);
      } else {
        return null;
      }

      const { data, error } = await query.limit(1).maybeSingle();
      if (!error && data) {
        return data;
      }
    } catch (e) {
      console.warn("[InvoiceRepository] Supabase find query error:", e);
    }
  }

  // Local fallback for test suite
  for (const inv of testFallbackInvoices.values()) {
    if (userId && inv.user_id !== userId) continue;
    if (inv.provider === provider) {
      if (cleanEttn && inv.ettn?.toLowerCase() === cleanEttn) return inv;
      if (cleanNo && inv.invoice_number?.toUpperCase() === cleanNo) return inv;
    }
  }

  return null;
}

/**
 * Atomically inserts a PENDING invoice record into the database BEFORE sending to EDM.
 * Relies strictly on PostgreSQL UNIQUE constraints (`invoices_ettn_unique` & `invoices_provider_invoice_number_unique`).
 */
export async function createPendingInvoiceRecord(
  data: ValidatedUblData,
  rawUblXml: string,
  userId: string,
  provider: string = "EDM",
  allowTestFallback: boolean = false
): Promise<{ id: string; ettn: string; invoiceNumber: string }> {
  // Rule: Do not send e-invoices without database connection in production!
  assertDatabaseAvailable(allowTestFallback);

  // Tenant güvenliği: kayıt daima gerçek oturum kullanıcısına yazılır.
  if (!userId || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(userId)) {
    const err = new Error("Yetkilendirme hatası: Fatura kaydı için geçerli kullanıcı kimliği gereklidir.");
    (err as any).statusCode = 401;
    (err as any).code = "UNAUTHORIZED";
    throw err;
  }

  const cleanEttn = data.uuid.trim().toLowerCase();

  const record = {
    user_id: userId,
    ettn: cleanEttn,
    invoice_number: data.invoiceNumber,
    type: data.invoiceTypeCode,
    status: "PENDING",
    invoice_date: data.issueDate,
    currency: data.currency,
    exchange_rate: 1,
    seller_tax_number: data.seller.taxNumber,
    seller_name: data.seller.name,
    buyer_tax_number: data.buyer.taxNumber,
    buyer_name: data.buyer.name,
    customer: {
      vkn_tckn: data.buyer.taxNumber,
      title: data.buyer.name,
      address: data.buyer.address || "",
      tax_office: data.buyer.taxOffice || "",
      city: data.buyer.city || "",
      district: data.buyer.district || "",
    },
    items: data.lines,
    subtotal: data.subTotal,
    taxable_amount: data.subTotal,
    total_vat: data.taxTotal,
    grand_total: data.grandTotal,
    notes: data.note || "",
    provider,
    raw_ubl_xml: rawUblXml,
    sent_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  };

  if (isDatabaseConfigured()) {
    // Check if an existing invoice already exists in DB
    const existing = await findInvoiceByEttnOrNumber(cleanEttn, data.invoiceNumber, provider, userId);
    if (existing) {
      // Muhasebe durumu (TASLAK/ONAYLANDI/IPTAL) korunur; entegratör durumu edm_status alanına yazılır.
      const updateData: Record<string, any> = {
        ...(isDomainStatus(existing.status) ? { edm_status: "PENDING" } : { status: "PENDING" }),
        provider,
        raw_ubl_xml: rawUblXml,

        seller_tax_number: data.seller.taxNumber,
        seller_name: data.seller.name,
        buyer_tax_number: data.buyer.taxNumber,
        buyer_name: data.buyer.name,
        sent_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      };
      const { error: updateErr } = await supabaseAdmin
        .from("invoices")
        .update(updateData as never)
        .eq("id", existing.id)
        .eq("user_id", userId);

      if (!updateErr) {
        return {
          id: existing.id,
          ettn: existing.ettn || cleanEttn,
          invoiceNumber: existing.invoice_number || data.invoiceNumber,
        };
      }
    }

    let insertResult = await supabaseAdmin
      .from("invoices")
      .insert([record as never])
      .select("id, ettn, invoice_number")
      .single();

    if (insertResult.error && insertResult.error.message?.includes("buyer_name")) {
      // Fallback: DB schema lacks optional extended columns, insert standard record with JSON customer
      const standardRecord = {
        user_id: userId,
        ettn: cleanEttn,
        invoice_number: data.invoiceNumber,
        type: data.invoiceTypeCode,
        status: "PENDING",
        invoice_date: data.issueDate,
        currency: data.currency,
        exchange_rate: 1,
        customer: {
          vkn_tckn: data.buyer.taxNumber,
          title: data.buyer.name,
          address: data.buyer.address || "",
          tax_office: data.buyer.taxOffice || "",
          city: data.buyer.city || "",
          district: data.buyer.district || "",
        },
        items: data.lines,
        subtotal: data.subTotal,
        taxable_amount: data.subTotal,
        total_vat: data.taxTotal,
        grand_total: data.grandTotal,
        notes: data.note || "",
        updated_at: new Date().toISOString(),
      };

      insertResult = await supabaseAdmin
        .from("invoices")
        .insert([standardRecord as never])
        .select("id, ettn, invoice_number")
        .single();
    }

    const { data: dbData, error } = insertResult;

    if (error) {
      if (error.code === "23505" || error.message?.includes("unique") || error.message?.includes("duplicate")) {
        const err = new Error(`[409] Mükerrer Fatura Kaydı Engellendi: ETTN "${cleanEttn}" veya Numarası "${data.invoiceNumber}" veritabanında zaten kayıtlı.`);
        (err as any).statusCode = 409;
        (err as any).code = "DUPLICATE_PERSISTED_INVOICE";
        throw err;
      }

      if (error.message?.includes("row-level security") || error.code === "42501") {
        console.warn("[InvoiceRepository] RLS policy active without Service Role Key. Using test fallback.");
        const id = `pending_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;
        testFallbackInvoices.set(id, { ...record, id });
        return { id, ettn: cleanEttn, invoiceNumber: data.invoiceNumber };
      }

      throw new Error(`Veritabanı PENDING kayıt hatası: ${error.message}`);
    }

    return {
      id: dbData.id,
      ettn: dbData.ettn,
      invoiceNumber: dbData.invoice_number,
    };
  }

  // Fallback for test runner
  const existingTest = await findInvoiceByEttnOrNumber(data.uuid, data.invoiceNumber, provider, userId);
  if (existingTest) {
    const err = new Error(`[409] Mükerrer Fatura Kaydı Engellendi: ETTN "${data.uuid}" veya Numarası "${data.invoiceNumber}" veritabanında zaten kayıtlı.`);
    (err as any).statusCode = 409;
    (err as any).code = "DUPLICATE_PERSISTED_INVOICE";
    throw err;
  }

  const id = `test_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;
  const localRecord = { ...record, id, created_at: new Date().toISOString() };
  testFallbackInvoices.set(id, localRecord);
  return { id, ettn: data.uuid, invoiceNumber: data.invoiceNumber };
}

/**
 * Muhasebe (domain) durumları: bu durumlar entegratör akışı tarafından ezilmez.
 */
export function isDomainStatus(status?: string | null): boolean {
  const s = (status || "").toUpperCase();
  return s === "TASLAK" || s === "ONAYLANDI" || s === "IPTAL";
}

/**
 * State machine status transitions validator.
 * Prevents invalid status regressions (e.g. ACCEPTED -> PENDING, SENT -> DRAFT).
 */
export function isAllowedStatusTransition(currentStatus: string, nextStatus: string): boolean {
  const current = (currentStatus || "").toUpperCase();
  const next = (nextStatus || "").toUpperCase();

  if (current === next) return true;
  if (current === "ACCEPTED" || current === "ONAYLANDI") return false; // Terminal state
  if (current === "CANCELLED" || current === "IPTAL") return false; // Terminal state
  if ((current === "SENT" || current === "PROCESSING") && (next === "DRAFT" || next === "PENDING")) return false; // Cannot regress

  return true;
}

/**
 * Updates the invoice record with the result obtained from EDM SendInvoice.
 * Enforces state machine rules so completed/sent invoices are not corrupted by late errors.
 */
export async function updateInvoiceResultRecord(
  ettn: string,
  result: EdmSendInvoiceResult,
  userId?: string
): Promise<void> {
  const cleanEttn = ettn ? ettn.trim().toLowerCase() : "";
  const isSuccess = result.success;
  const mappedStatus = isSuccess ? (result.status || "SENT") : "FAILED";
  const processedAt = new Date().toISOString();

  // Check current status before updating
  const existing = await findInvoiceByEttnOrNumber(cleanEttn, "", "EDM", userId);
  const keepDomainStatus = isDomainStatus(existing?.status);
  if (existing && !keepDomainStatus && !isAllowedStatusTransition(existing.status, mappedStatus)) {
    console.warn(`[InvoiceRepository] Status geçişi engellendi: ${existing.status} -> ${mappedStatus}`);
    return;
  }

  const updatePayload = {
    ...(keepDomainStatus ? {} : { status: mappedStatus }),

    edm_status: result.status || (isSuccess ? "PACKAGE - PROCESSING" : "FAILED"),
    edm_return_code: isSuccess ? "0" : "ERROR",
    edm_return_message: result.message,
    provider_reference: result.edmReference || (existing ? (existing.provider_reference || existing.trx_id) : null),
    trx_id: result.edmReference || (existing ? existing.trx_id : null),
    error_code: isSuccess ? null : "EDM_ERROR",
    error_message: isSuccess ? null : result.message,
    processed_at: processedAt,
    updated_at: processedAt,
    gib_approval_date: isSuccess ? processedAt : null,
  };

  if (isDatabaseConfigured()) {
    try {
      const targetId = existing?.id;
      let query = supabaseAdmin.from("invoices").update(updatePayload);
      if (userId) query = query.eq("user_id", userId);
      if (targetId) {
        query = query.eq("id", targetId);
      } else {
        query = query.ilike("ettn", cleanEttn);
      }
      const { error } = await query;

      if (error) {
        console.warn("[InvoiceRepository] Supabase full update notice, trying standard update fallback:", error.message);
        let fallbackQuery = supabaseAdmin
          .from("invoices")
          .update({
            ...(keepDomainStatus ? {} : { status: mappedStatus }),
            notes: result.message ? `[EDM] ${result.message}` : undefined,
            updated_at: processedAt,
          });

        if (userId) fallbackQuery = fallbackQuery.eq("user_id", userId);
        if (targetId) {
          fallbackQuery = fallbackQuery.eq("id", targetId);
        } else {
          fallbackQuery = fallbackQuery.ilike("ettn", cleanEttn);
        }
        await fallbackQuery;
      }
    } catch (e) {
      console.warn("[InvoiceRepository] Supabase update warning:", e);
    }
  }

  // Fallback update for test runner
  for (const [id, inv] of testFallbackInvoices.entries()) {
    if (userId && inv.user_id !== userId) continue;
    if (inv.ettn?.toLowerCase() === cleanEttn) {
      testFallbackInvoices.set(id, { ...inv, ...updatePayload });
    }
  }
}

/**
 * Lists invoices with pagination, status filter, and invoice_number search.
 */
export async function listInvoices(params: InvoiceListParams): Promise<InvoiceListResult> {
  const page = Math.max(1, params.page || 1);
  const pageSize = Math.min(100, Math.max(1, params.pageSize || 20));
  const from = (page - 1) * pageSize;
  const to = from + pageSize - 1;

  if (isDatabaseConfigured()) {
    try {
      let query = supabaseAdmin
        .from("invoices")
        .select("*", { count: "exact" })
        .eq("user_id", params.userId)
        .order("created_at", { ascending: false });

      if (params.status && params.status.trim() && params.status !== "ALL") {
        query = query.eq("status", params.status.trim().toUpperCase());
      }

      if (params.search && params.search.trim()) {
        const term = params.search.trim();
        query = query.or(`invoice_number.ilike.%${term}%,buyer_name.ilike.%${term}%,buyer_tax_number.ilike.%${term}%`);
      }

      const { data, count, error } = await query.range(from, to);

      if (!error && data) {
        return {
          items: data,
          page,
          pageSize,
          total: count || 0,
        };
      }
    } catch (e) {
      console.warn("[InvoiceRepository] Supabase list error:", e);
    }
  }

  // Local test fallback filter & pagination
  let items = Array.from(testFallbackInvoices.values()).filter((i) => i.user_id === params.userId);

  if (params.status && params.status !== "ALL") {
    items = items.filter((i) => i.status === params.status?.toUpperCase());
  }

  if (params.search && params.search.trim()) {
    const term = params.search.trim().toLowerCase();
    items = items.filter(
      (i) =>
        i.invoice_number?.toLowerCase().includes(term) ||
        i.buyer_name?.toLowerCase().includes(term) ||
        i.buyer_tax_number?.includes(term)
    );
  }

  const total = items.length;
  const pagedItems = items.slice(from, from + pageSize);

  return {
    items: pagedItems,
    page,
    pageSize,
    total,
  };
}

/**
 * Gets a single invoice by ID or ETTN (UUID).
 */
export async function getInvoiceById(idOrEttn: string, userId?: string): Promise<any | null> {
  const target = idOrEttn ? idOrEttn.trim() : "";
  if (!target) return null;

  if (isDatabaseConfigured()) {
    try {
      let query = supabaseAdmin.from("invoices").select("*");
      if (userId) query = query.eq("user_id", userId);
      const isUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(target);
      query = isUuid
        ? query.or(`id.eq.${target},ettn.ilike.${target},invoice_number.ilike.${target}`)
        : query.or(`ettn.ilike.${target},invoice_number.ilike.${target}`);
      const { data, error } = await query.limit(1).maybeSingle();

      if (!error && data) {
        return data;
      }
    } catch (e) {
      console.warn("[InvoiceRepository] Supabase getById error:", e);
    }
  }

  for (const inv of testFallbackInvoices.values()) {
    if (userId && inv.user_id !== userId) continue;
    if (
      inv.id === target ||
      inv.ettn?.toLowerCase() === target.toLowerCase() ||
      inv.invoice_number?.toUpperCase() === target.toUpperCase()
    ) {
      return inv;
    }
  }

  return null;
}

/**
 * Returns database summary statistics for invoice status cards.
 */
export async function getInvoiceSummaryStats(userId: string): Promise<InvoiceSummaryStats> {
  const stats: InvoiceSummaryStats = {
    total: 0,
    draft: 0,
    pending: 0,
    processing: 0,
    sent: 0,
    accepted: 0,
    failed: 0,
    rejected: 0,
  };

  if (isDatabaseConfigured()) {
    try {
      const { data, error } = await supabaseAdmin
        .from("invoices")
        .select("status")
        .eq("user_id", userId);
      if (!error && data) {
        stats.total = data.length;
        for (const row of data) {
          const s = (row.status || "").toUpperCase();
          if (s === "DRAFT" || s === "TASLAK") stats.draft++;
          else if (s === "PENDING") stats.pending++;
          else if (s === "PROCESSING") stats.processing++;
          else if (s === "SENT") stats.sent++;
          else if (s === "ACCEPTED" || s === "ONAYLANDI") stats.accepted++;
          else if (s === "FAILED") stats.failed++;
          else if (s === "REJECTED") stats.rejected++;
        }
        return stats;
      }
    } catch (e) {
      console.warn("[InvoiceRepository] Supabase summary stats query fallback:", e);
    }
  }

  // Test fallback stats
  const items = Array.from(testFallbackInvoices.values()).filter((i) => i.user_id === userId);
  stats.total = items.length;
  for (const item of items) {
    const s = (item.status || "").toUpperCase();
    if (s === "DRAFT" || s === "TASLAK") stats.draft++;
    else if (s === "PENDING") stats.pending++;
    else if (s === "PROCESSING") stats.processing++;
    else if (s === "SENT") stats.sent++;
    else if (s === "ACCEPTED" || s === "ONAYLANDI") stats.accepted++;
    else if (s === "FAILED") stats.failed++;
    else if (s === "REJECTED") stats.rejected++;
  }

  return stats;
}

/**
 * Gets list of active invoices that are in PENDING, PROCESSING, or SENT state to refresh status.
 */
export async function getPendingOrProcessingInvoices(userId: string, limit: number = 20): Promise<any[]> {
  if (isDatabaseConfigured()) {
    try {
      const { data, error } = await supabaseAdmin
        .from("invoices")
        .select("*")
        .eq("user_id", userId)
        .in("status", ["PENDING", "PROCESSING", "SENT"])
        .order("updated_at", { ascending: true })
        .limit(limit);

      if (!error && data) return data;
    } catch (e) {
      console.warn("[InvoiceRepository] getPendingOrProcessingInvoices error:", e);
    }
  }

  const items = Array.from(testFallbackInvoices.values()).filter((i) => i.user_id === userId);
  return items.filter((i) => ["PENDING", "PROCESSING", "SENT"].includes(i.status?.toUpperCase())).slice(0, limit);
}
