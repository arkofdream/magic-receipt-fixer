import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import {
  Trash2,
  AlertCircle,
  Info,
  Check,
  Edit,
  PlusCircle,
  ArrowLeft,
  ShoppingCart,
  Send,
  RotateCcw,
  Eye,
  EyeOff,
  CornerUpLeft,
  FileCode,
  Copy,
  Download,
} from "lucide-react";
import { toast } from "sonner";

// NumericGridInput component handles React's type="number" decimal typing issue
function NumericGridInput({
  value,
  onChange,
  onEnter,
  disabled,
  className,
  placeholder,
  hasError,
  min,
  max,
}: {
  value: number;
  onChange: (val: number) => void;
  onEnter?: () => void;
  disabled?: boolean;
  className?: string;
  placeholder?: string;
  hasError?: boolean;
  min?: string;
  max?: string;
}) {
  const [localVal, setLocalVal] = useState(value === 0 ? "" : String(value));
  useEffect(() => {
    if (value === 0 && localVal === "") return;
    if (Number(localVal) !== value && localVal !== value + "." && !localVal.endsWith("0")) {
      setLocalVal(value === 0 ? "" : String(value));
    }
  }, [value]);

  return (
    <Input
      className={`${className} ${hasError ? "border-destructive focus-visible:ring-destructive text-destructive font-semibold" : ""}`}
      type="number"
      min={min}
      max={max}
      step="any"
      placeholder={placeholder}
      value={localVal}
      onChange={(e) => {
        const val = e.target.value.replace(",", ".");
        setLocalVal(val);
        const parsed = val === "" ? 0 : Number(val);
        if (!isNaN(parsed)) {
          onChange(parsed);
        }
      }}
      onBlur={() => {
        if (localVal.endsWith(".")) setLocalVal(localVal.slice(0, -1));
      }}
      onKeyDown={(e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          onEnter?.();
        }
      }}
      disabled={disabled}
    />
  );
}

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
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogFooter,
} from "@/components/ui/dialog";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { createUblTrInvoice, parseUblXmlForensic } from "@/lib/ubl";
import { getMyCompanyProfile } from "@/lib/profile.functions";
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
  mode?: "SATIS" | "SATIS_IADE" | "ALIS" | "ALIS_IADE" | undefined;
  returnInvoiceId?: string | undefined;
};

export const Route = createFileRoute("/_authenticated/fatura-kes")({
  validateSearch: (search: Record<string, unknown>): SearchParams => {
    const editId = search["editId"];
    const mode = search["mode"] as "SATIS" | "SATIS_IADE" | "ALIS" | "ALIS_IADE" | undefined;
    const returnInvoiceId = search["returnInvoiceId"] as string | undefined;
    return {
      editId: typeof editId === "string" ? editId : undefined,
      mode:
        mode === "ALIS" || mode === "ALIS_IADE" || mode === "SATIS" || mode === "SATIS_IADE"
          ? mode
          : undefined,
      returnInvoiceId: typeof returnInvoiceId === "string" ? returnInvoiceId : undefined,
    };
  },
  head: () => ({
    meta: [
      { title: "Fatura Kes, Satış & Alış İadesi | e-Fatura Portalı" },
      {
        name: "description",
        content:
          "Satış faturası kesin, satış iadesi kaydedin, tedarikçi alış faturası işleyin veya alış iadesi oluşturun. KDV ve tevkifat otomatik hesaplanır.",
      },
      { property: "og:title", content: "Fatura Kes, Satış & Alış İadesi | e-Fatura Portalı" },
      { property: "og:description", content: "Satış, satış iadesi, alış ve alış iadesi faturaları yönetimi." },
    ],
  }),
  component: NewInvoicePage,
});



function NewInvoicePage() {
  const navigate = useNavigate();
  const searchParams = Route.useSearch();
  const editId = searchParams.editId;
  const initialMode = searchParams.mode || "SATIS";
  const initialReturnInvoiceId = searchParams.returnInvoiceId;

  const queryClient = useQueryClient();

  // İşlem Modu: "SATIS" | "SATIS_IADE" | "ALIS" | "ALIS_IADE"
  const [operationMode, setOperationMode] = useState<"SATIS" | "SATIS_IADE" | "ALIS" | "ALIS_IADE">(initialMode);
  const [type, setType] = useState("SATIS");
  const [date, setDate] = useState(new Date().toISOString().split("T")[0]);
  const [currency, setCurrency] = useState("TRY");
  const [customerId, setCustomerId] = useState("");
  const [customer, setCustomer] = useState<InvoiceCustomer>(emptyCustomer);
  const [items, setItems] = useState<InvoiceItem[]>([newItem()]);
  const [notes, setNotes] = useState("");
  const [paymentInfo, setPaymentInfo] = useState("");
  const [serialPrefix, setSerialPrefix] = useState("");
  const [selectedTevkifatCode, setSelectedTevkifatCode] = useState<string>("");
  const [isVknValidating, setIsVknValidating] = useState(false);
  const [warehouseId, setWarehouseId] = useState<string>("");
  const [supplierInvoiceNumber, setSupplierInvoiceNumber] = useState<string>("");
  const [originalInvoiceId, setOriginalInvoiceId] = useState<string>(initialReturnInvoiceId || "");

  // Kalem Açıklaması Kolonu Göster/Gizle Durumu (Varsayılan Açık)
  const [showDescription, setShowDescription] = useState(true);

  // XML Forensic Modal State
  const [showXmlModal, setShowXmlModal] = useState(false);
  const [previewXmlString, setPreviewXmlString] = useState("");

  // Firma Profili (Satıcı VKN)
  const { data: companyProfile } = useQuery({
    queryKey: ["company-profile"],
    queryFn: () => getMyCompanyProfile(),
  });

  function handlePreviewXml() {
    try {
      const ettn = generateEttn();
      const ublXml = createUblTrInvoice({
        uuid: ettn,
        invoiceNumber: `${serialPrefix || "EAR"}${new Date().getFullYear()}000000001`,
        issueDate: date,
        issueTime: new Date().toISOString().split("T")[1]?.slice(0, 8) || "12:00:00",
        currency,
        profileId: (type === "SATIS" ? "EARSIVFATURA" : "TICARIFATURA") as any,
        invoiceTypeCode: type as any,
        seller: {
          taxNumber: companyProfile?.vknTckn || "1234567801",
          name: companyProfile?.companyTitle || "Fuat Ekiz Teknoloji A.Ş.",
          taxOffice: companyProfile?.taxOffice || "",
          address: companyProfile?.address || "",
        },
        buyer: {
          taxNumber: customer.vknTckn || "11111111111",
          name: customer.title || "Alıcı Müşteri",
          taxOffice: customer.taxOffice || "",
          address: customer.address || "",
          city: customer.city || "",
          district: customer.district || "",
        },
        lines: items.map((it) => ({
          name: it.name || "Ürün/Hizmet",
          quantity: Number(it.quantity) || 1,
          unitPrice: Number(it.unitPrice) || 0,
          discountRate: Number(it.discountRate) || 0,
          vatRate: Number(it.vatRate) || 20,
        })),
        note: notes.trim(),
      });

      setPreviewXmlString(ublXml);
      setShowXmlModal(true);

      const forensic = parseUblXmlForensic(ublXml);
      console.log("[NES XML FORENSIC]", {
        supplierVkn: forensic.supplierVkn,
        customerVkn: forensic.customerVkn,
        supplierEndpointId: forensic.supplierEndpointId,
        customerEndpointId: forensic.customerEndpointId,
        xmlLength: forensic.xmlLength,
      });
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : "XML önizleme oluşturulamadı.");
    }
  }

  // Müşteriler & Tedarikçiler
  const { data: customers = [] } = useQuery({
    queryKey: ["customers"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("customers")
        .select("*")
        .is("deleted_at", null)
        .order("title");
      if (error && isMissingColumnError(error)) {
        const fallback = await supabase.from("customers").select("*").order("title");
        if (fallback.error) throw fallback.error;
        return fallback.data ?? [];
      }
      if (error) throw error;
      return data ?? [];
    },
  });

  // Depolar
  const { data: warehouses = [] } = useQuery({
    queryKey: ["warehouses"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("warehouses")
        .select("*")
        .is("deleted_at", null)
        .order("created_at");
      if (error) throw error;
      return data ?? [];
    },
  });

  // Katalog Ürünleri
  const { data: products = [], isLoading: productsLoading } = useQuery({
    queryKey: ["products"],
    queryFn: async () => {
      const { data, error } = await supabase.from("products").select("*").is("deleted_at", null).order("name");
      if (error && isMissingColumnError(error)) {
        const fallback = await supabase.from("products").select("*").order("name");
        if (fallback.error) throw fallback.error;
        return fallback.data ?? [];
      }
      if (error) throw error;
      return data ?? [];
    },
  });

  // Alış faturaları listesi (Alış iadesi için kaynak fatura seçimi)
  const { data: purchaseInvoices = [] } = useQuery({
    queryKey: ["purchase-invoices-for-return"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("invoices")
        .select("id, invoice_number, invoice_date, grand_total, customer_id, customer, items, type, status")
        .in("type", ["ALIS", "GELEN_FATURA", "GELEN_E_ARSIV"])
        .is("deleted_at", null)
        .order("invoice_date", { ascending: false });
      if (error) throw error;
      return data ?? [];
    },
    enabled: operationMode === "ALIS_IADE",
  });

  // Satış faturaları listesi (Satış iadesi için kaynak fatura seçimi)
  const { data: salesInvoices = [] } = useQuery({
    queryKey: ["sales-invoices-for-return"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("invoices")
        .select("id, invoice_number, invoice_date, grand_total, customer_id, customer, items, type, status")
        .in("type", ["SATIS", "E_ARSIV", "TEVKIFAT", "ISTISNA", "IHRAC_KAYITLI"])
        .eq("status", "ONAYLANDI")
        .is("deleted_at", null)
        .order("invoice_date", { ascending: false });
      if (error) throw error;
      return data ?? [];
    },
    enabled: operationMode === "SATIS_IADE",
  });

  // Düzenleme modunda mevcut faturayı çek
  const { data: existingInvoice } = useQuery({
    queryKey: ["invoice", editId],
    queryFn: async () => {
      if (!editId) return null;
      const { data, error } = await supabase.from("invoices").select("*").eq("id", editId).maybeSingle();
      if (error) throw error;
      return data;
    },
    enabled: Boolean(editId),
  });

  useEffect(() => {
    if (!existingInvoice) return;
    const invType = existingInvoice.type || "SATIS";
    setType(invType);
    if (invType === "ALIS" || invType === "GELEN_FATURA" || invType === "GELEN_E_ARSIV") {
      setOperationMode("ALIS");
    } else if (invType === "ALIS_IADE") {
      setOperationMode("ALIS_IADE");
    } else if (invType === "SATIS_IADE" || invType === "GENEL_IADE") {
      setOperationMode("SATIS_IADE");
    } else {
      setOperationMode("SATIS");
    }

    setDate(existingInvoice.invoice_date || new Date().toISOString().split("T")[0]);
    setCurrency(existingInvoice.currency || "TRY");
    setCustomerId(existingInvoice.customer_id || "");
    setNotes(existingInvoice.notes || "");
    setPaymentInfo(existingInvoice.payment_info || "");
    setWarehouseId((existingInvoice as any).warehouse_id || "");
    setSupplierInvoiceNumber(existingInvoice.invoice_number || "");

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

  // Alış İadesi modunda orijinal fatura seçildiğinde
  function handleSelectOriginalPurchaseInvoice(invId: string) {
    setOriginalInvoiceId(invId);
    const orig = purchaseInvoices.find((i) => i.id === invId);
    if (orig) {
      if (orig.customer_id) setCustomerId(orig.customer_id);
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
      setSupplierInvoiceNumber(`IADE-${orig.invoice_number || ""}`);
    }
  }

  // Satış İadesi modunda orijinal fatura seçildiğinde
  function handleSelectOriginalSalesInvoice(invId: string) {
    setOriginalInvoiceId(invId);
    const orig = salesInvoices.find((i) => i.id === invId);
    if (orig) {
      if (orig.customer_id) setCustomerId(orig.customer_id);
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
      setSupplierInvoiceNumber(`IAD-${orig.invoice_number || ""}`);
    }
  }

  const isTevkifatli = operationMode === "SATIS" && (type === "TEVKIFAT" || Boolean(selectedTevkifatCode));

  const totals = invoiceTotals(items, isTevkifatli);

  function addItem() {
    setItems([...items, newItem()]);
  }

  function removeItem(id: string) {
    if (items.length <= 1) {
      toast.error("En az 1 fatura kalemi bulunmalıdır.");
      return;
    }
    setItems(items.filter((item) => item.id !== id));
  }

  function updateItem(id: string, patch: Partial<InvoiceItem>) {
    setItems(items.map((item) => (item.id === id ? { ...item, ...patch } : item)));
  }

  function handleProductSelect(itemId: string, productId: string) {
    const p = products.find((prod) => prod.id === productId);
    if (!p) return;

    const isPurchase = operationMode === "ALIS" || operationMode === "ALIS_IADE";
    const selectedPrice = isPurchase ? Number(p.purchase_price ?? 0) : Number(p.unit_price ?? 0);

    updateItem(itemId, {
      productId: p.id,
      code: p.code || "",
      name: p.name,
      unit: p.unit || "Adet",
      unitPrice: selectedPrice,
      vatRate: Number(p.vat_rate ?? 20),
      discountRate: Number(p.discount_rate ?? 0),
    });
  }

  function handleCustomerSelect(cId: string) {
    setCustomerId(cId);
    const selected = customers.find((c) => c.id === cId);
    if (selected) {
      setCustomer({
        vknTckn: selected.vkn_tckn || "",
        title: selected.title || "",
        taxOffice: selected.tax_office || "",
        address: selected.address || "",
        city: selected.city || "",
        district: selected.district || "",
        neighborhood: (selected as any).neighborhood || "",
        email: selected.email || "",
        phone: selected.phone || "",
        customPrefix: (selected as any).custom_prefix || customPrefix,
      });
      if ((selected as any).custom_prefix) {
        setSerialPrefix((selected as any).custom_prefix);
      }
    }
  }

  function isInvalidQuantity(qty: number): boolean {
    return isNaN(qty) || qty <= 0;
  }

  const isNonEditable = Boolean(
    existingInvoice &&
      (existingInvoice.status === "ONAYLANDI" ||
        existingInvoice.status === "IPTAL" ||
        existingInvoice.posted === true),
  );

  const saveInvoice = useMutation({
    mutationFn: async (newStatus: "TASLAK" | "ONAYLANDI") => {
      if (!customer.vknTckn.trim()) throw new Error("Müşteri VKN/TCKN zorunludur.");
      if (!customer.title.trim()) throw new Error("Müşteri Ünvanı zorunludur.");
      if (items.length === 0) throw new Error("En az 1 fatura kalemi gereklidir.");

      for (let i = 0; i < items.length; i++) {
        const it = items[i];
        if (isInvalidQuantity(it.quantity)) {
          throw new Error(`${i + 1}. kalem için geçerli bir miktar (0'dan büyük) giriniz.`);
        }
        if (!it.name.trim()) {
          throw new Error(`${i + 1}. kalem için ürün adı zorunludur.`);
        }
      }

      if (operationMode === "ALIS") {
        // --- 1. ALIŞ FATURASI AKIŞI ---
        if (!supplierInvoiceNumber.trim()) {
          throw new Error("Tedarikçi fatura numarası zorunludur.");
        }

        const cleanPrefix = (serialPrefix || customer.customPrefix || "EAR").trim().toUpperCase().slice(0, 3);
        const ettn = generateEttn();

        const rpcArgs: any = {
          p_invoice_date: date,
          p_supplier_id: customerId || null,
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
        };

        let rpcName = "";

        if (editId && existingInvoice) {
          // Güncelleme senaryosu (Sadece taslaklar güncellenebilir)
          rpcArgs.p_invoice_id = editId;
          if (newStatus === "ONAYLANDI") {
            rpcName = "update_and_approve_purchase_invoice";
          } else {
            rpcName = "update_purchase_invoice";
            rpcArgs.p_status = newStatus;
          }
        } else {
          // Yeni oluşturma senaryosu
          rpcArgs.p_ettn = ettn;
          if (newStatus === "ONAYLANDI") {
            rpcName = "create_and_approve_purchase_invoice";
          } else {
            rpcName = "create_purchase_invoice";
            rpcArgs.p_status = newStatus;
          }
        }

        const { data: _result, error } = await supabase.rpc(rpcName as any, rpcArgs);
        if (error) throw error;

      } else if (operationMode === "ALIS_IADE") {
        // --- 2. ALIŞ İADESİ AKIŞI ---
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

      } else if (operationMode === "SATIS_IADE") {
        // --- 3. SATIŞ İADESİ AKIŞI (create_sales_return) ---
        const { data: _result, error } = await supabase.rpc("create_sales_return", {
          p_original_invoice_id: originalInvoiceId || undefined,
          p_return_date: date,
          p_items: JSON.parse(JSON.stringify(items)),
          p_description: notes.trim() || undefined,
          p_warehouse_id: warehouseId || undefined,
          p_return_doc_no: supplierInvoiceNumber.trim() || undefined,
        });
        if (error) throw error;

      } else {
        // --- 4. STANDART SATIŞ FATURASI AKIŞI ---
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
            
            const rpcName = newStatus === "ONAYLANDI" ? "create_and_approve_sales_invoice" : "create_sales_invoice";
            
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            const rpcArgs: any = {
              p_invoice_date: date,
              p_type: type,
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
            };
            
            if (newStatus !== "ONAYLANDI") {
              rpcArgs.p_status = newStatus;
            }

            const { data: _result, error } = await supabase.rpc(rpcName as any, rpcArgs);
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
                  isEinvoiceTaxpayer: Boolean(customer?.isEinvoiceTaxpayer),
                  profileId: Boolean(customer?.isEinvoiceTaxpayer) ? "TICARIFATURA" : "EARSIVFATURA",
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
          ? "Alış faturası kaydedildi; 153/191/320 fişi ve stok girişi işlendi."
          : operationMode === "ALIS_IADE"
            ? "Alış iadesi işlendi; 320/153/191 fişi ve stok çıkışı yapıldı."
            : operationMode === "SATIS_IADE"
              ? "Satış iadesi işlendi; 610/191/120 ve 153/621 stok maliyet iadesi yapıldı."
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

  const filteredPartners = customers.filter((c) => {
    if (operationMode === "ALIS" || operationMode === "ALIS_IADE") {
      return c.partner_type === "TEDARIKCI";
    }
    return c.partner_type !== "TEDARIKCI";
  });

  return (
    <AppShell
      title={
        operationMode === "ALIS"
          ? "Tedarikçi Alış Faturası Girişi"
          : operationMode === "ALIS_IADE"
            ? "Alış İadesi Oluştur"
            : operationMode === "SATIS_IADE"
              ? "Satış İadesi Faturası Oluştur"
              : editId
                ? "Faturayı Düzenle"
                : "Yeni Fatura Kes"
      }
      subtitle={
        operationMode === "ALIS"
          ? "Gelen tedarikçi faturasını işleyin; 153/191/320 muhasebe kaydı ve stok girişi otomatik yapılır."
          : operationMode === "ALIS_IADE"
            ? "Tedarikçiye iade edilen malları kaydedin, stoktan düşülsün ve 320 borç kaydı oluşturulsun."
            : operationMode === "SATIS_IADE"
              ? "Müşteriden iade alınan malları kaydedin; 610/191/120 ve 153/621 maliyet iadesi otomatik işlensin."
              : "e-Fatura / e-Arşiv faturası oluşturun veya taslak olarak kaydedin."
      }
      actions={
        <div className="flex items-center gap-2">
          <Button variant="outline" size="sm" onClick={() => navigate({ to: "/faturalar" })}>
            <ArrowLeft className="size-4 mr-1.5" /> Geri Dön
          </Button>
          <Button
            variant="outline"
            size="sm"
            onClick={handlePreviewXml}
            className="gap-1.5 border-indigo-500/40 text-indigo-600 dark:text-indigo-400 hover:bg-indigo-50 dark:hover:bg-indigo-950/40"
          >
            <FileCode className="size-4" /> XML'i Görüntüle
          </Button>
          {!isNonEditable && (
            <>
              <Button
                variant="outline"
                size="sm"
                disabled={saveInvoice.isPending}
                onClick={() => saveInvoice.mutate("TASLAK")}
              >
                Taslak Kaydet
              </Button>
              <Button
                size="sm"
                className="bg-primary text-primary-foreground font-semibold"
                disabled={saveInvoice.isPending}
                onClick={() => saveInvoice.mutate("ONAYLANDI")}
              >
                {saveInvoice.isPending
                  ? "İşleniyor..."
                  : operationMode === "ALIS"
                    ? "Alış Faturasını Onayla & Kaydet"
                    : operationMode === "ALIS_IADE"
                      ? "Alış İadesini Onayla"
                      : operationMode === "SATIS_IADE"
                        ? "Satış İadesini Onayla"
                        : "Faturayı Onayla & Gönder"}
              </Button>
            </>
          )}
        </div>
      }
    >
      {/* İŞLEM MODU SEÇİCİ */}
      {!editId && (
        <div className="mb-4">
          <Tabs
            value={operationMode}
            onValueChange={(v) => {
              const m = v as "SATIS" | "SATIS_IADE" | "ALIS" | "ALIS_IADE";
              setOperationMode(m);
              setCustomerId("");
              setCustomer(emptyCustomer);
              if (m === "ALIS") setType("ALIS");
              else if (m === "ALIS_IADE") setType("ALIS_IADE");
              else if (m === "SATIS_IADE") setType("SATIS_IADE");
              else setType("SATIS");
            }}
          >
            <TabsList className="grid grid-cols-4 max-w-2xl bg-muted/80">
              <TabsTrigger value="SATIS" className="gap-1.5 font-medium text-xs">
                <Send className="size-3.5" /> Satış Faturası
              </TabsTrigger>
              <TabsTrigger value="SATIS_IADE" className="gap-1.5 font-medium text-xs">
                <CornerUpLeft className="size-3.5 text-amber-500" /> Satış İadesi
              </TabsTrigger>
              <TabsTrigger value="ALIS" className="gap-1.5 font-medium text-xs">
                <ShoppingCart className="size-3.5" /> Alış Faturası
              </TabsTrigger>
              <TabsTrigger value="ALIS_IADE" className="gap-1.5 font-medium text-xs">
                <RotateCcw className="size-3.5 text-destructive" /> Alış İadesi
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
                      : operationMode === "SATIS_IADE"
                        ? "Satış İade Bilgileri"
                        : "Fatura Bilgileri"}
                </CardTitle>
                <Badge
                  variant={
                    operationMode === "ALIS"
                      ? "secondary"
                      : operationMode === "ALIS_IADE" || operationMode === "SATIS_IADE"
                        ? "destructive"
                        : "default"
                  }
                >
                  {operationMode === "ALIS"
                    ? "ALIŞ FATURASI"
                    : operationMode === "ALIS_IADE"
                      ? "ALIŞ İADESİ"
                      : operationMode === "SATIS_IADE"
                        ? "SATIŞ İADESİ"
                        : "SATIŞ FATURASI"}
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

              {operationMode === "SATIS_IADE" && (
                <div className="space-y-1 sm:col-span-2">
                  <Label>Orijinal Satış Faturası Seçimi (Opsiyonel)</Label>
                  <Select value={originalInvoiceId || undefined} onValueChange={handleSelectOriginalSalesInvoice}>
                    <SelectTrigger>
                      <SelectValue placeholder="İade alınan satış faturasını seçiniz..." />
                    </SelectTrigger>
                    <SelectContent>
                      {salesInvoices.map((si) => (
                        <SelectItem key={si.id} value={si.id}>
                          {si.invoice_number} - {(si.customer as any)?.title || "Müşteri"} ({formatMoney(si.grand_total)})
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
                        {c.code} ({c.symbol}) - {c.name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>

              <div className="space-y-1">
                <Label>İlgili Depo (Stok Giriş / Çıkış)</Label>
                <Select value={warehouseId} onValueChange={setWarehouseId} disabled={isNonEditable}>
                  <SelectTrigger>
                    <SelectValue placeholder="Depo Seçiniz (Varsayılan Depo)" />
                  </SelectTrigger>
                  <SelectContent>
                    {warehouses.map((w) => (
                      <SelectItem key={w.id} value={w.id}>
                        {w.name} {w.is_default ? "(Varsayılan)" : ""}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>

              {isTevkifatli && (
                <div className="space-y-1 sm:col-span-2">
                  <Label>Tevkifat Kodu ve Oranı</Label>
                  <Select
                    value={selectedTevkifatCode}
                    onValueChange={(val) => {
                      setSelectedTevkifatCode(val);
                      const rate = TEVKIFAT_RATES[val] ?? 0;
                      setItems(
                        items.map((it) => ({
                          ...it,
                          tevkifatCode: val,
                          tevkifatRate: rate,
                        })),
                      );
                    }}
                    disabled={isNonEditable}
                  >
                    <SelectTrigger>
                      <SelectValue placeholder="Tevkifat kodu seçiniz..." />
                    </SelectTrigger>
                    <SelectContent>
                      {TEVKIFAT_CODES.map((t) => (
                        <SelectItem key={t.code} value={t.code}>
                          [{t.code}] {t.name} (Tevkifat Oranı: {t.rateText})
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
              )}
            </CardContent>
          </Card>

          {/* 2. MÜŞTERİ / TEDARİKÇİ BİLGİLERİ */}
          <Card>
            <CardHeader className="pb-3">
              <CardTitle className="text-base">
                {operationMode === "ALIS" || operationMode === "ALIS_IADE" ? "Tedarikçi (Satıcı) Bilgileri" : "Alıcı Bilgileri"}
              </CardTitle>
            </CardHeader>
            <CardContent className="space-y-4">
              <div className="space-y-1">
                <Label>
                  {operationMode === "ALIS" || operationMode === "ALIS_IADE"
                    ? "Kayıtlı Tedarikçilerden Seç"
                    : "Kayıtlı Müşterilerden Seç"}
                </Label>
                <Select value={customerId} onValueChange={handleCustomerSelect} disabled={isNonEditable}>
                  <SelectTrigger>
                    <SelectValue
                      placeholder={
                        operationMode === "ALIS" || operationMode === "ALIS_IADE"
                          ? "Tedarikçi Seçin (veya elle girin)"
                          : "Müşteri Seçin (veya elle girin)"
                      }
                    />
                  </SelectTrigger>
                  <SelectContent>
                    {filteredPartners.map((c) => (
                      <SelectItem key={c.id} value={c.id}>
                        {c.title} ({c.vkn_tckn})
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>

              <div className="grid gap-4 sm:grid-cols-2">
                <div className="space-y-1">
                  <Label htmlFor="vkn">VKN / TCKN *</Label>
                  <Input
                    id="vkn"
                    value={customer.vknTckn}
                    onChange={(e) => setCustomer({ ...customer, vknTckn: e.target.value })}
                    disabled={isNonEditable}
                    maxLength={11}
                  />
                  {vknWarning && (
                    <p className="text-[10px] text-amber-600 dark:text-amber-400">
                      Geçersiz VKN (10 hane) veya TCKN (11 hane) formatı.
                    </p>
                  )}
                </div>
                <div className="space-y-1">
                  <Label htmlFor="title">Ünvan / Ad Soyad *</Label>
                  <Input
                    id="title"
                    value={customer.title}
                    onChange={(e) => setCustomer({ ...customer, title: e.target.value })}
                    disabled={isNonEditable}
                  />
                </div>
              </div>

              <div className="grid gap-4 sm:grid-cols-2">
                <div className="space-y-1">
                  <Label htmlFor="taxOffice">Vergi Dairesi</Label>
                  <Input
                    id="taxOffice"
                    value={customer.taxOffice}
                    onChange={(e) => setCustomer({ ...customer, taxOffice: e.target.value })}
                    disabled={isNonEditable}
                  />
                </div>
                <div className="space-y-1">
                  <Label htmlFor="email">E-Posta</Label>
                  <Input
                    id="email"
                    type="email"
                    value={customer.email}
                    onChange={(e) => setCustomer({ ...customer, email: e.target.value })}
                    disabled={isNonEditable}
                  />
                </div>
              </div>

              <div className="space-y-1">
                <Label htmlFor="address">Açık Adres</Label>
                <Textarea
                  id="address"
                  rows={2}
                  value={customer.address}
                  onChange={(e) => setCustomer({ ...customer, address: e.target.value })}
                  disabled={isNonEditable}
                />
              </div>

              <AddressSelect
                city={customer.city}
                district={customer.district}
                neighborhood={customer.neighborhood}
                onChange={({ city, district, neighborhood }) =>
                  setCustomer({ ...customer, city, district, neighborhood })
                }
                disabled={isNonEditable}
              />
            </CardContent>
          </Card>

          {/* 3. MAL / HİZMET KALEMLERİ */}
          <Card>
            <CardHeader className="pb-3 flex flex-row items-center justify-between">
              <div>
                <CardTitle className="text-base">Mal / Hizmet Kalemleri ({items.length})</CardTitle>
                <CardDescription>
                  {operationMode === "ALIS"
                    ? "Alış yapılan ürünler ve net birim alış fiyatları"
                    : operationMode === "ALIS_IADE" || operationMode === "SATIS_IADE"
                      ? "İadeye konu olan ürünler ve iade birim fiyatları"
                      : "Satış kalemleri ve KDV oranları"}
                </CardDescription>
              </div>
              <div className="flex items-center gap-2">
                {/* AÇIKLAMA KOLONU GÖSTER / GİZLE BUTONU */}
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => setShowDescription(!showDescription)}
                  className="gap-1.5 text-xs h-8"
                  title="Kalem Açıklaması Kolonunu Göster / Gizle"
                >
                  {showDescription ? <EyeOff className="size-3.5" /> : <Eye className="size-3.5" />}
                  {showDescription ? "Açıklamayı Gizle" : "Açıklama Ekle"}
                </Button>

                {!isNonEditable && (
                  <Button size="sm" variant="outline" onClick={addItem} className="gap-1.5 text-xs h-8">
                    <PlusCircle className="size-3.5" /> Kalem Ekle
                  </Button>
                )}
              </div>
            </CardHeader>
            <CardContent className="space-y-3">
              <datalist id="products-datalist">
                {products.map((p) => (
                  <option key={p.id} value={p.name} />
                ))}
              </datalist>
              {/* DESKTOP & TABLET KOMPAKT TABLO GÖRÜNÜMÜ */}
              <div className="hidden md:block overflow-x-auto rounded-md border border-border/60">
                <table className="w-full min-w-[850px] text-left text-xs border-collapse">
                  <thead>
                    <tr className="bg-muted/50 border-b border-border/60 text-muted-foreground font-medium">
                      <th className="py-2 px-2.5 w-8 text-center">#</th>
                      <th className="py-2 px-2.5 min-w-[200px]">Ürün / Hizmet Adı</th>
                      <th className="py-2 px-2.5 w-32">Miktar</th>
                      <th className="py-2 px-2.5 w-28">Birim</th>
                      <th className="py-2 px-2.5 w-32">
                        {operationMode === "ALIS" ? "Alış Fiyatı" : "Birim Fiyat"}
                      </th>
                      <th className="py-2 px-2.5 w-20">KDV</th>
                      <th className="py-2 px-2.5 w-24">İsk. %</th>
                      <th className="py-2 px-2.5 w-32 text-right">Satır Toplamı</th>
                      {showDescription && (
                        <th className="py-2 px-2.5 min-w-[180px]">Kalem Açıklaması</th>
                      )}
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

                          {/* 2. TEK ÜRÜN / HİZMET ALANI (DATALIST + ENTER DESTEĞİ) */}
                          <td className="py-2 px-2.5 space-y-1.5 align-top pt-2">
                            <Input
                              list="products-datalist"
                              className="h-8 text-xs bg-background"
                              value={item.name}
                              onChange={(e) => {
                                const val = e.target.value;
                                const matched = products.find((p) => p.name === val);
                                if (matched) {
                                  handleProductSelect(item.id, matched.id);
                                } else {
                                  updateItem(item.id, { name: val, productId: undefined, code: "" });
                                }
                              }}
                              onKeyDown={(e) => {
                                if (e.key === "Enter") {
                                  e.preventDefault();
                                  if (index === items.length - 1) {
                                    addItem();
                                  }
                                }
                              }}
                              placeholder="Katalogdan seç veya yaz..."
                              disabled={isNonEditable}
                            />
                          </td>

                          {/* 3. MİKTAR */}
                          <td className="py-2 px-2.5 align-top pt-2">
                            {(() => {
                              const isQtyError = isInvalidQuantity(item.quantity);
                              return (
                                <div className="space-y-1">
                                  <NumericGridInput
                                    className="h-8 text-xs bg-background text-foreground font-mono font-semibold w-full"
                                    min="0.0001"
                                    placeholder="1"
                                    value={item.quantity}
                                    hasError={isQtyError}
                                    onChange={(val) => updateItem(item.id, { quantity: val })}
                                    onEnter={() => {
                                      if (index === items.length - 1) addItem();
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
                              <SelectTrigger className="h-8 text-xs bg-background text-foreground font-semibold">
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
                            <NumericGridInput
                              className="h-8 text-xs bg-background text-foreground font-mono font-semibold w-full"
                              min="0"
                              placeholder="0.00"
                              value={item.unitPrice}
                              onChange={(val) => updateItem(item.id, { unitPrice: val })}
                              onEnter={() => {
                                if (index === items.length - 1) addItem();
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
                              <SelectTrigger className="h-8 text-xs bg-background text-foreground font-semibold">
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
                            <NumericGridInput
                              className="h-8 text-xs bg-background text-foreground font-mono font-semibold w-full"
                              min="0"
                              max="100"
                              placeholder="0"
                              value={item.discountRate}
                              onChange={(val) => updateItem(item.id, { discountRate: val })}
                              onEnter={() => {
                                if (index === items.length - 1) addItem();
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

                          {/* 9. AÇIKLAMA KOLONU (EN SAĞDA) */}
                          {showDescription && (
                            <td className="py-2 px-2.5 align-top pt-2">
                              <Input
                                className="h-8 text-xs bg-background"
                                value={item.description || ""}
                                onChange={(e) => updateItem(item.id, { description: e.target.value })}
                                placeholder="Ek kalem açıklaması..."
                                disabled={isNonEditable}
                              />
                            </td>
                          )}

                          {/* 10. İŞLEMLER */}
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

              {/* MOBİL GÖRÜNÜM (md:hidden) */}
              <div className="md:hidden space-y-3">
                {items.map((item, index) => {
                  const t = itemTotals(item);
                  return (
                    <Card key={item.id} className="p-3 border border-border/80 space-y-2.5">
                      <div className="flex items-center justify-between pb-1 border-b border-border/50">
                        <span className="font-bold text-xs">#{index + 1} Kalem</span>
                        {!isNonEditable && items.length > 1 && (
                          <Button
                            variant="ghost"
                            size="sm"
                            className="h-7 text-destructive"
                            onClick={() => removeItem(item.id)}
                          >
                            <Trash2 className="size-3.5 mr-1" /> Sil
                          </Button>
                        )}
                      </div>
                      <Input
                        list="products-datalist"
                        className="h-8 text-xs font-medium"
                        placeholder="Katalogdan seç veya yaz..."
                        value={item.name}
                        onChange={(e) => {
                          const val = e.target.value;
                          const matched = products.find((p) => p.name === val);
                          if (matched) {
                            handleProductSelect(item.id, matched.id);
                          } else {
                            updateItem(item.id, { name: val, productId: undefined, code: "" });
                          }
                        }}
                        onKeyDown={(e) => {
                          if (e.key === "Enter") {
                            e.preventDefault();
                            if (index === items.length - 1) {
                              addItem();
                            }
                          }
                        }}
                        disabled={isNonEditable}
                      />
                      <div className="grid grid-cols-2 gap-2">
                        <div>
                          <Label className="text-[10px]">Miktar</Label>
                          <NumericGridInput
                            className="h-8 text-xs font-mono w-full"
                            value={item.quantity}
                            onChange={(val) => updateItem(item.id, { quantity: val })}
                            onEnter={() => {
                              if (index === items.length - 1) addItem();
                            }}
                            disabled={isNonEditable}
                          />
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
                      </div>
                      <div className="grid grid-cols-3 gap-2">
                        <div>
                          <Label className="text-[10px]">Birim Fiyat</Label>
                          <NumericGridInput
                            className="h-8 text-xs font-mono w-full"
                            value={item.unitPrice}
                            onChange={(val) => updateItem(item.id, { unitPrice: val })}
                            onEnter={() => {
                              if (index === items.length - 1) addItem();
                            }}
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
                              {VAT_RATES.map((r) => (
                                <SelectItem key={r} value={String(r)}>
                                  %{r}
                                </SelectItem>
                              ))}
                            </SelectContent>
                          </Select>
                        </div>
                        <div>
                          <Label className="text-[10px]">İskonto %</Label>
                          <NumericGridInput
                            className="h-8 text-xs font-mono w-full"
                            value={item.discountRate}
                            onChange={(val) => updateItem(item.id, { discountRate: val })}
                            onEnter={() => {
                              if (index === items.length - 1) addItem();
                            }}
                            disabled={isNonEditable}
                          />
                        </div>
                      </div>
                      {showDescription && (
                        <div>
                          <Label className="text-[10px]">Kalem Açıklaması</Label>
                          <Input
                            className="h-8 text-xs"
                            placeholder="Açıklama..."
                            value={item.description || ""}
                            onChange={(e) => updateItem(item.id, { description: e.target.value })}
                            disabled={isNonEditable}
                          />
                        </div>
                      )}
                      <div className="pt-1 flex items-center justify-between text-xs font-semibold">
                        <span className="text-muted-foreground">Satır Toplamı:</span>
                        <span>{formatMoney(t.total, currency)}</span>
                      </div>
                    </Card>
                  );
                })}
              </div>
            </CardContent>
          </Card>

          {/* 4. NOTLAR VE ÖDEME BİLGİLERİ */}
          <Card>
            <CardHeader className="pb-3">
              <CardTitle className="text-base">Fatura Notları & Ödeme Bilgisi</CardTitle>
            </CardHeader>
            <CardContent className="space-y-4">
              <div className="space-y-1">
                <Label htmlFor="notes">Fatura Notu</Label>
                <Textarea
                  id="notes"
                  rows={2}
                  placeholder="Fatura altında görünecek genel notlar..."
                  value={notes}
                  onChange={(e) => setNotes(e.target.value)}
                  disabled={isNonEditable}
                />
              </div>
              <div className="space-y-1">
                <Label htmlFor="payment">Banka / IBAN / Ödeme Bilgileri</Label>
                <Input
                  id="payment"
                  placeholder="TR00 0000 0000 0000 0000 0000 00 (Ziraat Bankası)"
                  value={paymentInfo}
                  onChange={(e) => setPaymentInfo(e.target.value)}
                  disabled={isNonEditable}
                />
              </div>
            </CardContent>
          </Card>
        </div>

        {/* SAĞ PANEL: ÖZET VE TOPLAMLAR */}
        <div className="space-y-6">
          <Card className="sticky top-6 border-primary/20 bg-card">
            <CardHeader className="pb-3 border-b border-border/50">
              <CardTitle className="text-base">Genel Toplam Özeti</CardTitle>
            </CardHeader>
            <CardContent className="space-y-3 pt-4">
              <div className="flex justify-between text-xs text-muted-foreground">
                <span>Ara Toplam (Brüt):</span>
                <span className="font-mono">{formatMoney(totals.subtotal, currency)}</span>
              </div>

              {totals.totalDiscount > 0 && (
                <div className="flex justify-between text-xs text-destructive">
                  <span>Toplam İskonto:</span>
                  <span className="font-mono">-{formatMoney(totals.totalDiscount, currency)}</span>
                </div>
              )}

              <div className="flex justify-between text-xs font-medium">
                <span>KDV Matrahı:</span>
                <span className="font-mono">{formatMoney(totals.taxableAmount, currency)}</span>
              </div>

              <div className="flex justify-between text-xs text-muted-foreground">
                <span>Toplam KDV:</span>
                <span className="font-mono">{formatMoney(totals.totalVat, currency)}</span>
              </div>

              {isTevkifatli && totals.totalTevkifat > 0 && (
                <>
                  <div className="flex justify-between text-xs text-amber-600 dark:text-amber-400">
                    <span>Tevkif Edilen KDV:</span>
                    <span className="font-mono">-{formatMoney(totals.totalTevkifat, currency)}</span>
                  </div>
                  <div className="flex justify-between text-xs text-emerald-600 dark:text-emerald-400">
                    <span>Beyan Edilecek KDV:</span>
                    <span className="font-mono">{formatMoney(totals.payableVat, currency)}</span>
                  </div>
                </>
              )}

              <div className="border-t border-border pt-3 mt-3 flex justify-between items-baseline">
                <span className="text-sm font-bold">Ödenecek Tutar:</span>
                <span className="text-xl font-bold font-mono text-primary">
                  {formatMoney(totals.grandTotal, currency)}
                </span>
              </div>

              <div className="pt-2 text-[11px] text-muted-foreground italic leading-tight">
                Yalnız: {numberToTurkishWords(totals.grandTotal, currency)}
              </div>

              {!isNonEditable && (
                <div className="pt-4 space-y-2">
                  <Button
                    className="w-full bg-primary text-primary-foreground font-semibold h-10"
                    disabled={saveInvoice.isPending}
                    onClick={() => saveInvoice.mutate("ONAYLANDI")}
                  >
                    {saveInvoice.isPending
                      ? "İşleniyor..."
                      : operationMode === "ALIS"
                        ? "Alış Faturasını Onayla"
                        : operationMode === "ALIS_IADE"
                          ? "Alış İadesini Onayla"
                          : operationMode === "SATIS_IADE"
                            ? "Satış İadesini Onayla"
                            : "Faturayı Onayla & Kaydet"}
                  </Button>
                  <Button
                    variant="outline"
                    className="w-full text-xs"
                    disabled={saveInvoice.isPending}
                    onClick={() => saveInvoice.mutate("TASLAK")}
                  >
                    Taslak Olarak Sakla
                  </Button>
                </div>
              )}
            </CardContent>
          </Card>
        </div>
      </div>

      {/* NES UBL-TR 2.1 XML FORENSIC MODAL */}
      <Dialog open={showXmlModal} onOpenChange={setShowXmlModal}>
        <DialogContent className="max-w-4xl max-h-[85vh] flex flex-col">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2 text-base font-bold">
              <FileCode className="size-5 text-indigo-600 dark:text-indigo-400" /> NES UBL-TR 2.1 XML Forensic Önizleme
            </DialogTitle>
            <DialogDescription className="text-xs">
              NES API sunucusuna iletilmek üzere oluşturulan ham UBL-TR 2.1 XML belgesi ve doğrulanmış parti metadataları.
            </DialogDescription>
          </DialogHeader>

          {(() => {
            const metadata = parseUblXmlForensic(previewXmlString);
            return (
              <div className="space-y-4 overflow-y-auto pr-1 flex-1">
                {/* FORENSIC METADATA CARDS */}
                <div className="grid grid-cols-2 md:grid-cols-4 gap-3 bg-muted/40 p-3 rounded-lg border border-border/60 text-xs">
                  <div className="space-y-1">
                    <span className="text-muted-foreground text-[11px] block font-medium">Gönderici VKN / TCKN</span>
                    <span className="font-mono font-bold text-indigo-600 dark:text-indigo-400 block">{metadata.supplierVkn}</span>
                  </div>
                  <div className="space-y-1">
                    <span className="text-muted-foreground text-[11px] block font-medium">Alıcı VKN / TCKN</span>
                    <span className="font-mono font-bold text-emerald-600 dark:text-emerald-400 block">{metadata.customerVkn}</span>
                  </div>
                  <div className="space-y-1">
                    <span className="text-muted-foreground text-[11px] block font-medium">Gönderici EndpointID</span>
                    <span className="font-mono text-[11px] text-foreground truncate block" title={metadata.supplierEndpointId}>{metadata.supplierEndpointId}</span>
                  </div>
                  <div className="space-y-1">
                    <span className="text-muted-foreground text-[11px] block font-medium">Alıcı EndpointID</span>
                    <span className="font-mono text-[11px] text-foreground truncate block" title={metadata.customerEndpointId}>{metadata.customerEndpointId}</span>
                  </div>
                </div>

                {/* XML CODE DISPLAY AREA */}
                <div className="relative rounded-md border border-border/80 bg-slate-950 text-slate-100 p-4 font-mono text-xs overflow-x-auto max-h-[350px]">
                  <pre className="whitespace-pre">{previewXmlString}</pre>
                </div>
              </div>
            );
          })()}

          <DialogFooter className="flex items-center justify-between sm:justify-between pt-2 border-t">
            <span className="text-xs text-muted-foreground font-mono">
              Uzunluk: {previewXmlString.length} bayt
            </span>
            <div className="flex gap-2">
              <Button
                variant="outline"
                size="sm"
                onClick={() => {
                  navigator.clipboard.writeText(previewXmlString);
                  toast.success("UBL XML kopyalandı!");
                }}
                className="gap-1.5"
              >
                <Copy className="size-3.5" /> Kopyala
              </Button>
              <Button
                variant="default"
                size="sm"
                onClick={() => {
                  const blob = new Blob([previewXmlString], { type: "application/xml" });
                  const url = URL.createObjectURL(blob);
                  const a = document.createElement("a");
                  a.href = url;
                  a.download = `UBL-TR-${parseUblXmlForensic(previewXmlString).uuid}.xml`;
                  a.click();
                  URL.revokeObjectURL(url);
                  toast.success("UBL XML dosyası indirildi!");
                }}
                className="gap-1.5 bg-indigo-600 hover:bg-indigo-700 text-white"
              >
                <Download className="size-3.5" /> XML'i İndir
              </Button>
              <Button variant="ghost" size="sm" onClick={() => setShowXmlModal(false)}>
                Kapat
              </Button>
            </div>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </AppShell>
  );
}
