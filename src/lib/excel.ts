import * as XLSX from "xlsx";

export type SheetRow = Record<string, string>;

/** Excel/CSV dosyasını okuyup ilk sayfayı satır nesnelerine çevirir. */
export async function readSheetRows(file: File): Promise<SheetRow[]> {
  const buffer = await file.arrayBuffer();
  const workbook = XLSX.read(buffer, { type: "array" });
  const sheetName = workbook.SheetNames[0];
  if (!sheetName) return [];
  const sheet = workbook.Sheets[sheetName];
  if (!sheet) return [];
  const rows = XLSX.utils.sheet_to_json<Record<string, unknown>>(sheet, { defval: "", raw: false });
  return rows.map((row) => {
    const normalized: SheetRow = {};
    for (const [key, value] of Object.entries(row)) {
      normalized[String(key).trim()] = value == null ? "" : String(value).trim();
    }
    return normalized;
  });
}

/** Verilen başlık ve satırlarla bir .xlsx dosyası indirir (şablon veya dışa aktarım). */
export function downloadWorkbook(
  headers: string[],
  rows: (string | number)[][],
  filename: string,
  sheetName = "Sayfa1",
) {
  const sheet = XLSX.utils.aoa_to_sheet([headers, ...rows]);
  sheet["!cols"] = headers.map((h) => ({ wch: Math.max(14, h.length + 4) }));
  const workbook = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(workbook, sheet, sheetName);
  XLSX.writeFile(workbook, filename);
}

/** Başlıkları esnek eşleştirir: büyük/küçük harf, boşluk ve Türkçe karakter farklarını yok sayar. */
export function normalizeHeader(value: string) {
  return value
    .toLocaleLowerCase("tr-TR")
    .replace(/[ıi̇]/g, "i")
    .replace(/ş/g, "s")
    .replace(/ğ/g, "g")
    .replace(/ü/g, "u")
    .replace(/ö/g, "o")
    .replace(/ç/g, "c")
    .replace(/[^a-z0-9]/g, "");
}

export function pickColumn(row: SheetRow, candidates: string[]): string {
  const wanted = candidates.map(normalizeHeader);
  for (const [key, value] of Object.entries(row)) {
    if (wanted.includes(normalizeHeader(key))) return value;
  }
  return "";
}

export function parseNumber(value: string): number {
  if (!value) return 0;
  const cleaned = value.replace(/\s|₺|TL/gi, "").replace(/\.(?=\d{3}(\D|$))/g, "").replace(",", ".");
  const parsed = Number(cleaned);
  return Number.isFinite(parsed) ? parsed : 0;
}
