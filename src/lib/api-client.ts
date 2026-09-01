import { supabase } from "@/integrations/supabase/client";

/**
 * /api/* uç noktalarına oturum belirteci ekleyerek istek atar.
 * Sunucu tarafı kullanıcı kimliğini yalnızca bu belirteçten türetir.
 */
export async function apiFetch(input: string, init: RequestInit = {}): Promise<Response> {
  const { data } = await supabase.auth.getSession();
  const token = data.session?.access_token;

  const headers = new Headers(init.headers);
  if (token) headers.set("Authorization", `Bearer ${token}`);

  return fetch(input, { ...init, headers });
}
