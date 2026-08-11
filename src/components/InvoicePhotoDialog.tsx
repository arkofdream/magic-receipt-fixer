import { useRef, useState } from "react";
import { useMutation } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { Camera } from "lucide-react";
import { toast } from "sonner";

import { extractInvoiceFromPhoto, type ExtractedInvoice } from "@/lib/invoice-ocr.functions";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";

function readAsDataUrl(file: File) {
  return new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(new Error("Dosya okunamadı."));
    reader.readAsDataURL(file);
  });
}

/** Görseli en fazla 1600px kenara küçültüp JPEG data URL üretir (istek boyutunu düşürür). */
async function compressImage(file: File): Promise<string> {
  const dataUrl = await readAsDataUrl(file);
  try {
    const img = new Image();
    img.src = dataUrl;
    await img.decode();
    const scale = Math.min(1, 1600 / Math.max(img.width, img.height));
    const canvas = document.createElement("canvas");
    canvas.width = Math.round(img.width * scale);
    canvas.height = Math.round(img.height * scale);
    const ctx = canvas.getContext("2d");
    if (!ctx) return dataUrl;
    ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
    return canvas.toDataURL("image/jpeg", 0.85);
  } catch {
    return dataUrl;
  }
}

/** Fiş/fatura fotoğrafını yapay zeka ile okuyup fatura formunu doldurur. */
export function InvoicePhotoDialog({ onExtracted }: { onExtracted: (data: ExtractedInvoice) => void }) {
  const [open, setOpen] = useState(false);
  const [preview, setPreview] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);
  const extract = useServerFn(extractInvoiceFromPhoto);

  const run = useMutation({
    mutationFn: async (imageDataUrl: string) => extract({ data: { imageDataUrl } }),
    onSuccess: (data) => {
      onExtracted(data);
      toast.success("Fotoğraftan bilgiler forma aktarıldı. Lütfen kontrol edin.");
      setOpen(false);
      setPreview("");
    },
    onError: (e: Error) => toast.error(e.message),
  });

  async function handleFile(file: File) {
    const dataUrl = await compressImage(file);
    setPreview(dataUrl);
    run.mutate(dataUrl);
  }

  return (
    <Dialog
      open={open}
      onOpenChange={(v) => {
        setOpen(v);
        if (!v) setPreview("");
      }}
    >
      <DialogTrigger asChild>
        <Button variant="outline" className="gap-2">
          <Camera className="size-4" />
          Fotoğraftan Doldur
        </Button>
      </DialogTrigger>
      <DialogContent className="max-h-[85vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Fotoğraftan Fatura Oluştur</DialogTitle>
        </DialogHeader>
        <div className="space-y-4">
          <p className="text-sm text-muted-foreground">
            Fiş veya faturanın net bir fotoğrafını yükleyin; alıcı bilgileri ve kalemler otomatik doldurulur.
            Kaydetmeden önce bilgileri mutlaka kontrol edin.
          </p>
          <input
            ref={inputRef}
            type="file"
            accept="image/*"
            capture="environment"
            className="hidden"
            onChange={(e) => {
              const file = e.target.files?.[0];
              e.target.value = "";
              if (file) void handleFile(file);
            }}
          />
          <Button onClick={() => inputRef.current?.click()} disabled={run.isPending} className="w-full">
            {run.isPending ? "Okunuyor…" : "Fotoğraf Seç / Çek"}
          </Button>
          {preview ? (
            <img src={preview} alt="Yüklenen fatura fotoğrafı önizlemesi" className="max-h-64 w-full rounded-md object-contain" />
          ) : null}
        </div>
      </DialogContent>
    </Dialog>
  );
}
