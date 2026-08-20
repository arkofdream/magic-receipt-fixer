import { supabase } from "@/integrations/supabase/client";

/**
 * Checks if a Supabase error is caused by a missing column in the DB schema cache (e.g. deleted_at not existing).
 */
export function isMissingColumnError(error: any): boolean {
  if (!error) return false;
  const msg = (error.message || "").toLowerCase();
  const details = (error.details || "").toLowerCase();
  const code = String(error.code || "");

  return (
    code === "42703" ||
    code === "PGRST204" ||
    msg.includes("deleted_at") ||
    msg.includes("schema cache") ||
    msg.includes("does not exist") ||
    details.includes("deleted_at")
  );
}

/**
 * Perform a soft delete update, with fallback to hard delete if deleted_at column is missing.
 */
export async function safeSoftDelete(
  table:
    | "invoices"
    | "customers"
    | "products"
    | "account_transactions"
    | "stock_movements"
    | "pos_sales"
    | "warehouses",
  id: string,
  userId?: string,
): Promise<void> {
  const { error } = await supabase
    .from(table as any)
    .update({
      deleted_at: new Date().toISOString(),
      deleted_by: userId || null,
    })
    .eq("id", id);

  if (error) {
    if (isMissingColumnError(error)) {
      // Hard delete fallback
      if (table === "invoices") {
        await supabase.from("account_transactions").delete().eq("source_id", id);
        await supabase.from("stock_movements").delete().eq("source_id", id);
      }
      const { error: hardErr } = await supabase.from(table as any).delete().eq("id", id);
      if (hardErr) throw hardErr;
    } else {
      throw error;
    }
  } else {
    // Soft delete succeeded, soft-delete related records if possible
    if (table === "invoices") {
      try {
        await supabase
          .from("account_transactions")
          .update({ deleted_at: new Date().toISOString(), deleted_by: userId || null })
          .eq("source_id", id);
        await supabase
          .from("stock_movements")
          .update({ deleted_at: new Date().toISOString(), deleted_by: userId || null })
          .eq("source_id", id);
      } catch {
        // ignore if related soft-delete fails
      }
    }
  }
}

/**
 * Perform a trash query (deleted_at is not null), returning [] if column is missing in DB.
 */
export async function safeFetchTrash<T = any>(
  fetchTrash: () => Promise<{ data: T[] | null; error: any }>,
): Promise<T[]> {
  const res = await fetchTrash();
  if (res.error) {
    if (isMissingColumnError(res.error)) {
      return [];
    }
    throw res.error;
  }
  return res.data ?? [];
}
