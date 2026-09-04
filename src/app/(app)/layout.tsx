import { redirect } from "next/navigation";
import Link from "next/link";

import { SignOutButton } from "@/components/auth/sign-out-button";
import { AppNav } from "@/components/nav/app-nav";
import { createClient } from "@/lib/supabase/server";

/**
 * Shell for every signed-in surface. The route group keeps the existing URLs
 * (/dashboard, /import/:id) unchanged while giving them one header.
 *
 * Middleware already gates these paths; the layout checks again because a
 * server render must never assume the middleware ran.
 */
export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  return (
    <div className="min-h-screen">
      <header className="border-b border-border">
        <div className="mx-auto flex w-full max-w-5xl flex-wrap items-center justify-between gap-3 px-6 py-3">
          <div className="flex items-center gap-6">
            <Link href="/dashboard" className="text-sm font-semibold tracking-tight">
              Health Platform
            </Link>
            <AppNav />
          </div>
          <div className="flex items-center gap-3">
            <span className="max-w-[10rem] truncate text-xs text-muted-foreground sm:max-w-none">
              Signed in as {user.email}
            </span>
            <SignOutButton />
          </div>
        </div>
      </header>
      {children}
    </div>
  );
}
