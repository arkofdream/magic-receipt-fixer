import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";

/**
 * Sunucu tarafı kimlik bilgisi şifreleme yardımcıları (AES-256-GCM).
 * Anahtar sunucu ortamından (EFATURA_CREDENTIALS_KEY) veya proje ID fallback'inden türetilir.
 */
function key(): Buffer {
  const raw =
    process.env["EFATURA_CREDENTIALS_KEY"] ||
    process.env["SUPABASE_PROJECT_ID"] ||
    "magic_receipt_default_secure_vault_key_2026";
  return createHash("sha256").update(raw).digest();
}

export function encryptSecret(plaintext: string): string {
  if (!plaintext) return "";
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key(), iv);
  const ct = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), ct]).toString("base64");
}

export function decryptSecret(stored: string): string {
  if (!stored) return "";
  try {
    const buf = Buffer.from(stored, "base64");
    if (buf.length < 29) return ""; // iv(12) + tag(16) + min 1 byte ct
    const iv = buf.subarray(0, 12);
    const tag = buf.subarray(12, 28);
    const ct = buf.subarray(28);
    const decipher = createDecipheriv("aes-256-gcm", key(), iv);
    decipher.setAuthTag(tag);
    return Buffer.concat([decipher.update(ct), decipher.final()]).toString("utf8");
  } catch {
    return "";
  }
}
