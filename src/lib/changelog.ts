export type ChangeType = "Yeni" | "İyileştirme" | "Düzeltme" | "Kaldırıldı";

export type ChangelogEntry = {
  id: string;
  version: string;
  date: string; // ISO yyyy-mm-dd
  title: string;
  summary: string;
  changes: { type: ChangeType; text: string }[];
};

/**
 * Uygulama güncellemeleri. En yeni sürüm en üstte olacak şekilde ekleyin.
 */
export const CHANGELOG: ChangelogEntry[] = [
  {
    id: "2026-08-11",
    version: "1.2.0",
    date: "2026-08-11",
    title: "Güncelleme Notları ekranı",
    summary:
      "Yapılan tüm güncellemeleri tarihleriyle birlikte görebileceğiniz yeni bir ekran eklendi.",
    changes: [
      { type: "Yeni", text: "Sol menüye ve üst bara 'Güncellemeler' bölümü eklendi." },
      { type: "Yeni", text: "Her sürüm tıklandığında detayları ve yapılış tarihi görüntülenebiliyor." },
      { type: "İyileştirme", text: "Okunmamış güncellemeler için üst barda bildirim rozeti gösteriliyor." },
    ],
  },
  {
    id: "2026-08-10",
    version: "1.1.0",
    date: "2026-08-10",
    title: "Katalog düzeltmesi ve sadeleştirme",
    summary:
      "Fatura kesme ekranındaki ürün kataloğu listelenme sorunu giderildi, fotoğraftan fatura doldurma özelliği kaldırıldı.",
    changes: [
      { type: "Düzeltme", text: "'Katalogdan Seç' listesi artık ürünleri doğru şekilde gösteriyor." },
      { type: "İyileştirme", text: "Katalog için yükleniyor, hata ve boş liste durumları eklendi." },
      { type: "Kaldırıldı", text: "Fotoğraftan fatura doldurma özelliği tamamen kaldırıldı." },
    ],
  },
  {
    id: "2026-08-01",
    version: "1.0.0",
    date: "2026-08-01",
    title: "İlk sürüm",
    summary: "e-Fatura Portalı yayında: fatura kesme, arşiv, cari, ürün, POS ve Z raporu.",
    changes: [
      { type: "Yeni", text: "Fatura kesme, fatura arşivi ve PDF çıktısı." },
      { type: "Yeni", text: "Cari rehberi, ürün & hizmet kataloğu ve Excel içe aktarma." },
      { type: "Yeni", text: "POS satışları ve günlük Z raporu." },
      { type: "Yeni", text: "GİB / entegratör bağlantı ayarları." },
    ],
  },
];

export const LATEST_CHANGELOG_ID = CHANGELOG[0]?.id ?? "";
export const CHANGELOG_SEEN_KEY = "efatura:changelog-seen";

export function formatChangelogDate(date: string): string {
  return new Date(`${date}T00:00:00`).toLocaleDateString("tr-TR", {
    day: "2-digit",
    month: "long",
    year: "numeric",
  });
}
