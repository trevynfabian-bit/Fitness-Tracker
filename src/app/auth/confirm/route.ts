import { NextResponse, type NextRequest } from "next/server";
import type { EmailOtpType } from "@supabase/supabase-js";

import { createClient } from "@/lib/supabase/server";
import { safeRedirectPath } from "@/lib/routes";

/**
 * Emits a same-origin redirect with a relative Location header.
 *
 * Neither `new URL(path, request.url)` nor `request.nextUrl` may be used to
 * build this redirect. In a Route Handler both resolve to the server's own
 * origin (`localhost`), not the origin the client used. The session cookie
 * this route sets is scoped to the request's host, so redirecting to a
 * different host silently drops the session the user just established -
 * confirmation appears to succeed and the user lands back on the login page.
 *
 * A relative Location is valid per RFC 7231 and is what the middleware emits,
 * so the browser stays on whatever origin it was already using. Cookies set
 * through `cookies()` are merged into this response by Next.js.
 */
function redirectTo(target: string): NextResponse {
  return new NextResponse(null, {
    status: 307,
    headers: { Location: target },
  });
}

/**
 * Handles the link Supabase emails after sign up (and password recovery).
 * Exchanges the one-time token for a session, then redirects.
 */
export async function GET(request: NextRequest) {
  const { searchParams } = request.nextUrl;
  const tokenHash = searchParams.get("token_hash");
  const type = searchParams.get("type") as EmailOtpType | null;
  const next = safeRedirectPath(searchParams.get("next"));

  if (!tokenHash || !type) {
    return redirectTo("/login?error=invalid_confirmation_link");
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.verifyOtp({ type, token_hash: tokenHash });

  if (error) {
    return redirectTo("/login?error=confirmation_failed");
  }

  return redirectTo(next);
}
