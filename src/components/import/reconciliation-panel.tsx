"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";

import { Alert } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import {
  OVERRIDE_MIN_REASON_LENGTH,
  overrideAvailability,
  type GuardResult,
} from "@/lib/import/reconciliation";

type Guard = GuardResult;

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
 *
 * A blocked plan can still be confirmed, but only through the override block
 * below, and it is deliberately not one click. Phase 5.1 made that a real
 * capability rather than a button the backend could never honour; the price of
 * making it real is that it has to look and read like what it is.
 */
export function ReconciliationPanel({ importId, plan }: { importId: string; plan: Plan }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [typed, setTyped] = useState("");
  const [acknowledged, setAcknowledged] = useState(false);
  const [overrideReason, setOverrideReason] = useState("");

  const blocking = plan.guard_results.filter((g) => g.outcome === "blocked");
  const availability = overrideAvailability(plan.guard_results);
  const decided = plan.decision !== null;

  const reasonOk = overrideReason.trim().length >= OVERRIDE_MIN_REASON_LENGTH;
  const typedOk = typed.trim() === String(plan.retire_count);
  const overrideReady = acknowledged && reasonOk && typedOk;

  async function decide(decision: "confirmed" | "skipped" | "cancelled", override?: boolean) {
    setBusy(true);
    setError(null);
    try {
      const response = await fetch(`/api/imports/${importId}/decision`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          planId: plan.id,
          decision,
          ...(override
            ? {
                override: {
                  acknowledged: true,
                  typedConfirmation: typed.trim(),
                  reason: overrideReason.trim(),
                },
              }
            : {}),
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

          {plan.verdict === "blocked" && !availability.available ? (
            <Alert tone="info">
              This plan cannot be overridden. Guard{" "}
              {availability.nonOverridable.join(", ")} has no override, so the only ways
              forward are importing without retiring, or cancelling.
            </Alert>
          ) : null}

          {plan.verdict === "blocked" && availability.available ? (
            <details className="rounded-md border border-destructive/50 bg-destructive/5">
              <summary className="cursor-pointer px-3 py-2 text-sm font-medium text-destructive">
                Override the safety block and retire {plan.retire_count} record
                {plan.retire_count === 1 ? "" : "s"}
              </summary>

              <div className="space-y-3 border-t border-destructive/30 px-3 py-3">
                <div className="space-y-2 text-sm">
                  <p>
                    <strong>
                      This import looks like a partial or incomplete snapshot of your history.
                    </strong>{" "}
                    Guard {availability.overridable.join(" and ")} stopped the retirement
                    automatically, to protect data the file may simply be missing rather than
                    data you meant to remove.
                  </p>
                  <p>
                    Overriding retires {plan.retire_count} historical record
                    {plan.retire_count === 1 ? "" : "s"} that exist in your account and are
                    absent from this file. Retirement is reversible for the life of the import,
                    but the records stop counting towards your history and your training
                    analytics until it is reversed.
                  </p>
                  <p className="text-muted-foreground">
                    This override is recorded against your account with the time, the reason you
                    give below, and the guard result it overrode.
                  </p>
                </div>

                <label className="flex items-start gap-2 text-sm">
                  <input
                    id="override-acknowledge"
                    type="checkbox"
                    checked={acknowledged}
                    onChange={(event) => setAcknowledged(event.target.checked)}
                    className="mt-1"
                  />
                  <span>
                    I understand this file may be incomplete, and I am choosing to retire{" "}
                    {plan.retire_count} historical record
                    {plan.retire_count === 1 ? "" : "s"} anyway.
                  </span>
                </label>

                <div className="space-y-1">
                  <label htmlFor="override-reason" className="text-xs text-muted-foreground">
                    Why are you overriding? (required, at least {OVERRIDE_MIN_REASON_LENGTH}{" "}
                    characters — this is stored in the audit trail)
                  </label>
                  <Textarea
                    id="override-reason"
                    value={overrideReason}
                    onChange={(event) => setOverrideReason(event.target.value)}
                    placeholder="For example: this export is authoritative, the older sessions were deleted deliberately."
                  />
                </div>

                <div className="space-y-1">
                  <label htmlFor="typed" className="text-xs text-muted-foreground">
                    Type {plan.retire_count} to confirm the number of records being retired
                  </label>
                  <Input
                    id="typed"
                    value={typed}
                    onChange={(event) => setTyped(event.target.value)}
                    className="w-40"
                  />
                </div>

                <Button
                  variant="destructive"
                  disabled={busy || !overrideReady}
                  onClick={() => void decide("confirmed", true)}
                >
                  Override {availability.overridable.join(" and ")} and retire{" "}
                  {plan.retire_count}
                </Button>
              </div>
            </details>
          ) : null}
        </div>
      )}
    </section>
  );
}
