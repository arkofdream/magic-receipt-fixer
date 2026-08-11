import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";

import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";

export type { ExtractedInvoice, ExtractedItem } from "@/lib/ai/invoice-ocr.server";

const InputSchema = z.object({
  imageDataUrl: z
    .string()
    .regex(/^data:image\/(png|jpeg|jpg|webp|heic);base64,[A-Za-z0-9+/=]+$/, "Desteklenmeyen görsel biçimi.")
    .max(8_000_000, "Görsel çok büyük (en fazla ~6 MB)."),
});

export const extractInvoiceFromPhoto = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: unknown) => InputSchema.parse(data))
  .handler(async ({ data }) => {
    const { extractInvoiceFromImage } = await import("@/lib/ai/invoice-ocr.server");
    return extractInvoiceFromImage(data.imageDataUrl);
  });
