import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { useState } from "react";
import { toast } from "sonner";

import { AppShell } from "@/components/AppShell";
import { LegalContent } from "@/components/LegalDocumentPage";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger,
} from "@/components/ui/accordion";
import {
  adminCreateLegalVersion,
  adminListAuditLog,
  adminListConsents,
  adminListLegalVersions,
  adminListSubscriptions,
  adminUpdateSubscription,
} from "@/lib/admin.functions";
import { getMyAccountFlags } from "@/lib/subscription.functions";
import { PLAN_LABELS, STATUS_LABELS, formatDate } from "@/lib/subscription";

export const Route = createFileRoute("/_authenticated/admin")({
  head: () => ({
    meta: [
      { title: "Yönetim Paneli | e-Fatura Portalı" },
      { name: "description", content: "Abonelik yönetimi, sözleşme versiyonları ve onay kayıtları." },
      { property: "og:title", content: "Yönetim Paneli" },
      { property: "og:description", content: "Abonelik ve sözleşme yönetimi." },
    ],
  }),
  component: AdminPage,
});

function AdminPage() {
  const fetchFlags = useServerFn(getMyAccountFlags);
  const flags = useQuery({ queryKey: ["account-flags"], queryFn: () => fetchFlags() });

  if (flags.isLoading) {
    return (
      <AppShell title="Yönetim Paneli">
        <p className="text-sm text-muted-foreground">Yetki kontrol ediliyor…</p>
      </AppShell>
    );
  }

  if (!flags.data?.isAdmin) {
    return (
      <AppShell title="Yönetim Paneli">
        <Card className="mx-auto max-w-lg">
          <CardContent className="p-6 text-center text-sm text-muted-foreground">
            Bu bölüme erişim yetkiniz bulunmuyor.
          </CardContent>
        </Card>
      </AppShell>
    );
  }

  return (
    <AppShell title="Yönetim Paneli" subtitle="Abonelik ve sözleşme yönetimi">
      <Tabs defaultValue="subs">
        <TabsList className="flex w-full flex-wrap justify-start">
          <TabsTrigger value="subs">Abonelik Yönetimi</TabsTrigger>
          <TabsTrigger value="legal">Sözleşme Yönetimi</TabsTrigger>
          <TabsTrigger value="consents">Onay Kayıtları</TabsTrigger>
          <TabsTrigger value="audit">İşlem Geçmişi</TabsTrigger>
        </TabsList>
        <TabsContent value="subs" className="pt-4">
          <SubscriptionsTab />
        </TabsContent>
        <TabsContent value="legal" className="pt-4">
          <LegalTab />
        </TabsContent>
        <TabsContent value="consents" className="pt-4">
          <ConsentsTab />
        </TabsContent>
        <TabsContent value="audit" className="pt-4">
          <AuditTab />
        </TabsContent>
      </Tabs>
    </AppShell>
  );
}

function SubscriptionsTab() {
  const queryClient = useQueryClient();
  const list = useServerFn(adminListSubscriptions);
  const update = useServerFn(adminUpdateSubscription);
  const [period, setPeriod] = useState<Record<string, "1_MONTH" | "1_YEAR">>({});
  const [price, setPrice] = useState<Record<string, string>>({});
  const [verified, setVerified] = useState<Record<string, boolean>>({});

  const subs = useQuery({ queryKey: ["admin-subscriptions"], queryFn: () => list() });

  const mutation = useMutation({
    mutationFn: (input: Parameters<typeof adminUpdateSubscription>[0]["data"]) =>
      update({ data: input }),
    onSuccess: () => {
      toast.success("Abonelik güncellendi.");
      queryClient.invalidateQueries({ queryKey: ["admin-subscriptions"] });
      queryClient.invalidateQueries({ queryKey: ["my-subscription"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  if (subs.isLoading) return <p className="text-sm text-muted-foreground">Yükleniyor…</p>;
  if (subs.error) return <p className="text-sm text-destructive">Abonelikler yüklenemedi.</p>;

  return (
    <div className="space-y-4">
      {(subs.data ?? []).map((s) => {
        const p = period[s.userId] ?? "1_MONTH";
        return (
          <Card key={s.userId}>
            <CardHeader className="pb-3">
              <CardTitle className="flex flex-wrap items-center gap-2 text-base">
                {s.companyTitle || s.email || s.userId}
                <Badge variant={s.isPaidAccessAllowed ? "secondary" : "destructive"}>
                  {STATUS_LABELS[s.status]}
                </Badge>
              </CardTitle>
              <CardDescription className="break-all">{s.email}</CardDescription>
            </CardHeader>
            <CardContent className="space-y-4 text-sm">
              <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
                <Info label="Paket" value={PLAN_LABELS[s.plan] ?? s.plan} />
                <Info label="Başlangıç" value={formatDate(s.startDate)} />
                <Info label="Bitiş" value={formatDate(s.endDate)} />
                <Info
                  label="Yenileme ücreti"
                  value={s.renewalPrice === null ? "—" : `${s.renewalPrice} TL`}
                />
                <Info label="Son ödeme" value={formatDate(s.lastPaymentDate)} />
                <Info label="Kalan gün" value={String(s.daysRemaining)} />
              </div>

              <div className="flex flex-col gap-2 sm:flex-row sm:flex-wrap sm:items-end">
                <div className="w-full sm:w-36">
                  <Label className="text-xs">Süre</Label>
                  <Select
                    value={p}
                    onValueChange={(v) => setPeriod((s2) => ({ ...s2, [s.userId]: v as "1_MONTH" | "1_YEAR" }))}
                  >
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="1_MONTH">1 ay</SelectItem>
                      <SelectItem value="1_YEAR">1 yıl</SelectItem>
                    </SelectContent>
                  </Select>
                </div>
                <div className="w-full sm:w-40">
                  <Label className="text-xs">Yenileme ücreti (TL)</Label>
                  <Input
                    inputMode="decimal"
                    placeholder="Örn. 0,00"
                    value={price[s.userId] ?? (s.renewalPrice === null ? "" : String(s.renewalPrice))}
                    onChange={(e) => setPrice((st) => ({ ...st, [s.userId]: e.target.value }))}
                  />
                </div>
                <label className="flex items-center gap-2 py-2 text-xs">
                  <Checkbox
                    checked={verified[s.userId] ?? false}
                    onCheckedChange={(c) =>
                      setVerified((st) => ({ ...st, [s.userId]: c === true }))
                    }
                  />
                  Ödeme doğrulandı
                </label>
              </div>

              <div className="flex flex-wrap gap-2">
                <Button
                  size="sm"
                  disabled={mutation.isPending}
                  onClick={() => {
                    const raw = price[s.userId];
                    const parsed = raw === undefined || raw.trim() === "" ? null : Number(raw.replace(",", "."));
                    if (parsed !== null && Number.isNaN(parsed)) {
                      toast.error("Geçerli bir yenileme ücreti girin.");
                      return;
                    }
                    mutation.mutate({
                      targetUserId: s.userId,
                      action: "RENEW",
                      period: p,
                      renewalPrice: parsed,
                      paymentVerified: verified[s.userId] ?? false,
                    });
                  }}
                >
                  Aboneliği Yenile
                </Button>
                <Button
                  size="sm"
                  variant="outline"
                  disabled={mutation.isPending}
                  onClick={() => mutation.mutate({ targetUserId: s.userId, action: "REACTIVATE" })}
                >
                  Aktif Et
                </Button>
                <Button
                  size="sm"
                  variant="outline"
                  disabled={mutation.isPending}
                  onClick={() => mutation.mutate({ targetUserId: s.userId, action: "SUSPEND" })}
                >
                  Askıya Al
                </Button>
                <Button
                  size="sm"
                  variant="destructive"
                  disabled={mutation.isPending}
                  onClick={() => mutation.mutate({ targetUserId: s.userId, action: "CANCEL" })}
                >
                  İptal Et
                </Button>
              </div>
            </CardContent>
          </Card>
        );
      })}
    </div>
  );
}

function LegalTab() {
  const queryClient = useQueryClient();
  const list = useServerFn(adminListLegalVersions);
  const create = useServerFn(adminCreateLegalVersion);
  const versions = useQuery({ queryKey: ["admin-legal"], queryFn: () => list() });

  const [docType, setDocType] = useState<"membership_terms" | "kvkk_notice">("membership_terms");
  const [version, setVersion] = useState("");
  const [title, setTitle] = useState("");
  const [content, setContent] = useState("");
  const [requiresReacceptance, setRequiresReacceptance] = useState(false);

  const mutation = useMutation({
    mutationFn: () =>
      create({ data: { docType, version, title, content, requiresReacceptance } }),
    onSuccess: () => {
      toast.success("Yeni sözleşme versiyonu yayımlandı.");
      setVersion("");
      setTitle("");
      setContent("");
      setRequiresReacceptance(false);
      queryClient.invalidateQueries({ queryKey: ["admin-legal"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  return (
    <div className="grid gap-6 lg:grid-cols-2">
      <Card>
        <CardHeader>
          <CardTitle>Yeni Versiyon Oluştur</CardTitle>
          <CardDescription>Eski versiyonlar silinmez, arşivde saklanır.</CardDescription>
        </CardHeader>
        <CardContent className="space-y-3">
          <div>
            <Label className="text-xs">Belge</Label>
            <Select value={docType} onValueChange={(v) => setDocType(v as typeof docType)}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="membership_terms">Üyelik Sözleşmesi</SelectItem>
                <SelectItem value="kvkk_notice">KVKK Aydınlatma Metni</SelectItem>
              </SelectContent>
            </Select>
          </div>
          <div>
            <Label className="text-xs">Versiyon</Label>
            <Input value={version} onChange={(e) => setVersion(e.target.value)} placeholder="v1.1" />
          </div>
          <div>
            <Label className="text-xs">Başlık</Label>
            <Input value={title} onChange={(e) => setTitle(e.target.value)} />
          </div>
          <div>
            <Label className="text-xs">İçerik</Label>
            <Textarea
              rows={10}
              value={content}
              onChange={(e) => setContent(e.target.value)}
              placeholder="## 1. Taraflar&#10;..."
            />
          </div>
          <label className="flex items-center gap-2 text-sm">
            <Checkbox
              checked={requiresReacceptance}
              onCheckedChange={(c) => setRequiresReacceptance(c === true)}
            />
            Kullanıcıların yeniden onaylaması gerekiyor
          </label>
          <Button
            className="w-full"
            disabled={mutation.isPending || version.trim() === "" || content.trim().length < 50}
            onClick={() => mutation.mutate()}
          >
            Versiyonu Yayımla
          </Button>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Versiyon Arşivi</CardTitle>
          <CardDescription>Tüm sözleşme ve KVKK versiyonları</CardDescription>
        </CardHeader>
        <CardContent>
          {versions.isLoading ? (
            <p className="text-sm text-muted-foreground">Yükleniyor…</p>
          ) : (
            <Accordion type="single" collapsible>
              {(versions.data ?? []).map((d) => (
                <AccordionItem key={d.id} value={d.id}>
                  <AccordionTrigger className="text-left text-sm">
                    <span>
                      {d.docType === "membership_terms" ? "Üyelik Sözleşmesi" : "KVKK Aydınlatma"} ·{" "}
                      {d.version}
                      <span className="ml-2 text-xs text-muted-foreground">
                        {formatDate(d.publishedAt)}
                      </span>
                    </span>
                  </AccordionTrigger>
                  <AccordionContent>
                    <LegalContent content={d.content} />
                  </AccordionContent>
                </AccordionItem>
              ))}
            </Accordion>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

function ConsentsTab() {
  const list = useServerFn(adminListConsents);
  const consents = useQuery({ queryKey: ["admin-consents"], queryFn: () => list() });

  if (consents.isLoading) return <p className="text-sm text-muted-foreground">Yükleniyor…</p>;

  return (
    <Card>
      <CardHeader>
        <CardTitle>Kullanıcı Onay Kayıtları</CardTitle>
        <CardDescription>Hangi kullanıcının hangi versiyonu kabul ettiği</CardDescription>
      </CardHeader>
      <CardContent className="overflow-x-auto">
        <table className="w-full min-w-[640px] text-left text-sm">
          <thead className="text-xs text-muted-foreground">
            <tr>
              <th className="py-2">Kullanıcı</th>
              <th>Belge</th>
              <th>Versiyon</th>
              <th>Durum</th>
              <th>Tarih</th>
            </tr>
          </thead>
          <tbody>
            {(consents.data ?? []).map((c) => (
              <tr key={c.id} className="border-t border-border">
                <td className="py-2 font-mono text-xs">{c.user_id.slice(0, 8)}…</td>
                <td>{c.consent_type}</td>
                <td>{c.document_version}</td>
                <td>{c.accepted ? "Verildi" : "Verilmedi"}</td>
                <td>{formatDate(c.accepted_at)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </CardContent>
    </Card>
  );
}

function AuditTab() {
  const list = useServerFn(adminListAuditLog);
  const log = useQuery({ queryKey: ["admin-audit"], queryFn: () => list() });

  if (log.isLoading) return <p className="text-sm text-muted-foreground">Yükleniyor…</p>;

  return (
    <Card>
      <CardHeader>
        <CardTitle>Yönetici İşlem Geçmişi</CardTitle>
      </CardHeader>
      <CardContent className="space-y-2 text-sm">
        {(log.data ?? []).length === 0 ? (
          <p className="text-muted-foreground">Kayıt yok.</p>
        ) : (
          (log.data ?? []).map((e) => (
            <div key={e.id} className="rounded-md border border-border p-3">
              <p className="font-medium">{e.action}</p>
              <p className="text-xs text-muted-foreground">
                {formatDate(e.createdAt)}
                {e.targetUserId ? ` · ${e.targetUserId.slice(0, 8)}…` : ""}
              </p>
            </div>
          ))
        )}
      </CardContent>
    </Card>
  );
}

function Info({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-xs text-muted-foreground">{label}</p>
      <p className="font-medium">{value}</p>
    </div>
  );
}
