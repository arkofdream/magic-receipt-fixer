import { createFileRoute } from "@tanstack/react-router";
import { AppShell } from "@/components/AppShell";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { useState, useMemo } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { formatMoney, formatDate } from "@/lib/invoice";
import { toast } from "sonner";
import { CheckCircle2, CreditCard, AlertCircle } from "lucide-react";

export const Route = createFileRoute("/_authenticated/odeme")({
  component: OdemePage,
});

function OdemePage() {
  const queryClient = useQueryClient();
  const [supplierId, setSupplierId] = useState<string>("");
  const [invoiceId, setInvoiceId] = useState<string>("");
  const [amountStr, setAmountStr] = useState<string>("");

  const { data: suppliers = [] } = useQuery({
    queryKey: ["odeme-suppliers"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("customers")
        .select("id, title, vkn_tckn, partner_type")
        .in("partner_type", ["TEDARIKCI", "MUSTERI_TEDARIKCI", "DIGER"])
        .is("deleted_at", null)
        .order("title");
      if (error) throw error;
      return data;
    }
  });

  const { data: invoices = [], isLoading: invoicesLoading } = useQuery({
    queryKey: ["odeme-invoices", supplierId],
    enabled: !!supplierId,
    queryFn: async () => {
      const { data: invs, error: invError } = await supabase
        .from("invoices")
        .select("id, invoice_number, invoice_date, grand_total, type, currency")
        .eq("customer_id", supplierId)
        .eq("status", "ONAYLANDI")
        .in("type", ["ALIS", "GELEN_FATURA", "GELEN_E_ARSIV", "MUSTAHSIL"])
        .is("deleted_at", null);
      if (invError) throw invError;

      if (!invs || invs.length === 0) return [];

      const invoiceIds = invs.map(i => i.id);
      const { data: pmts, error: pError } = await supabase
        .from("account_transactions")
        .select("source_id, amount")
        .in("source_id", invoiceIds)
        .eq("source", "FATURA_ODEME");
      if (pError) throw pError;

      const paidMap = new Map<string, number>();
      for (const p of pmts || []) {
        paidMap.set(p.source_id, (paidMap.get(p.source_id) || 0) + Number(p.amount));
      }

      return invs.map(inv => {
        const paid = paidMap.get(inv.id) || 0;
        const remaining = Math.max(0, Number(inv.grand_total) - paid);
        return { ...inv, paid, remaining };
      }).filter(inv => inv.remaining > 0.01);
    }
  });

  const selectedInvoice = useMemo(() => invoices.find(i => i.id === invoiceId), [invoices, invoiceId]);

  const handleInvoiceSelect = (id: string) => {
    setInvoiceId(id);
    const inv = invoices.find(i => i.id === id);
    if (inv) {
      setAmountStr(inv.remaining.toString());
    } else {
      setAmountStr("");
    }
  };

  const submitMut = useMutation({
    mutationFn: async () => {
      const amt = parseFloat(amountStr);
      if (isNaN(amt) || amt <= 0) throw new Error("Geçerli ve 0'dan büyük bir tutar giriniz.");
      if (!invoiceId) throw new Error("Fatura seçimi zorunludur.");
      
      const { data, error } = await supabase.rpc("process_invoice_payment", {
        p_invoice_id: invoiceId,
        p_amount: amt,
        p_is_purchase: true
      });
      
      if (error) {
        if (error.message.includes('100 Kasa') || error.message.includes('320')) {
             throw new Error(error.message + " (Hesap Planınızı Kontrol Edin)");
        }
        throw error;
      }
      if (data && !data.success) throw new Error(data.message || "Bilinmeyen hata");
    },
    onSuccess: () => {
      toast.success("Ödeme başarıyla kaydedildi.");
      setInvoiceId("");
      setAmountStr("");
      queryClient.invalidateQueries({ queryKey: ["odeme-invoices"] });
      queryClient.invalidateQueries({ queryKey: ["vade-takip-transactions"] });
      queryClient.invalidateQueries({ queryKey: ["vade-takip-payments"] });
      queryClient.invalidateQueries({ queryKey: ["customer-balances"] });
      queryClient.invalidateQueries({ queryKey: ["account-transactions"] });
    },
    onError: (e: Error) => {
      toast.error(e.message);
    }
  });

  return (
    <AppShell title="Ödeme Girişi" subtitle="Tedarikçilerinize yaptığınız ödemeleri (fatura bazlı) kaydedin.">
      <div className="max-w-xl mx-auto space-y-6">
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <CreditCard className="size-5 text-rose-600" />
              Ödeme Fişi
            </CardTitle>
            <CardDescription>
              Seçilen fatura üzerinden "FATURA_ODEME" türünde finansal kayıt oluşur ve cari bakiye güncellenir.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="space-y-2">
              <Label>Tedarikçi / Cari Hesap <span className="text-destructive">*</span></Label>
              <Select value={supplierId} onValueChange={(v) => { setSupplierId(v); setInvoiceId(""); setAmountStr(""); }}>
                <SelectTrigger>
                  <SelectValue placeholder="Tedarikçi Seçin" />
                </SelectTrigger>
                <SelectContent>
                  {suppliers.map(c => (
                    <SelectItem key={c.id} value={c.id}>
                      {c.title}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            {supplierId && (
              <div className="space-y-2">
                <Label>Ödenecek Fatura <span className="text-destructive">*</span></Label>
                {invoicesLoading ? (
                  <div className="text-sm text-muted-foreground p-3 border rounded bg-muted/20">Açık faturalar yükleniyor...</div>
                ) : invoices.length === 0 ? (
                  <div className="text-sm text-muted-foreground p-3 border rounded bg-muted/20 space-y-2">
                    <p>Bu tedarikçiye ait açık (ödenmemiş) onaylı alış faturası bulunamadı.</p>
                    <div className="flex items-start gap-1.5 p-2 bg-amber-500/10 text-amber-700 dark:text-amber-400 rounded text-xs border border-amber-500/20">
                       <AlertCircle className="size-3.5 mt-0.5 shrink-0" />
                       <p><strong>Not (Backend Eksikliği):</strong> Fatura bağlantısı olmayan bağımsız manuel tahsilat/ödeme girişi (manuel hesap hareketine ödeme bağlama) backend RPC altyapısındaki (<code>process_invoice_payment</code>) kısıtlamalar nedeniyle bu ekrandan yapılamamaktadır. İşlem fatura ID'si zorunlu kılar. Bu özellik "Gelecek Faz" konusu olarak raporlanmıştır.</p>
                    </div>
                  </div>
                ) : (
                  <Select value={invoiceId} onValueChange={handleInvoiceSelect}>
                    <SelectTrigger>
                      <SelectValue placeholder="Ödeme yapılacak faturayı seçin" />
                    </SelectTrigger>
                    <SelectContent>
                      {invoices.map(inv => (
                        <SelectItem key={inv.id} value={inv.id}>
                          {inv.invoice_number || "No'suz"} - {formatDate(inv.invoice_date)} (Kalan: {formatMoney(inv.remaining, inv.currency)})
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                )}
              </div>
            )}

            {invoiceId && selectedInvoice && (
              <div className="space-y-2 pt-2 border-t mt-4">
                <Label>Ödeme Tutarı (TL) <span className="text-destructive">*</span></Label>
                <Input 
                  type="number" 
                  step="0.01"
                  min="0.01"
                  max={selectedInvoice.remaining}
                  value={amountStr} 
                  onChange={e => setAmountStr(e.target.value)} 
                  placeholder="0.00" 
                  className="text-lg font-semibold h-12"
                />
                <div className="flex justify-between items-center text-xs mt-1">
                  <span className="text-muted-foreground">
                    En fazla kalan tutar kadar girebilirsiniz: {formatMoney(selectedInvoice.remaining, selectedInvoice.currency)}
                  </span>
                  {parseFloat(amountStr) < selectedInvoice.remaining && parseFloat(amountStr) > 0 && (
                    <span className="text-amber-600 font-medium flex items-center gap-1">
                      <CheckCircle2 className="size-3.5" /> Kısmi Ödeme
                    </span>
                  )}
                </div>
              </div>
            )}

            <Button 
              className="w-full mt-6 bg-rose-600 hover:bg-rose-700 h-11" 
              disabled={!invoiceId || !amountStr || parseFloat(amountStr) <= 0 || submitMut.isPending}
              onClick={() => submitMut.mutate()}
            >
              {submitMut.isPending ? "Ödeme Kaydediliyor..." : "Ödemeyi Kaydet"}
            </Button>

          </CardContent>
        </Card>
      </div>
    </AppShell>
  );
}
