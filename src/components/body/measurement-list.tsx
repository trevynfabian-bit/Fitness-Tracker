"use client";

import { useState } from "react";

import { MeasurementForm } from "@/components/body/measurement-form";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { formatLocalDate } from "@/lib/read-model/format";
import type { MeasurableMetric, Measurement } from "@/lib/read-model/body";

/**
 * Recorded measurements, newest first, each correctable in place.
 *
 * What is shown is the value currently in force. A row marked "corrected" is
 * one whose current value came from a correction rather than from the original
 * entry — the original is still in the raw layer, and a rebuild would reach the
 * same conclusion from it.
 */
export function MeasurementList({
  measurements,
  metrics,
}: {
  measurements: Measurement[];
  metrics: MeasurableMetric[];
}) {
  const [correcting, setCorrecting] = useState<Measurement | null>(null);

  return (
    // role="list" is not redundant here. Tailwind's preflight sets
    // list-style: none, and Chromium drops the list/listitem roles from the
    // accessibility tree when it does, so a screen reader would announce these
    // as loose paragraphs rather than as a list of measurements.
    <ul role="list" className="divide-y divide-border rounded-lg border border-border">
      {measurements.map((measurement) => (
        <li key={measurement.id} className="px-4 py-3">
          <div className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
            <div className="min-w-0">
              <p className="text-sm font-medium">
                {measurement.displayName}
                {measurement.qualifier ? (
                  <span className="text-muted-foreground"> · {measurement.qualifier}</span>
                ) : null}
              </p>
              <p className="text-xs text-muted-foreground">
                {formatLocalDate(measurement.localDate)}
                {measurement.corrected ? (
                  <>
                    {" · "}
                    <Badge>corrected</Badge>
                  </>
                ) : null}
              </p>
            </div>

            <div className="flex items-baseline gap-3">
              <p className="tabular-nums">
                <span className="text-base font-semibold">{format(measurement.valueNum)}</span>{" "}
                <span className="text-xs text-muted-foreground">{measurement.unit}</span>
                {measurement.sourceUnit !== measurement.unit ? (
                  <span className="ml-2 text-xs text-muted-foreground">
                    (entered {format(measurement.sourceValueNum)} {measurement.sourceUnit})
                  </span>
                ) : null}
              </p>
              <Button
                variant="outline"
                size="sm"
                onClick={() =>
                  setCorrecting(correcting?.id === measurement.id ? null : measurement)
                }
              >
                {correcting?.id === measurement.id ? "Close" : "Correct"}
              </Button>
            </div>
          </div>

          {correcting?.id === measurement.id ? (
            <div className="mt-3 rounded-md border border-border p-3">
              <MeasurementForm
                metrics={metrics}
                correcting={measurement}
                onCancel={() => setCorrecting(null)}
              />
            </div>
          ) : null}
        </li>
      ))}
    </ul>
  );
}

function format(value: number | null): string {
  if (value === null) return "—";
  return new Intl.NumberFormat("en-GB", { maximumFractionDigits: 2 }).format(value);
}
