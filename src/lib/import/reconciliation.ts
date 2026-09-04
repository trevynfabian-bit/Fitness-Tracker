/**
 * Snapshot reconciliation guards (v3 section 4.3, PRD section 11, I-10).
 *
 * Pure. Given counts and key sets, decides what the retire stage is allowed to
 * do. The stage computes a plan, persists it, and halts; it never retires
 * inside an unattended job.
 *
 * The database enforces the same conclusions independently: a blocked plan can
 * never be confirmed, a row can only be retired when a confirmed plan names it,
 * and a manual-origin row can never be retired at all. This module decides;
 * the schema makes the decision impossible to bypass.
 */

export type GuardId = "G1" | "G2" | "G3" | "G4" | "G5" | "G6" | "G7" | "G8" | "G9" | "G10";
export type GuardOutcome = "pass" | "warn" | "blocked";
export type Verdict = "safe" | "warn" | "blocked";

/** v3 section 4.3 gives an override to exactly two guards. */
export const OVERRIDABLE_GUARDS: ReadonlySet<GuardId> = new Set<GuardId>(["G4", "G6"]);

export type GuardResult = {
  id: GuardId;
  outcome: GuardOutcome;
  detail: string;
  overridable: boolean;
};

export type ReconciliationInput = {
  hadFatalErrors: boolean;
  rowsTotal: number;
  recordsInvalid: number;
  validRowCount: number;
  addCount: number;
  updateCount: number;
  unchangedCount: number;
  retireCount: number;
  existingInScopeCount: number;
  incomingInScopeCount: number;
  /** Local dates spanned by the file itself. */
  fileDateFrom: string | null;
  fileDateTo: string | null;
  /** Local dates spanned by the existing data within scope. */
  existingDateFrom: string | null;
  existingDateTo: string | null;
  /** Retirement candidates that fall outside the file's own date span. */
  retirementsOutsideFileSpan: number;
  /** Retirement candidates whose source_key differs from the profile's. */
  retirementsFromOtherSources: number;
  /** Retirement candidates originating from a manual record. */
  retirementsFromManual: number;
  /** Reduced-tier buckets skipped because the incoming sample count was lower. */
  reducedBucketsSkipped: number;
};

export const G1_INVALID_RATIO = 0.05;
export const G2_MIN_VALID_ROWS = 10;
export const G4_MIN_COVERAGE = 0.7;
export const G5_MIN_SPAN_COVERAGE = 0.8;
export const G6_MAX_RETIRE_RATIO = 0.25;
export const G6_MAX_RETIRE_COUNT = 500;

function daySpan(from: string | null, to: string | null): number {
  if (!from || !to) return 0;
  const ms = Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`);
  return Number.isFinite(ms) ? Math.max(0, ms / 86400000) + 1 : 0;
}

export function retireRatio(input: ReconciliationInput): number {
  if (input.existingInScopeCount === 0) return 0;
  return input.retireCount / input.existingInScopeCount;
}

/**
 * Evaluates every guard in order. The most severe outcome wins.
 * Every guard is reported, including the ones that passed, so the persisted
 * plan records what was checked and not merely what failed.
 */
export function evaluateGuards(input: ReconciliationInput): {
  results: GuardResult[];
  verdict: Verdict;
} {
  const results: GuardResult[] = [];
  const ratio = retireRatio(input);
  const add = (id: GuardId, outcome: GuardOutcome, detail: string) =>
    results.push({ id, outcome, detail, overridable: OVERRIDABLE_GUARDS.has(id) });

  // G1: a partly failed parse must never drive retirement.
  const invalidRatio = input.rowsTotal === 0 ? 0 : input.recordsInvalid / input.rowsTotal;
  if (input.hadFatalErrors || invalidRatio > G1_INVALID_RATIO) {
    add(
      "G1",
      "blocked",
      input.hadFatalErrors
        ? "the import produced fatal errors"
        : `${input.recordsInvalid} of ${input.rowsTotal} rows were invalid (${(invalidRatio * 100).toFixed(1)}%, limit ${G1_INVALID_RATIO * 100}%)`,
    );
  } else {
    add("G1", "pass", `${input.recordsInvalid} of ${input.rowsTotal} rows invalid`);
  }

  // G2: an empty or truncated export can retire nothing, ever.
  if (input.validRowCount < G2_MIN_VALID_ROWS) {
    add("G2", "blocked", `the file contains only ${input.validRowCount} valid rows, fewer than ${G2_MIN_VALID_ROWS}`);
  } else {
    add("G2", "pass", `${input.validRowCount} valid rows`);
  }

  // G3: a file that matches nothing is not a snapshot of this data.
  const matched = input.addCount + input.updateCount + input.unchangedCount;
  if (input.retireCount > 0 && matched === 0) {
    add("G3", "blocked", "the file proposes retirements but matches no existing record");
  } else {
    add("G3", "pass", `${matched} rows added, updated or unchanged`);
  }

  // G4: the coverage floor. This is the truncated-export guard.
  const coverage =
    input.existingInScopeCount === 0 ? 1 : input.incomingInScopeCount / input.existingInScopeCount;
  if (input.existingInScopeCount > 0 && coverage < G4_MIN_COVERAGE) {
    add(
      "G4",
      "blocked",
      `the file contains ${input.incomingInScopeCount} records in scope against ${input.existingInScopeCount} existing (${(coverage * 100).toFixed(0)}%, floor ${G4_MIN_COVERAGE * 100}%). This usually means the export is partial rather than complete.`,
    );
  } else {
    add("G4", "pass", `${(coverage * 100).toFixed(0)}% of existing records in scope are present`);
  }

  // G5: a narrow file span narrows the scope rather than wiping outside it.
  const fileSpan = daySpan(input.fileDateFrom, input.fileDateTo);
  const existingSpan = daySpan(input.existingDateFrom, input.existingDateTo);
  const spanCoverage = existingSpan === 0 ? 1 : fileSpan / existingSpan;
  if (existingSpan > 0 && spanCoverage < G5_MIN_SPAN_COVERAGE) {
    add(
      "G5",
      "warn",
      `the file spans ${fileSpan} days against ${existingSpan} days of existing data; scope narrowed to the file's own span`,
    );
  } else {
    add("G5", "pass", `the file spans ${fileSpan} days`);
  }

  // G6: a large retirement needs a typed confirmation even when it looks sound.
  if (ratio > G6_MAX_RETIRE_RATIO || input.retireCount > G6_MAX_RETIRE_COUNT) {
    add(
      "G6",
      "warn",
      `${input.retireCount} records would be retired, ${(ratio * 100).toFixed(0)}% of those in scope`,
    );
  } else {
    add("G6", "pass", `${input.retireCount} records would be retired`);
  }

  // G7: a retirement outside the file's own dates is a structural bug.
  if (input.retirementsOutsideFileSpan > 0) {
    add("G7", "blocked", `${input.retirementsOutsideFileSpan} retirements fall outside the file's own date range`);
  } else {
    add("G7", "pass", "all retirements fall inside the file's date range");
  }

  // G8: scope leak.
  if (input.retirementsFromOtherSources > 0) {
    add("G8", "blocked", `${input.retirementsFromOtherSources} retirements target records from another source`);
  } else {
    add("G8", "pass", "no retirement targets another source");
  }

  // G9: manual data is the only data that cannot be re-obtained. No override.
  if (input.retirementsFromManual > 0) {
    add("G9", "blocked", `${input.retirementsFromManual} retirements target manually entered records; this guard has no override`);
  } else {
    add("G9", "pass", "no retirement targets a manual record");
  }

  // G10: reduced-tier coverage, reported rather than blocking.
  if (input.reducedBucketsSkipped > 0) {
    add("G10", "warn", `${input.reducedBucketsSkipped} reduced buckets skipped as thinner duplicates`);
  } else {
    add("G10", "pass", "no reduced buckets skipped");
  }

  const verdict: Verdict = results.some((r) => r.outcome === "blocked")
    ? "blocked"
    : results.some((r) => r.outcome === "warn")
      ? "warn"
      : "safe";

  return { results, verdict };
}

/** The guards that actually blocked, for the confirmation screen. */
export function blockingGuards(results: GuardResult[]): GuardResult[] {
  return results.filter((r) => r.outcome === "blocked");
}

/**
 * What the user may do next. Append-only is always available: it completes the
 * import as a pure append, adding and updating without retiring anything, and
 * v3 section 4.1 requires it to be a single click.
 */
export function availableDecisions(results: GuardResult[]): {
  canConfirm: boolean;
  canOverride: GuardId[];
  appendOnlyAvailable: true;
} {
  const blocked = blockingGuards(results);
  const nonOverridable = blocked.filter((r) => !r.overridable);
  return {
    canConfirm: blocked.length === 0,
    canOverride: nonOverridable.length > 0 ? [] : blocked.map((r) => r.id),
    appendOnlyAvailable: true,
  };
}

/** Up to 50 examples for the confirmation screen (v3 section 4.2). */
export function retireKeySample<T>(items: T[], limit = 50): T[] {
  return items.slice(0, limit);
}

/** Retirements per month, so the user sees the shape rather than a number. */
export function retireDateHistogram(dates: string[]): Record<string, number> {
  const histogram: Record<string, number> = {};
  for (const date of dates) {
    const month = date.slice(0, 7);
    histogram[month] = (histogram[month] ?? 0) + 1;
  }
  return histogram;
}
