import { createFileRoute, Link } from "@tanstack/react-router";
import { FileCheck2, ShieldCheck, Users, Package, Download, Monitor } from "lucide-react";

import { Button } from "@/components/ui/button";
import { DESKTOP_DOWNLOAD_URL } from "@/lib/download";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "Magic Receipt | GİB E-Fatura, E-Arşiv & Ön Muhasebe" },
      {
        name: "description",
        content:
          "GİB uyumlu e-fatura ve e-arşiv faturalarınızı hazırlayın, cari ve ürün kataloğunuzu yönetin, faturalarınızı tek panelden takip edin.",
      },
      { property: "og:title", content: "Magic Receipt | Ön Muhasebe & e-Fatura" },
      {
        property: "og:description",
        content: "Fatura kesme, cari rehberi, stok ve ürün kataloğu tek panelde.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: Landing,
});

const features = [
  {
    icon: FileCheck2,
    title: "Fatura Kes & e-Arşiv",
    desc: "E-Arşiv ve e-fatura kalemlerini KDV, tevkifat ve iskonto ile hatasız hesaplayın.",
  },
  {
    icon: Users,
    title: "Cari Rehberi & Ekstre",
    desc: "VKN/TCKN ile müşterilerinizi kaydedin, bakiye ve ekstrelerini tek tıkla takip edin.",
  },
  {
    icon: Package,
    title: "Ürün & Stok Kataloğu",
    desc: "Çoklu depo, barkod, kritik stok uyarıları ve fiyat listelerini yönetin.",
  },
  {
    icon: ShieldCheck,
    title: "Masaüstü & Güvenli Bulut",
    desc: "Hem tarayıcıdan hem de Windows masaüstü uygulamasından güvenle erişin.",
  },
];

function Landing() {
  return (
    <div className="min-h-screen bg-background">
      <header className="flex items-center justify-between border-b border-border px-6 py-4">
        <span className="text-lg font-bold tracking-tight text-foreground">Magic Receipt</span>
        <div className="flex items-center gap-3">
          <Button asChild variant="outline" size="sm" className="gap-2">
            <a href={DESKTOP_DOWNLOAD_URL} target="_blank" rel="noopener noreferrer">
              <Download className="size-4" />
              Windows İçin İndir (.exe)
            </a>
          </Button>
          <Button asChild size="sm">
            <Link to="/auth">Giriş Yap</Link>
          </Button>
        </div>
      </header>

      <section className="mx-auto max-w-4xl px-6 py-20 text-center">
        <div className="mb-4 inline-flex items-center gap-2 rounded-full bg-accent px-3 py-1 text-xs font-semibold text-accent-foreground">
          <Monitor className="size-3.5" /> Web & Windows Masaüstü Sürümü Yayında
        </div>
        <h1 className="text-4xl font-bold tracking-tight text-foreground sm:text-5xl">
          Ön muhasebe ve faturalarınızı kolayca yönetin
        </h1>
        <p className="mx-auto mt-5 max-w-2xl text-lg text-muted-foreground">
          Cari hesaplar, ürün/stok kataloğu, POS satışları ve otomatik KDV/tevkifat hesaplamasıyla
          e-arşiv faturalarınızı hazırlayın, arşivinizden takip edin.
        </p>
        <div className="mt-8 flex flex-wrap justify-center gap-4">
          <Button asChild size="lg">
            <Link to="/auth">Web'den Hemen Başla</Link>
          </Button>
          <Button asChild size="lg" variant="outline" className="gap-2">
            <a href={DESKTOP_DOWNLOAD_URL} target="_blank" rel="noopener noreferrer">
              <Download className="size-4" />
              Windows Uygulamasını İndir (.exe)
            </a>
          </Button>
        </div>
      </section>

      <section className="mx-auto grid max-w-5xl gap-4 px-6 pb-24 sm:grid-cols-2">
        {features.map((f) => (
          <div key={f.title} className="rounded-lg border border-border bg-card p-6 shadow-sm">
            <f.icon className="size-6 text-primary" />
            <h2 className="mt-4 text-base font-semibold text-card-foreground">{f.title}</h2>
            <p className="mt-1 text-sm text-muted-foreground">{f.desc}</p>
          </div>
        ))}
      </section>
    </div>
  );
}
