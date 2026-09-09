import Link from "next/link";

import { CHART_RANGES, RANGE_LABEL, type ChartRange } from "@/lib/read-model/charts";
import { cn } from "@/lib/utils";

/**
 * The chart window, as links rather than client state.
 *
 * A range is part of what the page is showing, so it belongs in the URL: the
 * view is shareable, the back button does the obvious thing, and the server
 * renders the range it was asked for instead of hydrating and then re-fetching.
 * The same reasoning as the history pagination.
 */
export function RangeSelector({
  basePath,
  query,
  active,
}: {
  basePath: string;
  query?: Record<string, string | undefined>;
  active: ChartRange;
}) {
  const href = (range: ChartRange) => {
    const params = new URLSearchParams();
    for (const [key, value] of Object.entries(query ?? {})) {
      if (value) params.set(key, value);
    }
    params.set("range", range);
    return `${basePath}?${params.toString()}`;
  };

  return (
    <div
      role="group"
      aria-label="Chart range"
      className="-mx-1 flex flex-wrap items-center gap-1"
    >
      {CHART_RANGES.map((range) => {
        const current = range === active;
        return (
          <Link
            key={range}
            href={href(range)}
            aria-current={current ? "true" : undefined}
            className={cn(
              "rounded-md px-2.5 py-1 text-xs font-medium tabular-nums transition-colors",
              current
                ? "bg-foreground text-background"
                : "text-muted-foreground hover:bg-muted hover:text-foreground",
            )}
          >
            <span className="sr-only">{RANGE_LABEL[range]}</span>
            <span aria-hidden="true">{range}</span>
          </Link>
        );
      })}
    </div>
  );
}
