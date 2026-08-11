import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";

export type { ProvinceSummary, ProvinceDetail, NeighborhoodList } from "@/lib/address/address.server";

export const listProvinces = createServerFn({ method: "GET" }).handler(async () => {
  const { fetchProvinces } = await import("@/lib/address/address.server");
  return fetchProvinces();
});

export const getProvinceDetail = createServerFn({ method: "GET" })
  .inputValidator((data: unknown) => z.object({ provinceId: z.number().int().positive() }).parse(data))
  .handler(async ({ data }) => {
    const { fetchProvinceDetail } = await import("@/lib/address/address.server");
    return fetchProvinceDetail(data.provinceId);
  });
