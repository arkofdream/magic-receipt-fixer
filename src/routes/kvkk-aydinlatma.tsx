import { createFileRoute } from "@tanstack/react-router";

import { LegalDocumentPage } from "@/components/LegalDocumentPage";
import { getActiveLegalDocument } from "@/lib/legal.functions";

export const Route = createFileRoute("/kvkk-aydinlatma")({
  loader: () => getActiveLegalDocument({ data: { docType: "kvkk_notice" } }),
  head: () => ({
    meta: [
      { title: "KVKK Aydınlatma Metni | e-Fatura Portalı" },
      {
        name: "description",
        content:
          "e-Fatura Portalı KVKK aydınlatma metni: işlenen kişisel veriler, işleme amaçları, saklama süresi ve ilgili kişi hakları.",
      },
      { property: "og:title", content: "KVKK Aydınlatma Metni" },
      {
        property: "og:description",
        content: "İşlenen kişisel veriler, amaçlar, saklama süresi ve KVKK m.11 kapsamındaki haklarınız.",
      },
      { property: "og:type", content: "article" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: KvkkPage,
  errorComponent: () => <LegalError />,
  notFoundComponent: () => <LegalError />,
});

function LegalError() {
  return (
    <div className="flex min-h-screen items-center justify-center px-4 text-center text-sm text-muted-foreground">
      Aydınlatma metni şu anda görüntülenemiyor. Lütfen daha sonra tekrar deneyin.
    </div>
  );
}

function KvkkPage() {
  const doc = Route.useLoaderData();
  if (!doc) return <LegalError />;
  return (
    <LegalDocumentPage
      title={doc.title}
      version={doc.version}
      publishedAt={doc.publishedAt}
      content={doc.content}
    />
  );
}
