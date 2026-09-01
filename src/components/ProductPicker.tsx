import { useEffect, useMemo, useRef, useState } from "react";
import { Package, Briefcase, X } from "lucide-react";

import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";

export type PickerProduct = {
  id: string;
  name: string;
  code?: string | null;
  unit?: string | null;
  category?: string | null;
  track_stock?: boolean | null;
};

export function isServiceProduct(p: Pick<PickerProduct, "category" | "track_stock">): boolean {
  return (p.category ?? "").toLocaleLowerCase("tr") === "hizmet" || p.track_stock === false;
}

type Props = {
  value: string;
  productId?: string | undefined;
  locked?: boolean | undefined;
  products: PickerProduct[];
  disabled?: boolean;
  placeholder?: string;
  className?: string;
  /** Katalogdan bir ürün seçildi */
  onSelectProduct: (productId: string) => void;
  /** Serbest metin kalem onaylandı */
  onCommitFreeText: (name: string) => void;
  /** Kullanıcı yazarken (henüz seçim yok) */
  onTextChange: (name: string) => void;
  /** Chip kaldırıldı */
  onClear: () => void;
  /** Seçim tamamlandıktan sonra bir sonraki alana geçiş için (opsiyonel) */
  onCommitted?: () => void;
};

const MAX_RESULTS = 30;

export function ProductPicker({
  value,
  productId,
  locked,
  products,
  disabled,
  placeholder = "Katalogdan seç veya yaz...",
  className,
  onSelectProduct,
  onCommitFreeText,
  onTextChange,
  onClear,
  onCommitted,
}: Props) {
  const [open, setOpen] = useState(false);
  const [highlight, setHighlight] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);
  const wrapRef = useRef<HTMLDivElement>(null);

  const query = value.trim().toLocaleLowerCase("tr");
  const results = useMemo(() => {
    if (!query) return products.slice(0, MAX_RESULTS);
    return products
      .filter((p) => {
        const name = (p.name ?? "").toLocaleLowerCase("tr");
        const code = (p.code ?? "").toLocaleLowerCase("tr");
        return name.includes(query) || code.includes(query);
      })
      .slice(0, MAX_RESULTS);
  }, [products, query]);

  useEffect(() => {
    setHighlight(0);
  }, [query, open]);

  useEffect(() => {
    if (!open) return;
    function onDocDown(e: MouseEvent) {
      if (!wrapRef.current?.contains(e.target as Node)) setOpen(false);
    }
    document.addEventListener("mousedown", onDocDown);
    return () => document.removeEventListener("mousedown", onDocDown);
  }, [open]);

  const selectedProduct = productId ? products.find((p) => p.id === productId) : undefined;
  const showChip = Boolean(locked) && value.trim() !== "";

  function commit(index: number) {
    const picked = results[index];
    if (picked) {
      onSelectProduct(picked.id);
    } else if (value.trim() !== "") {
      onCommitFreeText(value.trim());
    } else {
      return;
    }
    setOpen(false);
    onCommitted?.();
  }

  if (showChip) {
    const service = selectedProduct ? isServiceProduct(selectedProduct) : !productId;
    return (
      <div className={cn("flex min-h-8 flex-wrap items-center gap-1.5", className)}>
        <span
          className={cn(
            "inline-flex max-w-full items-center gap-1.5 rounded-full border px-2.5 py-1 text-xs font-semibold",
            service
              ? "border-amber-500/40 bg-amber-500/10 text-amber-700 dark:text-amber-400"
              : "border-primary/40 bg-primary/10 text-primary",
          )}
          title={selectedProduct ? selectedProduct.name : "Serbest metin kalem"}
        >
          {service ? <Briefcase className="size-3 shrink-0" /> : <Package className="size-3 shrink-0" />}
          <span className="truncate">{value}</span>
          {!productId && <span className="opacity-70">(serbest)</span>}
          {!disabled && (
            <button
              type="button"
              aria-label="Kalem seçimini kaldır"
              className="ml-0.5 rounded-full p-0.5 hover:bg-foreground/10"
              onClick={() => {
                onClear();
                setOpen(false);
                requestAnimationFrame(() => inputRef.current?.focus());
              }}
            >
              <X className="size-3" />
            </button>
          )}
        </span>
      </div>
    );
  }

  return (
    <div ref={wrapRef} className={cn("relative", className)}>
      <Input
        ref={inputRef}
        role="combobox"
        aria-expanded={open}
        aria-autocomplete="list"
        autoComplete="off"
        className="h-8 text-xs bg-background"
        placeholder={placeholder}
        value={value}
        disabled={disabled}
        onFocus={() => setOpen(true)}
        onChange={(e) => {
          onTextChange(e.target.value);
          setOpen(true);
        }}
        onKeyDown={(e) => {
          if (e.key === "ArrowDown") {
            e.preventDefault();
            setOpen(true);
            setHighlight((h) => Math.min(h + 1, Math.max(results.length - 1, 0)));
            return;
          }
          if (e.key === "ArrowUp") {
            e.preventDefault();
            setHighlight((h) => Math.max(h - 1, 0));
            return;
          }
          if (e.key === "Escape") {
            if (open) {
              e.preventDefault();
              e.stopPropagation();
              setOpen(false);
            }
            return;
          }
          if (e.key === "Enter") {
            // Autocomplete açıkken Enter önce seçim yapar, formu göndermez.
            e.preventDefault();
            e.stopPropagation();
            commit(open && results.length > 0 ? highlight : -1);
            return;
          }
          if (e.key === "Tab") {
            if (open && results.length > 0 && value.trim() !== "") {
              commit(highlight);
            } else if (value.trim() !== "") {
              commit(-1);
            }
          }
        }}
      />

      {open && (
        <div className="absolute z-50 mt-1 max-h-60 w-full min-w-[240px] overflow-auto rounded-md border border-border bg-popover p-1 shadow-lg">
          {results.length === 0 ? (
            <div className="px-2 py-2 text-xs text-muted-foreground">
              {value.trim()
                ? "Katalogda bulunamadı — Enter ile serbest kalem olarak ekleyin."
                : "Katalogda ürün bulunmuyor."}
            </div>
          ) : (
            results.map((p, i) => {
              const service = isServiceProduct(p);
              return (
                <button
                  key={p.id}
                  type="button"
                  className={cn(
                    "flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-xs",
                    i === highlight ? "bg-accent text-accent-foreground" : "hover:bg-accent/60",
                  )}
                  onMouseEnter={() => setHighlight(i)}
                  // mousedown: input blur olmadan seçim yapılır
                  onMouseDown={(e) => {
                    e.preventDefault();
                    commit(i);
                  }}
                >
                  {service ? (
                    <Briefcase className="size-3.5 shrink-0 text-amber-600" />
                  ) : (
                    <Package className="size-3.5 shrink-0 text-primary" />
                  )}
                  <span className="truncate font-medium">{p.name}</span>
                  {p.code ? <span className="ml-auto shrink-0 font-mono text-[10px] text-muted-foreground">{p.code}</span> : null}
                </button>
              );
            })
          )}
        </div>
      )}
    </div>
  );
}
