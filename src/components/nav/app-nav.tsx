"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

import { cn } from "@/lib/utils";

/**
 * The product's primary navigation.
 *
 * Five destinations, flat. A training log is a navigation problem before it is
 * a visualisation problem: the reader is either looking at the whole history,
 * one session, one exercise, or bringing more data in.
 */
const ITEMS = [
  { href: "/dashboard", label: "Dashboard" },
  { href: "/history", label: "History" },
  { href: "/exercises", label: "Exercises" },
  { href: "/body", label: "Body" },
  { href: "/import", label: "Import" },
  { href: "/settings", label: "Settings" },
] as const;

export function AppNav() {
  const pathname = usePathname() ?? "";

  return (
    <nav aria-label="Primary" className="-mx-1 flex gap-1 overflow-x-auto">
      {ITEMS.map((item) => {
        const active = pathname === item.href || pathname.startsWith(`${item.href}/`);
        return (
          <Link
            key={item.href}
            href={item.href}
            aria-current={active ? "page" : undefined}
            className={cn(
              "whitespace-nowrap rounded-md px-3 py-1.5 text-sm font-medium transition-colors",
              active
                ? "bg-muted text-foreground"
                : "text-muted-foreground hover:bg-muted hover:text-foreground",
            )}
          >
            {item.label}
          </Link>
        );
      })}
    </nav>
  );
}
