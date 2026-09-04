"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";

import { Alert } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

type Guard = { id: string; outcome: string; detail: string; overridable: boolean };

export type Plan = {
  id: string;
  verdict: "safe" | "warn" | "blocked";
  decision: string | null;
  add_count: number;
  update_count: number;
  unchanged_count: number;
  retire_count: number;
  existing_in_scope_count: number;
  retire_ratio: string;
  retire_date_histogram: Record<string, number>;
  retire_key_sample: { local_date: string; natural_key: string }[];
  guard_results: Guard[];
};

/**
 * The confirmation screen (v3 section 4.4).
 *
 * Renders the projected impact before any decision: what would be added,
 * updated, left alone and retired; the shape of the retirement by month;
 * examples of what would go; and every guard that fired with its reason.
 *
 * "Import without retiring" is the recommended action and is always one click,
 * because a partial export is the common cause of a large retirement.
 */
export function ReconciliationPanel({ importId, plan }: { importId: string; plan: Plan }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [typed, setTyped] = useState("");

  const blocking = plan.guard_results.filter((g) => g.outcome === "blocked");
  const overridable = blocking.length > 0 && blocking.every((g) => g.overridable);
  const decided = plan.decision !== null;

  async function decide(decision: "confirmed" | "skipped" | "cancelled", overrideGuardId?: string) {
    setBusy(true);
    setError(null);
    try {
      const response = await fetch(`/api/imports/${importId}/decision`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          planId: plan.id,
          decision,
          ...(overrideGuardId ? { overrideGuardId, typedConfirmation: typed } : {}),
        }),
      });
      const body = await response.json();
      if (!response.ok) throw new Error(body.error ?? "decision failed");
      router.refresh();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="space-y-4 rounded-lg border border-destructive/40 p-4">
      <h2 className="text-sm font-semibold uppercase tracking-wide">
        Snapshot import — confirmation required
      </h2>

      <dl className="grid grid-cols-2 gap-2 text-sm sm:grid-cols-4">
        {[
          ["Add", plan.add_count],
          ["Update", plan.update_count],
          ["Unchanged", plan.unchanged_count],
          ["Retire", plan.retire_count],
        ].map(([label, value]) => (
          <div key={String(label)} className="rounded-md border border-border p-2">
            <dt className="text-xs text-muted-foreground">{label}</dt>
            <dd className="font-mono text-base">{value}</dd>
          </div>
        ))}
      </dl>

      <p className="text-sm text-muted-foreground">
        {plan.retire_count} of {plan.existing_in_scope_count} existing records in this scope would
        be retired ({(Number(plan.retire_ratio) * 100).toFixed(0)}%).
      </p>

      {Object.keys(plan.retire_date_histogram).length ? (
        <div>
          <h3 className="text-xs font-medium uppercase text-muted-foreground">Retirements by month</h3>
          <ul className="mt-1 space-y-0.5 font-mono text-xs">
            {Object.entries(plan.retire_date_histogram).map(([month, count]) => (
              <li key={month}>
                {month} {"▇".repeat(Math.min(24, count))} {count}
              </li>
            ))}
          </ul>
        </div>
      ) : null}

      {plan.retire_key_sample.length ? (
        <div>
          <h3 className="text-xs font-medium uppercase text-muted-foreground">
            Examples of what would be retired
          </h3>
          <ul className="mt-1 max-h-40 overflow-y-auto font-mono text-xs">
            {plan.retire_key_sample.slice(0, 10).map((s) => (
              <li key={s.natural_key}>
                {s.local_date} {s.natural_key.slice(0, 16)}…
              </li>
            ))}
            {plan.retire_count > 10 ? <li>… {plan.retire_count - 10} more</li> : null}
          </ul>
        </div>
      ) : null}

      {blocking.map((guard) => (
        <Alert key={guard.id} tone="error">
          <strong>Guard {guard.id} triggered.</strong> {guard.detail}
          {guard.overridable ? "" : " This guard has no override."}
        </Alert>
      ))}

      {error ? <Alert tone="error">{error}</Alert> : null}

      {decided ? (
        <Alert tone="info">This plan was already decided: {plan.decision}.</Alert>
      ) : (
        <div className="space-y-3">
          <div className="flex flex-wrap gap-2">
            <Button onClick={() => void decide("skipped")} disabled={busy}>
              Import without retiring (recommended)
            </Button>
            <Button variant="outline" onClick={() => void decide("cancelled")} disabled={busy}>
              Cancel
            </Button>
            {plan.verdict !== "blocked" ? (
              <Button variant="outline" onClick={() => void decide("confirmed")} disabled={busy}>
                Confirm and retire {plan.retire_count}
              </Button>
            ) : null}
          </div>

          {plan.verdict === "blocked" && overridable ? (
            <div className="flex flex-wrap items-end gap-2">
              <div className="space-y-1">
                <label htmlFor="typed" className="text-xs text-muted-foreground">
                  Retire anyway — type {plan.retire_count} to confirm
                </label>
                <Input
                  id="typed"
                  value={typed}
                  onChange={(event) => setTyped(event.target.value)}
                  className="w-40"
                />
              </div>
              <Button
                variant="outline"
                disabled={busy || typed !== String(plan.retire_count)}
                onClick={() => void decide("confirmed", blocking[0]?.id)}
              >
                Override {blocking[0]?.id} and retire
              </Button>
            </div>
          ) : null}
        </div>
      )}
    </section>
  );
}
