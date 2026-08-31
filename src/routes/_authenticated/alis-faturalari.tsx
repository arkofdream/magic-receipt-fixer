import { createFileRoute } from "@tanstack/react-router";
import { InvoicesPage } from "./faturalar";

export const Route = createFileRoute("/_authenticated/alis-faturalari")({
  head: () => ({
    meta: [
      { title: "Alış Faturaları | e-Fatura Portalı" },
      {
        name: "description",
        content: "Gelen e-faturalar ve alış faturalarınızı yönetin.",
      },
    ],
  }),
  component: InvoicesPage,
});
