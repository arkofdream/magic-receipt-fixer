import { createFileRoute } from "@tanstack/react-router";

import { LegalDocumentPage } from "@/components/LegalDocumentPage";
import { getActiveLegalDocument } from "@/lib/legal.functions";

export const Route = createFileRoute("/uyelik-sozlesmesi")({
  loader: () => getActiveLegalDocument({ data: { docType: "membership_terms" } }),
  head: () => ({
    meta: [
      { title: "Üyelik ve Yazılım Hizmeti Kullanım Sözleşmesi | e-Fatura Portalı" },
      {
        name: "description",
        content:
          "e-Fatura Portalı üyelik ve yazılım hizmeti kullanım sözleşmesi: abonelik, yenileme, veri saklama ve sorumluluk koşulları.",
      },
      { property: "og:title", content: "Üyelik ve Yazılım Hizmeti Kullanım Sözleşmesi" },
      {
        property: "og:description",
        content:
          "Abonelik, yenileme, veri saklama ve sorumluluk koşullarını içeren üyelik sözleşmesi.",
      },
      { property: "og:type", content: "article" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: MembershipTermsPage,
  errorComponent: () => <LegalError />,
  notFoundComponent: () => <LegalError />,
});

function LegalError() {
  return (
    <div className="flex min-h-screen items-center justify-center px-4 text-center text-sm text-muted-foreground">
      Sözleşme metni şu anda görüntülenemiyor. Lütfen daha sonra tekrar deneyin.
    </div>
  );
}

function MembershipTermsPage() {
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
