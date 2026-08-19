-- Migration: Üyelik Sözleşmesi v1.2 (Aylık 6.000 TL & Taahhütsüz/Sıfır Cayma Bedeli İptal Politikası)

-- 1. Üyelik Sözleşmesini (membership_terms v1.2) ekle
INSERT INTO public.legal_documents (doc_type, version, title, content, is_published, requires_reacceptance, published_at)
VALUES (
  'membership_terms',
  'v1.2',
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

## 6. Abonelik Süresi, Aylık Ücret ve Gelecek Dönem Fiyatlandırma Politikası
6.1. Platformun aylık kullanım ve lisans yenileme bedeli, işbu sözleşmenin yürürlük tarihi itibarıyla **aylık 6.000 TL (Altı Bin Türk Lirası)**'dir. Abonelik süresi aylık periyotlar halinde işler.
6.2. **Fiyat Güncelleme ve Büyük Özellik Değişiklikleri:** Hizmet Sağlayıcı; ilerleyen dönemlerde sisteme eklenecek yeni modüller, yapay zekâ destekli otomasyonlar, gelişmiş entegrasyonlar, büyük çaplı özellik geliştirmeleri, sunucu ve altyapı maliyetleri ile ekonomik parametreler doğrultusunda aylık abonelik ve yenileme fiyatlarında artış yapma ve fiyat tarifesini güncelleme hakkını saklı tutar.
6.3. Fiyat güncellemeleri, peşin ödenmiş mevcut aktif ayı/dönemi etkilemez; Kullanıcı'nın bir sonraki aylık yenileme döneminden itibaren geçerli olur. Yenileme öncesinde güncel bedel Kullanıcı'ya bildirilir.

## 7. Abonelik Yenileme ve Hizmetin Sürdürülmesi
7.1. Kullanıcı'nın aboneliği, satın aldığı aylık dönem boyunca aktiftir. Yeni dönemin başlaması için ilgili döneme ait aylık yenileme bedelinin ödenmesi gerekir.
7.2. Yenileme bedelinin ödenmemesi durumunda hesabın ücretli modülleri askıya alınabilir; ancak kayıtlı geçmiş veriler silinmez ve saklama süresince muhafaza edilir.
7.3. Platformda otomatik habersiz kart çekimi (otomatik tahsilat) uygulanmamakta olup, yenileme işlemleri Kullanıcı'nın talebi ve ödeme onayı ile aylık olarak gerçekleştirilir.

## 8. Abonelik İptali, Cayma Hakkı ve Cayma Bedeli Politikası
8.1. **Taahhütsüz Hizmet:** Platform aboneliği herhangi bir asgari süre veya taahhüt şartı içermemektedir. Bu doğrultuda aboneliğin iptali halinde Kullanıcı'ya **herhangi bir cezai şart, taahhüt bozma bedeli veya cayma bedeli yansıtılmaz**.
8.2. **İptal Talebi ve Dönem Sonu Erişimi:** Kullanıcı, dilediği zaman herhangi bir gerekçe göstermeksizin ve cayma bedeli ödemeksizin aboneliğini iptal edebilir. İptal talebinde bulunulduğunda, bedeli peşin ödenmiş olan mevcut aylık kullanım döneminin sonuna kadar sisteme tam erişim devam eder; dönem sonunda ise ek bir bedel tahsil edilmeksizin abonelik sona erdirilir.
8.3. **Elektronik Hizmet ve İade Koşulları:** 6502 sayılı Tüketicinin Korunması Hakkında Kanun ve Mesafeli Sözleşmeler Yönetmeliği uyarınca; elektronik ortamda anında ifa edilen ve gayrimaddi hak niteliğindeki dijital yazılım hizmeti Kullanıcı'nın kullanımına derhal sunulduğundan, fiilen başlanmış ve kullanılan cari aylık döneme ait peşin ödenen abonelik bedeli iade edilmez. Ancak Kullanıcı'dan sonraki aylar için herhangi bir ek ücret veya cayma bedeli talep edilmez.
8.4. **Verilerin Korunması:** Abonelik iptali veya sona ermesi durumunda Kullanıcı'nın geçmiş dönemlere ait fatura, cari, ürün ve muhasebe kayıtları silinmez; mevzuat gereği yasal saklama süreleri boyunca güvenli veritabanlarında saklanmaya devam eder.

## 9. Hizmetin Askıya Alınması ve Fesih
Mevzuata, kamu düzenine veya işbu sözleşme hükümlerine aykırı kullanım, üçüncü kişilerin haklarının ihlali veya sistem güvenliğini tehdit eden girişimlerin tespiti halinde Hizmet Sağlayıcı hizmeti tek taraflı askıya alabilir veya sözleşmeyi feshedebilir.

## 10. Kullanıcı Tarafından Girilen Verilerin Mülkiyeti
Kullanıcı tarafından sisteme girilen cari, fatura, stok ve muhasebe kayıtlarının mülkiyeti Kullanıcı'ya aittir. Hizmet Sağlayıcı bu verileri yalnızca sözleşme kapsamındaki hizmetin ifası ve mevzuat gereksinimleri çerçevesinde işler.

## 11. Kişisel Verilerin Korunması (KVKK)
Taraflar, 6698 sayılı Kişisel Verilerin Korunması Kanunu'na tam uyum sağlayacağını kabul eder. Kişisel ve ticari veriler yüksek güvenlikli şifreleme ve sunucu standartlarında korunur.

## 12. Fikri Mülkiyet Hakları
Yazılımın tüm kod, tasarım, algoritma, görsel ve marka hakları münhasıran Hizmet Sağlayıcı'ya aittir. Tersine mühendislik yapılması, kaynak kodların kopyalanması veya üçüncü kişilere satılması kesinlikle yasaktır.

## 13. Yetkili Mahkeme ve Uygulanacak Hukuk
İşbu sözleşmeye Türkiye Cumhuriyeti hukuku uygulanır. Sözleşmenin uygulanmasından doğabilecek uyuşmazlıklarda Hizmet Sağlayıcı'nın yerleşim yeri mahkemeleri ve icra müdürlükleri yetkilidir.

## 14. Yürürlük
İşbu sözleşme, Kullanıcı'nın kayıt sırasında elektronik onay kutusunu işaretlemesiyle birlikte yürürlüğe girer.$doc$,
  true,
  false,
  now()
)
ON CONFLICT (doc_type, version) DO UPDATE SET
  title = EXCLUDED.title,
  content = EXCLUDED.content,
  is_published = true,
  published_at = now();
