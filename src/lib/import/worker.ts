import type { SupabaseClient } from "@supabase/supabase-js";

import { parseCsv } from "./csv";
import { rowHash } from "./natural-key";
import {
  computeDerivedFields,
  DERIVED_KEY,
  normalize,
  NORMALIZE_VERSION,
  NormalizeError,
} from "./normalize";
import {
  evaluateGuards,
  retireDateHistogram,
  retireKeySample,
  retireRatio,
  type ReconciliationInput,
} from "./reconciliation";
import { mappingSpecSchema, type MappingSpec, type RegistrySnapshot } from "./types";

/**
 * The worker (v2 section 1.3, ADR-22).
 *
 * A pure function over (job, batch): every stage takes a job row, does one
 * checkpointed batch of work, writes its cursor and returns. Where it runs is a
 * deployment detail, so lifting it from a cron route to a long-running
 * container later needs no rewrite.
 *
 * It runs on an elevated connection because normalization is the sanctioned
 * canonical write path and the client roles hold SELECT only (I-4, RD-3).
 *
 * Nothing here branches on a vendor. Stages branch on job.stage and the
 * normalizer branches on template (I-9).
 */

export const INGEST_CHUNK_ROWS = 500;
export const NORMALIZE_BATCH_ROWS = 500;

export type JobRow = {
  id: string;
  user_id: string;
  import_id: string;
  stage: "ingest" | "normalize" | "retire" | "rollup" | "derive" | "timeline" | "insights";
  state: string;
  cursor: Record<string, unknown>;
  attempts: number;
};

export type BatchOutcome = {
  jobId: string;
  stage: JobRow["stage"];
  state: "running" | "done" | "failed";
  processed: number;
  cursor: Record<string, unknown>;
  message: string;
};

type Db = SupabaseClient;

async function loadImport(db: Db, importId: string) {
  const { data, error } = await db.from("data_imports").select("*").eq("id", importId).single();
  if (error) throw new Error(`import ${importId}: ${error.message}`);
  return data;
}

function mappingSpecOf(record: { mapping_spec_snapshot: unknown }): MappingSpec {
  const parsed = mappingSpecSchema.safeParse(record.mapping_spec_snapshot);
  if (!parsed.success) {
    throw new Error(
      `frozen mapping spec is invalid: ${parsed.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; ")}`,
    );
  }
  return parsed.data;
}

export async function downloadImportFile(db: Db, storagePath: string): Promise<string> {
  const { data, error } = await db.storage.from("imports").download(storagePath);
  if (error || !data) throw new Error(`cannot read ${storagePath}: ${error?.message ?? "no data"}`);
  return await data.text();
}

/**
 * The registry snapshot, read once per batch and passed into normalization so
 * the normalizer itself performs no database reads (I-3).
 */
export async function loadRegistrySnapshot(db: Db, userId: string): Promise<RegistrySnapshot> {
  const [definitions, aliases, units, conversions] = await Promise.all([
    db.from("exercise_definitions").select("id, key, user_id").or(`user_id.is.null,user_id.eq.${userId}`),
    db.from("exercise_aliases").select("alias_normalized, exercise_definition_id, user_id").or(`user_id.is.null,user_id.eq.${userId}`),
    db.from("units").select("id, key, dimension, user_id").or(`user_id.is.null,user_id.eq.${userId}`),
    db.from("unit_conversions").select("from_unit_id, to_unit_id, factor, offset, user_id").or(`user_id.is.null,user_id.eq.${userId}`),
  ]);

  for (const result of [definitions, aliases, units, conversions]) {
    if (result.error) throw new Error(`registry snapshot: ${result.error.message}`);
  }

  const unitById = new Map<string, { id: string; key: string; dimension: string }>();
  const unitByKey = new Map<string, { id: string; key: string; dimension: string }>();
  for (const unit of units.data ?? []) {
    const entry = { id: unit.id as string, key: unit.key as string, dimension: unit.dimension as string };
    unitById.set(entry.id, entry);
    unitByKey.set(entry.key, entry);
  }

  const unitConversions = new Map<string, { factor: string; offset: string }>();
  for (const row of conversions.data ?? []) {
    const from = unitById.get(row.from_unit_id as string);
    const to = unitById.get(row.to_unit_id as string);
    if (from && to) {
      unitConversions.set(`${from.key}->${to.key}`, {
        factor: String(row.factor),
        offset: String(row.offset),
      });
    }
  }

  return {
    exerciseDefinitions: new Map(
      (definitions.data ?? []).map((d) => [d.id as string, { id: d.id as string, key: d.key as string }]),
    ),
    exerciseAliases: new Map(
      (aliases.data ?? []).map((a) => [a.alias_normalized as string, a.exercise_definition_id as string]),
    ),
    metricAliases: new Map(),
    metricDefinitions: new Map(),
    units: unitByKey,
    unitConversions,
  };
}

async function setJob(db: Db, jobId: string, patch: Record<string, unknown>) {
  const { error } = await db.from("import_jobs").update(patch).eq("id", jobId);
  if (error) throw new Error(`job ${jobId}: ${error.message}`);
}

async function setImport(db: Db, importId: string, patch: Record<string, unknown>) {
  const { error } = await db.from("data_imports").update(patch).eq("id", importId);
  if (error) throw new Error(`import ${importId}: ${error.message}`);
}

async function enqueue(db: Db, job: JobRow, stage: JobRow["stage"]) {
  const { error } = await db.from("import_jobs").insert({
    user_id: job.user_id,
    import_id: job.import_id,
    stage,
    state: "queued",
    cursor: {},
  });
  if (error) throw new Error(`enqueue ${stage}: ${error.message}`);
}

// ---------------------------------------------------------------------------
// Stage A: ingest. File -> raw_records, in checkpointed chunks.
// ---------------------------------------------------------------------------

async function runIngest(db: Db, job: JobRow): Promise<BatchOutcome> {
  const record = await loadImport(db, job.import_id);
  const spec = mappingSpecOf(record);

  if (!record.storage_path) throw new Error("import has no storage_path");
  const text = await downloadImportFile(db, record.storage_path as string);
  const parsed = parseCsv(text);
  const derived = computeDerivedFields(spec, parsed.rows);

  const lastRow = Number(job.cursor.last_row ?? 0);
  const slice = parsed.rows.slice(lastRow, lastRow + INGEST_CHUNK_ROWS);

  if (slice.length > 0) {
    const payloads = slice.map((row, offset) => {
      const index = lastRow + offset;
      const payload = { ...row, [DERIVED_KEY]: derived[index] ?? {} };
      return {
        user_id: job.user_id,
        import_id: job.import_id,
        source_key: record.source_key,
        row_number: index + 1,
        payload,
        // The hash covers the source row only, not the derived block: two
        // identical source rows are duplicates whatever ordinal they were given.
        row_hash: rowHash(row),
        precedence_rank: 0,
        granularity: "row",
        normalize_status: "pending",
      };
    });

    // The unique index on (import_id, row_hash) makes chunk replay idempotent
    // (v2 section 5.2), so a re-invocation after a worker kill cannot duplicate.
    const { error } = await db.from("raw_records").upsert(payloads, {
      onConflict: "import_id,row_hash",
      ignoreDuplicates: true,
    });
    if (error) throw new Error(`ingest chunk at row ${lastRow}: ${error.message}`);
  }

  const nextRow = lastRow + slice.length;
  const finished = nextRow >= parsed.rows.length;

  await setImport(db, job.import_id, {
    rows_total: parsed.rows.length,
    rows_ingested: nextRow,
    status: finished ? "normalizing" : "ingesting",
  });

  if (finished) {
    await setJob(db, job.id, { state: "done", finished_at: new Date().toISOString(), cursor: { last_row: nextRow } });
    await enqueue(db, job, "normalize");
  } else {
    await setJob(db, job.id, { cursor: { last_row: nextRow }, heartbeat_at: new Date().toISOString() });
  }

  return {
    jobId: job.id,
    stage: "ingest",
    state: finished ? "done" : "running",
    processed: slice.length,
    cursor: { last_row: nextRow },
    message: `ingested ${nextRow} of ${parsed.rows.length} rows`,
  };
}

// ---------------------------------------------------------------------------
// Stage B: normalize. raw_records -> canonical rows, in checkpointed batches.
// ---------------------------------------------------------------------------

async function runNormalize(db: Db, job: JobRow): Promise<BatchOutcome> {
  const record = await loadImport(db, job.import_id);
  const spec = mappingSpecOf(record);
  const registry = await loadRegistrySnapshot(db, job.user_id);

  const lastRawId = Number(job.cursor.last_raw_id ?? 0);
  const { data: rawRecords, error } = await db
    .from("raw_records")
    .select("id, user_id, source_key, payload")
    .eq("import_id", job.import_id)
    .eq("normalize_status", "pending")
    .gt("id", lastRawId)
    .order("id", { ascending: true })
    .limit(NORMALIZE_BATCH_ROWS);
  if (error) throw new Error(`normalize read: ${error.message}`);

  let added = 0;
  let updated = 0;
  let unchanged = 0;
  let invalid = 0;
  let cursor = lastRawId;

  for (const raw of rawRecords ?? []) {
    cursor = raw.id as number;
    try {
      const result = normalize(
        {
          id: raw.id as number,
          userId: raw.user_id as string,
          sourceKey: raw.source_key as string,
          payload: raw.payload as Record<string, unknown>,
        },
        spec,
        registry,
        NORMALIZE_VERSION,
      );

      for (const workout of result.workouts) {
        const { data: wk, error: wkError } = await db.rpc("import_upsert_strength_workout", {
          p_user_id: raw.user_id,
          p_natural_key: workout.naturalKey,
          p_start_utc: workout.startUtc,
          p_tz_offset_minutes: workout.tzOffsetMinutes,
          p_local_date: workout.localDate,
          p_duration_s: workout.durationS,
          p_title: workout.title,
          p_source_key: record.source_key,
          p_external_id: workout.externalId,
          p_raw_record_id: raw.id,
          p_import_id: job.import_id,
        });
        if (wkError) throw new Error(wkError.message);
        const row = Array.isArray(wk) ? wk[0] : wk;
        const workoutId = row.workout_id as string;

        for (const exercise of result.exercises) {
          const { data: exerciseId, error: exError } = await db.rpc("import_upsert_strength_exercise", {
            p_user_id: raw.user_id,
            p_workout_id: workoutId,
            p_exercise_definition_id: exercise.exerciseDefinitionId,
            p_exercise_name_raw: exercise.exerciseNameRaw,
            p_order_index: exercise.orderIndex,
            p_raw_record_id: raw.id,
            p_import_id: job.import_id,
          });
          if (exError) throw new Error(exError.message);

          for (const set of result.sets) {
            const { data: outcome, error: setError } = await db.rpc("import_upsert_strength_set", {
              p_user_id: raw.user_id,
              p_natural_key: set.naturalKey,
              p_exercise_id: exerciseId,
              p_set_number: set.setNumber,
              p_set_type: set.setType,
              p_weight_kg: set.weightKg,
              p_reps: set.reps,
              p_rpe: set.rpe,
              p_duration_s: set.durationS,
              p_distance_m: set.distanceM,
              p_raw_record_id: raw.id,
            });
            if (setError) throw new Error(setError.message);
            if (outcome === "added") added += 1;
            else if (outcome === "updated") updated += 1;
            else unchanged += 1;
          }
        }
      }

      await db
        .from("raw_records")
        .update({
          processed_at: new Date().toISOString(),
          normalize_version: NORMALIZE_VERSION,
          normalize_status: "ok",
          normalize_error: null,
          normalized_keys: result.naturalKeys,
        })
        .eq("id", raw.id);
    } catch (cause) {
      // v2 section 4.2 step 6: an invalid row is retained in raw and reported,
      // never dropped, so a mapping fix plus a re-normalize needs no re-upload.
      invalid += 1;
      const message = cause instanceof NormalizeError ? cause.message : String(cause);
      await db
        .from("raw_records")
        .update({
          processed_at: new Date().toISOString(),
          normalize_version: NORMALIZE_VERSION,
          normalize_status: "invalid",
          normalize_error: message.slice(0, 2000),
        })
        .eq("id", raw.id);
    }
  }

  const finished = (rawRecords ?? []).length < NORMALIZE_BATCH_ROWS;

  await setImport(db, job.import_id, {
    records_added: (record.records_added ?? 0) + added,
    records_updated: (record.records_updated ?? 0) + updated,
    duplicates_skipped: (record.duplicates_skipped ?? 0) + unchanged,
    records_invalid: (record.records_invalid ?? 0) + invalid,
  });

  if (!finished) {
    await setJob(db, job.id, { cursor: { last_raw_id: cursor }, heartbeat_at: new Date().toISOString() });
    return {
      jobId: job.id,
      stage: "normalize",
      state: "running",
      processed: (rawRecords ?? []).length,
      cursor: { last_raw_id: cursor },
      message: `normalized a batch of ${(rawRecords ?? []).length}`,
    };
  }

  await setJob(db, job.id, { state: "done", finished_at: new Date().toISOString(), cursor: { last_raw_id: cursor } });

  if (record.import_mode === "full_snapshot") {
    await setImport(db, job.import_id, { status: "planning_reconciliation" });
    await enqueue(db, job, "retire");
  } else {
    await finishImport(db, job.import_id);
  }

  return {
    jobId: job.id,
    stage: "normalize",
    state: "done",
    processed: (rawRecords ?? []).length,
    cursor: { last_raw_id: cursor },
    message: `normalize complete: ${added} added, ${updated} updated, ${unchanged} unchanged, ${invalid} invalid`,
  };
}

// ---------------------------------------------------------------------------
// Stage C: retire. Computes a plan, persists it, and HALTS (v3 section 4.1).
// Nothing is retired here. Nothing is retired anywhere without a human.
// ---------------------------------------------------------------------------

async function runRetire(db: Db, job: JobRow): Promise<BatchOutcome> {
  const record = await loadImport(db, job.import_id);

  const { data: keyRows, error: keyError } = await db
    .from("raw_records")
    .select("normalized_keys")
    .eq("import_id", job.import_id)
    .eq("normalize_status", "ok");
  if (keyError) throw new Error(`retire: ${keyError.message}`);

  const incomingKeys = [...new Set((keyRows ?? []).flatMap((r) => (r.normalized_keys as string[]) ?? []))];

  // v2 section 7.4: derive_from_file uses the min and max local_date OBSERVED
  // IN THE FILE, which is what stops a partial export wiping history outside
  // its own range. It must therefore be derived from the keys this file
  // produced, not from which rows happen to carry this import_id: a re-import
  // whose rows are all unchanged stamps no import_id at all, and deriving the
  // span from it would silently skip reconciliation altogether.
  const { data: span, error: spanError } = await db
    .from("strength_workouts")
    .select("local_date")
    .eq("user_id", job.user_id)
    .in("natural_key", incomingKeys)
    .order("local_date", { ascending: true });
  if (spanError) throw new Error(`retire span: ${spanError.message}`);

  const dates = (span ?? []).map((r) => r.local_date as string);
  const fileDateFrom = dates[0] ?? null;
  const fileDateTo = dates[dates.length - 1] ?? null;

  if (!fileDateFrom || !fileDateTo) {
    await setJob(db, job.id, { state: "done", finished_at: new Date().toISOString() });
    await finishImport(db, job.import_id);
    return {
      jobId: job.id, stage: "retire", state: "done", processed: 0, cursor: {},
      message: "no rows in scope; nothing to reconcile",
    };
  }

  const { data: scopeJson, error: scopeError } = await db.rpc("import_reconciliation_scope", {
    p_user_id: job.user_id,
    p_source_key: record.source_key,
    p_date_from: fileDateFrom,
    p_date_to: fileDateTo,
    p_incoming_keys: incomingKeys,
  });
  if (scopeError) throw new Error(`retire scope: ${scopeError.message}`);
  const scope = scopeJson as Record<string, unknown>;

  const retireKeys = (scope.retire_keys as string[]) ?? [];
  const retireDates = (scope.retire_dates as string[]) ?? [];

  const guardInput: ReconciliationInput = {
    hadFatalErrors: false,
    rowsTotal: Number(record.rows_total ?? 0),
    recordsInvalid: Number(record.records_invalid ?? 0),
    validRowCount: Number(record.rows_total ?? 0) - Number(record.records_invalid ?? 0),
    addCount: Number(record.records_added ?? 0),
    updateCount: Number(record.records_updated ?? 0),
    unchangedCount: Number(record.duplicates_skipped ?? 0),
    retireCount: retireKeys.length,
    existingInScopeCount: Number(scope.existing_in_scope_count ?? 0),
    incomingInScopeCount: Number(scope.incoming_in_scope_count ?? 0),
    fileDateFrom,
    fileDateTo,
    existingDateFrom: (scope.existing_date_from as string | null) ?? null,
    existingDateTo: (scope.existing_date_to as string | null) ?? null,
    retirementsOutsideFileSpan: Number(scope.retirements_outside_file_span ?? 0),
    retirementsFromOtherSources: Number(scope.retirements_from_other_sources ?? 0),
    retirementsFromManual: Number(scope.retirements_from_manual ?? 0),
    reducedBucketsSkipped: 0,
  };

  const { results, verdict } = evaluateGuards(guardInput);

  const { error: planError } = await db.from("reconciliation_plans").insert({
    user_id: job.user_id,
    import_id: job.import_id,
    scope: {
      source_key: record.source_key,
      templates: [record.template],
      date_from: fileDateFrom,
      date_to: fileDateTo,
      metric_keys: null,
    },
    add_count: guardInput.addCount,
    update_count: guardInput.updateCount,
    unchanged_count: guardInput.unchangedCount,
    retire_count: retireKeys.length,
    existing_in_scope_count: guardInput.existingInScopeCount,
    retire_ratio: retireRatio(guardInput).toFixed(4),
    retire_key_sample: retireKeySample((scope.retire_sample as unknown[]) ?? []),
    retire_date_histogram: retireDateHistogram(retireDates),
    retire_natural_keys: retireKeys,
    guard_results: results,
    verdict,
  });
  if (planError) throw new Error(`persist plan: ${planError.message}`);

  await setJob(db, job.id, { state: "done", finished_at: new Date().toISOString() });

  // The retire stage halts here. It never retires.
  if (retireKeys.length === 0) {
    await finishImport(db, job.import_id);
    return {
      jobId: job.id, stage: "retire", state: "done", processed: 0, cursor: {},
      message: "plan persisted: nothing to retire",
    };
  }

  await setImport(db, job.import_id, { status: "awaiting_retirement_confirmation" });
  return {
    jobId: job.id,
    stage: "retire",
    state: "done",
    processed: retireKeys.length,
    cursor: {},
    message: `plan persisted with verdict ${verdict}: ${retireKeys.length} retirement candidates, awaiting confirmation`,
  };
}

async function finishImport(db: Db, importId: string) {
  const record = await loadImport(db, importId);
  await setImport(db, importId, {
    status: Number(record.records_invalid ?? 0) > 0 ? "completed_with_errors" : "completed",
    imported_at: record.imported_at ?? new Date().toISOString(),
  });
}

// ---------------------------------------------------------------------------
// The pure function over (job, batch).
// ---------------------------------------------------------------------------

export async function runJobBatch(db: Db, job: JobRow): Promise<BatchOutcome> {
  await setJob(db, job.id, {
    state: "running",
    started_at: new Date().toISOString(),
    heartbeat_at: new Date().toISOString(),
    attempts: job.attempts + 1,
  });

  try {
    switch (job.stage) {
      case "ingest":
        return await runIngest(db, job);
      case "normalize":
        return await runNormalize(db, job);
      case "retire":
        return await runRetire(db, job);
      default:
        await setJob(db, job.id, { state: "done", finished_at: new Date().toISOString() });
        return {
          jobId: job.id, stage: job.stage, state: "done", processed: 0, cursor: {},
          message: `stage ${job.stage} is not part of Phase 3`,
        };
    }
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause);
    // v2 section 5.3: retry with backoff, max five attempts.
    const exhausted = job.attempts + 1 >= 5;
    await setJob(db, job.id, {
      state: exhausted ? "failed" : "queued",
      last_error: message.slice(0, 2000),
      finished_at: exhausted ? new Date().toISOString() : null,
    });
    if (exhausted) await setImport(db, job.import_id, { status: "failed" });
    return { jobId: job.id, stage: job.stage, state: "failed", processed: 0, cursor: {}, message };
  }
}

/** Drains queued work. One batch per job per invocation, as a cron tick would. */
export async function drainJobs(db: Db, maxBatches = 200): Promise<BatchOutcome[]> {
  const outcomes: BatchOutcome[] = [];
  for (let i = 0; i < maxBatches; i += 1) {
    const { data, error } = await db
      .from("import_jobs")
      .select("id, user_id, import_id, stage, state, cursor, attempts")
      .in("state", ["queued", "running"])
      .order("created_at", { ascending: true })
      .limit(1);
    if (error) throw new Error(`drain: ${error.message}`);
    const job = (data ?? [])[0] as JobRow | undefined;
    if (!job) break;

    const outcome = await runJobBatch(db, job);
    outcomes.push(outcome);
    if (outcome.state === "failed") break;
  }
  return outcomes;
}
