/**
 * Fiş / fatura fotoğrafından alan çıkarımı (sunucu tarafı).
 * Lovable AI Gateway üzerinden görsel destekli model kullanılır;
 * API anahtarı yalnızca sunucuda okunur.
 */

export type ExtractedItem = {
  name: string;
  unit: string;
  quantity: number;
  unitPrice: number;
  vatRate: number;
};

export type ExtractedInvoice = {
  customer: {
    vknTckn: string;
    title: string;
    taxOffice: string;
    address: string;
    city: string;
    district: string;
  };
  invoiceDate: string;
  items: ExtractedItem[];
  note: string;
};

const SYSTEM_PROMPT = `Sen Türkçe fatura ve fiş görüntülerini okuyan bir asistansın.
Görseldeki satıcı/alıcı bilgilerini ve satır kalemlerini çıkar.
Sadece görselde açıkça okunabilen bilgileri doldur; okunamayanları boş string veya 0 bırak.
Tutarları nokta ondalık ayırıcı ile sayı olarak ver. KDV oranını yüzde olarak (örn. 20) ver.
Tarihi YYYY-MM-DD biçiminde ver.`;

const SCHEMA = {
  type: "object",
  properties: {
    customer: {
      type: "object",
      properties: {
        vknTckn: { type: "string" },
        title: { type: "string" },
        taxOffice: { type: "string" },
        address: { type: "string" },
        city: { type: "string" },
        district: { type: "string" },
      },
      required: ["vknTckn", "title", "taxOffice", "address", "city", "district"],
      additionalProperties: false,
    },
    invoiceDate: { type: "string" },
    items: {
      type: "array",
      items: {
        type: "object",
        properties: {
          name: { type: "string" },
          unit: { type: "string" },
          quantity: { type: "number" },
          unitPrice: { type: "number" },
          vatRate: { type: "number" },
        },
        required: ["name", "unit", "quantity", "unitPrice", "vatRate"],
        additionalProperties: false,
      },
    },
    note: { type: "string" },
  },
  required: ["customer", "invoiceDate", "items", "note"],
  additionalProperties: false,
} as const;

export async function extractInvoiceFromImage(imageDataUrl: string): Promise<ExtractedInvoice> {
  const apiKey = process.env["LOVABLE_API_KEY"];
  if (!apiKey) throw new Error("Yapay zeka servisi yapılandırılmamış.");

  const response = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json", "Lovable-API-Key": apiKey },
    body: JSON.stringify({
      model: "google/gemini-3.6-flash",
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        {
          role: "user",
          content: [
            { type: "text", text: "Bu fatura/fiş görselindeki bilgileri çıkar." },
            { type: "image_url", image_url: { url: imageDataUrl } },
          ],
        },
      ],
      response_format: {
        type: "json_schema",
        json_schema: { name: "invoice_extraction", strict: true, schema: SCHEMA },
      },
    }),
  });

  if (response.status === 429) throw new Error("Yapay zeka istek limiti aşıldı, lütfen biraz sonra tekrar deneyin.");
  if (response.status === 402) throw new Error("Yapay zeka kredisi tükendi. Lütfen çalışma alanınıza kredi ekleyin.");
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Görsel okunamadı (${response.status}): ${text.slice(0, 300)}`);
  }

  const json = (await response.json()) as { choices?: { message?: { content?: string } }[] };
  const content = json.choices?.[0]?.message?.content ?? "";
  let parsed: Partial<ExtractedInvoice>;
  try {
    parsed = JSON.parse(content) as Partial<ExtractedInvoice>;
  } catch {
    throw new Error("Görselden okunan veri çözümlenemedi.");
  }

  const c = parsed.customer ?? ({} as ExtractedInvoice["customer"]);
  return {
    customer: {
      vknTckn: String(c.vknTckn ?? ""),
      title: String(c.title ?? ""),
      taxOffice: String(c.taxOffice ?? ""),
      address: String(c.address ?? ""),
      city: String(c.city ?? ""),
      district: String(c.district ?? ""),
    },
    invoiceDate: String(parsed.invoiceDate ?? ""),
    items: (parsed.items ?? []).slice(0, 50).map((i) => ({
      name: String(i?.name ?? ""),
      unit: String(i?.unit ?? "Adet") || "Adet",
      quantity: Number(i?.quantity) || 1,
      unitPrice: Number(i?.unitPrice) || 0,
      vatRate: Number.isFinite(Number(i?.vatRate)) ? Number(i?.vatRate) : 20,
    })),
    note: String(parsed.note ?? ""),
  };
}
