import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { useMemo } from "react";

import { getProvinceDetail, listProvinces } from "@/lib/address.functions";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";

export type AddressValue = { city: string; district: string; neighborhood: string };

export type AddressSelectProps = {
  value?: AddressValue;
  city?: string;
  district?: string;
  neighborhood?: string;
  onChange: (value: AddressValue) => void;
  disabled?: boolean;
};

/**
 * İl / İlçe / Mahalle seçimi bileşeni.
 * Hem nesne formatını (value={{ city, district, neighborhood }})
 * hem de tekil prop formatını (city={...} district={...} neighborhood={...}) destekler.
 * İl değiştiğinde eski ilçe ve mahalleyi otomatik sıfırlar ve yeni ilçeleri yükler.
 */
export function AddressSelect({
  value,
  city,
  district,
  neighborhood,
  onChange,
  disabled,
}: AddressSelectProps) {
  const safeCity = city !== undefined ? city : value?.city || "";
  const safeDistrict = district !== undefined ? district : value?.district || "";
  const safeNeighborhood = neighborhood !== undefined ? neighborhood : value?.neighborhood || "";

  const safeValue: AddressValue = {
    city: safeCity,
    district: safeDistrict,
    neighborhood: safeNeighborhood,
  };

  const fetchProvinces = useServerFn(listProvinces);
  const fetchDetail = useServerFn(getProvinceDetail);

  const provincesQuery = useQuery({
    queryKey: ["address", "provinces"],
    queryFn: () => fetchProvinces(),
    staleTime: 1000 * 60 * 60,
    retry: 1,
  });

  const provinces = provincesQuery.data ?? [];
  const selectedProvince = provinces.find(
    (p) => p.name.localeCompare(safeValue.city || "", "tr", { sensitivity: "base" }) === 0,
  );

  const detailQuery = useQuery({
    queryKey: ["address", "province", selectedProvince?.id],
    queryFn: () => fetchDetail({ data: { provinceId: selectedProvince!.id } }),
    enabled: Boolean(selectedProvince?.id),
    staleTime: 1000 * 60 * 60,
    retry: 1,
  });

  const districts = useMemo(() => detailQuery.data?.districts ?? [], [detailQuery.data?.districts]);
  const neighborhoods = useMemo(() => {
    const match = districts.find(
      (d) => d.district.localeCompare(safeValue.district || "", "tr", { sensitivity: "base" }) === 0,
    );
    return match?.neighborhoods ?? [];
  }, [districts, safeValue.district]);

  if (provincesQuery.isError) {
    return (
      <div className="grid gap-3 sm:grid-cols-3">
        <div className="space-y-1.5">
          <Label>İl</Label>
          <Input
            value={safeValue.city}
            onChange={(e) => onChange({ ...safeValue, city: e.target.value })}
            placeholder="İl girin"
            disabled={disabled ?? false}
          />
        </div>
        <div className="space-y-1.5">
          <Label>İlçe</Label>
          <Input
            value={safeValue.district}
            onChange={(e) => onChange({ ...safeValue, district: e.target.value })}
            placeholder="İlçe girin"
            disabled={disabled ?? false}
          />
        </div>
        <div className="space-y-1.5">
          <Label>Mahalle / Köy</Label>
          <Input
            value={safeValue.neighborhood}
            onChange={(e) => onChange({ ...safeValue, neighborhood: e.target.value })}
            placeholder="Mahalle girin"
            disabled={disabled ?? false}
          />
        </div>
      </div>
    );
  }

  return (
    <div className="grid gap-3 sm:grid-cols-3">
      <div className="space-y-1.5">
        <Label>İl</Label>
        <Select
          value={safeValue.city || undefined}
          disabled={disabled || provincesQuery.isLoading}
          onValueChange={(newCity) => onChange({ city: newCity, district: "", neighborhood: "" })}
        >
          <SelectTrigger className="bg-background">
            <SelectValue placeholder={provincesQuery.isLoading ? "Yükleniyor…" : "İl seçin"} />
          </SelectTrigger>
          <SelectContent className="max-h-72">
            {provinces.map((p) => (
              <SelectItem key={p.id} value={p.name}>
                {p.name}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      <div className="space-y-1.5">
        <Label>İlçe</Label>
        <Select
          value={safeValue.district || undefined}
          disabled={disabled || !selectedProvince || detailQuery.isLoading}
          onValueChange={(newDistrict) =>
            onChange({ ...safeValue, district: newDistrict, neighborhood: "" })
          }
        >
          <SelectTrigger className="bg-background">
            <SelectValue
              placeholder={
                !selectedProvince
                  ? "Önce il seçin"
                  : detailQuery.isLoading
                    ? "Yükleniyor…"
                    : "İlçe seçin"
              }
            />
          </SelectTrigger>
          <SelectContent className="max-h-72">
            {districts.map((d) => (
              <SelectItem key={d.district} value={d.district}>
                {d.district}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      <div className="space-y-1.5">
        <Label>Mahalle / Köy</Label>
        <Select
          value={safeValue.neighborhood || undefined}
          disabled={disabled || !safeValue.district || neighborhoods.length === 0}
          onValueChange={(newNeighborhood) =>
            onChange({ ...safeValue, neighborhood: newNeighborhood })
          }
        >
          <SelectTrigger className="bg-background">
            <SelectValue
              placeholder={
                !safeValue.district
                  ? "Önce ilçe seçin"
                  : neighborhoods.length === 0
                    ? "Mahalle seçin (opsiyonel)"
                    : "Mahalle seçin"
              }
            />
          </SelectTrigger>
          <SelectContent className="max-h-72">
            {neighborhoods.map((n) => (
              <SelectItem key={n} value={n}>
                {n}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
    </div>
  );
}
