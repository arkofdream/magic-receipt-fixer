/**
 * NES Bilgi Test Ortamı için Resmi Test VKN Whitelist Yönetimi.
 * YALNIZCA NES TEST ortamında geçerlidir.
 * Production ortamında kesinlikle devre dışıdır.
 */

export const NES_TEST_ALLOWED_SENDERS = ["1234567801"];
export const NES_TEST_ALLOWED_RECEIVERS = ["1234567802"];

export type VknContext = {
  vkn: string;
  role: "SENDER" | "RECEIVER";
  environment?: "TEST" | "PROD" | string;
  integratorName?: string;
  baseUrl?: string;
};

/**
 * Bir VKN'nin NES Test whitelist istisnasına tabi olup olmadığını kontrol eder.
 * Sadece TEST ortamında, NES Bilgi entegrasyonunda ve tanımlı resmi test VKN'si ise true döner.
 */
export function isNesTestVknAllowed(context: VknContext): boolean {
  if (!context.vkn) return false;
  const cleanVkn = context.vkn.trim().replace(/\D/g, "");

  const env = (context.environment || "").toUpperCase();
  const url = (context.baseUrl || "").toLowerCase();

  // Production ortamı tespiti (Explicit PROD veya apitest/test içermeyen canlı URL)
  const isExplicitProd =
    env === "PROD" || (url.length > 0 && !url.includes("apitest") && !url.includes("test"));

  if (isExplicitProd) {
    return false; // PRODUCTION'DA KESİNLİKLE WHITELIST KULLANILAMAZ
  }

  const isTestEnv =
    env === "TEST" ||
    url.includes("apitest.nes.com.tr") ||
    url.includes("test") ||
    url.length === 0;

  const provider = (context.integratorName || "").toLowerCase();
  const isNes = provider.includes("nes") || url.includes("nes.com.tr") || provider.length === 0;

  if (!isTestEnv || !isNes) {
    return false;
  }

  if (context.role === "SENDER") {
    return NES_TEST_ALLOWED_SENDERS.includes(cleanVkn);
  }

  if (context.role === "RECEIVER") {
    return NES_TEST_ALLOWED_RECEIVERS.includes(cleanVkn);
  }

  return false;
}
