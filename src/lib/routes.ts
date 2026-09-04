/**
 * Route classification. Dependency-free so it can be unit tested and imported
 * from both the middleware and the server components.
 */

/** Route prefixes that require an authenticated session. */
export const PROTECTED_PREFIXES = ["/dashboard", "/registry", "/import"] as const;

/** Routes an authenticated user should not sit on. */
export const AUTH_ROUTES = ["/login", "/signup"] as const;

function matches(pathname: string, prefix: string): boolean {
  return pathname === prefix || pathname.startsWith(`${prefix}/`);
}

export function isProtectedPath(pathname: string): boolean {
  return PROTECTED_PREFIXES.some((prefix) => matches(pathname, prefix));
}

export function isAuthPath(pathname: string): boolean {
  return AUTH_ROUTES.some((route) => matches(pathname, route));
}

/**
 * Guards against open redirects: only same-origin absolute paths are accepted.
 */
export function safeRedirectPath(
  candidate: string | null | undefined,
  fallback = "/dashboard",
): string {
  if (!candidate) return fallback;
  if (!candidate.startsWith("/")) return fallback;
  if (candidate.startsWith("//")) return fallback;
  if (candidate.includes("\\")) return fallback;
  return candidate;
}
