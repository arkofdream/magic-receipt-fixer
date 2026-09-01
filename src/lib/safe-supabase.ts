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
      // Finansal kayitlarin manuel silinmesi FAZ 6A kapsaminda kaldirildi. 
      // Eger fis taslak ise finansal kaydi yoktur. Eger onayli ise silinemez.
      
      const { error: hardErr } = await supabase.from(table as any).delete().eq("id", id);
      if (hardErr) throw hardErr;
    } else {
      throw error;
    }
  } else {
    // Gecici fisler haricinde kayit silinmedigi icin cascade update iptal edildi.
  }
}

/**
 * Perform a trash query (deleted_at is not null), returning [] if column is missing in DB.
 */
export async function safeFetchTrash<T = any>(
  fetchTrash: () => PromiseLike<{ data: T[] | null; error: any }>,
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
