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
  value,
  onChange,
  disabled,
}: {
  value: AddressValue;
  onChange: (value: AddressValue) => void;
  disabled?: boolean;
}) {
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
    (p) => p.name.localeCompare(value.city, "tr", { sensitivity: "base" }) === 0,
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
      (d) => d.district.localeCompare(value.district, "tr", { sensitivity: "base" }) === 0,
    );
    return match?.neighborhoods ?? [];
  }, [districts, value.district]);

  if (provincesQuery.isError) {
    return (
      <>
        <TextField
          label="İl"
          value={value.city}
          onChange={(city) => onChange({ ...value, city })}
          disabled={disabled ?? false}
        />
        <TextField
          label="İlçe"
          value={value.district}
          onChange={(district) => onChange({ ...value, district })}
          disabled={disabled ?? false}
        />
        <TextField
          label="Mahalle / Köy"
          value={value.neighborhood}
          onChange={(neighborhood) => onChange({ ...value, neighborhood })}
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
          {...(value.city ? { value: value.city } : {})}
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
          {...(value.district ? { value: value.district } : {})}
          disabled={disabled || !selectedProvince || detailQuery.isLoading}
          onValueChange={(district) => onChange({ ...value, district, neighborhood: "" })}
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
          {...(value.neighborhood ? { value: value.neighborhood } : {})}
          disabled={disabled || neighborhoods.length === 0}
          onValueChange={(neighborhood) => onChange({ ...value, neighborhood })}
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
