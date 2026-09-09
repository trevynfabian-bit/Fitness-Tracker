"use client";

import * as React from "react";

/**
 * One tooltip body for every chart here. Values wear text tokens, never the
 * series colour; the coloured mark in the chart already carries identity.
 */
export function TooltipBox({
  label,
  rows,
}: {
  label: string;
  rows: { name: string; value: string }[];
}) {
  return (
    <div className="rounded-md border border-border bg-card px-3 py-2 text-xs shadow-sm">
      <p className="font-medium text-foreground">{label}</p>
      <dl className="mt-1 space-y-0.5">
        {rows.map((row) => (
          <div key={row.name} className="flex gap-3">
            <dt className="text-muted-foreground">{row.name}</dt>
            <dd className="ml-auto tabular-nums text-foreground">{row.value}</dd>
          </div>
        ))}
      </dl>
    </div>
  );
}
