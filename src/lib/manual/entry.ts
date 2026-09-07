import type { SupabaseClient } from "@supabase/supabase-js";

import { drainUserRollupQueue } from "@/lib/analytics/rollup";
import { rowHash } from "@/lib/import/natural-key";
import { NORMALIZE_VERSION } from "@/lib/import/normalize";
import { MANUAL_METRICS_PROFILE } from "@/lib/import/profiles";
import { drainImportJobs } from "@/lib/import/worker";

/**
 * Manual entry (v2 section 0.2, ADR-06, I-1).
 *
 * A typed measurement does not go into `metrics`. It becomes a synthetic
 * import and a raw record, and the ordinary normalizer turns that raw record
 * into the canonical row. There is no second write path, and no code here
 * knows what a metric means: it writes the payload the profile's mapping spec
 * describes and lets normalization do the rest.
 *
 * A correction is not an UPDATE either. It is another raw record, at a higher
 * precedence rank, naming the observation it supersedes. The canonical row
 * moves because the upsert prefers the higher-precedence origin — which is
 * also why replaying the raw layer in any order lands on the corrected value.
 *
 * This runs on the elevated connection because normalization is the sanctioned
 * canonical write path and the client roles hold SELECT only on raw_records and
 * the canonical tables (I-4, RD-3). The user id comes from the caller's
 * authenticated session and never from a request body.
 */

type Db = SupabaseClient;

export const MANUAL_SOURCE_KEY = "manual";
/** v2 section 4.3, ADR-07: 0 imported, 10 manual entry, 20 manual correction. */
export const PRECEDENCE_MANUAL_ENTRY = 10;
export const PRECEDENCE_MANUAL_CORRECTION = 20;

export type MeasurementInput = {
  metricKey: string;
  /** As the person typed it, in `unit`. Converted to canonical at normalize. */
  value: string;
  unit: string;
  /** ISO 8601 carrying an offset: the profile's timezone mode is 'embedded'. */
  measuredAt: string;
  qualifier?: string | null;
  /** Set to correct an existing observation, identified by its natural key. */
  supersedesNaturalKey?: string | null;
};

export type MeasurementResult = {
  importId: string;
  rawRecordIds: number[];
  added: number;
  updated: number;
  unchanged: number;
  invalid: number;
  errors: string[];
};

function payloadFor(measurement: MeasurementInput): Record<string, string> {
  return {
    metric_key: measurement.metricKey.trim(),
    value: measurement.value.trim(),
    unit: measurement.unit.trim(),
    measured_at: measurement.measuredAt,
    qualifier: (measurement.qualifier ?? "").trim(),
  };
}

/**
 * Records one submission of one or more measurements.
 *
 * One synthetic import per submission, one raw record per measurement: the
 * import is the act, the raw records are what was said in it.
 */
export async function recordMeasurements(
  db: Db,
  userId: string,
  measurements: MeasurementInput[],
): Promise<MeasurementResult> {
  if (measurements.length === 0) {
    throw new Error("a manual import must carry at least one measurement");
  }

  const importId = crypto.randomUUID();

  const { error: importError } = await db.from("data_imports").insert({
    id: importId,
    user_id: userId,
    source_key: MANUAL_SOURCE_KEY,
    template: MANUAL_METRICS_PROFILE.template,
    // No file. data_imports.storage_path is nullable and file_type allows
    // 'manual' precisely so a synthetic import is a first-class import rather
    // than a file import with holes in it.
    file_type: "manual",
    file_name: "manual entry",
    // Frozen at entry time, exactly as a file import freezes its own, so
    // editing the profile later cannot change what this entry meant.
    mapping_spec_snapshot: MANUAL_METRICS_PROFILE.mapping_spec,
    normalize_version: NORMALIZE_VERSION,
    import_mode: "append",
    status: "queued",
    rows_total: measurements.length,
    rows_ingested: measurements.length,
  });
  if (importError) throw new Error(`manual import: ${importError.message}`);

  const rows = measurements.map((measurement) => {
    const payload = payloadFor(measurement);
    const correcting = Boolean(measurement.supersedesNaturalKey);
    return {
      user_id: userId,
      import_id: importId,
      source_key: MANUAL_SOURCE_KEY,
      payload,
      row_hash: rowHash(payload),
      precedence_rank: correcting ? PRECEDENCE_MANUAL_CORRECTION : PRECEDENCE_MANUAL_ENTRY,
      supersedes_natural_key: measurement.supersedesNaturalKey ?? null,
    };
  });

  const { data: inserted, error: rawError } = await db
    .from("raw_records")
    .insert(rows)
    .select("id");
  if (rawError) throw new Error(`manual raw records: ${rawError.message}`);

  const { error: jobError } = await db.from("import_jobs").insert({
    user_id: userId,
    import_id: importId,
    stage: "normalize",
    state: "queued",
    cursor: {},
  });
  if (jobError) throw new Error(`manual normalize job: ${jobError.message}`);

  // Drained inline. The worker is a pure function over (job, batch) and where
  // it runs is a deployment detail; a one-row import has no reason to wait for
  // a cron tick, and the user gets to see what they just recorded.
  const outcomes = await drainImportJobs(db, importId);

  // And the analytics scopes normalization just marked dirty, for the same
  // reason: a measurement that is in the list but not yet on the chart reads
  // as a bug.
  //
  // This user's scopes only, and bounded. The queue is global; draining all of
  // it here would make one typed number wait on every other user's import
  // backlog, inside this person's request.
  //
  // A failure here must not fail the entry — the canonical row is already
  // written and correct, the scope stays dirty, and the next worker tick or
  // rebuild computes it (v2 §1.4).
  try {
    await drainUserRollupQueue(db, userId);
  } catch (cause) {
    console.error(
      `rollup drain after manual import ${importId}:`,
      cause instanceof Error ? cause.message : cause,
    );
  }

  const { data: record } = await db
    .from("data_imports")
    .select("records_added, records_updated, duplicates_skipped, records_invalid, error_log")
    .eq("id", importId)
    .single();

  return {
    importId,
    rawRecordIds: (inserted ?? []).map((row) => row.id as number),
    added: Number(record?.records_added ?? 0),
    updated: Number(record?.records_updated ?? 0),
    unchanged: Number(record?.duplicates_skipped ?? 0),
    invalid: Number(record?.records_invalid ?? 0),
    errors: outcomes.filter((o) => o.state === "failed").map((o) => o.message),
  };
}
