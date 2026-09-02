# 4 Maddelik Düzeltme Planı

Notlardaki dört madde, mevcut arayüz ve muhasebe akışı bozulmadan uygulanacak.

## 1. Kullanıcıya özel gizli bilgiler (kendi ".env"i)

Bugün e-Fatura entegratör bilgileri kısmen kod içinde sabit (EDM test kullanıcı/şifre/URL), kısmen veritabanında tutuluyor. Hedef: her kullanıcının kendi entegratör kimlik bilgileri yalnızca veritabanında, şifrelenmiş olarak dursun.

- `efatura_connection_settings` tablosu zaten kullanıcı bazlı ve RLS korumalı; tüm gizli alanlar (şifre, API key) AES-256-GCM ile şifrelenmeye devam eder.
- Koddaki sabit test kullanıcı adı/şifre/servis adresi tamamen kaldırılır; kimlik bilgisi bulunamazsa işlem net bir hata ile durur ("Ayarlar > e-Fatura bağlantısı tanımlanmamış").
- Gizli değerler hiçbir API yanıtında, logda veya arayüzde geri döndürülmez; sadece "tanımlı / tanımlı değil" bilgisi gösterilir.

## 2. Tablette ürün/hizmet ekleme kayması

Kalem tablosu şu anda 768px'ten itibaren 850px minimum genişlikte açılıyor; tablet genişliğinde taşma ve kayma oluyor.

- Tablo görünümü daha geniş ekranlara (lg ve üzeri) alınır; tablet, halihazırda mobilde kullanılan kart düzenini kullanır (dokunmatik için daha rahat).
- Fatura sayfasının içerik konteyneri tablet kırılımında genişletilir, iç boşluklar küçültülür.
- Ürün seçici (katalogdan seç) alanı tablette tam genişlik ve düzgün hizalı olacak şekilde düzeltilir.
- iPad genişliklerinde (768 / 820 / 1024 px) kontrol edilir.

## 3. EDM entegratörünün koddan çıkarılması

EDM'e özel sabit bilgiler ve varsayılan seçim çakışmaya sebep oluyor.

- EDM'e ait sabit servis adresi, test kullanıcı adı ve şifresi koddan silinir.
- Entegratör listesinde EDM varsayılan/otomatik seçim olmaktan çıkarılır; entegratör yalnızca kullanıcının Ayarlar'da seçtiği ve bilgilerini girdiği kayıttan belirlenir.
- Gönderim akışının kendisi (fatura oluştur → onayla → XML → gönder → durum sorgula → mükerrer koruması) aynen korunur; sadece kimlik/adres bilgisinin kaynağı veritabanı olur.

Not: EDM protokol kodu tamamen silinirse şu an çalışan tek gerçek gönderim yolu da kalkar. Bu yüzden plan, "EDM'i sabit/varsayılan entegratör olmaktan ve kimlik bilgilerini koddan çıkarmak" şeklinde uygulanır. Protokol kodunun da tümüyle silinmesini istiyorsanız belirtin, o zaman gönderim geçici olarak devre dışı kalır.

## 4. Deneme süresi / ödeme yapılmazsa kilitleme

- Abonelik durumu `EXPIRED`, `SUSPENDED` veya `CANCELLED` ise; fatura kesme, e-Fatura gönderme, stok/cari/kasa/banka kayıt ekleme ve düzenleme gibi yazma işlemleri kilitlenir.
- Okuma ve dışa aktarma (geçmiş faturaları görme, PDF/Excel indirme) açık kalır — kullanıcı verisine erişimi engellenmez.
- Süresi dolmuş kullanıcıya üstte kalıcı bir uyarı şeridi ve "Aboneliği Yenile" yönlendirmesi gösterilir.
- Kilit yalnızca arayüzde değil, sunucu tarafında da uygulanır (abonelik kontrolü API/serverFn seviyesinde), böylece atlatılamaz.

## Teknik özet

- `src/lib/edm.ts`: sabit `DEFAULT_EDM_TEST_URL` ve varsayılan kullanıcı/şifre kaldırılır; ayarlar `efatura_connection_settings`'ten okunur.
- `src/lib/einvoice/provider.ts`: EDM'in otomatik varsayılan kaydı kaldırılır, seçim kullanıcı ayarına bağlanır.
- `src/routes/_authenticated/fatura-kes.tsx`: kalem tablosu `md:` → `lg:`, kart düzeni tablete uzatılır, konteyner genişliği ayarlanır.
- Abonelik kontrolü: `effectiveStatus` üzerinden ortak bir `requireActiveSubscription` yardımcı fonksiyonu; yazma uçlarında (fatura, cari, stok, kasa, banka) çağrılır; arayüzde uyarı şeridi + buton kilidi.
