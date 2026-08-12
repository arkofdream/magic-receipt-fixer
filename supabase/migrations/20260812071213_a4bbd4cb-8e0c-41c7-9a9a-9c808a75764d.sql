-- ROLES
CREATE TYPE public.app_role AS ENUM ('admin', 'user');

CREATE TABLE public.user_roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  role public.app_role NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, role)
);
GRANT SELECT ON public.user_roles TO authenticated;
GRANT ALL ON public.user_roles TO service_role;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.has_role(_user_id uuid, _role public.app_role)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role)
$$;

CREATE POLICY "Users read own roles" ON public.user_roles
FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Admins read all roles" ON public.user_roles
FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));

-- LEGAL DOCUMENTS
CREATE TABLE public.legal_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  doc_type text NOT NULL CHECK (doc_type IN ('membership_terms', 'kvkk_notice')),
  version text NOT NULL,
  title text NOT NULL,
  content text NOT NULL,
  is_published boolean NOT NULL DEFAULT true,
  requires_reacceptance boolean NOT NULL DEFAULT false,
  published_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (doc_type, version)
);
GRANT SELECT ON public.legal_documents TO anon;
GRANT SELECT, INSERT ON public.legal_documents TO authenticated;
GRANT ALL ON public.legal_documents TO service_role;
ALTER TABLE public.legal_documents ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can read published legal documents" ON public.legal_documents
FOR SELECT TO anon, authenticated USING (is_published);
CREATE POLICY "Admins can read all legal documents" ON public.legal_documents
FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins can create legal document versions" ON public.legal_documents
FOR INSERT TO authenticated WITH CHECK (public.has_role(auth.uid(), 'admin'));

CREATE TRIGGER update_legal_documents_updated_at
BEFORE UPDATE ON public.legal_documents
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- USER CONSENTS (append-only)
CREATE TABLE public.user_consents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  consent_type text NOT NULL CHECK (consent_type IN ('membership_terms', 'kvkk_notice', 'marketing_consent')),
  document_version text NOT NULL DEFAULT '',
  accepted boolean NOT NULL DEFAULT false,
  accepted_at timestamptz NOT NULL DEFAULT now(),
  user_agent text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT ON public.user_consents TO authenticated;
GRANT ALL ON public.user_consents TO service_role;
ALTER TABLE public.user_consents ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users read own consents" ON public.user_consents
FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Admins read all consents" ON public.user_consents
FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Users insert own consents" ON public.user_consents
FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

-- SUBSCRIPTIONS
CREATE TABLE public.subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL UNIQUE,
  plan text NOT NULL DEFAULT 'TRIAL' CHECK (plan IN ('TRIAL', 'MONTHLY', 'YEARLY')),
  status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'UPCOMING_EXPIRY', 'EXPIRED', 'SUSPENDED', 'CANCELLED')),
  start_date date NOT NULL DEFAULT CURRENT_DATE,
  end_date date NOT NULL DEFAULT (CURRENT_DATE + INTERVAL '14 days'),
  renewal_price numeric,
  last_payment_date date,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.subscriptions TO authenticated;
GRANT ALL ON public.subscriptions TO service_role;
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users read own subscription" ON public.subscriptions
FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Admins read all subscriptions" ON public.subscriptions
FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins update subscriptions" ON public.subscriptions
FOR UPDATE TO authenticated USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

CREATE TRIGGER update_subscriptions_updated_at
BEFORE UPDATE ON public.subscriptions
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- ADMIN AUDIT LOG
CREATE TABLE public.admin_audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_user_id uuid NOT NULL,
  action text NOT NULL,
  target_user_id uuid,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.admin_audit_log TO authenticated;
GRANT ALL ON public.admin_audit_log TO service_role;
ALTER TABLE public.admin_audit_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins read audit log" ON public.admin_audit_log
FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));

-- new user gets a trial subscription
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  INSERT INTO public.profiles (id, email, company_title)
  VALUES (NEW.id, COALESCE(NEW.email, ''), COALESCE(NEW.raw_user_meta_data->>'company_title', ''))
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.subscriptions (user_id, plan, status, start_date, end_date)
  VALUES (NEW.id, 'TRIAL', 'ACTIVE', CURRENT_DATE, CURRENT_DATE + INTERVAL '14 days')
  ON CONFLICT (user_id) DO NOTHING;

  RETURN NEW;
END;
$function$;

-- seed v1.0 legal documents
INSERT INTO public.legal_documents (doc_type, version, title, content) VALUES
('membership_terms', 'v1.0', 'ÜYELİK VE YAZILIM HİZMETİ KULLANIM SÖZLEŞMESİ', $doc$## 1. Taraflar
İşbu sözleşme; bir tarafta [ŞİRKET UNVANI] (Adres: [ADRES], Vergi No: [VERGİ NUMARASI], E-posta: [E-POSTA], Telefon: [TELEFON]) ("Hizmet Sağlayıcı") ile diğer tarafta platforma üye olan gerçek veya tüzel kişi ("Kullanıcı") arasında elektronik ortamda kurulmuştur.

## 2. Sözleşmenin Konusu
Sözleşmenin konusu; Hizmet Sağlayıcı tarafından sunulan web tabanlı e-fatura/e-arşiv hazırlama ve ön muhasebe yazılım hizmetinden Kullanıcı'nın abonelik karşılığında yararlanmasına ilişkin tarafların hak ve yükümlülüklerinin belirlenmesidir.

## 3. Üyelik ve Kullanıcı Hesabı
Kullanıcı, kayıt sırasında verdiği bilgilerin doğru ve güncel olduğunu beyan eder. Hesap bilgilerinin ve şifrenin gizliliğinden Kullanıcı sorumludur. Hesap üzerinden yapılan işlemler Kullanıcı tarafından yapılmış sayılır. Yetkisiz erişim şüphesi halinde Kullanıcı, Hizmet Sağlayıcı'yı gecikmeksizin bilgilendirir.

## 4. Yazılım Hizmeti
Hizmet, "hizmet olarak yazılım" (SaaS) modeliyle sunulur. Kullanıcı'ya yazılımın mülkiyeti değil, abonelik süresi boyunca kullanım hakkı tanınır. Hizmet Sağlayıcı, yazılımın işlevlerini geliştirebilir, güncelleyebilir; esaslı değişiklikler makul süre önce duyurulur.

## 5. E-Fatura, GİB ve Özel Entegratör İşlemleri
5.1. Hizmet Sağlayıcı, yalnızca kendi platformunun teknik işleyişinden ve platform kaynaklı arızaların giderilmesinden sorumludur.
5.2. Gelir İdaresi Başkanlığı (GİB) sistemlerinin erişilemez olması, bakımda bulunması veya GİB kaynaklı teknik sorunlar nedeniyle belgelerin iletilememesi hallerinde, bu durum Hizmet Sağlayıcı'nın kontrolü dışındadır. Hizmet Sağlayıcı bu hallerde durumu Kullanıcı'ya bildirmek ve kendi tarafındaki gerekli teknik önlemleri almakla yükümlüdür.
5.3. Kullanıcı'nın tercih ettiği özel entegratör sistemlerinden kaynaklanan erişim veya işlem problemlerinde de aynı esas geçerlidir; Hizmet Sağlayıcı entegratör hizmetinin sağlayıcısı değildir.
5.4. Kullanıcı; firma bilgilerinin, mükellefiyet ve yetkilendirme kayıtlarının, mali mühür/e-imza araçlarının ve entegrasyon hesap bilgilerinin doğruluğundan ve geçerliliğinden sorumludur.
5.5. Bu madde, Hizmet Sağlayıcı'nın kendi kusurundan doğan sorumluluğunu ortadan kaldıracak şekilde yorumlanamaz.

## 6. Abonelik Süresi ve Ücretlendirme
Abonelik, Kullanıcı'nın seçtiği aylık veya yıllık dönem için geçerlidir. Güncel abonelik ücretleri ve yenileme ücreti, satın alma/ödeme ekranında ve Kullanıcı'nın hesabındaki "Abonelik" bölümünde gösterilir. Kullanıcı'ya önceden bildirilmemiş bir ücret uygulanmaz.

## 7. Abonelik Yenileme ve Yenileme Ücretinin Ödenmemesi
Kullanıcı'nın aboneliği, satın aldığı abonelik dönemi boyunca geçerlidir. Yeni abonelik döneminin başlaması için ilgili yenileme ücretinin ödenmesi gerekir. Yenileme ücretinin ödenmemesi halinde yeni abonelik dönemi başlatılmaz ve Hizmet Sağlayıcı, Kullanıcı'ya bildirilen abonelik koşullarına ve yürürlükteki mevzuata uygun olarak hesabın ücretli özelliklerine erişimi askıya alabilir veya hizmeti sonlandırabilir. Kullanıcı'ya abonelik bitiş tarihi ve yenileme koşulları hakkında makul süre içerisinde bilgilendirme yapılır. Platformda otomatik ödeme (otomatik tahsilat) yöntemi bulunmamaktadır; yenileme, ödemenin yapılması ve doğrulanması üzerine gerçekleştirilir.

## 8. Hizmetin Askıya Alınması ve Hesabın Kapatılması
Hizmet Sağlayıcı; ödenmiş ve devam eden abonelik dönemini haklı bir sebep olmaksızın sona erdirmez. Mevzuata veya işbu sözleşmeye aykırı kullanım, üçüncü kişilerin haklarının ihlali veya sistem güvenliğini tehdit eden kullanım hallerinde, Kullanıcı bilgilendirilerek hizmet askıya alınabilir veya sözleşme feshedilebilir.

## 9. Kullanıcının Yükümlülükleri
Kullanıcı; hizmeti mevzuata uygun kullanmayı, doğru ve güncel bilgi girmeyi, hesabını üçüncü kişilerle paylaşmamayı, yazılımın güvenliğini tehlikeye atacak işlemlerden kaçınmayı kabul eder.

## 10. Kullanıcı Tarafından Girilen Veriler
Kullanıcı tarafından girilen fatura, cari, ürün ve benzeri verilerin doğruluğu ve mevzuata uygunluğu Kullanıcı'nın sorumluluğundadır. Bu veriler üzerindeki haklar Kullanıcı'ya aittir; Hizmet Sağlayıcı bu verileri yalnızca hizmetin sunulması amacıyla işler.

## 11. Kişisel Verilerin Korunması
Kişisel veriler, 6698 sayılı Kişisel Verilerin Korunması Kanunu ve ilgili mevzuata uygun olarak işlenir. Ayrıntılı bilgi KVKK Aydınlatma Metni'nde yer alır. Aydınlatma metni, açık rıza anlamına gelmez; açık rıza gerektiren işlemler için ayrıca onay alınır.

## 12. Gizlilik ve Bilgi Güvenliği
Hizmet Sağlayıcı, Kullanıcı verilerinin güvenliği için uygun teknik ve idari tedbirleri alır; verileri hizmetin sunulması ve hukuki yükümlülükler dışında üçüncü kişilerle paylaşmaz.

## 13. Fikri Mülkiyet Hakları
Yazılım, arayüz, tasarım, kaynak kod ve marka unsurlarına ilişkin haklar Hizmet Sağlayıcı'ya veya lisans verenlerine aittir. Kullanıcı'ya devredilemez, münhasır olmayan ve abonelik süresiyle sınırlı bir kullanım hakkı tanınır.

## 14. Hizmet Kesintileri ve Bakım
Planlı bakım çalışmaları mümkün olduğunca önceden duyurulur. Beklenmeyen kesintilerde Hizmet Sağlayıcı, hizmeti makul en kısa sürede yeniden erişilebilir kılmak için gerekli çabayı gösterir.

## 15. Sözleşmenin Feshi
Taraflar, yürürlükteki mevzuattan doğan hakları saklı kalmak kaydıyla sözleşmeyi feshedebilir. Kullanıcı, hesabını kapatarak aboneliğini yenilememeyi tercih edebilir. Tüketici mevzuatından doğan cayma ve diğer zorunlu haklar saklıdır.

## 16. Veri Saklama ve Hesap Sonlandırma
Abonelik sona erdiğinde Kullanıcı verileri derhal ve geri döndürülemez şekilde silinmez. Veriler, mevzuattan doğan saklama yükümlülükleri ve Hizmet Sağlayıcı'nın veri saklama politikası çerçevesinde belirlenen süre boyunca saklanır; sürenin sonunda mevzuata uygun şekilde silinir, yok edilir veya anonim hale getirilir. Kullanıcı, saklama süresi içinde verilerinin silinmesini talep edebilir; mevzuatın saklamayı zorunlu kıldığı veriler bu talebin kapsamı dışındadır.

## 17. Sözleşme Değişiklikleri
Hizmet Sağlayıcı, sözleşmede değişiklik yapabilir. Değişiklikler yeni versiyon numarasıyla yayımlanır; önceki versiyonlar ve Kullanıcı'nın onay kayıtları saklanır. Esaslı değişikliklerde Kullanıcı'dan yeniden onay alınabilir.

## 18. Uygulanacak Hukuk ve Yetkili Merciler
Sözleşmeye Türkiye Cumhuriyeti hukuku uygulanır. Uyuşmazlıklarda [ŞİRKET UNVANI]'nın bulunduğu yer mahkemeleri ve icra daireleri yetkilidir. Tüketici sıfatını haiz Kullanıcılar bakımından, tüketici hakem heyetleri ve tüketici mahkemelerinin yetkisine ilişkin mevzuat hükümleri saklıdır.

## 19. Yürürlük
İşbu sözleşme, Kullanıcı'nın kayıt sırasında elektronik ortamda onay vermesiyle yürürlüğe girer.$doc$),
('kvkk_notice', 'v1.0', 'KVKK AYDINLATMA METNİ', $doc$## 1. Veri Sorumlusu
6698 sayılı Kişisel Verilerin Korunması Kanunu ("KVKK") uyarınca veri sorumlusu: [ŞİRKET UNVANI], Adres: [ADRES], Vergi No: [VERGİ NUMARASI], E-posta: [E-POSTA], Telefon: [TELEFON].

## 2. İşlenen Kişisel Veriler
Kimlik ve iletişim verileri (ad-soyad/unvan, e-posta, telefon), müşteri işlem verileri (fatura, cari ve ürün kayıtları), işlem güvenliği verileri (giriş kayıtları, cihaz/tarayıcı bilgisi), abonelik ve ödeme sürecine ilişkin veriler.

## 3. Kişisel Verilerin İşlenme Amaçları
Üyelik hesabının oluşturulması ve yönetilmesi, yazılım hizmetinin sunulması, e-fatura/e-arşiv süreçlerinin yürütülmesi, abonelik ve faturalandırma işlemleri, destek taleplerinin karşılanması, bilgi güvenliğinin sağlanması, hukuki yükümlülüklerin yerine getirilmesi.

## 4. İşleme Hukuki Sebepleri
Sözleşmenin kurulması veya ifası için gerekli olması, hukuki yükümlülüğün yerine getirilmesi, bir hakkın tesisi/kullanılması/korunması, veri sorumlusunun meşru menfaati ve gerektiği hallerde açık rıza (KVKK m.5).

## 5. Kişisel Verilerin Aktarılması
Veriler; mevzuattan doğan yükümlülükler kapsamında yetkili kamu kurum ve kuruluşlarına, hizmetin sunulması için gerekli olduğu ölçüde barındırma, altyapı ve entegrasyon hizmeti sağlayıcılarına, KVKK m.8 ve m.9'daki şartlara uygun olarak aktarılabilir.

## 6. Saklama Süresi
Kişisel veriler, işleme amacının gerektirdiği süre ile mevzuatta öngörülen saklama süreleri boyunca saklanır; sürenin sonunda silinir, yok edilir veya anonim hale getirilir.

## 7. Veri Güvenliği
Veri sorumlusu, kişisel verilerin hukuka aykırı işlenmesini ve erişilmesini önlemek amacıyla uygun teknik ve idari tedbirleri alır.

## 8. İlgili Kişinin Hakları
KVKK m.11 uyarınca; kişisel verilerinizin işlenip işlenmediğini öğrenme, bilgi talep etme, işleme amacını öğrenme, aktarıldığı kişileri bilme, düzeltilmesini/silinmesini isteme, işlemenin sınırlandırılmasını talep etme, otomatik sistemlerle analiz sonucu aleyhinize bir sonuç doğmasına itiraz etme ve zarara uğramanız halinde giderim talep etme haklarına sahipsiniz.

## 9. Başvuru Yöntemi
Başvurularınızı [E-POSTA] adresine veya [ADRES] adresine, Veri Sorumlusuna Başvuru Usul ve Esasları Hakkında Tebliğ'de belirtilen usullere uygun şekilde iletebilirsiniz.

Bu metin aydınlatma yükümlülüğünün yerine getirilmesi amacıyla hazırlanmıştır ve tek başına açık rıza beyanı niteliği taşımaz.$doc$);