import * as React from "react";

import { Card } from "@/components/ui/card";

/**
 * Common chrome for every chart on the product surface.
 *
 * The title names the single series, which is why none of these charts carries
 * a legend: identity never depends on hue when there is one hue. The table
 * behind the disclosure is the accessibility path, and it is the same numbers
 * the chart draws, not a summary of them.
 */
export function ChartFrame({
  title,
  description,
  tableCaption,
  children,
  table,
}: {
  title: string;
  description?: string;
  tableCaption?: string;
  children: React.ReactNode;
  table?: React.ReactNode;
}) {
  return (
    <Card>
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h3 className="text-sm font-medium">{title}</h3>
      </div>
      {description ? (
        <p className="mt-1 text-xs text-muted-foreground">{description}</p>
      ) : null}
      <div className="mt-4">{children}</div>
      {table ? (
        <details className="mt-3 text-xs">
          <summary className="cursor-pointer text-muted-foreground hover:text-foreground">
            {tableCaption ?? "View as table"}
          </summary>
          <div className="mt-2 overflow-x-auto">{table}</div>
        </details>
      ) : null}
    </Card>
  );
}
