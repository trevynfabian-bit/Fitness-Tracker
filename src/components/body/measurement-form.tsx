"use client";

import { useState } from "react";

import { Alert } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import type { MeasurableMetric, Measurement } from "@/lib/read-model/body";

/**
 * Recording a measurement, and correcting one.
 *
 * Both are the same form and the same request, because they are the same act
 * at the domain level: a person stating what a measurement was. The difference
 * is one field — the observation being superseded — and the difference in the
 * data is a raw record at a higher precedence rank, not an edit.
 *
 * What can be entered, and in which units, comes from the registry rather than
 * from a list held here.
 */
export function MeasurementForm({
  metrics,
  correcting,
  onCancel,
}: {
  metrics: MeasurableMetric[];
  correcting?: Measurement;
  onCancel?: () => void;
}) {
  const initialMetric =
    metrics.find((m) => m.key === correcting?.metricKey) ?? metrics[0];

  const [metricKey, setMetricKey] = useState(initialMetric?.key ?? "");
  const [value, setValue] = useState(
    correcting ? String(correcting.sourceValueNum ?? "") : "",
  );
  const [unit, setUnit] = useState(correcting?.sourceUnit ?? initialMetric?.canonicalUnit ?? "");
  const [measuredAt, setMeasuredAt] = useState(
    localInputValue(correcting?.timestampUtc ?? new Date().toISOString()),
  );
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const metric = metrics.find((m) => m.key === metricKey) ?? initialMetric;

  function chooseMetric(key: string) {
    setMetricKey(key);
    const next = metrics.find((m) => m.key === key);
    if (next && !next.units.includes(unit)) setUnit(next.canonicalUnit);
  }

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const response = await fetch("/api/measurements", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          measurements: [
            {
              metricKey,
              value: value.trim(),
              unit,
              // The browser's own offset, so the instant and the local date the
              // person experienced are both recorded (v2 section 8).
              measuredAt: withOffset(measuredAt),
              ...(correcting ? { supersedesNaturalKey: correcting.naturalKey } : {}),
            },
          ],
        }),
      });
      const body = await response.json();
      if (!response.ok) throw new Error(body.error ?? "could not record the measurement");

      // A full reload, not router.refresh().
      //
      // router.refresh() is a best-effort transition: the App Router aborts
      // its RSC fetch when another update or a pending prefetch for the same
      // route intervenes, and it does so silently. The failure mode is the
      // worst one this form has — the measurement is written, normalized and
      // rolled up correctly, and the page goes on showing the list without
      // it, so the person believes nothing happened and records it twice.
      //
      // Whether the race is lost depends on payload size and on what the
      // router already has in flight, which is why this was survivable while
      // /body was a form and a list and became reproducible once the charts
      // were added to the same route. See
      // docs/architecture-implementation-notes.md N-14.
      //
      // A reload costs one render of a page the person is already looking at,
      // and it cannot fail to show what was just written. For a form whose
      // whole purpose is recording a measurement, that trade is not close.
      window.location.reload();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
      setBusy(false);
    }
  }

  if (metrics.length === 0) {
    return <Alert tone="info">No metric in the registry is marked as manually recordable.</Alert>;
  }

  return (
    <form onSubmit={submit} className="space-y-3">
      {correcting ? (
        <Alert tone="info">
          Correcting the {correcting.displayName.toLowerCase()} recorded on{" "}
          {correcting.localDate}. The original entry is kept: this is recorded as a
          correction that supersedes it, not as an edit.
        </Alert>
      ) : null}

      <div className="grid gap-3 sm:grid-cols-2">
        <div>
          <Label htmlFor="metric">Measurement</Label>
          <select
            id="metric"
            value={metricKey}
            onChange={(event) => chooseMetric(event.target.value)}
            disabled={Boolean(correcting)}
            className="mt-1 h-10 w-full rounded-md border border-input bg-transparent px-3 text-sm disabled:opacity-50"
          >
            {metrics.map((option) => (
              <option key={option.key} value={option.key}>
                {option.displayName}
              </option>
            ))}
          </select>
        </div>

        <div>
          <Label htmlFor="measured-at">Measured at</Label>
          <Input
            id="measured-at"
            type="datetime-local"
            value={measuredAt}
            onChange={(event) => setMeasuredAt(event.target.value)}
            className="mt-1"
            required
          />
        </div>

        <div>
          <Label htmlFor="value">Value</Label>
          <Input
            id="value"
            inputMode="decimal"
            value={value}
            onChange={(event) => setValue(event.target.value)}
            className="mt-1"
            placeholder="82.4"
            required
          />
        </div>

        <div>
          <Label htmlFor="unit">Unit</Label>
          <select
            id="unit"
            value={unit}
            onChange={(event) => setUnit(event.target.value)}
            className="mt-1 h-10 w-full rounded-md border border-input bg-transparent px-3 text-sm"
          >
            {(metric?.units ?? []).map((option) => (
              <option key={option} value={option}>
                {option}
              </option>
            ))}
          </select>
        </div>
      </div>

      {metric && unit !== metric.canonicalUnit ? (
        <p className="text-xs text-muted-foreground">
          Stored in {metric.canonicalUnit}. What you typed is kept alongside it, so the
          value can always be shown back in {unit}.
        </p>
      ) : null}

      {error ? <Alert tone="error">{error}</Alert> : null}

      <div className="flex gap-2">
        <Button type="submit" disabled={busy}>
          {correcting ? "Record correction" : "Record measurement"}
        </Button>
        {onCancel ? (
          <Button type="button" variant="outline" onClick={onCancel} disabled={busy}>
            Cancel
          </Button>
        ) : null}
      </div>
    </form>
  );
}

/** An ISO instant as the value a datetime-local input wants, in local time. */
function localInputValue(isoUtc: string): string {
  const date = new Date(isoUtc);
  const offset = date.getTimezoneOffset();
  return new Date(date.getTime() - offset * 60000).toISOString().slice(0, 16);
}

/**
 * A datetime-local value carries no zone, and the profile's timestamp mode is
 * 'embedded': a naive instant would be rejected rather than silently assumed
 * to be UTC. The browser's own offset is appended here, which is the only
 * place that knows it.
 */
function withOffset(localValue: string): string {
  const local = new Date(localValue);
  const offsetMinutes = -local.getTimezoneOffset();
  const sign = offsetMinutes >= 0 ? "+" : "-";
  const absolute = Math.abs(offsetMinutes);
  const hours = String(Math.floor(absolute / 60)).padStart(2, "0");
  const minutes = String(absolute % 60).padStart(2, "0");
  return `${localValue}:00${sign}${hours}:${minutes}`;
}
