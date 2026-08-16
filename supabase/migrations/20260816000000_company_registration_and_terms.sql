-- Migration: Şirket Bilgileri ile Kayıt ve Güncel Üyelik Sözleşmesi (6.000 TL Yıllık Ücret & Fiyat Politikası)

-- 1. handle_new_user trigger fonksiyonunu firma bilgilerini profiles tablosuna tam yazacak şekilde güncelle
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  INSERT INTO public.profiles (
    id,
    email,
    company_title,
    vkn_tckn,
    tax_office,
    address,
    phone
  )
  VALUES (
    NEW.id,
    COALESCE(NEW.email, ''),
    COALESCE(NEW.raw_user_meta_data->>'company_title', ''),
    COALESCE(NEW.raw_user_meta_data->>'vkn_tckn', ''),
    COALESCE(NEW.raw_user_meta_data->>'tax_office', ''),
    COALESCE(NEW.raw_user_meta_data->>'address', ''),
    COALESCE(NEW.raw_user_meta_data->>'phone', '')
  )
  ON CONFLICT (id) DO UPDATE SET
    company_title = CASE WHEN EXCLUDED.company_title <> '' THEN EXCLUDED.company_title ELSE public.profiles.company_title END,
    vkn_tckn = CASE WHEN EXCLUDED.vkn_tckn <> '' THEN EXCLUDED.vkn_tckn ELSE public.profiles.vkn_tckn END,
    tax_office = CASE WHEN EXCLUDED.tax_office <> '' THEN EXCLUDED.tax_office ELSE public.profiles.tax_office END,
    address = CASE WHEN EXCLUDED.address <> '' THEN EXCLUDED.address ELSE public.profiles.address END,
    phone = CASE WHEN EXCLUDED.phone <> '' THEN EXCLUDED.phone ELSE public.profiles.phone END,
    email = CASE WHEN EXCLUDED.email <> '' THEN EXCLUDED.email ELSE public.profiles.email END,
    updated_at = now();

  INSERT INTO public.subscriptions (
    user_id,
    plan,
    status,
    start_date,
    end_date,
    renewal_price
  )
  VALUES (
    NEW.id,
    'TRIAL',
    'ACTIVE',
    CURRENT_DATE,
    CURRENT_DATE + INTERVAL '14 days',
    6000
  )
  ON CONFLICT (user_id) DO NOTHING;

  RETURN NEW;
END;
$function$;

-- 2. Üyelik Sözleşmesini (membership_terms v1.1) ekle / güncelle (6.000 TL Yıllık & Yeni Özellikler Fiyat Güncelleme Şartı)
INSERT INTO public.legal_documents (doc_type, version, title, content, is_published, requires_reacceptance, published_at)
VALUES (
  'membership_terms',
  'v1.1',
  'ÜYELİK VE YAZILIM HİZMETİ KULLANIM SÖZLEŞMESİ',
  $doc$## 1. Taraflar
İşbu sözleşme; bir tarafta [ŞİRKET UNVANI] (Adres: [ADRES], Vergi No: [VERGİ NUMARASI], E-posta: [E-POSTA], Telefon: [TELEFON]) ("Hizmet Sağlayıcı") ile diğer tarafta platforma kurumsal veya şahıs şirketi olarak gerçek/tüzel kişi firma bilgileriyle kayıt olan kullanıcı ("Kullanıcı") arasında elektronik ortamda akdedilmiştir.

## 2. Sözleşmenin Konusu
Sözleşmenin konusu; Hizmet Sağlayıcı tarafından sunulan bulut ve web tabanlı e-fatura/e-arşiv hazırlama, cari hesap yönetimi, stok takibi ve ön muhasebe yazılım hizmetinden Kullanıcı'nın abonelik karşılığında yararlanmasına ilişkin tarafların hak ve yükümlülüklerinin belirlenmesidir.

## 3. Üyelik, Doğrulanabilir Firma Bilgileri ve Kullanıcı Hesabı
3.1. Kullanıcı, kayıt esnasında sisteme girdiği firma unvanı, Vergi Kimlik Numarası (VKN) / T.C. Kimlik Numarası (TCKN), vergi dairesi, adres ve telefon bilgilerinin resmi kayıtlara uygun, gerçek ve eksiksiz olduğunu beyan ve taahhüt eder.
3.2. Hizmet Sağlayıcı, sahte, geçersiz veya algoritma doğrulamasını karşılamayan mükellefiyet bilgileriyle yapılan kayıtları kabul etmeme, askıya alma veya sonlandırma hakkına sahiptir.
3.3. Kayıt aşamasında bildirilen firma bilgileri, Kullanıcı'nın sistemdeki firma profili ve e-fatura düzenleme ayarlarına otomatik olarak işlenir.
3.4. Hesap bilgilerinin ve şifrenin gizliliğinden Kullanıcı sorumludur. Hesap üzerinden gerçekleştirilen tüm işlemler Kullanıcı adına yapılmış sayılır.

## 4. Yazılım Hizmeti ve Kapsamı
Hizmet, "hizmet olarak yazılım" (SaaS) modeliyle sunulmaktadır. Kullanıcı'ya yazılımın mülkiyeti değil, abonelik süresi boyunca kullanım hakkı (lisansı) tanınır.

## 5. E-Fatura, GİB ve Özel Entegratör İşlemleri
5.1. Hizmet Sağlayıcı, platformun teknik işleyişinden ve yazılım kaynaklı teknik arızaların giderilmesinden sorumludur.
5.2. Gelir İdaresi Başkanlığı (GİB) sistemlerinin erişilemez olması, bakımda bulunması veya GİB kaynaklı teknik sorunlar nedeniyle belgelerin iletilememesi Hizmet Sağlayıcı'nın kontrolü dışındadır.
5.3. Kullanıcı'nın tercih ettiği özel entegratör sistemlerinden veya entegrasyon şifrelerinden kaynaklanan aksaklıklarda Hizmet Sağlayıcı sorumlu tutulamaz.
5.4. Düzenlenen fatura ve resmi evrakların içeriğinden, vergi oranlarından ve yasal bildirim sürelerinden münhasıran Kullanıcı sorumludur.

## 6. Abonelik Süresi, Yıllık Ücret ve Gelecek Dönem Fiyatlandırma Politikası
6.1. Platformun yıllık kullanım ve lisans yenileme bedeli, işbu sözleşmenin yürürlük tarihi itibarıyla **yıllık 6.000 TL (Altı Bin Türk Lirası)**'dir.
6.2. **Fiyat Güncelleme ve Büyük Özellik Değişiklikleri:** Hizmet Sağlayıcı; ilerleyen yıllarda ve dönemlerde sisteme eklenecek yeni modüller, yapay zekâ destekli otomasyonlar, gelişmiş entegrasyonlar, büyük çaplı özellik geliştirmeleri, sunucu ve altyapı maliyetleri ile ekonomik parametreler doğrultusunda yıllık abonelik ve yenileme fiyatlarında artış yapma ve fiyat tarifesini güncelleme hakkını saklı tutar.
6.3. Fiyat güncellemeleri, mevcut aktif dönemi etkilemez; Kullanıcı'nın bir sonraki abonelik yenileme döneminden itibaren geçerli olur. Yenileme öncesinde güncel bedel Kullanıcı'ya bildirilir.

## 7. Abonelik Yenileme ve Hizmetin Sürdürülmesi
7.1. Kullanıcı'nın aboneliği, satın aldığı dönem boyunca aktiftir. Yeni dönemin başlaması için ilgili döneme ait yenileme bedelinin ödenmesi gerekir.
7.2. Yenileme bedelinin ödenmemesi durumunda hesabın ücretli modülleri askıya alınabilir; ancak kayıtlı geçmiş veriler silinmez ve saklama süresince muhafaza edilir.
7.3. Platformda otomatik habersiz kart çekimi (otomatik tahsilat) uygulanmamakta olup, yenileme işlemleri Kullanıcı'nın talebi ve ödeme onayı ile gerçekleştirilir.

## 8. Hizmetin Askıya Alınması ve Fesih
Mevzuata, kamu düzenine veya işbu sözleşme hükümlerine aykırı kullanım, üçüncü kişilerin haklarının ihlali veya sistem güvenliğini tehdit eden girişimlerin tespiti halinde Hizmet Sağlayıcı hizmeti tek taraflı askıya alabilir veya sözleşmeyi feshedebilir.

## 9. Kullanıcı Tarafından Girilen Verilerin Mülkiyeti
Kullanıcı tarafından sisteme girilen cari, fatura, stok ve muhasebe kayıtlarının mülkiyeti Kullanıcı'ya aittir. Hizmet Sağlayıcı bu verileri yalnızca sözleşme kapsamındaki hizmetin ifası ve mevzuat gereksinimleri çerçevesinde işler.

## 10. Kişisel Verilerin Korunması (KVKK)
Taraflar, 6698 sayılı Kişisel Verilerin Korunması Kanunu'na tam uyum sağlayacağını kabul eder. Kişisel ve ticari veriler yüksek güvenlikli şifreleme ve sunucu standartlarında korunur.

## 11. Fikri Mülkiyet Hakları
Yazılımın tüm kod, tasarım, algoritma, görsel ve marka hakları münhasıran Hizmet Sağlayıcı'ya aittir. Tersine mühendislik yapılması, kaynak kodların kopyalanması veya üçüncü kişilere satılması kesinlikle yasaktır.

## 12. Yetkili Mahkeme ve Uygulanacak Hukuk
İşbu sözleşmeye Türkiye Cumhuriyeti hukuku uygulanır. Sözleşmenin uygulanmasından doğabilecek uyuşmazlıklarda Hizmet Sağlayıcı'nın yerleşim yeri mahkemeleri ve icra müdürlükleri yetkilidir.

## 13. Yürürlük
İşbu sözleşme, Kullanıcı'nın kayıt sırasında elektronik onay kutusunu işaretlemesiyle birlikte yürürlüğe girer.$doc$,
  true,
  true,
  now()
)
ON CONFLICT (doc_type, version) DO UPDATE SET
  title = EXCLUDED.title,
  content = EXCLUDED.content,
  is_published = true,
  published_at = now();
