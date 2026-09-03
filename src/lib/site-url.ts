import { headers } from "next/headers";

import { clientEnv } from "@/lib/env";

/**
 * Absolute origin for auth email redirect links.
 * Prefers the explicitly configured site URL; otherwise derives it from the
 * forwarded request headers.
 */
export async function getSiteUrl(): Promise<string> {
  if (clientEnv.NEXT_PUBLIC_SITE_URL) {
    return clientEnv.NEXT_PUBLIC_SITE_URL.replace(/\/$/, "");
  }

  const headerList = await headers();
  const host = headerList.get("x-forwarded-host") ?? headerList.get("host");
  const proto = headerList.get("x-forwarded-proto") ?? "http";

  if (!host) {
    throw new Error(
      "Cannot determine site URL. Set NEXT_PUBLIC_SITE_URL for this deployment.",
    );
  }

  return `${proto}://${host}`;
}
