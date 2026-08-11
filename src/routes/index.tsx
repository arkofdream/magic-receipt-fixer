import { createFileRoute, Link } from "@tanstack/react-router";
import { FileCheck2, ShieldCheck, Users, Package } from "lucide-react";

import { Button } from "@/components/ui/button";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "e-Fatura Portalı | GİB E-Fatura & E-Arşiv Kesme" },
      {
        name: "description",
        content:
          "GİB uyumlu e-fatura ve e-arşiv faturalarınızı hazırlayın, cari ve ürün kataloğunuzu yönetin, faturalarınızı tek panelden takip edin.",
      },
      { property: "og:title", content: "e-Fatura Portalı | GİB E-Fatura & E-Arşiv" },
      {
        property: "og:description",
        content: "Fatura kesme, cari rehberi ve ürün kataloğu tek panelde.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: Landing,
});

const features = [
  { icon: FileCheck2, title: "Fatura Kes", desc: "E-Arşiv ve e-fatura kalemlerini KDV, tevkifat ve iskonto ile hesaplayın." },
  { icon: Users, title: "Cari Rehberi", desc: "VKN/TCKN ile müşterilerinizi kaydedin, faturaya tek tıkla aktarın." },
  { icon: Package, title: "Ürün Kataloğu", desc: "Sık kullandığınız hizmet ve ürünleri fiyatlarıyla saklayın." },
  { icon: ShieldCheck, title: "Güvenli Depolama", desc: "Verileriniz hesabınıza özel, yalnızca siz erişebilirsiniz." },
];

function Landing() {
  return (
    <div className="min-h-screen bg-background">
      <header className="flex items-center justify-between border-b border-border px-6 py-4">
        <span className="text-lg font-bold tracking-tight">e-Fatura Portalı</span>
        <Button asChild size="sm">
          <Link to="/auth">Giriş Yap</Link>
        </Button>
      </header>

      <section className="mx-auto max-w-4xl px-6 py-20 text-center">
        <p className="mb-4 inline-block rounded-full bg-accent px-3 py-1 text-xs font-semibold text-accent-foreground">
          GİB E-Fatura & E-Arşiv
        </p>
        <h1 className="text-4xl font-bold tracking-tight text-foreground sm:text-5xl">
          Faturalarınızı dakikalar içinde hazırlayın
        </h1>
        <p className="mx-auto mt-5 max-w-2xl text-lg text-muted-foreground">
          Cari rehberi, ürün kataloğu ve otomatik KDV/tevkifat hesaplamasıyla e-arşiv faturalarınızı
          hazırlayın, arşivinizden takip edin.
        </p>
        <div className="mt-8 flex justify-center gap-3">
          <Button asChild size="lg">
            <Link to="/auth">Hemen Başla</Link>
          </Button>
        </div>
      </section>

      <section className="mx-auto grid max-w-5xl gap-4 px-6 pb-24 sm:grid-cols-2">
        {features.map((f) => (
          <div key={f.title} className="rounded-lg border border-border bg-card p-6">
            <f.icon className="size-6 text-primary" />
            <h2 className="mt-4 text-base font-semibold text-card-foreground">{f.title}</h2>
            <p className="mt-1 text-sm text-muted-foreground">{f.desc}</p>
          </div>
        ))}
      </section>
    </div>
  );
}
