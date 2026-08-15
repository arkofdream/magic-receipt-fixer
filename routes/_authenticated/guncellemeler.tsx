import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { CalendarDays, ChevronDown } from "lucide-react";

import { AppShell } from "@/components/AppShell";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  CHANGELOG,
  CHANGELOG_SEEN_KEY,
  LATEST_CHANGELOG_ID,
  formatChangelogDate,
  type ChangeType,
} from "@/lib/changelog";

export const Route = createFileRoute("/_authenticated/guncellemeler")({
  head: () => ({
    meta: [
      { title: "Güncellemeler | e-Fatura Portalı" },
      {
        name: "description",
        content:
          "Uygulamaya eklenen yenilikleri, iyileştirmeleri ve düzeltmeleri tarihleriyle inceleyin.",
      },
      { property: "og:title", content: "Güncellemeler | e-Fatura Portalı" },
      {
        property: "og:description",
        content: "Sürüm notları ve yapılan değişikliklerin tarihçesi.",
      },
    ],
  }),
  component: ChangelogPage,
});

const toneFor: Record<ChangeType, "default" | "secondary" | "destructive" | "outline"> = {
  Yeni: "default",
  İyileştirme: "secondary",
  Düzeltme: "outline",
  Kaldırıldı: "destructive",
};

function ChangelogPage() {
  const [openId, setOpenId] = useState<string | null>(LATEST_CHANGELOG_ID || null);

  useEffect(() => {
    try {
      localStorage.setItem(CHANGELOG_SEEN_KEY, LATEST_CHANGELOG_ID);
      window.dispatchEvent(new Event("changelog-seen"));
    } catch {
      /* localStorage kullanılamıyorsa yok say */
    }
  }, []);

  return (
    <AppShell
      title="Güncellemeler"
      subtitle="Uygulamada yapılan değişiklikler ve yayınlandıkları tarihler"
    >
      <div className="space-y-3">
        {CHANGELOG.map((entry) => {
          const open = openId === entry.id;
          return (
            <Card key={entry.id}>
              <CardHeader className="pb-3">
                <button
                  type="button"
                  onClick={() => setOpenId(open ? null : entry.id)}
                  aria-expanded={open}
                  className="flex w-full items-start justify-between gap-4 text-left"
                >
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <CardTitle className="text-base">{entry.title}</CardTitle>
                      <Badge variant="secondary">v{entry.version}</Badge>
                      {entry.id === LATEST_CHANGELOG_ID ? <Badge>Son sürüm</Badge> : null}
                    </div>
                    <p className="mt-1 flex items-center gap-1.5 text-xs text-muted-foreground">
                      <CalendarDays className="size-3.5" />
                      {formatChangelogDate(entry.date)}
                    </p>
                    <p className="mt-2 text-sm text-muted-foreground">{entry.summary}</p>
                  </div>
                  <ChevronDown
                    className={`mt-1 size-4 shrink-0 text-muted-foreground transition-transform ${open ? "rotate-180" : ""}`}
                  />
                </button>
              </CardHeader>
              {open ? (
                <CardContent className="pt-0">
                  <ul className="space-y-2 border-t border-border pt-4">
                    {entry.changes.map((change, i) => (
                      <li key={i} className="flex items-start gap-2 text-sm">
                        <Badge variant={toneFor[change.type]} className="shrink-0">
                          {change.type}
                        </Badge>
                        <span className="text-foreground">{change.text}</span>
                      </li>
                    ))}
                  </ul>
                </CardContent>
              ) : null}
            </Card>
          );
        })}
      </div>
    </AppShell>
  );
}
