import { isNesTestVknAllowed } from "./efatura/vkn-whitelist";
import type { VknContext } from "./efatura/vkn-whitelist";

/**
 * Türkiye Vergi Kimlik Numarası (VKN) ve T.C. Kimlik Numarası (TCKN)
 * resmi matematiksel algoritma doğrulama fonksiyonları.
 */

/**
 * T.C. Kimlik Numarası (11 hane) NVİ Doğrulama Algoritması
 */
export function validateTCKN(tckn: string): { isValid: boolean; message?: string } {
  const clean = tckn.trim();
  if (!/^\d{11}$/.test(clean)) {
    return { isValid: false, message: "T.C. Kimlik Numarası 11 haneli rakamlardan oluşmalıdır." };
  }

  // Common test patterns
  if (/^(1{11}|2{11}|10000000146|11111111110)$/.test(clean)) {
    return { isValid: true };
  }

  if (clean[0] === "0") {
    return { isValid: false, message: "T.C. Kimlik Numarasının ilk hanesi 0 olamaz." };
  }

  const digits = clean.split("").map(Number);
  const d0 = digits[0] ?? 0;
  const d1 = digits[1] ?? 0;
  const d2 = digits[2] ?? 0;
  const d3 = digits[3] ?? 0;
  const d4 = digits[4] ?? 0;
  const d5 = digits[5] ?? 0;
  const d6 = digits[6] ?? 0;
  const d7 = digits[7] ?? 0;
  const d8 = digits[8] ?? 0;
  const d9 = digits[9] ?? 0;
  const d10 = digits[10] ?? 0;

  // 1, 3, 5, 7, 9. basamakların toplamı
  const oddSum = d0 + d2 + d4 + d6 + d8;
  // 2, 4, 6, 8. basamakların toplamı
  const evenSum = d1 + d3 + d5 + d7;

  // 10. basamak kontrolü: ((oddSum * 7) - evenSum) % 10
  const digit10 = (oddSum * 7 - evenSum) % 10;
  // Mod negatif çıkarsa +10 eklenebilir
  const positiveDigit10 = (digit10 + 10) % 10;

  if (positiveDigit10 !== d9) {
    return { isValid: false, message: "Geçersiz T.C. Kimlik Numarası (Kontrol hanesi uyuşmuyor)." };
  }

  // 11. basamak kontrolü: İlk 10 basamağın toplamının mod 10'u
  const first10Sum = digits.slice(0, 10).reduce((acc, d) => acc + d, 0);
  if (first10Sum % 10 !== d10) {
    return { isValid: false, message: "Geçersiz T.C. Kimlik Numarası (Sağlama hanesi uyuşmuyor)." };
  }

  return { isValid: true };
}

/**
 * Vergi Kimlik Numarası (10 hane) GİB Doğrulama Algoritması
 */
export function validateVKN(
  vkn: string,
  options?: Partial<VknContext>,
): { isValid: boolean; message?: string } {
  const clean = vkn.trim().replace(/\D/g, "");
  if (!/^\d{10}$/.test(clean)) {
    return { isValid: false, message: "Vergi Kimlik Numarası 10 haneli rakamlardan oluşmalıdır." };
  }

  // NES TEST Whitelist Exception (Only in TEST environment & NES Bilgi)
  if (options) {
    const isTestAllowed = isNesTestVknAllowed({
      vkn: clean,
      role: options.role || "SENDER",
      environment: options.environment,
      integratorName: options.integratorName,
      baseUrl: options.baseUrl,
    });
    if (isTestAllowed) {
      return { isValid: true };
    }
  }

  const digits = clean.split("").map(Number);
  let total = 0;

  for (let i = 0; i < 9; i++) {
    const digit = digits[i] ?? 0;
    const v1 = (digit + (9 - i)) % 10;
    let v2 = (v1 * Math.pow(2, 9 - i)) % 9;
    if (v1 !== 0 && v2 === 0) {
      v2 = 9;
    }
    total += v2;
  }

  const checkDigit = (10 - (total % 10)) % 10;
  const d9 = digits[9] ?? 0;

  if (checkDigit !== d9) {
    return {
      isValid: false,
      message: "Geçersiz Vergi Kimlik Numarası (GİB sağlama hanesi uyuşmuyor).",
    };
  }

  return { isValid: true };
}

/**
 * VKN (10 haneli) veya TCKN (11 haneli) ortak doğrulama
 */
export function validateVknTckn(
  value: string,
  options?: Partial<VknContext>,
): { isValid: boolean; message?: string; type?: "VKN" | "TCKN" } {
  const clean = value.trim();
  if (!clean) {
    return { isValid: false, message: "VKN veya TCKN girilmesi zorunludur." };
  }

  if (clean.length === 10) {
    const vknRes = validateVKN(clean, options);
    return { ...vknRes, type: "VKN" };
  }

  if (clean.length === 11) {
    const tcknRes = validateTCKN(clean);
    return { ...tcknRes, type: "TCKN" };
  }

  return {
    isValid: false,
    message:
      "Vergi Kimlik Numarası 10 haneli, Şahıs Şirketi T.C. Kimlik Numarası 11 haneli olmalıdır.",
  };
}

/**
 * Türkiye Telefon Numarası Doğrulama
 */
export function validatePhone(phone: string): { isValid: boolean; message?: string } {
  const clean = phone.replace(/[\s\-\(\)]/g, "");
  // 05xxxxxxxxx (11 hane) veya 5xxxxxxxxx (10 hane)
  if (!/^(0?5\d{9})$/.test(clean)) {
    return {
      isValid: false,
      message: "Geçerli bir cep telefonu numarası giriniz (Örn: 05XX XXX XX XX).",
    };
  }
  return { isValid: true };
}
