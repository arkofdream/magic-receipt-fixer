import { createServerFn } from "@tanstack/react-start";
import { createClient } from "@supabase/supabase-js";
import { z } from "zod";

import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import type { Database } from "@/integrations/supabase/types";

export type LegalDocType = "membership_terms" | "kvkk_notice";

export type LegalDocument = {
  id: string;
  docType: LegalDocType;
  version: string;
  title: string;
  content: string;
  publishedAt: string;
  requiresReacceptance: boolean;
};

export type ConsentRecord = {
  id: string;
  consentType: "membership_terms" | "kvkk_notice" | "marketing_consent";
  documentVersion: string;
  accepted: boolean;
  acceptedAt: string;
};

function publicClient() {
  return createClient<Database>(
    process.env["SUPABASE_URL"]!,
    process.env["SUPABASE_PUBLISHABLE_KEY"]!,
    { auth: { storage: undefined, persistSession: false, autoRefreshToken: false } },
  );
}

const docTypeSchema = z.object({
  docType: z.enum(["membership_terms", "kvkk_notice"]),
});

const FALLBACK_DOCUMENTS: Record<LegalDocType, LegalDocument> = {
  membership_terms: {
    id: "default-membership-terms",
    docType: "membership_terms",
    version: "v1.2",
    title: "ÜYELİK VE YAZILIM HİZMETİ KULLANIM SÖZLEŞMESİ",
    publishedAt: new Date().toISOString(),
    requiresReacceptance: false,
    content: `## 1. Taraflar
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
İşbu sözleşme, Kullanıcı'nın kayıt sırasında elektronik onay kutusunu işaretlemesiyle birlikte yürürlüğe girer.`,
  },
  kvkk_notice: {
    id: "default-kvkk-notice",
    docType: "kvkk_notice",
    version: "v1.0",
    title: "KVKK AYDINLATMA METNİ",
    publishedAt: new Date().toISOString(),
    requiresReacceptance: false,
    content: `## 1. Veri Sorumlusu
6698 sayılı Kişisel Verilerin Korunması Kanunu ("KVKK") uyarınca veri sorumlusu: [ŞİRKET UNVANI], Adres: [ADRES], Vergi No: [VERGİ NUMARASI], E-posta: [E-POSTA], Telefon: [TELEFON].

## 2. İşlenen Kişisel Veriler
Kimlik ve iletişim verileri (ad-soyad/unvan, vergi no/TCKN, e-posta, telefon, adres), müşteri işlem verileri (fatura, cari ve ürün kayıtları), işlem güvenliği verileri (giriş kayıtları, cihaz/tarayıcı bilgisi), abonelik ve lisans işlem verileri.

## 3. Kişisel Verilerin İşlenme Amaçları
Üyelik hesabının oluşturulması ve doğrulanması, firma profilinin tanımlanması, yazılım hizmetinin sunulması, e-fatura/e-arşiv süreçlerinin yürütülmesi, abonelik ve faturalandırma işlemleri, bilgi güvenliğinin sağlanması, mevzuattan doğan yasal yükümlülüklerin yerine getirilmesi.

## 4. İşleme Hukuki Sebepleri
Sözleşmenin kurulması veya ifası için gerekli olması, veri sorumlusunun hukuki yükümlülüğünü yerine getirmesi, bir hakkın tesisi veya korunması ve veri sorumlusunun meşru menfaati (KVKK m.5).

## 5. Kişisel Verilerin Aktarılması
Veriler; mevzuattan doğan yükümlülükler kapsamında yetkili kamu kurum ve kuruluşlarına (GİB vb.), hizmetin sunulması için gerekli olduğu ölçüde barındırma, altyapı ve entegrasyon hizmeti sağlayıcılarına aktarılabilir.

## 6. Saklama Süresi ve Güvenlik
Kişisel veriler, yasal saklama süreleri boyunca şifrelenmiş güvenli veritabanlarında saklanır; sürenin sonunda mevzuata uygun şekilde silinir, yok edilir veya anonim hale getirilir.

## 7. İlgili Kişinin Hakları
KVKK m.11 uyarınca; verilerinizin işlenip işlenmediğini öğrenme, bilgi talep etme, düzeltilmesini/silinmesini isteme ve mevzuatın tanıdığı tüm hakları [E-POSTA] adresinden talep edebilirsiniz.`,
  },
};

/** Public: latest published version of a legal document. */
export const getActiveLegalDocument = createServerFn({ method: "GET" })
  .inputValidator((data: unknown) => docTypeSchema.parse(data))
  .handler(async ({ data }): Promise<LegalDocument | null> => {
    try {
      const { data: rows, error } = await publicClient()
        .from("legal_documents")
        .select("id, doc_type, version, title, content, published_at, requires_reacceptance")
        .eq("doc_type", data.docType)
        .eq("is_published", true)
        .order("published_at", { ascending: false })
        .limit(1);

      if (error) {
        console.warn("Legal document read error, falling back to static version:", error.message);
        return FALLBACK_DOCUMENTS[data.docType] ?? null;
      }
      const row = rows?.[0];
      if (!row) return FALLBACK_DOCUMENTS[data.docType] ?? null;
      return {
        id: row.id,
        docType: row.doc_type as LegalDocType,
        version: row.version,
        title: row.title,
        content: row.content,
        publishedAt: row.published_at,
        requiresReacceptance: row.requires_reacceptance,
      };
    } catch {
      return FALLBACK_DOCUMENTS[data.docType] ?? null;
    }
  });

/** Public: current versions of both documents, used by the signup form. */
export const getCurrentLegalVersions = createServerFn({ method: "GET" }).handler(async () => {
  try {
    const { data, error } = await publicClient()
      .from("legal_documents")
      .select("doc_type, version, published_at")
      .eq("is_published", true)
      .order("published_at", { ascending: false });

    if (error) throw new Error(error.message);
    const pick = (t: LegalDocType) => data?.find((d) => d.doc_type === t)?.version ?? (t === "membership_terms" ? "v1.2" : "v1.0");
    return { membership_terms: pick("membership_terms"), kvkk_notice: pick("kvkk_notice") };
  } catch {
    return { membership_terms: "v1.2", kvkk_notice: "v1.0" };
  }
});

/**
 * Records the consents the user gave at signup. The user id always comes from the
 * validated bearer token, never from the client payload. Idempotent per version.
 */
export const recordSignupConsents = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: unknown) =>
    z
      .object({
        membershipTermsVersion: z.string().trim().min(1).max(20),
        kvkkVersion: z.string().trim().min(1).max(20),
        marketingConsent: z.boolean(),
        userAgent: z.string().max(400).default(""),
      })
      .parse(data),
  )
  .handler(async ({ data, context }) => {
    const { data: existing, error: readError } = await context.supabase
      .from("user_consents")
      .select("consent_type, document_version")
      .eq("user_id", context.userId);
    if (readError) throw new Error(readError.message);

    const has = (type: string, version: string) =>
      (existing ?? []).some((r) => r.consent_type === type && r.document_version === version);

    const rows: Database["public"]["Tables"]["user_consents"]["Insert"][] = [];
    if (!has("membership_terms", data.membershipTermsVersion)) {
      rows.push({
        user_id: context.userId,
        consent_type: "membership_terms",
        document_version: data.membershipTermsVersion,
        accepted: true,
        user_agent: data.userAgent,
      });
    }
    if (!has("kvkk_notice", data.kvkkVersion)) {
      rows.push({
        user_id: context.userId,
        consent_type: "kvkk_notice",
        document_version: data.kvkkVersion,
        accepted: true,
        user_agent: data.userAgent,
      });
    }
    if (!has("marketing_consent", data.membershipTermsVersion)) {
      rows.push({
        user_id: context.userId,
        consent_type: "marketing_consent",
        document_version: data.membershipTermsVersion,
        accepted: data.marketingConsent,
        user_agent: data.userAgent,
      });
    }

    if (rows.length > 0) {
      const { error } = await context.supabase.from("user_consents").insert(rows);
      if (error) throw new Error(error.message);
    }
    return { recorded: rows.length };
  });

/** The signed-in user's own consent history. */
export const getMyConsents = createServerFn({ method: "GET" })
  .middleware([requireSupabaseAuth])
  .handler(async ({ context }): Promise<ConsentRecord[]> => {
    const { data, error } = await context.supabase
      .from("user_consents")
      .select("id, consent_type, document_version, accepted, accepted_at")
      .eq("user_id", context.userId)
      .order("accepted_at", { ascending: false });
    if (error) throw new Error(error.message);
    return (data ?? []).map((r) => ({
      id: r.id,
      consentType: r.consent_type as ConsentRecord["consentType"],
      documentVersion: r.document_version,
      accepted: r.accepted,
      acceptedAt: r.accepted_at,
    }));
  });
