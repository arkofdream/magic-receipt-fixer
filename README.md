# Magic Receipt — Ön Muhasebe & e-Fatura Uygulaması

Magic Receipt; küçük ve orta ölçekli işletmeler (KOBİ), e-ticaret satıcıları ve serbest meslek sahipleri için tasarlanmış modern, güvenli ve kurumsal düzeyde bir ön muhasebe ve e-Fatura/e-Arşiv yönetim sistemidir.

Bu repository hem **Web Uygulaması (TanStack Start / React 19 / Nitro)** hem de **Windows Masaüstü Uygulaması (Electron / NSIS Installer)** olarak eksiksiz çalışacak şekilde yapılandırılmıştır.

---

## 🚀 Temel Özellikler ve Modüller

1. **Dashboard & Finansal Özet**: Toplam ciro, KDV matrahı, hesaplanan KDV, taslak ve onaylı fatura sayıları, son kesilen faturalar tablosu.
2. **Cari Hesap Yönetimi**: Müşteri ve tedarikçi ayrımı, bakiye, borç/alacak takibi, ekstre görüntüleme & Excel çıktısı, cari virman işlemleri.
3. **Ürün & Hizmet Kataloğu**: Kod, barkod, kategori, alış/satış fiyatı, KDV oranı, iskonto ve kritik stok uyarıları.
4. **Stok ve Depo Yönetimi**: Çoklu depo tanımlama, stok giriş/çıkış, depolar arası transfer ve sayım hareketleri, kritik stok takibi.
5. **e-Fatura & e-Arşiv Düzenleme**:
   - Satış, İade, Tevkifatlı ve İstisna fatura türleri.
   - Çoklu para birimi (TRY, USD, EUR, GBP).
   - 2 haneli kuruş ve matrah yuvarlama güvenliği.
   - Standart Tevkifat oranları (2/10, 3/10, 5/10, 7/10, 9/10, Tam Tevkifat).
   - Türkiye VKN (10 hane) ve TCKN (11 hane) algoritmik kontrolü.
   - Otomatik ETTN ve seri/sıra fatura numarası üretimi.
6. **Fatura Arşivi & Tahsilat**: Fatura durumları (Taslak, İletildi, İptal), faturaya bağlı kısmi veya tam tahsilat kaydı, toplu ve tekil PDF indirme, güvenli fatura iptalinde stok ve cari kayıtlarını dengeleme.
7. **POS & Kasa Satışları**: Perakende/kasa satışlarının KDV oranlarına göre dökümü, elle veya Excel ile toplu satış girişi.
8. **Günlük Z Raporu**: Tarih bazlı ciro, KDV matrah dağılımı, iptal oranları ve tek tıkla resmi Z Raporu PDF çıktısı.
9. **Firma Profil Bilgileri**: Ayarlar ekranından firma unvanı, VKN/TCKN, vergi dairesi, adres, telefon ve e-posta bilgilerinin yönetimi.
10. **e-Fatura & Entegratör Mimarisi**:
    - GİB Portalı (Doğrudan) ve Özel Entegratörler (Uyumsoft, Foriba/Sovos, QNB e-Finans, Logo, Nes Bilgi, Digital Planet vb.).
    - Test / Canlı ortam desteği.
    - AES-256-GCM ile sunucu tarafında şifrelenen kimlik bilgileri (Client bundle'a asla sızdırılmaz).
    - Canlı API doğrulaması ve dürüst durum raporlaması.
11. **Excel İçe / Dışa Aktarma**: Türkçe ve uluslararası para formatlarını (`1.250,50 TL`, `1,250.50`) ayrıştırma, satır bazlı hata raporlama ve şablon indirme.
12. **Abonelik & Admin Paneli**: Deneme sürümü ve abonelik takibi, admin yetkilendirmesi, sözleşme versiyon yönetimi, KVKK ve işlem denetim günlükleri (Audit Log).
13. **Windows Masaüstü Uygulaması**: Electron + NSIS kurulum paketi (`MagicReceiptSetup.exe`) ile Windows PC'lerde yerel masaüstü deneyimi.

---

## 🛠️ Teknoloji Yığını

- **Frontend & SSR**: React 19, TanStack Start, TanStack Router, TanStack Query (React Query)
- **UI & Stil**: TailwindCSS v4, Radix UI Primitives, Lucide Icons, Sonner Toast
- **Backend / Sunucu**: Nitro Engine, Server Functions (`createServerFn`), Server Middleware
- **Veritabanı & Güvenlik**: Supabase (PostgreSQL), Row Level Security (RLS), AES-256-GCM Kimlik Şifreleme
- **PDF & Excel**: jsPDF, jspdf-autotable, RobotoTR Unicode Font, SheetJS (XLSX)
- **Masaüstü & Dağıtım**: Electron, electron-builder, NSIS x64 Installer

---

## ⚙️ Kurulum ve Çalıştırma

### Gereksinimler

- Node.js (v18.0+ veya v20.0+ önerilir)
- npm veya bun

### 1. Bağımlılıkları Yükleyin

```bash
npm install
```

### 2. Ortam Değişkenlerini Ayarlayın

`.env.example` dosyasını `.env` olarak kopyalayın ve Supabase bilgilerinizi girin:

```env
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_PUBLISHABLE_KEY=sb_publishable_your_key
SUPABASE_PROJECT_ID=your_project_id
SUPABASE_SERVICE_ROLE_KEY=your_service_role_key

VITE_SUPABASE_URL=https://your-project.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=sb_publishable_your_key
VITE_SUPABASE_PROJECT_ID=your_project_id

EFATURA_CREDENTIALS_KEY=your_32_byte_secret_key
```

### 3. Geliştirme Modunda Çalıştırma (Web)

```bash
npm run dev
```

Uygulama `http://localhost:5173` adresinde açılacaktır.

### 4. Production Build (Web)

```bash
npm run build
```

---

## 🖥️ Windows Masaüstü Uygulaması (Desktop App)

### Geliştirme Modunda Masaüstü Uygulaması

```bash
npm run desktop:dev
```

### Masaüstü Derlemesi

```bash
npm run desktop:build
```

### Windows Kurulum Dosyası (NSIS Installer) Üretme

```bash
npm run dist:win
```

Bu komut çalıştırıldığında çıktılar `release/` dizinine yerleştirilir:

- **Kurulum Dosyası (Installer)**: `release/MagicReceiptSetup.exe`
- **Taşınabilir / Paketlenmiş Klasör**: `release/win-unpacked/Magic Receipt.exe`

Installer özellikleri:

- Standart Windows kurulum sihirbazı (NSIS)
- Masaüstü ve Başlat Menüsü kısayolları
- Kolay Denetim Masası / Program Ekle-Kaldır desteği
- Multi-instance kilit koruması

---

## 🔒 Güvenlik Mimarisi

- **Multi-Tenant Veri İzolasyonu**: Her tablo (`customers`, `products`, `invoices`, `account_transactions`, `warehouses`, `stock_movements`, `pos_sales`, `efatura_connection_settings`, `subscriptions`) `user_id = auth.uid()` RLS politikası ile korunmaktadır.
- **Hizmet Rolü Anahtarı Koruması**: `SUPABASE_SERVICE_ROLE_KEY` yalnızca sunucu fonksiyonlarında kullanılır, renderer veya client bundle'a asla sızdırılmaz.
- **e-Fatura Kimlik Bilgileri**: GİB şifresi ve entegratör API anahtarları sunucu tarafında AES-256-GCM ile şifrelenir ve kullanıcı ekranında maskeli olarak korunur.
- **Electron Güvenlik Standartları**: `contextIsolation: true`, `nodeIntegration: false`, `sandbox: true`, harici URL'ler için güvenli sistem tarayıcısı yönlendirmesi.

---

## 📁 Orijinal Proje Yedek Koruması

Projenin ilk başlangıçtaki tüm dosyaları **`backup/original/`** dizininde değişmez olarak muhafaza edilmektedir.
