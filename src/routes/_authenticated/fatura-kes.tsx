import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { Trash2, AlertCircle, Info, Check, Edit, PlusCircle, ArrowLeft, ShoppingCart, Send, RotateCcw } from "lucide-react";
import { toast } from "sonner";

import { AppShell } from "@/components/AppShell";
import { AddressSelect } from "@/components/AddressSelect";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import { ChevronsUpDown } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { isMissingColumnError } from "@/lib/safe-supabase";
import {
  emptyCustomer,
  formatMoney,
  generateEttn,
  INVOICE_TYPES,
  INVOICE_TYPE_DETAILS,
  TEVKIFAT_CODES,
  TEVKIFAT_RATES,
  EXEMPTION_CODES,
  CURRENCY_OPTIONS,
  UNIT_OPTIONS,
  VAT_RATES,
  invoiceTotals,
  itemTotals,
  newItem,
  numberToTurkishWords,
  roundMoney,
  isValidVknTckn,
  type InvoiceCustomer,
  type InvoiceItem,
} from "@/lib/invoice";

type SearchParams = {
  editId?: string | undefined;
  mode?: "SATIS" | "ALIS" | "ALIS_IADE" | undefined;
  returnInvoiceId?: string | undefined;
};

export const Route = createFileRoute("/_authenticated/fatura-kes")({
  validateSearch: (search: Record<string, unknown>): SearchParams => {
    const editId = search["editId"];
    const mode = search["mode"] as "SATIS" | "ALIS" | "ALIS_IADE" | undefined;
    const returnInvoiceId = search["returnInvoiceId"] as string | undefined;
    return {
      editId: typeof editId === "string" ? editId : undefined,
      mode: mode === "ALIS" || mode === "ALIS_IADE" || mode === "SATIS" ? mode : undefined,
      returnInvoiceId: typeof returnInvoiceId === "string" ? returnInvoiceId : undefined,
    };
  },
  head: () => ({
    meta: [
      { title: "Fatura Kes & Alış Girişi | e-Fatura Portalı" },
      {
        name: "description",
        content:
          "Satış faturası kesin, tedarikçi alış faturası işleyin veya alış iadesi oluşturun. KDV ve tevkifat otomatik hesaplanır.",
      },
      { property: "og:title", content: "Fatura Kes & Alış Girişi | e-Fatura Portalı" },
      { property: "og:description", content: "Satış, alış ve iade faturaları yönetimi." },
    ],
  }),
  component: NewInvoicePage,
});

function ProductCombobox({
  value,
  onSelect,
  disabled,
  products,
  isLoading,
  operationMode,
}: {
  value?: string;
  onSelect: (id: string) => void;
  disabled?: boolean;
  products: Array<{ id: string; name: string; code?: string; unit_price?: number; purchase_price?: number }>;
  isLoading?: boolean;
  operationMode?: string;
}) {
  const [open, setOpen] = useState(false);
  const selectedProduct = products.find((p) => p.id === value);

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button
          variant="outline"
          role="combobox"
          aria-expanded={open}
          disabled={disabled}
          className="h-8 w-full justify-between text-xs bg-background font-normal px-2.5"
        >
          <span className="truncate">
            {selectedProduct ? selectedProduct.name : "Katalogdan ürün seç (isteğe bağlı)..."}
          </span>
          <ChevronsUpDown className="ml-1 size-3.5 shrink-0 opacity-50" />
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-[320px] sm:w-[360px] p-0" align="start">
        <Command>
          <CommandInput placeholder="Ürün adı veya kodu ara..." className="h-8 text-xs" />
          <CommandList className="max-h-[220px] overflow-y-auto">
            {isLoading ? (
              <div className="p-3 text-xs text-muted-foreground text-center">Ürünler yükleniyor...</div>
            ) : (
              <>
                <CommandEmpty className="py-3 text-xs text-muted-foreground text-center">
                  Ürün bulunamadı.
                </CommandEmpty>
                <CommandGroup>
                  {products.map((p) => {
                    const isPurchase = operationMode === "ALIS" || operationMode === "ALIS_IADE";
                    const priceText = isPurchase
                      ? `Alış: ${formatMoney(p.purchase_price ?? 0)}`
                      : `Satış: ${formatMoney(p.unit_price ?? 0)}`;
                    const isSelected = p.id === value;

                    return (
                      <CommandItem
                        key={p.id}
                        value={`${p.name} ${p.code || ""}`}
                        onSelect={() => {
                          onSelect(p.id);
                          setOpen(false);
                        }}
                        className="text-xs flex items-center justify-between py-1.5 px-2 cursor-pointer"
                      >
                        <div className="flex items-center gap-2 truncate">
                          <Check
                            className={`size-3.5 text-primary ${
                              isSelected ? "opacity-100" : "opacity-0"
                            }`}
                          />
                          <span className="truncate font-medium">{p.name}</span>
                        </div>
                        <span className="text-[10px] text-muted-foreground font-mono ml-2 shrink-0">
                          {priceText}
                        </span>
                      </CommandItem>
                    );
                  })}
                </CommandGroup>
              </>
            )}
          </CommandList>
        </Command>
      </PopoverContent>
    </Popover>
  );
}

function NewInvoicePage() {
  const navigate = useNavigate();
  const searchParams = Route.useSearch();
  const editId = searchParams.editId;
  const initialMode = searchParams.mode || "SATIS";
  const returnInvoiceId = searchParams.returnInvoiceId;
  const queryClient = useQueryClient();

  const [operationMode, setOperationMode] = useState<"SATIS" | "ALIS" | "ALIS_IADE">(initialMode);
  const [type, setType] = useState("SATIS");
  const [currency, setCurrency] = useState("TRY");
  const [date, setDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [customer, setCustomer] = useState<InvoiceCustomer>(emptyCustomer);
  const [customerId, setCustomerId] = useState<string>("");
  const [supplierInvoiceNumber, setSupplierInvoiceNumber] = useState<string>("");
  const [originalInvoiceId, setOriginalInvoiceId] = useState<string>(returnInvoiceId || "");
  const [warehouseId, setWarehouseId] = useState<string>("");
  const [serialPrefix, setSerialPrefix] = useState("EAR");
  const [items, setItems] = useState<InvoiceItem[]>([newItem()]);
  const [selectedTevkifatCode, setSelectedTevkifatCode] = useState<string>("");
  const [selectedExemptionCode, setSelectedExemptionCode] = useState<string>("301");
  const [tevkifatRate, setTevkifatRate] = useState("0");
  const [notes, setNotes] = useState("");
  const [paymentInfo, setPaymentInfo] = useState("");

  const { data: customers = [] } = useQuery({
    queryKey: ["customers"],
    queryFn: async () => {
      const { data, error } = await supabase.from("customers").select("*").order("title");
      if (error) throw error;
      return data ?? [];
    },
  });

  const {
    data: products = [],
    isLoading: productsLoading,
    error: productsError,
  } = useQuery({
    queryKey: ["products", "catalog"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("products")
        .select("*")
        .is("deleted_at", null)
        .order("name");
      if (error) throw error;
      return data ?? [];
    },
    staleTime: 0,
    refetchOnMount: "always",
  });

  const { data: warehouses = [] } = useQuery({
    queryKey: ["warehouses"],
    queryFn: async () => {
      const { data, error } = await supabase.from("warehouses").select("*").order("name");
      if (error) throw error;
      return data ?? [];
    },
  });

  // Alış faturaları listesi (Alış iadesi için kaynak fatura seçimi)
  const { data: purchaseInvoices = [] } = useQuery({
    queryKey: ["invoices", "purchase-list"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("invoices")
        .select("*")
        .in("type", ["ALIS", "GELEN_FATURA", "GELEN_E_ARSIV"])
        .eq("status", "ONAYLANDI")
        .order("invoice_date", { ascending: false });
      if (error) throw error;
      return data ?? [];
    },
  });

  // Eğer Düzenleme (editId) modundaysak faturayı yükle
  const { data: existingInvoice } = useQuery({
    queryKey: ["invoice-detail", editId],
    queryFn: async () => {
      if (!editId) return null;
      const { data, error } = await supabase.from("invoices").select("*").eq("id", editId).single();
      if (error) throw error;
      return data;
    },
    enabled: Boolean(editId),
  });

  const isNonEditable = Boolean(
    existingInvoice && (existingInvoice.status !== "TASLAK" || existingInvoice.posted)
  );

  useEffect(() => {
    if (!existingInvoice) return;
    const invType = existingInvoice.type || "SATIS";
    setType(invType);
    if (invType === "ALIS" || invType === "GELEN_FATURA" || invType === "GELEN_E_ARSIV") {
      setOperationMode("ALIS");
      setSupplierInvoiceNumber(existingInvoice.invoice_number || "");
    } else if (invType === "ALIS_IADE") {
      setOperationMode("ALIS_IADE");
    } else {
      setOperationMode("SATIS");
    }

    setCurrency(existingInvoice.currency || "TRY");
    setDate(existingInvoice.invoice_date || new Date().toISOString().slice(0, 10));
    setCustomerId(existingInvoice.customer_id || "");
    setWarehouseId(existingInvoice.warehouse_id || "");
    setNotes(existingInvoice.notes || "");
    setPaymentInfo(existingInvoice.payment_info || "");

    const customPrefix = existingInvoice.invoice_number ? existingInvoice.invoice_number.slice(0, 3) : "EAR";
    setSerialPrefix(customPrefix);

    if (existingInvoice.customer && typeof existingInvoice.customer === "object") {
      const c = existingInvoice.customer as Partial<InvoiceCustomer>;
      setCustomer({
        vknTckn: c.vknTckn || "",
        title: c.title || "",
        taxOffice: c.taxOffice || "",
        address: c.address || "",
        city: c.city || "",
        district: c.district || "",
        neighborhood: c.neighborhood || "",
        email: c.email || "",
        phone: c.phone || "",
        customPrefix: c.customPrefix || customPrefix,
      });
    }

    if (Array.isArray(existingInvoice.items) && existingInvoice.items.length > 0) {
      setItems(existingInvoice.items as InvoiceItem[]);
    }
  }, [existingInvoice]);

  // Alış İadesi modunda orijinal fatura seçildiğinde kalemleri ve tedarikçiyi otomatik doldur
  function handleSelectOriginalPurchaseInvoice(invId: string) {
    setOriginalInvoiceId(invId);
    const orig = purchaseInvoices.find((i) => i.id === invId);
    if (orig) {
      if (orig.customer_id) {
        setCustomerId(orig.customer_id);
      }
      if (orig.customer && typeof orig.customer === "object") {
        const c = orig.customer as Partial<InvoiceCustomer>;
        setCustomer({
          vknTckn: c.vknTckn || "",
          title: c.title || "",
          taxOffice: c.taxOffice || "",
          address: c.address || "",
          city: c.city || "",
          district: c.district || "",
          neighborhood: c.neighborhood || "",
          email: c.email || "",
          phone: c.phone || "",
          customPrefix: "",
        });
      }
      if (Array.isArray(orig.items) && orig.items.length > 0) {
        setItems(orig.items as InvoiceItem[]);
      }
      setWarehouseId(orig.warehouse_id || "");
      setSupplierInvoiceNumber(`IADE-${orig.invoice_number || ""}`);
    }
  }

  const isTevkifatli = operationMode === "SATIS" && (type === "TEVKIFAT" || Boolean(selectedTevkifatCode));
  const activeTevkifatRate = isTevkifatli ? Number(tevkifatRate) || 0 : 0;
  const totals = invoiceTotals(items, activeTevkifatRate);
  const wordsAmount = numberToTurkishWords(totals.grandTotal, currency);

  function handleTevkifatCodeChange(code: string) {
    setSelectedTevkifatCode(code);
    const found = TEVKIFAT_CODES.find((c) => c.code === code);
    if (found) {
      setTevkifatRate(String(found.rate));
    }
  }

  function addItem() {
    setItems((prev) => [...prev, newItem()]);
  }

  function removeItem(id: string) {
    if (items.length <= 1) {
      toast.error("En az bir kalem bulunmalıdır.");
      return;
    }
    setItems((prev) => prev.filter((i) => i.id !== id));
  }

  function updateItem(id: string, updates: Partial<InvoiceItem>) {
    setItems((prev) => prev.map((i) => (i.id === id ? { ...i, ...updates } : i)));
  }

  function handleProductSelect(itemId: string, productId: string) {
    const product = products.find((p) => p.id === productId);
    if (!product) return;
    const isPurchase = operationMode === "ALIS" || operationMode === "ALIS_IADE";
    const selectedPrice = isPurchase
      ? Number(product.purchase_price ?? product.unit_price ?? 0)
      : Number(product.unit_price ?? 0);

    updateItem(itemId, {
      productId: product.id,
      name: product.name,
      unit: product.unit || "Adet",
      unitPrice: selectedPrice,
      vatRate: Number(product.vat_rate ?? 20),
    });
  }

  function handleSelectCustomer(id: string) {
    setCustomerId(id);
    const c = customers.find((cust) => cust.id === id);
    if (!c) return;
    const prefix = c.code ? c.code.slice(0, 3).toUpperCase() : serialPrefix;
    setSerialPrefix(prefix);
    setCustomer({
      vknTckn: c.vkn_tckn || "",
      title: c.title || "",
      taxOffice: c.tax_office || "",
      address: c.address || "",
      city: c.city || "",
      district: c.district || "",
      neighborhood: c.neighborhood || "",
      email: c.email || "",
      phone: c.phone || "",
      customPrefix: prefix,
    });
  }

function isInvalidQuantity(qty: number | undefined | null): boolean {
  if (qty === undefined || qty === null || isNaN(qty)) return true;
  return qty <= 0;
}

  const saveInvoice = useMutation({
    mutationFn: async (newStatus: "TASLAK" | "ONAYLANDI" = "TASLAK") => {
      if (isNonEditable) {
        throw new Error("Onaylanmış veya iptal edilmiş faturalar düzenlenemez.");
      }
      if (!customer.vknTckn.trim() || !customer.title.trim()) {
        throw new Error(operationMode === "ALIS" ? "Tedarikçi VKN/TCKN ve unvan bilgileri zorunludur." : "Alıcı VKN/TCKN ve unvan bilgileri zorunludur.");
      }
      if (items.length === 0 || items.some((i) => !i.name.trim())) {
        throw new Error("En az bir geçerli açıklamayla fatura kalemi girmelisiniz.");
      }
      const invalidQtyIndex = items.findIndex((i) => isInvalidQuantity(i.quantity));
      if (invalidQtyIndex !== -1) {
        throw new Error(`${invalidQtyIndex + 1}. kalem için miktar 0'dan büyük bir sayı olmalıdır.`);
      }

      const { data: userData } = await supabase.auth.getUser();
      const userId = userData.user?.id;
      if (!userId) throw new Error("Oturum bulunamadı. Lütfen yeniden giriş yapınız.");

      if (operationMode === "ALIS") {
        // --- 1. ALIŞ FATURASI AKIŞI (create_purchase_invoice) ---
        if (!customerId) {
          throw new Error("Tedarikçi seçimi zorunludur.");
        }
        if (!supplierInvoiceNumber.trim()) {
          throw new Error("Tedarikçi fatura numarası zorunludur.");
        }

        const { data: _result, error } = await supabase.rpc("create_purchase_invoice", {
          p_invoice_date: date,
          p_supplier_id: customerId,
          p_invoice_number: supplierInvoiceNumber.trim(),
          p_warehouse_id: warehouseId || null,
          p_supplier_info: JSON.parse(JSON.stringify(customer)),
          p_items: JSON.parse(JSON.stringify(items)),
          p_subtotal: totals.subtotal,
          p_total_discount: totals.totalDiscount,
          p_taxable_amount: totals.taxableAmount,
          p_total_vat: totals.totalVat,
          p_total_tevkifat: 0,
          p_grand_total: totals.grandTotal,
          p_currency: currency,
          p_exchange_rate: 1,
          p_notes: notes.trim(),
          p_payment_info: paymentInfo.trim(),
          p_ettn: generateEttn(),
          p_status: newStatus,
        });
        if (error) throw error;

      } else if (operationMode === "ALIS_IADE") {
        // --- 2. ALIŞ İADESİ AKIŞI (create_purchase_return) ---
        if (!originalInvoiceId) {
          throw new Error("İade edilecek orijinal alış faturası seçilmelidir.");
        }
        if (!supplierInvoiceNumber.trim()) {
          throw new Error("İade fatura/irsaliye numarası zorunludur.");
        }

        const { data: _result, error } = await supabase.rpc("create_purchase_return", {
          p_original_invoice_id: originalInvoiceId,
          p_return_date: date,
          p_return_invoice_number: supplierInvoiceNumber.trim(),
          p_items: JSON.parse(JSON.stringify(items)),
          p_warehouse_id: warehouseId || null,
          p_notes: notes.trim(),
        });
        if (error) throw error;

      } else {
        // --- 3. SATIŞ FATURASI AKIŞI (Mevcut Mantık Korundu) ---
        if (editId && existingInvoice) {
          const shouldPost = newStatus === "ONAYLANDI";
          const { error: updateError } = await supabase
            .from("invoices")
            .update({
              customer_id: customerId || null,
              warehouse_id: warehouseId || null,
              type,
              status: newStatus,
              posted: shouldPost,
              gib_approval_date: shouldPost ? new Date().toISOString() : null,
              invoice_date: date,
              currency,
              exchange_rate: 1,
              customer: JSON.parse(JSON.stringify(customer)),
              items: JSON.parse(JSON.stringify(items)),
              subtotal: totals.subtotal,
              total_discount: totals.totalDiscount,
              taxable_amount: totals.taxableAmount,
              total_vat: totals.totalVat,
              total_tevkifat: totals.totalTevkifat,
              grand_total: totals.grandTotal,
              notes: notes.trim(),
              payment_info: paymentInfo.trim(),
            })
            .eq("id", editId);
          if (updateError) throw updateError;
        } else {
          const ettn = generateEttn();
          const cleanPrefix = (serialPrefix || customer.customPrefix || "EAR").trim().toUpperCase().slice(0, 3);
          const { data: _result, error } = await supabase.rpc("create_sales_invoice", {
            p_invoice_date: date,
            p_type: type,
            p_status: newStatus,
            p_customer_id: customerId || null,
            p_warehouse_id: warehouseId || null,
            p_customer_info: JSON.parse(JSON.stringify({ ...customer, customPrefix: cleanPrefix })),
            p_items: JSON.parse(JSON.stringify(items)),
            p_subtotal: totals.subtotal,
            p_total_discount: totals.totalDiscount,
            p_taxable_amount: totals.taxableAmount,
            p_total_vat: totals.totalVat,
            p_total_tevkifat: totals.totalTevkifat,
            p_grand_total: totals.grandTotal,
            p_currency: currency,
            p_exchange_rate: 1,
            p_notes: notes.trim(),
            p_payment_info: paymentInfo.trim(),
            p_ettn: ettn,
            p_prefix: cleanPrefix,
          });
          if (error) throw error;

          if (newStatus === "ONAYLANDI" && (operationMode === "SATIS" || type === "E_ARSIV" || type === "SATIS")) {
            try {
              const { sendInvoiceToProvider } = await import("@/lib/efatura-settings.functions");
              const res = await sendInvoiceToProvider({
                data: {
                  ettn,
                  invoiceNumber: (_result as any)?.invoice_number || ettn,
                  customerName: customer.title || (customer as any).name || "",
                  customerTaxNumber: customer.vknTckn,
                  grandTotal: totals.grandTotal,
                  type,
                  isDirectSend: "true",
                  items: JSON.parse(JSON.stringify(items)),
                },
              });
              if (res && res.ok) {
                toast.success("Fatura NES Bilgi servisine başarıyla yüklendi!");
              } else if (res && res.message) {
                toast.info(`Entegratör Yanıtı: ${res.message}`);
              }
            } catch (providerErr) {
              console.error("Entegratör gönderim uyarısı:", providerErr);
            }
          }
        }
      }
    },
    onSuccess: (_data, newStatus) => {
      toast.success(
        operationMode === "ALIS"
          ? "Alış faturası başarıyla kaydedildi; 153/191/320 muhasebe fişi ve stok girişi işlendi."
          : operationMode === "ALIS_IADE"
            ? "Alış iadesi başarıyla işlendi; 320/153/191 fişi ve stok çıkışı yapıldı."
            : editId
              ? "Fatura başarıyla güncellendi."
              : newStatus === "ONAYLANDI"
                ? "Fatura başarıyla onaylandı; cari ve stok hareketleri işlendi."
                : "Fatura taslak olarak başarıyla kaydedildi.",
      );
      queryClient.invalidateQueries({ queryKey: ["invoices"] });
      queryClient.invalidateQueries({ queryKey: ["customers"] });
      queryClient.invalidateQueries({ queryKey: ["customer-balances"] });
      queryClient.invalidateQueries({ queryKey: ["account-transactions"] });
      queryClient.invalidateQueries({ queryKey: ["stock-movements"] });
      queryClient.invalidateQueries({ queryKey: ["products"] });
      queryClient.invalidateQueries({ queryKey: ["trial-balance"] });
      queryClient.invalidateQueries({ queryKey: ["reconciliation-summary"] });
      queryClient.invalidateQueries({ queryKey: ["accounting-audit"] });
      navigate({ to: "/faturalar" });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const vknWarning = customer.vknTckn.trim() ? !isValidVknTckn(customer.vknTckn) : false;
  const currentTevkifatObj = TEVKIFAT_CODES.find((c) => c.code === selectedTevkifatCode);

  // Müşteri / Tedarikçi Listesi Filtresi
  const filteredPartners = customers.filter((c) => {
    if (operationMode === "ALIS" || operationMode === "ALIS_IADE") {
      return c.partner_type === "TEDARIKCI";
    }
    return c.partner_type !== "TEDARIKCI";
  });

  return (
    <AppShell
      title={
        editId
          ? "Faturayı Düzenle"
          : operationMode === "ALIS"
            ? "Alış Faturası Girişi (Gelen Fatura)"
            : operationMode === "ALIS_IADE"
              ? "Alış İadesi Oluştur (Tedarikçiye İade)"
              : "Fatura Kes"
      }
      subtitle={
        operationMode === "ALIS"
          ? "Tedarikçiden gelen alış faturasını kaydedin, 153/191/320 yevmiye fişi ve stok girişi otomatik işlensin."
          : operationMode === "ALIS_IADE"
            ? "Tedarikçiye iade edilen malları kaydedin, stoktan düşülsün ve 320 borç kaydı oluşturulsun."
            : "E-Arşiv / E-Fatura düzenleyin, KDV ve tevkifatı otomatik hesaplayın."
      }
      actions={
        <div className="flex gap-2">
          {editId ? (
            <Button variant="outline" size="sm" onClick={() => navigate({ to: "/faturalar" })}>
              <ArrowLeft className="mr-1 size-4" /> Vazgeç
            </Button>
          ) : null}
        </div>
      }
    >
      {/* İŞLEM MODU SEÇİCİ */}
      {!editId && (
        <div className="mb-4">
          <Tabs
            value={operationMode}
            onValueChange={(v) => {
              const m = v as "SATIS" | "ALIS" | "ALIS_IADE";
              setOperationMode(m);
              setCustomerId("");
              setCustomer(emptyCustomer);
              if (m === "ALIS") setType("ALIS");
              else if (m === "ALIS_IADE") setType("ALIS_IADE");
              else setType("SATIS");
            }}
          >
            <TabsList className="grid grid-cols-3 max-w-lg bg-muted/80">
              <TabsTrigger value="SATIS" className="gap-1.5 font-medium">
                <Send className="size-4" /> Satış Faturası Kes
              </TabsTrigger>
              <TabsTrigger value="ALIS" className="gap-1.5 font-medium">
                <ShoppingCart className="size-4" /> Alış Faturası İşle
              </TabsTrigger>
              <TabsTrigger value="ALIS_IADE" className="gap-1.5 font-medium">
                <RotateCcw className="size-4" /> Alış İadesi Yap
              </TabsTrigger>
            </TabsList>
          </Tabs>
        </div>
      )}

      <div className="grid gap-6 lg:grid-cols-3">
        {/* SOL VE ORTA: FORM ALANLARI */}
        <div className="space-y-6 lg:col-span-2">
          {/* 1. FATURA TİPİ VE TEMEL BİLGİLER */}
          <Card>
            <CardHeader className="pb-3">
              <div className="flex items-center justify-between">
                <CardTitle className="text-base">
                  {operationMode === "ALIS"
                    ? "Alış Fatura Bilgileri"
                    : operationMode === "ALIS_IADE"
                      ? "Alış İade Bilgileri"
                      : "Fatura Bilgileri"}
                </CardTitle>
                <Badge variant={operationMode === "ALIS" ? "secondary" : operationMode === "ALIS_IADE" ? "destructive" : "default"}>
                  {operationMode === "ALIS" ? "ALIŞ FATURASI" : operationMode === "ALIS_IADE" ? "ALIŞ İADESİ" : "SATIŞ FATURASI"}
                </Badge>
              </div>
            </CardHeader>
            <CardContent className="grid gap-4 sm:grid-cols-2">
              {operationMode === "SATIS" && (
                <>
                  <div className="space-y-1">
                    <Label>Fatura Tipi</Label>
                    <Select value={type} onValueChange={(v) => setType(v)} disabled={isNonEditable}>
                      <SelectTrigger>
                        <SelectValue placeholder="Fatura Tipi Seçin" />
                      </SelectTrigger>
                      <SelectContent>
                        {INVOICE_TYPES.map((t) => (
                          <SelectItem key={t.value} value={t.value}>
                            {t.label}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  </div>
                  <div className="space-y-1">
                    <Label>Fatura Seri Öneki (3 Harf)</Label>
                    <Input
                      placeholder="Örn: EAR, ABC"
                      maxLength={3}
                      value={serialPrefix}
                      onChange={(e) => setSerialPrefix(e.target.value.toUpperCase().slice(0, 3))}
                      disabled={isNonEditable}
                      className="font-mono uppercase tracking-wider font-semibold"
                    />
                  </div>
                </>
              )}

              {operationMode === "ALIS_IADE" && (
                <div className="space-y-1 sm:col-span-2">
                  <Label>Orijinal Alış Faturası Seçimi *</Label>
                  <Select value={originalInvoiceId || undefined} onValueChange={handleSelectOriginalPurchaseInvoice}>
                    <SelectTrigger>
                      <SelectValue placeholder="İade edilecek onaylı alış faturasını seçiniz..." />
                    </SelectTrigger>
                    <SelectContent>
                      {purchaseInvoices.map((pi) => (
                        <SelectItem key={pi.id} value={pi.id}>
                          {pi.invoice_number} - {(pi.customer as any)?.title || "Tedarikçi"} ({formatMoney(pi.grand_total)})
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
              )}

              {operationMode !== "SATIS" && (
                <div className="space-y-1">
                  <Label>{operationMode === "ALIS" ? "Tedarikçi Fatura No *" : "İade Belge No *"}</Label>
                  <Input
                    placeholder="Örn: ABC2026000001234"
                    value={supplierInvoiceNumber}
                    onChange={(e) => setSupplierInvoiceNumber(e.target.value)}
                  />
                </div>
              )}

              <div className="space-y-1">
                <Label>Fatura Tarihi</Label>
                <Input
                  type="date"
                  value={date}
                  onChange={(e) => setDate(e.target.value)}
                  disabled={isNonEditable}
                />
              </div>

              <div className="space-y-1">
                <Label>Para Birimi</Label>
                <Select value={currency} onValueChange={setCurrency} disabled={isNonEditable}>
                  <SelectTrigger>
                    <SelectValue placeholder="Para Birimi" />
                  </SelectTrigger>
                  <SelectContent>
                    {CURRENCY_OPTIONS.map((c) => (
                      <SelectItem key={c.code} value={c.code}>
                        {c.label} ({c.symbol})
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>

              <div className="space-y-1">
                <Label>Depo Seçimi</Label>
                <Select value={warehouseId || "none"} onValueChange={(v) => setWarehouseId(v === "none" ? "" : v)} disabled={isNonEditable}>
                  <SelectTrigger>
                    <SelectValue placeholder="Depo Seçiniz (İsteğe bağlı)" />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="none">Depo Seçilmedi (Varsayılan)</SelectItem>
                    {warehouses.map((w) => (
                      <SelectItem key={w.id} value={w.id}>
                        {w.name} {w.code ? `(${w.code})` : ""}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
            </CardContent>
          </Card>

          {/* 2. ALICI VEYA TEDARİKÇİ BİLGİLERİ */}
          <Card>
            <CardHeader className="pb-3">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <CardTitle className="text-base">
                  {operationMode === "ALIS" || operationMode === "ALIS_IADE" ? "Tedarikçi (Satıcı) Bilgileri" : "Alıcı Bilgileri"}
                </CardTitle>
                <div className="w-56">
                  <Select value={customerId || undefined} onValueChange={handleSelectCustomer} disabled={isNonEditable}>
                    <SelectTrigger className="h-8 text-xs">
                      <SelectValue placeholder={operationMode === "ALIS" ? "Tedarikçi seçiniz..." : "Kayıtlı cari seç..."} />
                    </SelectTrigger>
                    <SelectContent>
                      {filteredPartners.map((c) => (
                        <SelectItem key={c.id} value={c.id} className="text-xs">
                          {c.title} {c.vkn_tckn ? `(${c.vkn_tckn})` : ""}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
              </div>
            </CardHeader>
            <CardContent className="grid gap-3 sm:grid-cols-2">
              <div className="space-y-1">
                <Label htmlFor="vkn">VKN / TCKN *</Label>
                <Input
                  id="vkn"
                  value={customer.vknTckn}
                  onChange={(e) => setCustomer({ ...customer, vknTckn: e.target.value })}
                  placeholder="Vergi / TC Kimlik No"
                  disabled={isNonEditable}
                />
                {vknWarning && (
                  <p className="text-xs text-amber-600 flex items-center gap-1">
                    <AlertCircle className="size-3" /> VKN 10 haneli veya TCKN 11 haneli olmalıdır.
                  </p>
                )}
              </div>

              <div className="space-y-1">
                <Label htmlFor="title">Unvan / Ad Soyad *</Label>
                <Input
                  id="title"
                  value={customer.title}
                  onChange={(e) => setCustomer({ ...customer, title: e.target.value })}
                  placeholder="Firma Unvanı veya Şahıs Adı"
                  disabled={isNonEditable}
                />
              </div>

              <div className="space-y-1">
                <Label htmlFor="taxOffice">Vergi Dairesi</Label>
                <Input
                  id="taxOffice"
                  value={customer.taxOffice}
                  onChange={(e) => setCustomer({ ...customer, taxOffice: e.target.value })}
                  placeholder="Vergi Dairesi Adı"
                  disabled={isNonEditable}
                />
              </div>

              <div className="space-y-1">
                <Label htmlFor="email">E-posta</Label>
                <Input
                  id="email"
                  type="email"
                  value={customer.email}
                  onChange={(e) => setCustomer({ ...customer, email: e.target.value })}
                  placeholder="fatura@sirket.com"
                  disabled={isNonEditable}
                />
              </div>

              <div className="sm:col-span-2 space-y-1">
                <Label htmlFor="address">Adres</Label>
                <Input
                  id="address"
                  value={customer.address}
                  onChange={(e) => setCustomer({ ...customer, address: e.target.value })}
                  placeholder="Cadde, Sokak, No, Daire"
                  disabled={isNonEditable}
                />
              </div>

              <div className="sm:col-span-2">
                <AddressSelect
                  value={{
                    city: customer.city,
                    district: customer.district,
                    neighborhood: customer.neighborhood,
                  }}
                  onChange={({ city, district, neighborhood }) =>
                    setCustomer({ ...customer, city, district, neighborhood })
                  }
                  disabled={isNonEditable}
                />
              </div>
            </CardContent>
          </Card>

          {/* 3. FATURA KALEMLERİ */}
          <Card>
            <CardHeader className="pb-3 flex flex-row items-center justify-between">
              <div>
                <CardTitle className="text-base">Mal / Hizmet Kalemleri ({items.length})</CardTitle>
                <CardDescription>
                  {operationMode === "ALIS"
                    ? "Alış yapılan ürünler ve net birim alış fiyatları"
                    : "Satış kalemleri ve KDV oranları"}
                </CardDescription>
              </div>
              {!isNonEditable && (
                <Button size="sm" variant="outline" onClick={addItem} className="gap-1.5 text-xs">
                  <PlusCircle className="size-3.5" /> Kalem Ekle
                </Button>
              )}
            </CardHeader>
            <CardContent className="space-y-3">
              {/* DESKTOP & TABLET KOMPAKT TABLO GÖRÜNÜMÜ */}
              <div className="hidden md:block overflow-x-auto rounded-md border border-border/60">
                <table className="w-full text-left text-xs border-collapse">
                  <thead>
                    <tr className="bg-muted/50 border-b border-border/60 text-muted-foreground font-medium">
                      <th className="py-2 px-2.5 w-8 text-center">#</th>
                      <th className="py-2 px-2.5 min-w-[220px]">Katalog & Kalem Açıklaması</th>
                      <th className="py-2 px-2.5 w-24">Miktar</th>
                      <th className="py-2 px-2.5 w-28">Birim</th>
                      <th className="py-2 px-2.5 w-32">
                        {operationMode === "ALIS" ? "Alış Fiyatı" : "Birim Fiyat"}
                      </th>
                      <th className="py-2 px-2.5 w-20">KDV</th>
                      <th className="py-2 px-2.5 w-20">İsk. %</th>
                      <th className="py-2 px-2.5 w-32 text-right">Satır Toplamı</th>
                      {!isNonEditable && <th className="py-2 px-2 w-10 text-center"></th>}
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-border/40">
                    {items.map((item, index) => {
                      const t = itemTotals(item);
                      return (
                        <tr key={item.id} className="hover:bg-muted/20 transition-colors">
                          {/* 1. SIRA NO */}
                          <td className="py-2 px-2.5 text-center font-bold text-muted-foreground font-mono align-top pt-3">
                            {index + 1}
                          </td>

                          {/* 2. KATALOG & KALEM AÇIKLAMASI */}
                          <td className="py-2 px-2.5 space-y-1.5 align-top">
                            <ProductCombobox
                              value={item.productId || undefined}
                              onSelect={(val) => handleProductSelect(item.id, val)}
                              disabled={isNonEditable}
                              products={products}
                              isLoading={productsLoading}
                              operationMode={operationMode}
                            />
                            <Input
                              className="h-8 text-xs bg-background"
                              value={item.name}
                              onChange={(e) => updateItem(item.id, { name: e.target.value })}
                              placeholder="Ürün veya hizmet açıklaması *"
                              disabled={isNonEditable}
                            />
                          </td>

                          {/* 3. MİKTAR */}
                          <td className="py-2 px-2.5 align-top pt-2">
                            {(() => {
                              const isQtyError = isInvalidQuantity(item.quantity);
                              return (
                                <div className="space-y-1">
                                  <Input
                                    className={`h-8 text-xs bg-background font-mono ${
                                      isQtyError
                                        ? "border-destructive focus-visible:ring-destructive text-destructive font-semibold"
                                        : ""
                                    }`}
                                    type="number"
                                    min="0.0001"
                                    step="any"
                                    value={item.quantity === 0 ? "" : item.quantity}
                                    onChange={(e) => {
                                      const val = e.target.value.replace(",", ".");
                                      const parsed = val === "" ? 0 : Number(val);
                                      updateItem(item.id, { quantity: isNaN(parsed) ? 0 : parsed });
                                    }}
                                    disabled={isNonEditable}
                                  />
                                  {isQtyError && (
                                    <span className="text-[10px] text-destructive font-medium block leading-tight">
                                      Miktar &gt; 0 olmalı
                                    </span>
                                  )}
                                </div>
                              );
                            })()}
                          </td>

                          {/* 4. BİRİM */}
                          <td className="py-2 px-2.5 align-top pt-2">
                            <Select
                              value={item.unit || "Adet"}
                              onValueChange={(v) => updateItem(item.id, { unit: v })}
                              disabled={isNonEditable}
                            >
                              <SelectTrigger className="h-8 text-xs bg-background">
                                <SelectValue placeholder="Birim" />
                              </SelectTrigger>
                              <SelectContent>
                                {UNIT_OPTIONS.map((u) => (
                                  <SelectItem key={u} value={u}>
                                    {u}
                                  </SelectItem>
                                ))}
                              </SelectContent>
                            </Select>
                          </td>

                          {/* 5. BİRİM FİYAT */}
                          <td className="py-2 px-2.5 align-top pt-2">
                            <Input
                              className="h-8 text-xs bg-background font-mono"
                              type="number"
                              min="0"
                              step="any"
                              placeholder="0.00"
                              value={item.unitPrice === 0 ? "" : item.unitPrice}
                              onChange={(e) => {
                                const val = e.target.value.replace(",", ".");
                                const parsed = val === "" ? 0 : Number(val);
                                updateItem(item.id, { unitPrice: isNaN(parsed) ? 0 : parsed });
                              }}
                              disabled={isNonEditable}
                            />
                          </td>

                          {/* 6. KDV */}
                          <td className="py-2 px-2.5 align-top pt-2">
                            <Select
                              value={String(item.vatRate ?? 20)}
                              onValueChange={(v) => updateItem(item.id, { vatRate: Number(v) })}
                              disabled={isNonEditable}
                            >
                              <SelectTrigger className="h-8 text-xs bg-background">
                                <SelectValue />
                              </SelectTrigger>
                              <SelectContent>
                                {VAT_RATES.map((rate) => (
                                  <SelectItem key={rate} value={String(rate)}>
                                    %{rate}
                                  </SelectItem>
                                ))}
                              </SelectContent>
                            </Select>
                          </td>

                          {/* 7. İSKONTO */}
                          <td className="py-2 px-2.5 align-top pt-2">
                            <Input
                              className="h-8 text-xs bg-background font-mono"
                              type="number"
                              min="0"
                              max="100"
                              step="any"
                              placeholder="0"
                              value={item.discountRate === 0 ? "" : item.discountRate}
                              onChange={(e) => {
                                const val = e.target.value.replace(",", ".");
                                const parsed = val === "" ? 0 : Number(val);
                                updateItem(item.id, { discountRate: isNaN(parsed) ? 0 : parsed });
                              }}
                              disabled={isNonEditable}
                            />
                          </td>

                          {/* 8. SATIR TOPLAMI */}
                          <td className="py-2 px-2.5 text-right font-mono align-top pt-2.5">
                            <div className="font-semibold text-xs text-foreground">
                              {formatMoney(t.total, currency)}
                            </div>
                            <div className="text-[10px] text-muted-foreground">
                              Matrah: {formatMoney(t.taxable, currency)}
                            </div>
                          </td>

                          {/* 9. İŞLEMLER */}
                          {!isNonEditable && (
                            <td className="py-2 px-2 text-center align-top pt-2">
                              {items.length > 1 && (
                                <Button
                                  variant="ghost"
                                  size="icon"
                                  className="h-7 w-7 text-destructive hover:bg-destructive/10"
                                  onClick={() => removeItem(item.id)}
                                  title="Kalemi Sil"
                                >
                                  <Trash2 className="size-3.5" />
                                </Button>
                              )}
                            </td>
                          )}
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>

              {/* MOBİL UYUMLU KOMPAKT KART GÖRÜNÜMÜ (md:hidden) */}
              <div className="md:hidden space-y-3">
                {items.map((item, index) => {
                  const t = itemTotals(item);
                  return (
                    <div
                      key={item.id}
                      className="p-3 rounded-lg border border-border/70 bg-card/40 space-y-2.5"
                    >
                      <div className="flex items-center justify-between gap-2">
                        <span className="text-xs font-bold text-muted-foreground font-mono">
                          #{index + 1}
                        </span>
                        <div className="flex-1 max-w-xs">
                          <ProductCombobox
                            value={item.productId || undefined}
                            onSelect={(val) => handleProductSelect(item.id, val)}
                            disabled={isNonEditable}
                            products={products}
                            isLoading={productsLoading}
                            operationMode={operationMode}
                          />
                        </div>
                        {!isNonEditable && items.length > 1 && (
                          <Button
                            variant="ghost"
                            size="icon"
                            className="h-7 w-7 text-destructive"
                            onClick={() => removeItem(item.id)}
                          >
                            <Trash2 className="size-3.5" />
                          </Button>
                        )}
                      </div>

                      <Input
                        className="h-8 text-xs"
                        value={item.name}
                        onChange={(e) => updateItem(item.id, { name: e.target.value })}
                        placeholder="Kalem açıklaması"
                        disabled={isNonEditable}
                      />

                      <div className="grid grid-cols-4 gap-2">
                        <div>
                          {(() => {
                            const isQtyError = isInvalidQuantity(item.quantity);
                            return (
                              <>
                                <Label className={`text-[10px] ${isQtyError ? "text-destructive font-bold" : ""}`}>
                                  Miktar
                                </Label>
                                <Input
                                  className={`h-8 text-xs font-mono ${
                                    isQtyError
                                      ? "border-destructive focus-visible:ring-destructive text-destructive font-semibold"
                                      : ""
                                  }`}
                                  type="number"
                                  min="0.0001"
                                  step="any"
                                  value={item.quantity === 0 ? "" : item.quantity}
                                  onChange={(e) => {
                                    const val = e.target.value.replace(",", ".");
                                    const parsed = val === "" ? 0 : Number(val);
                                    updateItem(item.id, { quantity: isNaN(parsed) ? 0 : parsed });
                                  }}
                                  disabled={isNonEditable}
                                />
                                {isQtyError && (
                                  <span className="text-[9px] text-destructive font-medium block leading-tight mt-0.5">
                                    Miktar &gt; 0 olmalı
                                  </span>
                                )}
                              </>
                            );
                          })()}
                        </div>
                        <div>
                          <Label className="text-[10px]">Birim</Label>
                          <Select
                            value={item.unit || "Adet"}
                            onValueChange={(v) => updateItem(item.id, { unit: v })}
                            disabled={isNonEditable}
                          >
                            <SelectTrigger className="h-8 text-xs">
                              <SelectValue />
                            </SelectTrigger>
                            <SelectContent>
                              {UNIT_OPTIONS.map((u) => (
                                <SelectItem key={u} value={u}>
                                  {u}
                                </SelectItem>
                              ))}
                            </SelectContent>
                          </Select>
                        </div>
                        <div>
                          <Label className="text-[10px]">Fiyat</Label>
                          <Input
                            className="h-8 text-xs font-mono"
                            type="number"
                            value={item.unitPrice}
                            onChange={(e) => updateItem(item.id, { unitPrice: Number(e.target.value) })}
                            disabled={isNonEditable}
                          />
                        </div>
                        <div>
                          <Label className="text-[10px]">KDV</Label>
                          <Select
                            value={String(item.vatRate ?? 20)}
                            onValueChange={(v) => updateItem(item.id, { vatRate: Number(v) })}
                            disabled={isNonEditable}
                          >
                            <SelectTrigger className="h-8 text-xs">
                              <SelectValue />
                            </SelectTrigger>
                            <SelectContent>
                              {VAT_RATES.map((rate) => (
                                <SelectItem key={rate} value={String(rate)}>
                                  %{rate}
                                </SelectItem>
                              ))}
                            </SelectContent>
                          </Select>
                        </div>
                      </div>

                      <div className="flex items-center justify-between pt-1 text-xs">
                        <span className="text-muted-foreground font-mono text-[11px]">
                          Matrah: {formatMoney(t.taxable, currency)}
                        </span>
                        <span className="font-semibold font-mono text-primary">
                          Toplam: {formatMoney(t.total, currency)}
                        </span>
                      </div>
                    </div>
                  );
                })}
              </div>

              {/* ALT KALEM EKLE BUTONU */}
              {!isNonEditable && (
                <div className="pt-2 flex justify-start">
                  <Button
                    size="sm"
                    variant="outline"
                    onClick={addItem}
                    className="gap-1.5 text-xs border-dashed"
                  >
                    <PlusCircle className="size-3.5" /> Kalem Ekle
                  </Button>
                </div>
              )}
            </CardContent>
          </Card>

          {/* 4. EK BİLGİLER */}
          <Card>
            <CardHeader className="pb-3">
              <CardTitle className="text-base">Ek Bilgiler & Notlar</CardTitle>
            </CardHeader>
            <CardContent className="grid gap-4 sm:grid-cols-2">
              <div className="space-y-2">
                <Label htmlFor="notes">Fatura Notu</Label>
                <Textarea
                  id="notes"
                  value={notes}
                  onChange={(e) => setNotes(e.target.value)}
                  placeholder="Fatura üzerinde görünecek özel notlar veya sipariş no"
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="payment">Ödeme / Banka Bilgileri</Label>
                <Textarea
                  id="payment"
                  value={paymentInfo}
                  onChange={(e) => setPaymentInfo(e.target.value)}
                  placeholder="Banka Adı, IBAN ve ödeme vadesi detayları"
                />
              </div>
            </CardContent>
          </Card>
        </div>

        {/* SAĞ TARAF: FATURA ÖZETİ */}
        <div>
          <Card className="lg:sticky lg:top-6 space-y-4">
            <CardHeader className="pb-2">
              <CardTitle className="text-base">
                {operationMode === "ALIS"
                  ? "Alış Faturası Özeti"
                  : operationMode === "ALIS_IADE"
                    ? "Alış İadesi Özeti"
                    : "Fatura Özeti & Döküm"}
              </CardTitle>
            </CardHeader>
            <CardContent className="space-y-3 text-sm">
              <Row label="Mal/Hizmet Toplamı" value={formatMoney(totals.subtotal, currency)} />
              {totals.totalDiscount > 0 ? (
                <Row
                  label="Toplam İskonto"
                  value={`- ${formatMoney(totals.totalDiscount, currency)}`}
                />
              ) : null}
              <Row label="KDV Matrahı (153)" value={formatMoney(totals.taxableAmount, currency)} />
              <Row
                label={operationMode === "ALIS" ? "İndirilecek KDV (191)" : "Hesaplanan KDV (391)"}
                value={formatMoney(totals.totalVat, currency)}
              />

              {/* KDV Dağılımı */}
              <div className="rounded-md bg-muted/40 p-2.5 space-y-1 text-xs font-mono">
                <span className="font-semibold text-muted-foreground font-sans">KDV Dilim Dağılımı:</span>
                {Object.entries(totals.vatBreakdown)
                  .filter(([_, v]) => v.taxable > 0)
                  .map(([rate, val]) => (
                    <div key={rate} className="flex justify-between text-muted-foreground">
                      <span>%{rate} KDV:</span>
                      <span>
                        Matrah: {formatMoney(val.taxable, currency)} | Vergi: {formatMoney(val.vat, currency)}
                      </span>
                    </div>
                  ))}
              </div>

              <div className="mt-4 flex items-center justify-between border-t border-border pt-3 text-lg font-bold">
                <span>{operationMode === "ALIS" ? "Tedarikçiye Borç (320)" : "Genel Toplam"}</span>
                <span className="text-primary font-mono">{formatMoney(totals.grandTotal, currency)}</span>
              </div>

              {/* Yazı İle */}
              <div className="rounded-md bg-muted p-2.5 text-xs text-muted-foreground">
                <span className="font-semibold text-foreground">Yazı İle: </span>
                <span className="italic">{wordsAmount}</span>
              </div>

              <div className="space-y-2 pt-3">
                {operationMode === "SATIS" && !editId && (
                  <Button
                    variant="outline"
                    className="w-full"
                    onClick={() => saveInvoice.mutate("TASLAK")}
                    disabled={saveInvoice.isPending}
                  >
                    {saveInvoice.isPending ? "Kaydediliyor…" : "Taslak Olarak Kaydet"}
                  </Button>
                )}
                <Button
                  className="w-full"
                  onClick={() => saveInvoice.mutate("ONAYLANDI")}
                  disabled={saveInvoice.isPending}
                >
                  {saveInvoice.isPending
                    ? "İşleniyor…"
                    : operationMode === "ALIS"
                      ? "Alış Faturasını Kaydet & Onayla"
                      : operationMode === "ALIS_IADE"
                        ? "Alış İadesini Onayla"
                        : editId
                          ? "Faturayı Güncelle & Onayla"
                          : "Kaydet ve Onayla"}
                </Button>
              </div>
            </CardContent>
          </Card>
        </div>
      </div>
    </AppShell>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between">
      <span className="text-muted-foreground">{label}</span>
      <span className="font-medium font-mono">{value}</span>
    </div>
  );
}
