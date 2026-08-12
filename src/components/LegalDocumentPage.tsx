import { Link } from "@tanstack/react-router";

import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";

/** Minimal, dependency-free renderer for the "## Heading" + paragraph legal text format. */
export function LegalContent({ content }: { content: string }) {
  const blocks = content.split(/\n{2,}/).map((b) => b.trim()).filter(Boolean);
  return (
    <div className="space-y-4">
      {blocks.map((block, i) =>
        block.startsWith("## ") ? (
          <h2 key={i} className="pt-2 text-lg font-semibold tracking-tight text-foreground">
            {block.slice(3)}
          </h2>
        ) : (
          <p key={i} className="whitespace-pre-line text-sm leading-relaxed text-muted-foreground">
            {block}
          </p>
        ),
      )}
    </div>
  );
}

export function LegalDocumentPage({
  title,
  version,
  publishedAt,
  content,
}: {
  title: string;
  version: string;
  publishedAt: string;
  content: string;
}) {
  return (
    <div className="min-h-screen bg-secondary">
      <header className="flex flex-wrap items-center justify-between gap-3 border-b border-border bg-card px-4 py-4 sm:px-6">
        <Link to="/" className="text-base font-bold tracking-tight">
          e-Fatura Portalı
        </Link>
        <Button asChild size="sm" variant="outline">
          <Link to="/auth">Giriş / Kayıt</Link>
        </Button>
      </header>

      <main className="mx-auto w-full max-w-3xl px-4 py-8 sm:px-6 sm:py-12">
        <h1 className="text-2xl font-bold tracking-tight text-foreground sm:text-3xl">{title}</h1>
        <p className="mt-2 text-xs text-muted-foreground">
          Versiyon {version} · Yayın tarihi{" "}
          {new Date(publishedAt).toLocaleDateString("tr-TR", {
            day: "2-digit",
            month: "long",
            year: "numeric",
          })}
        </p>
        <Card className="mt-6">
          <CardContent className="p-4 sm:p-6">
            <LegalContent content={content} />
          </CardContent>
        </Card>
      </main>
    </div>
  );
}
