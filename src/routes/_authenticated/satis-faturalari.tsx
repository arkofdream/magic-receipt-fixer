import { createFileRoute } from "@tanstack/react-router";
import { InvoicesPage } from "./faturalar";

export const Route = createFileRoute("/_authenticated/satis-faturalari")({
  head: () => ({
    meta: [
      { title: "Satış Faturaları | e-Fatura Portalı" },
      {
        name: "description",
        content: "Kesilen tüm e-arşiv, e-fatura ve satış faturalarınızı yönetin.",
      },
    ],
  }),
  component: InvoicesPage,
});
