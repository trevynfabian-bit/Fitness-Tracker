import Link from "next/link";

import { buttonVariants } from "@/components/ui/button";

/**
 * A record that does not exist and a record belonging to somebody else look
 * identical here, on purpose: row level security returns nothing in both cases
 * and this page reveals nothing about which one happened.
 */
export default function NotFound() {
  return (
    <main className="mx-auto w-full max-w-5xl px-6 py-20 text-center">
      <h1 className="text-2xl font-semibold tracking-tight">Not found</h1>
      <p className="mx-auto mt-2 max-w-md text-sm text-muted-foreground">
        This record does not exist in your account.
      </p>
      <div className="mt-6">
        <Link href="/dashboard" className={buttonVariants({ size: "sm" })}>
          Back to dashboard
        </Link>
      </div>
    </main>
  );
}
