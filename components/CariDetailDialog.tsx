import { useMemo, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Download } from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { supabase } from "@/integrations/supabase/client";
import { downloadWorkbook } from "@/lib/excel";
import { formatDate, formatMoney } from "@/lib/invoice";
import { TXN_LABELS, TXN_OPTIONS, addDaysISO, isDebit, today, type TxnType } from "@/lib/cari";

type CustomerRow = {
  id: string;
  title: string;
  vkn_tckn: string;
  partner_type: string;
  code: string;
  payment_term_days: number;
  risk_limit: number;
  opening_balance: number;
};

export function CariDetailDialog({
  customer,
  partners,
  onClose,
}: {
  customer: CustomerRow | null;
  partners: CustomerRow[];
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const [from, setFrom] = useState(addDaysISO(today(), -180));
  const [to, setTo] = useState(today());
  const [form, setForm] = useState({
    txnType: "BORC" as TxnType,
    amount: "",
    txnDate: today(),
    dueDate: "",
    documentNo: "",
    description: "",
  });
  const [virman, setVirman] = useState({ targetId: "", amount: "", description: "" });

  const customerId = customer?.id ?? null;

  const { data: rows = [], isLoading } = useQuery({
    queryKey: ["account-transactions", customerId, from, to],
    enabled: Boolean(customerId),
    queryFn: async () => {
      const { data, error } = await supabase
        .from("account_transactions")
        .select("*")
        .eq("customer_id", customerId!)
        .gte("txn_date", from)
        .lte("txn_date", to)
        .order("txn_date", { ascending: true })
        .order("created_at", { ascending: true });
      if (error) throw error;
      return data;
    },
  });

  const opening = Number(customer?.opening_balance ?? 0);

  const ledger = useMemo(() => {
    let running = opening;
    return rows.map((r) => {
      const amount = Number(r.amount);
      running += isDebit(r.txn_type) ? amount : -amount;
      return { ...r, running };
    });
  }, [rows, opening]);

  const totals = useMemo(() => {
    const debit =
      rows.filter((r) => isDebit(r.txn_type)).reduce((s, r) => s + Number(r.amount), 0) + opening;
    const credit = rows
      .filter((r) => !isDebit(r.txn_type))
      .reduce((s, r) => s + Number(r.amount), 0);
    return { debit, credit, balance: debit - credit };
  }, [rows, opening]);

  const overdue = useMemo(
    () => rows.filter((r) => r.due_date && r.due_date < today() && isDebit(r.txn_type)),
    [rows],
  );

  async function currentUserId() {
    const { data } = await supabase.auth.getUser();
    const id = data.user?.id;
    if (!id) throw new Error("Oturum bulunamadı.");
    return id;
  }

  function refresh() {
    queryClient.invalidateQueries({ queryKey: ["account-transactions"] });
    queryClient.invalidateQueries({ queryKey: ["customer-balances"] });
  }

  const addTxn = useMutation({
    mutationFn: async () => {
      if (!customerId) throw new Error("Cari seçili değil.");
      const amount = Number(form.amount);
      if (!amount || amount <= 0) throw new Error("Geçerli bir tutar girin.");
      const userId = await currentUserId();
      const { error } = await supabase.from("account_transactions").insert({
        user_id: userId,
        customer_id: customerId,
        txn_type: form.txnType,
        amount,
        txn_date: form.txnDate,
        due_date: form.dueDate || null,
        document_no: form.documentNo,
        description: form.description,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Cari hareket kaydedildi.");
      setForm((f) => ({ ...f, amount: "", documentNo: "", description: "", dueDate: "" }));
      refresh();
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const addVirman = useMutation({
    mutationFn: async () => {
      if (!customerId) throw new Error("Cari seçili değil.");
      const amount = Number(virman.amount);
      if (!amount || amount <= 0) throw new Error("Geçerli bir tutar girin.");
      if (!virman.targetId) throw new Error("Karşı cariyi seçin.");
      const userId = await currentUserId();
      const description = virman.description || "Cari virman";
      const { error } = await supabase.from("account_transactions").insert([
        {
          user_id: userId,
          customer_id: customerId,
          counter_customer_id: virman.targetId,
          txn_type: "ALACAK",
          amount,
          txn_date: today(),
          description,
          source: "VIRMAN",
        },
        {
          user_id: userId,
          customer_id: virman.targetId,
          counter_customer_id: customerId,
          txn_type: "BORC",
          amount,
          txn_date: today(),
          description,
          source: "VIRMAN",
        },
      ]);
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Virman tamamlandı.");
      setVirman({ targetId: "", amount: "", description: "" });
      refresh();
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const removeTxn = useMutation({
    mutationFn: async (id: string) => {
      const { data: userData } = await supabase.auth.getUser();
      const userId = userData.user?.id;
      const { error } = await supabase
        .from("account_transactions")
        .update({
          deleted_at: new Date().toISOString(),
          deleted_by: userId || null,
        })
        .eq("id", id);
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("Hareket silindi (Çöp Kutusuna taşındı).");
      refresh();
    },
    onError: (e: Error) => toast.error(e.message),
  });

  function exportStatement() {
    if (!customer) return;
    downloadWorkbook(
      ["Tarih", "Tür", "Belge No", "Açıklama", "Vade", "Borç", "Alacak", "Bakiye"],
      ledger.map((r) => [
        r.txn_date,
        TXN_LABELS[r.txn_type as TxnType] ?? r.txn_type,
        r.document_no,
        r.description,
        r.due_date ?? "",
        isDebit(r.txn_type) ? Number(r.amount) : 0,
        isDebit(r.txn_type) ? 0 : Number(r.amount),
        r.running,
      ]),
      `cari-ekstre-${customer.title.slice(0, 20)}-${today()}.xlsx`,
      "Ekstre",
    );
  }

  return (
    <Dialog open={Boolean(customer)} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-h-[90vh] max-w-4xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle className="flex flex-wrap items-center gap-2">
            {customer?.title}
            <Badge variant="outline">
              {customer?.partner_type === "TEDARIKCI" ? "Tedarikçi" : "Müşteri"}
            </Badge>
            {customer?.code ? (
              <span className="text-xs text-muted-foreground">#{customer.code}</span>
            ) : null}
          </DialogTitle>
        </DialogHeader>

        <div className="grid gap-3 sm:grid-cols-4">
          <SummaryBox label="Toplam Borç" value={formatMoney(totals.debit)} />
          <SummaryBox label="Toplam Alacak" value={formatMoney(totals.credit)} />
          <SummaryBox
            label="Bakiye"
            value={formatMoney(Math.abs(totals.balance))}
            hint={totals.balance > 0 ? "Borçlu" : totals.balance < 0 ? "Alacaklı" : "Kapalı"}
          />
          <SummaryBox label="Gecikmiş" value={String(overdue.length)} hint="vadesi geçen kayıt" />
        </div>

        <Tabs defaultValue="ekstre" className="mt-2">
          <TabsList>
            <TabsTrigger value="ekstre">Cari Ekstre</TabsTrigger>
            <TabsTrigger value="hareket">Yeni Hareket</TabsTrigger>
            <TabsTrigger value="virman">Virman</TabsTrigger>
          </TabsList>

          <TabsContent value="ekstre" className="space-y-3">
            <div className="flex flex-wrap items-end gap-3">
              <div className="space-y-1">
                <Label htmlFor="from">Başlangıç</Label>
                <Input
                  id="from"
                  type="date"
                  value={from}
                  onChange={(e) => setFrom(e.target.value)}
                />
              </div>
              <div className="space-y-1">
                <Label htmlFor="to">Bitiş</Label>
                <Input id="to" type="date" value={to} onChange={(e) => setTo(e.target.value)} />
              </div>
              <Button
                variant="outline"
                className="gap-2"
                onClick={exportStatement}
                disabled={ledger.length === 0}
              >
                <Download className="size-4" />
                Ekstreyi Aktar
              </Button>
            </div>

            {isLoading ? (
              <p className="text-sm text-muted-foreground">Yükleniyor…</p>
            ) : ledger.length === 0 ? (
              <p className="text-sm text-muted-foreground">Seçilen tarih aralığında hareket yok.</p>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b border-border text-left text-xs uppercase text-muted-foreground">
                      <th className="py-2 pr-3">Tarih</th>
                      <th className="py-2 pr-3">Tür</th>
                      <th className="py-2 pr-3">Açıklama</th>
                      <th className="py-2 pr-3">Vade</th>
                      <th className="py-2 pr-3 text-right">Borç</th>
                      <th className="py-2 pr-3 text-right">Alacak</th>
                      <th className="py-2 pr-3 text-right">Bakiye</th>
                      <th className="py-2" />
                    </tr>
                  </thead>
                  <tbody>
                    {ledger.map((r) => (
                      <tr key={r.id} className="border-b border-border/60 last:border-0">
                        <td className="py-2 pr-3 whitespace-nowrap">{formatDate(r.txn_date)}</td>
                        <td className="py-2 pr-3">
                          {TXN_LABELS[r.txn_type as TxnType] ?? r.txn_type}
                        </td>
                        <td className="py-2 pr-3">
                          {r.description || "-"}
                          {r.document_no ? (
                            <span className="text-muted-foreground"> · {r.document_no}</span>
                          ) : null}
                        </td>
                        <td className="py-2 pr-3 whitespace-nowrap">
                          {r.due_date ? (
                            <span
                              className={
                                r.due_date < today() && isDebit(r.txn_type)
                                  ? "text-destructive"
                                  : ""
                              }
                            >
                              {formatDate(r.due_date)}
                            </span>
                          ) : (
                            "-"
                          )}
                        </td>
                        <td className="py-2 pr-3 text-right">
                          {isDebit(r.txn_type) ? formatMoney(Number(r.amount)) : "-"}
                        </td>
                        <td className="py-2 pr-3 text-right">
                          {isDebit(r.txn_type) ? "-" : formatMoney(Number(r.amount))}
                        </td>
                        <td className="py-2 pr-3 text-right font-medium">
                          {formatMoney(r.running)}
                        </td>
                        <td className="py-2 text-right">
                          <Button variant="ghost" size="sm" onClick={() => removeTxn.mutate(r.id)}>
                            Sil
                          </Button>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </TabsContent>

          <TabsContent value="hareket">
            <form
              className="grid gap-3 sm:grid-cols-2"
              onSubmit={(e) => {
                e.preventDefault();
                addTxn.mutate();
              }}
            >
              <div className="space-y-1">
                <Label>Hareket Türü</Label>
                <Select
                  value={form.txnType}
                  onValueChange={(v) => setForm({ ...form, txnType: v as TxnType })}
                >
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {TXN_OPTIONS.map((o) => (
                      <SelectItem key={o.value} value={o.value}>
                        {o.label}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <p className="text-xs text-muted-foreground">
                  {TXN_OPTIONS.find((o) => o.value === form.txnType)?.hint}
                </p>
              </div>
              <div className="space-y-1">
                <Label htmlFor="amount">Tutar</Label>
                <Input
                  id="amount"
                  type="number"
                  step="0.01"
                  required
                  value={form.amount}
                  onChange={(e) => setForm({ ...form, amount: e.target.value })}
                />
              </div>
              <div className="space-y-1">
                <Label htmlFor="txnDate">İşlem Tarihi</Label>
                <Input
                  id="txnDate"
                  type="date"
                  value={form.txnDate}
                  onChange={(e) => setForm({ ...form, txnDate: e.target.value })}
                />
              </div>
              <div className="space-y-1">
                <Label htmlFor="dueDate">Vade Tarihi</Label>
                <Input
                  id="dueDate"
                  type="date"
                  value={form.dueDate}
                  onChange={(e) => setForm({ ...form, dueDate: e.target.value })}
                />
              </div>
              <div className="space-y-1">
                <Label htmlFor="documentNo">Belge No</Label>
                <Input
                  id="documentNo"
                  value={form.documentNo}
                  onChange={(e) => setForm({ ...form, documentNo: e.target.value })}
                />
              </div>
              <div className="space-y-1">
                <Label htmlFor="desc">Açıklama</Label>
                <Input
                  id="desc"
                  value={form.description}
                  onChange={(e) => setForm({ ...form, description: e.target.value })}
                />
              </div>
              <div className="sm:col-span-2">
                <Button type="submit" className="w-full" disabled={addTxn.isPending}>
                  Hareketi Kaydet
                </Button>
              </div>
            </form>
          </TabsContent>

          <TabsContent value="virman">
            <form
              className="grid gap-3 sm:grid-cols-2"
              onSubmit={(e) => {
                e.preventDefault();
                addVirman.mutate();
              }}
            >
              <div className="space-y-1 sm:col-span-2">
                <Label>Karşı Cari</Label>
                <Select
                  value={virman.targetId}
                  onValueChange={(v) => setVirman({ ...virman, targetId: v })}
                >
                  <SelectTrigger>
                    <SelectValue placeholder="Cari seçin" />
                  </SelectTrigger>
                  <SelectContent>
                    {partners
                      .filter((p) => p.id !== customerId)
                      .map((p) => (
                        <SelectItem key={p.id} value={p.id}>
                          {p.title}
                        </SelectItem>
                      ))}
                  </SelectContent>
                </Select>
                <p className="text-xs text-muted-foreground">
                  Tutar bu cariden düşülür, seçilen cariye borç olarak yazılır.
                </p>
              </div>
              <div className="space-y-1">
                <Label htmlFor="vamount">Tutar</Label>
                <Input
                  id="vamount"
                  type="number"
                  step="0.01"
                  required
                  value={virman.amount}
                  onChange={(e) => setVirman({ ...virman, amount: e.target.value })}
                />
              </div>
              <div className="space-y-1">
                <Label htmlFor="vdesc">Açıklama</Label>
                <Input
                  id="vdesc"
                  value={virman.description}
                  onChange={(e) => setVirman({ ...virman, description: e.target.value })}
                />
              </div>
              <div className="sm:col-span-2">
                <Button type="submit" className="w-full" disabled={addVirman.isPending}>
                  Virmanı Uygula
                </Button>
              </div>
            </form>
          </TabsContent>
        </Tabs>
      </DialogContent>
    </Dialog>
  );
}

function SummaryBox({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <div className="rounded-lg border border-border bg-card p-3">
      <p className="text-xs text-muted-foreground">{label}</p>
      <p className="text-lg font-semibold">{value}</p>
      {hint ? <p className="text-xs text-muted-foreground">{hint}</p> : null}
    </div>
  );
}
