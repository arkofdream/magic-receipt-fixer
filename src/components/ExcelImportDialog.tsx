import { useState } from "react";
import { Download, Upload } from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { downloadWorkbook, readSheetRows, type SheetRow } from "@/lib/excel";

export type ImportColumn = {
  /** Excel başlığı (şablonda görünen) */
  header: string;
  /** Kabul edilen alternatif başlıklar */
  aliases?: string[];
  example?: string;
};

/**
 * Genel amaçlı Excel içe aktarma penceresi:
 * şablon indirme, dosya seçme, önizleme ve toplu kayıt.
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
  mapRow: (row: SheetRow) => T | null;
  onImport: (rows: T[]) => Promise<void>;
  triggerLabel?: string;
}) {
  const [open, setOpen] = useState(false);
  const [rows, setRows] = useState<T[]>([]);
  const [fileName, setFileName] = useState("");
  const [busy, setBusy] = useState(false);

  function reset() {
    setRows([]);
    setFileName("");
  }

  async function handleFile(file: File) {
    try {
      const sheetRows = await readSheetRows(file);
      const mapped = sheetRows.map(mapRow).filter((r): r is T => r !== null);
      if (mapped.length === 0) {
        toast.error("Dosyada uygun satır bulunamadı. Şablon başlıklarını kullandığınızdan emin olun.");
        return;
      }
      setRows(mapped);
      setFileName(file.name);
      toast.success(`${mapped.length} satır okundu.`);
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
      <DialogContent className="max-h-[85vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
        </DialogHeader>

        <div className="space-y-4">
          <div className="rounded-md border border-border p-4">
            <p className="text-sm font-medium">1. Şablonu indirin</p>
            <p className="mt-1 text-xs text-muted-foreground">
              Başlıklar: {columns.map((c) => c.header).join(", ")}
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
              Şablonu indir (.xlsx)
            </Button>
          </div>

          <div className="rounded-md border border-border p-4">
            <p className="text-sm font-medium">2. Dosyayı seçin (.xlsx, .xls, .csv)</p>
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
              <p className="mt-2 text-xs text-muted-foreground">
                {fileName} — {rows.length} kayıt hazır.
              </p>
            ) : null}
          </div>

          <Button
            className="w-full"
            disabled={rows.length === 0 || busy}
            onClick={async () => {
              setBusy(true);
              try {
                await onImport(rows);
                setOpen(false);
                reset();
              } catch (error) {
                toast.error(error instanceof Error ? error.message : "İçe aktarma başarısız.");
              } finally {
                setBusy(false);
              }
            }}
          >
            {busy ? "Aktarılıyor…" : `${rows.length} kaydı içe aktar`}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}
