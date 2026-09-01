import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../integrations/supabase/types";

export class ApiAuthError extends Error {
  statusCode = 401;
  code = "UNAUTHORIZED";
  constructor(message: string) {
    super(message);
    this.name = "ApiAuthError";
  }
}

export interface ApiUserContext {
  userId: string;
  /** RLS, isteği yapan kullanıcı kimliğiyle uygulanır. */
  supabase: SupabaseClient<Database>;
}

function resolveEnv() {
  const url =
    process.env["SUPABASE_URL"] ||
    process.env["VITE_SUPABASE_URL"] ||
    "https://sbrbonguzeqpzqhejojc.supabase.co";
  const key =
    process.env["SUPABASE_PUBLISHABLE_KEY"] ||
    process.env["VITE_SUPABASE_PUBLISHABLE_KEY"] ||
    "sb_publishable_QrotNH4uE1aYrweiaPen_Q_TjwTSWwQ";
  return { url, key };
}

function createSupabaseFetch(apiKey: string, accessToken: string): typeof fetch {
  return (input, init) => {
    const headers = new Headers(
      typeof Request !== "undefined" && input instanceof Request ? input.headers : undefined,
    );
    if (init?.headers) {
      new Headers(init.headers).forEach((value, key) => headers.set(key, value));
    }
    headers.set("apikey", apiKey);
    headers.set("Authorization", `Bearer ${accessToken}`);
    return fetch(input, { ...init, headers });
  };
}

function extractToken(request: Request): string {
  const authHeader = request.headers.get("authorization") || request.headers.get("Authorization");
  if (authHeader && authHeader.startsWith("Bearer ")) {
    const token = authHeader.slice(7).trim();
    if (token) return token;
  }

  // @supabase/ssr çerezi (SSR akışları için yedek)
  const cookieHeader = request.headers.get("cookie") || "";
  const match =
    cookieHeader.match(/sb-[^=]+-auth-token=([^;]+)/) || cookieHeader.match(/sb-access-token=([^;]+)/);
  if (match?.[1]) {
    try {
      const raw = decodeURIComponent(match[1]).replace(/^base64-/, "");
      const parsed = JSON.parse(raw);
      const token = Array.isArray(parsed) ? parsed[0] : parsed?.access_token;
      if (typeof token === "string" && token) return token;
    } catch {
      // yoksay
    }
  }

  return "";
}

/**
 * Her /api/* isteğinde çağıranın kimliğini doğrular.
 * Sabit/varsayılan kullanıcı kimliği KULLANILMAZ; kimlik daima token'dan gelir.
 */
export async function requireApiUser(request: Request): Promise<ApiUserContext> {
  const token = extractToken(request);
  if (!token) {
    throw new ApiAuthError("Yetkilendirme gerekli: Oturum bilgisi (Bearer token) bulunamadı.");
  }
  if (token.split(".").length !== 3) {
    throw new ApiAuthError("Yetkilendirme hatası: Geçersiz oturum belirteci.");
  }

  const { url, key } = resolveEnv();
  const supabase = createClient<Database>(url, key, {
    global: { fetch: createSupabaseFetch(key, token) },
    auth: { storage: undefined, persistSession: false, autoRefreshToken: false },
  });

  const { data, error } = await supabase.auth.getClaims(token);
  const userId = data?.claims?.sub ? String(data.claims.sub) : "";
  if (error || !userId) {
    throw new ApiAuthError("Yetkilendirme hatası: Oturum doğrulanamadı.");
  }

  return { userId, supabase };
}

export function authErrorResponse(error: unknown): Response | null {
  if (!(error instanceof ApiAuthError)) return null;
  return Response.json(
    {
      success: false,
      message: error.message,
      data: null,
      error: { code: error.code, message: error.message },
    },
    { status: error.statusCode },
  );
}
