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

/**
 * İl / İlçe / Mahalle seçimi. Adres servisi erişilemezse otomatik olarak
 * serbest metin girişine döner, böylece kayıt akışı hiçbir zaman bloke olmaz.
 */
export function AddressSelect({
  value = { city: "", district: "", neighborhood: "" },
  onChange,
  disabled,
}: {
  value?: AddressValue;
  onChange: (value: AddressValue) => void;
  disabled?: boolean;
}) {
  const safeValue = value || { city: "", district: "", neighborhood: "" };
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
    enabled: Boolean(selectedProvince),
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
      <>
        <TextField
          label="İl"
          value={safeValue.city}
          onChange={(city) => onChange({ ...safeValue, city })}
          disabled={disabled ?? false}
        />
        <TextField
          label="İlçe"
          value={safeValue.district}
          onChange={(district) => onChange({ ...safeValue, district })}
          disabled={disabled ?? false}
        />
        <TextField
          label="Mahalle / Köy"
          value={safeValue.neighborhood}
          onChange={(neighborhood) => onChange({ ...safeValue, neighborhood })}
          disabled={disabled ?? false}
        />
      </>
    );
  }

  return (
    <>
      <div className="space-y-2">
        <Label>İl</Label>
        <Select
          {...(safeValue.city ? { value: safeValue.city } : {})}
          disabled={disabled || provincesQuery.isLoading}
          onValueChange={(city) => onChange({ city, district: "", neighborhood: "" })}
        >
          <SelectTrigger>
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

      <div className="space-y-2">
        <Label>İlçe</Label>
        <Select
          {...(safeValue.district ? { value: safeValue.district } : {})}
          disabled={disabled || !selectedProvince || detailQuery.isLoading}
          onValueChange={(district) => onChange({ ...safeValue, district, neighborhood: "" })}
        >
          <SelectTrigger>
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

      <div className="space-y-2">
        <Label>Mahalle / Köy</Label>
        <Select
          {...(safeValue.neighborhood ? { value: safeValue.neighborhood } : {})}
          disabled={disabled || neighborhoods.length === 0}
          onValueChange={(neighborhood) => onChange({ ...safeValue, neighborhood })}
        >
          <SelectTrigger>
            <SelectValue
              placeholder={neighborhoods.length === 0 ? "Önce ilçe seçin" : "Mahalle seçin"}
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
    </>
  );
}

function TextField({
  label,
  value,
  onChange,
  disabled,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  disabled: boolean;
}) {
  return (
    <div className="space-y-2">
      <Label>{label}</Label>
      <Input
        value={value}
        disabled={disabled ?? false}
        onChange={(e) => onChange(e.target.value)}
      />
    </div>
  );
}
