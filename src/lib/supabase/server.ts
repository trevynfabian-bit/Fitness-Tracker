import { cookies } from "next/headers";
import { createServerClient, type CookieOptions } from "@supabase/ssr";

import { clientEnv } from "@/lib/env";

/**
 * Server Supabase client for Server Components, Server Actions and Route
 * Handlers.
 *
 * This client uses the anon key and the caller's session cookie, so every
 * query runs under RLS as that user. The service role key is deliberately
 * absent from the application: nothing in the app is allowed to bypass RLS.
 */
export async function createClient() {
  const cookieStore = await cookies();

  return createServerClient(
    clientEnv.NEXT_PUBLIC_SUPABASE_URL,
    clientEnv.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
        setAll(
          cookiesToSet: { name: string; value: string; options?: CookieOptions }[],
        ) {
          try {
            for (const { name, value, options } of cookiesToSet) {
              cookieStore.set(name, value, options);
            }
          } catch {
            // Called from a Server Component, where cookies are read-only.
            // Session refresh is handled by middleware, so this is safe.
          }
        },
      },
    },
  );
}
