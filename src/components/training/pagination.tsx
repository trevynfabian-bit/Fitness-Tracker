import Link from "next/link";

import { cn } from "@/lib/utils";
import { buttonVariants } from "@/components/ui/button";

/**
 * Offset pagination over a server-side page.
 *
 * Links, not buttons: a page of history is addressable, shareable and
 * back-button-correct, and nothing about it needs client state.
 */
export function Pagination({
  basePath,
  query,
  offset,
  limit,
  totalCount,
  hasPrevious,
  hasNext,
  noun = "workouts",
}: {
  basePath: string;
  query?: Record<string, string | undefined>;
  offset: number;
  limit: number;
  totalCount: number;
  hasPrevious: boolean;
  hasNext: boolean;
  noun?: string;
}) {
  const href = (nextOffset: number) => {
    const params = new URLSearchParams();
    for (const [key, value] of Object.entries(query ?? {})) {
      if (value) params.set(key, value);
    }
    if (nextOffset > 0) params.set("offset", String(nextOffset));
    const qs = params.toString();
    return qs ? `${basePath}?${qs}` : basePath;
  };

  const first = totalCount === 0 ? 0 : offset + 1;
  const last = Math.min(offset + limit, totalCount);

  return (
    <div className="mt-4 flex items-center justify-between gap-4">
      <p className="text-xs text-muted-foreground">
        {totalCount === 0
          ? `No ${noun}`
          : `Showing ${first}–${last} of ${totalCount} ${noun}`}
      </p>
      <div className="flex gap-2">
        {hasPrevious ? (
          <Link
            href={href(Math.max(0, offset - limit))}
            className={buttonVariants({ variant: "outline", size: "sm" })}
            rel="prev"
          >
            Previous
          </Link>
        ) : (
          <span
            aria-disabled="true"
            className={cn(
              buttonVariants({ variant: "outline", size: "sm" }),
              "pointer-events-none opacity-40",
            )}
          >
            Previous
          </span>
        )}
        {hasNext ? (
          <Link
            href={href(offset + limit)}
            className={buttonVariants({ variant: "outline", size: "sm" })}
            rel="next"
          >
            Next
          </Link>
        ) : (
          <span
            aria-disabled="true"
            className={cn(
              buttonVariants({ variant: "outline", size: "sm" }),
              "pointer-events-none opacity-40",
            )}
          >
            Next
          </span>
        )}
      </div>
    </div>
  );
}
