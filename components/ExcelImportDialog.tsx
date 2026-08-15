import { useState } from "react";
import {
  AlertCircle,
  CheckCircle2,
  Download,
  FileSpreadsheet,
  Loader2,
  Upload,
} from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { downloadWorkbook, readSheetRows, type SheetRow } from "@/lib/excel";

export type ImportColumn = {
  /** Excel başlığı (şablonda görünen) */
  header: string;
  /** Kabul edilen alternatif başlıklar */
  aliases?: string[];
  example?: string;
};

export type RowParseResult<T> = {
  success: boolean;
  rowNumber: number;
  data?: T;
  error?: string;
};

/**
 * Genel amaçlı Excel içe aktarma penceresi:
 * şablon indirme, dosya seçme, satır bazlı doğrulama raporu ve güvenli toplu kayıt.
 */
export function ExcelImportDialog<T>({
  title,
  templateName,
  columns,
  mapRow,
  onImport,
  triggerLabel = "Excel'den İçe Aktar",
}: {
  title: string;
  templateName: string;
  columns: ImportColumn[];
  mapRow: (row: SheetRow, rowNumber: number) => { data?: T; error?: string } | T | null;
  onImport: (rows: T[]) => Promise<void>;
  triggerLabel?: string;
}) {
  const [open, setOpen] = useState(false);
  const [validRows, setValidRows] = useState<T[]>([]);
  const [errors, setErrors] = useState<{ rowNumber: number; reason: string }[]>([]);
  const [fileName, setFileName] = useState("");
  const [busy, setBusy] = useState(false);

  function reset() {
    setValidRows([]);
    setErrors([]);
    setFileName("");
  }

  async function handleFile(file: File) {
    reset();
    try {
      const sheetRows = await readSheetRows(file);
      if (sheetRows.length === 0) {
        toast.error("Dosyada okunabilir satır bulunamadı.");
        return;
      }

      const parsedValid: T[] = [];
      const parsedErrors: { rowNumber: number; reason: string }[] = [];

      sheetRows.forEach((row, idx) => {
        const rowNumber = idx + 2; // 1-indexed, header is row 1
        try {
          const res = mapRow(row, rowNumber);
          if (res === null) {
            // Empty row, skip
            return;
          }
          if (typeof res === "object" && res !== null && "error" in res && res.error) {
            parsedErrors.push({ rowNumber, reason: res.error });
          } else if (typeof res === "object" && res !== null && "data" in res && res.data) {
            parsedValid.push(res.data);
          } else {
            parsedValid.push(res as T);
          }
        } catch (err) {
          parsedErrors.push({
            rowNumber,
            reason: err instanceof Error ? err.message : "Satır verisi işlenemedi.",
          });
        }
      });

      setValidRows(parsedValid);
      setErrors(parsedErrors);
      setFileName(file.name);

      if (parsedValid.length > 0) {
        toast.success(`${parsedValid.length} geçerli satır ayrıştırıldı.`);
      } else {
        toast.error("Hiçbir geçerli satır bulunamadı. Lütfen şablon formatını kontrol ediniz.");
      }
    } catch (error) {
      toast.error(error instanceof Error ? error.message : "Dosya okunamadı.");
    }
  }

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        setOpen(next);
        if (!next) reset();
      }}
    >
      <DialogTrigger asChild>
        <Button variant="outline" className="gap-2">
          <Upload className="size-4" />
          {triggerLabel}
        </Button>
      </DialogTrigger>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-lg">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <FileSpreadsheet className="size-5 text-primary" />
            {title}
          </DialogTitle>
        </DialogHeader>

        <div className="space-y-4">
          <div className="rounded-md border border-border bg-card p-4">
            <p className="text-sm font-semibold">1. Şablon Excel Dosyasını İndirin</p>
            <p className="mt-1 text-xs text-muted-foreground">
              Kolonlar: {columns.map((c) => c.header).join(", ")}
            </p>
            <Button
              variant="secondary"
              size="sm"
              className="mt-3 gap-2"
              onClick={() =>
                downloadWorkbook(
                  columns.map((c) => c.header),
                  [columns.map((c) => c.example ?? "")],
                  templateName,
                )
              }
            >
              <Download className="size-4" />
              Şablonu İndir (.xlsx)
            </Button>
          </div>

          <div className="rounded-md border border-border bg-card p-4">
            <p className="text-sm font-semibold">2. Hazırlanan Dosyayı Seçin</p>
            <Input
              type="file"
              accept=".xlsx,.xls,.csv"
              className="mt-3"
              onChange={(e) => {
                const file = e.target.files?.[0];
                if (file) void handleFile(file);
              }}
            />

            {fileName ? (
              <div className="mt-3 space-y-2">
                <div className="flex flex-wrap items-center gap-2 text-xs">
                  <span className="font-medium text-foreground">{fileName}:</span>
                  <Badge variant="default" className="gap-1 bg-emerald-600">
                    <CheckCircle2 className="size-3" /> {validRows.length} Geçerli Satır
                  </Badge>
                  {errors.length > 0 ? (
                    <Badge variant="destructive" className="gap-1">
                      <AlertCircle className="size-3" /> {errors.length} Hatalı Satır
                    </Badge>
                  ) : null}
                </div>

                {errors.length > 0 ? (
                  <div className="max-h-36 overflow-y-auto rounded border border-destructive/30 bg-destructive/5 p-2 text-xs">
                    <p className="font-semibold text-destructive">Hatalı Satırlar ve Nedenleri:</p>
                    <ul className="mt-1 list-disc space-y-1 pl-4 text-muted-foreground">
                      {errors.slice(0, 10).map((err, i) => (
                        <li key={i}>
                          <span className="font-semibold text-foreground">
                            Satır {err.rowNumber}:
                          </span>{" "}
                          {err.reason}
                        </li>
                      ))}
                      {errors.length > 10 ? (
                        <li className="text-xs italic">
                          … ve {errors.length - 10} hatalı satır daha
                        </li>
                      ) : null}
                    </ul>
                  </div>
                ) : null}
              </div>
            ) : null}
          </div>

          <Button
            className="w-full gap-2"
            disabled={validRows.length === 0 || busy}
            onClick={async () => {
              setBusy(true);
              try {
                await onImport(validRows);
                toast.success(`${validRows.length} kayıt başarıyla içe aktarıldı.`);
                setOpen(false);
                reset();
              } catch (error) {
                toast.error(
                  error instanceof Error ? error.message : "İçe aktarma sırasında bir hata oluştu.",
                );
              } finally {
                setBusy(false);
              }
            }}
          >
            {busy ? (
              <>
                <Loader2 className="size-4 animate-spin" /> Aktarılıyor…
              </>
            ) : (
              `${validRows.length} Kaydı İçe Aktar`
            )}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}
