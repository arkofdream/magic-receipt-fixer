/**
 * e-Fatura Entegratör Yapılandırma ve Kimlik Doğrulama Tanımları.
 * Her entegratör için gerekli olan alanlar ve authentication yöntemleri dinamik olarak tanımlanır.
 */

export type AuthType = "API_KEY" | "USERNAME_PASSWORD" | "BASIC_AUTH" | "BEARER_TOKEN" | "CONFIGURABLE";

export type IntegratorConfig = {
  name: string;
  authType: AuthType;
  requiresUsername: boolean;
  requiresApiKey: boolean;
  baseUrlLabel: string;
  baseUrlPlaceholder: string;
  usernameLabel?: string;
  usernamePlaceholder?: string;
  apiKeyLabel: string;
  apiKeyPlaceholder: string;
};

export const INTEGRATORS_CONFIG: Record<string, IntegratorConfig> = {
  "Nes Bilgi": {
    name: "Nes Bilgi",
    authType: "API_KEY",
    requiresUsername: false,
    requiresApiKey: true,
    baseUrlLabel: "NES API Servis Adresi (URL)",
    baseUrlPlaceholder: "https://api.nes.com.tr",
    apiKeyLabel: "NES API Key / Secret",
    apiKeyPlaceholder: "NES API anahtarını girin",
  },
  "EDM Bilişim": {
    name: "EDM Bilişim",
    authType: "USERNAME_PASSWORD",
    requiresUsername: true,
    requiresApiKey: true,
    baseUrlLabel: "EDM Web Servis URL",
    baseUrlPlaceholder: "https://portal2.edmbilisim.com.tr/EFaturaEDM/EFaturaEDM.svc",
    usernameLabel: "EDM Kullanıcı Adı",
    usernamePlaceholder: "EDM portal kullanıcı kodunuz",
    apiKeyLabel: "EDM Şifre",
    apiKeyPlaceholder: "EDM portal şifreniz",
  },
  "Uyumsoft": {
    name: "Uyumsoft",
    authType: "USERNAME_PASSWORD",
    requiresUsername: true,
    requiresApiKey: true,
    baseUrlLabel: "Uyumsoft Servis URL",
    baseUrlPlaceholder: "https://efatura.uyumsoft.com.tr/Services/Integration",
    usernameLabel: "Uyumsoft Kullanıcı Adı",
    usernamePlaceholder: "API kullanıcı kodunuz",
    apiKeyLabel: "Uyumsoft Şifre",
    apiKeyPlaceholder: "API şifreniz",
  },
  "Foriba (Sovos)": {
    name: "Foriba (Sovos)",
    authType: "BASIC_AUTH",
    requiresUsername: true,
    requiresApiKey: true,
    baseUrlLabel: "Foriba Servis URL",
    baseUrlPlaceholder: "https://efatura.foriba.com/api",
    usernameLabel: "Foriba Kullanıcı Adı",
    usernamePlaceholder: "Kullanıcı kodunuz",
    apiKeyLabel: "API Key / Şifre",
    apiKeyPlaceholder: "API anahtarınız veya şifreniz",
  },
  "Logo İşbaşı / e-Logo": {
    name: "Logo İşbaşı / e-Logo",
    authType: "BASIC_AUTH",
    requiresUsername: true,
    requiresApiKey: true,
    baseUrlLabel: "Logo Servis URL",
    baseUrlPlaceholder: "https://elogo.logo.com.tr/api",
    usernameLabel: "Logo Kullanıcı Adı",
    usernamePlaceholder: "e-Logo kullanıcı adı",
    apiKeyLabel: "API Key / Şifre",
    apiKeyPlaceholder: "API şifreniz",
  },
  "QNB e-Finans": {
    name: "QNB e-Finans",
    authType: "USERNAME_PASSWORD",
    requiresUsername: true,
    requiresApiKey: true,
    baseUrlLabel: "QNB e-Finans Servis URL",
    baseUrlPlaceholder: "https://efinans.com.tr/api",
    usernameLabel: "QNB Kullanıcı Adı",
    usernamePlaceholder: "Müşteri kullanıcı kodunuz",
    apiKeyLabel: "API Key / Şifre",
    apiKeyPlaceholder: "Şifreniz veya API anahtarı",
  },
  "KolayBi": {
    name: "KolayBi",
    authType: "BEARER_TOKEN",
    requiresUsername: false,
    requiresApiKey: true,
    baseUrlLabel: "KolayBi API URL",
    baseUrlPlaceholder: "https://api.kolaybi.com",
    apiKeyLabel: "Bearer API Token",
    apiKeyPlaceholder: "API token anahtarınızı girin",
  },
  "Digital Planet": {
    name: "Digital Planet",
    authType: "USERNAME_PASSWORD",
    requiresUsername: true,
    requiresApiKey: true,
    baseUrlLabel: "Digital Planet Servis URL",
    baseUrlPlaceholder: "https://efatura.digitalplanet.com.tr/api",
    usernameLabel: "Kullanıcı Adı",
    usernamePlaceholder: "Kullanıcı kodunuz",
    apiKeyLabel: "Şifre / API Key",
    apiKeyPlaceholder: "Şifreniz",
  },
  "İzibiz": {
    name: "İzibiz",
    authType: "USERNAME_PASSWORD",
    requiresUsername: true,
    requiresApiKey: true,
    baseUrlLabel: "İzibiz Servis URL",
    baseUrlPlaceholder: "https://efatura.izibiz.com.tr/api",
    usernameLabel: "İzibiz Kullanıcı Adı",
    usernamePlaceholder: "Kullanıcı adınız",
    apiKeyLabel: "İzibiz Şifre",
    apiKeyPlaceholder: "Şifreniz",
  },
  "Trendyol / Pazaryeri Entegrasyonu": {
    name: "Trendyol / Pazaryeri Entegrasyonu",
    authType: "API_KEY",
    requiresUsername: true,
    requiresApiKey: true,
    baseUrlLabel: "Pazaryeri API URL",
    baseUrlPlaceholder: "https://api.trendyol.com/sapigw",
    usernameLabel: "Supplier ID / Merchant ID",
    usernamePlaceholder: "Satıcı ID numaranız",
    apiKeyLabel: "API Key & Secret",
    apiKeyPlaceholder: "API Key ve Secret anahtarınız",
  },
  "Diğer (Özel Entegratör)": {
    name: "Diğer (Özel Entegratör)",
    authType: "CONFIGURABLE",
    requiresUsername: false,
    requiresApiKey: true,
    baseUrlLabel: "Servis Uç Noktası (API URL)",
    baseUrlPlaceholder: "https://api.entegrator.com",
    usernameLabel: "API Kullanıcı Adı (varsa)",
    usernamePlaceholder: "api_kullanici_kodu",
    apiKeyLabel: "API Anahtarı / Secret / Şifre",
    apiKeyPlaceholder: "API anahtarını girin",
  },
};

/**
 * Belirtilen entegratör için dinamik yapılandırmayı getirir.
 */
export function getIntegratorConfig(providerName: string): IntegratorConfig {
  return (
    INTEGRATORS_CONFIG[providerName] ?? {
      name: providerName,
      authType: "CONFIGURABLE",
      requiresUsername: false,
      requiresApiKey: true,
      baseUrlLabel: "Servis Uç Noktası (API URL)",
      baseUrlPlaceholder: "https://api.entegrator.com",
      usernameLabel: "API Kullanıcı Adı (varsa)",
      usernamePlaceholder: "api_kullanici_kodu",
      apiKeyLabel: "API Anahtarı / Gizli Anahtar (Secret)",
      apiKeyPlaceholder: "API anahtarını girin",
    }
  );
}
