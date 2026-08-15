/**
 * Türkiye il / ilçe / mahalle verisi (sunucu tarafı).
 * Kaynak: https://turkiyeapi.dev — anahtar gerektirmez.
 * Sonuçlar sunucu belleğinde önbelleklenir; servis erişilemezse hata döner
 * ve arayüz serbest metin girişine geri düşer.
 */

export type ProvinceSummary = { id: number; name: string };
export type NeighborhoodList = { district: string; neighborhoods: string[] };
export type ProvinceDetail = { id: number; name: string; districts: NeighborhoodList[] };

const BASE = "https://turkiyeapi.dev/api/v1";

let provincesCache: ProvinceSummary[] | null = null;
const detailCache = new Map<number, ProvinceDetail>();

async function getJson<T>(url: string): Promise<T> {
  const response = await fetch(url, { headers: { accept: "application/json" } });
  if (!response.ok) throw new Error(`Adres servisi yanıt vermedi (${response.status}).`);
  return (await response.json()) as T;
}

export async function fetchProvinces(): Promise<ProvinceSummary[]> {
  if (provincesCache) return provincesCache;
  const json = await getJson<{ data: { id: number; name: string }[] }>(
    `${BASE}/provinces?fields=id,name`,
  );
  provincesCache = json.data.map((p) => ({ id: p.id, name: p.name }));
  return provincesCache;
}

export async function fetchProvinceDetail(provinceId: number): Promise<ProvinceDetail> {
  const cached = detailCache.get(provinceId);
  if (cached) return cached;
  const json = await getJson<{
    data: {
      id: number;
      name: string;
      districts: {
        name: string;
        neighborhoods?: { name: string }[];
        villages?: { name: string }[];
      }[];
    };
  }>(`${BASE}/provinces/${provinceId}?extend=true`);

  const detail: ProvinceDetail = {
    id: json.data.id,
    name: json.data.name,
    districts: (json.data.districts ?? [])
      .map((d) => ({
        district: d.name,
        neighborhoods: [...(d.neighborhoods ?? []), ...(d.villages ?? [])]
          .map((n) => n.name)
          .filter((v, i, arr) => arr.indexOf(v) === i)
          .sort((a, b) => a.localeCompare(b, "tr")),
      }))
      .sort((a, b) => a.district.localeCompare(b.district, "tr")),
  };
  detailCache.set(provinceId, detail);
  return detail;
}
