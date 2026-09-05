import type { SupabaseClient } from "@supabase/supabase-js";

/**
 * The analytics rollup, from the application's side (v2 section 9, ADR-19).
 *
 * This module is deliberately thin. The recomputation itself lives in SQL,
 * beside the canonical tables it reads, because it must be atomic per scope and
 * because a scope rebuilt in application code would be a second definition of
 * what a training metric is. What lives here is the plumbing: which days a
 * canonical change made dirty, and when to drain.
 *
 * It runs on the elevated connection, like normalization, because the rollup is
 * a privileged path and the client roles hold no privilege on the analytics
 * tables or on any of these functions (I-4, RD-3).
 *
 * Nothing here branches on a vendor (I-9). A day is dirty because canonical
 * rows for that day changed; where they came from is irrelevant.
 */

type Db = SupabaseClient;

/** How many scopes one worker invocation drains. */
export const ROLLUP_BATCH_SCOPES = 200;

/**
 * How long a claimed scope may sit before it is assumed abandoned.
 *
 * Long enough that a slow recompute is never stolen from a live worker, short
 * enough that a crashed one does not leave metrics stale for an hour.
 */
export const ROLLUP_STALE_CLAIM = "5 minutes";

export type RollupResult = {
  processed: number;
  failed: number;
  errors: { scope_id: number; user_id: string; local_date: string; attempts: number; error: string }[];
};

/**
 * Marks the days a canonical change touched.
 *
 * Idempotent and cheap, so callers enqueue defensively rather than reasoning
 * about what an earlier stage already did. An empty list is a no-op.
 */
export async function enqueueTrainingDays(
  db: Db,
  userId: string,
  dates: string[],
  reason: "import" | "retirement" | "rebuild",
): Promise<number> {
  const unique = [...new Set(dates.filter(Boolean))];
  if (unique.length === 0) return 0;

  const { data, error } = await db.rpc("rollup_enqueue_training_days", {
    p_user_id: userId,
    p_dates: unique,
    p_reason: reason,
  });
  if (error) throw new Error(`rollup enqueue: ${error.message}`);
  return Number(data ?? 0);
}

/**
 * The local dates a set of canonical workouts sit on.
 *
 * Takes natural keys rather than ids because that is what the import pipeline
 * knows: a re-import whose rows are all unchanged stamps no import_id on
 * anything, so asking "which rows carry this import_id" would find nothing
 * while the file still perfectly well determines which days it covered. This
 * is the same reasoning the retire stage uses to derive a file's date span.
 *
 * Retired workouts are included on purpose: a day whose workouts were just
 * retired is exactly a day whose metrics must be rebuilt.
 */
export async function daysForNaturalKeys(
  db: Db,
  userId: string,
  naturalKeys: string[],
): Promise<string[]> {
  if (naturalKeys.length === 0) return [];
  const dates = new Set<string>();

  // Chunked: a large import can produce more keys than one URL can carry.
  for (let i = 0; i < naturalKeys.length; i += 200) {
    const { data, error } = await db
      .from("strength_workouts")
      .select("local_date")
      .eq("user_id", userId)
      .in("natural_key", naturalKeys.slice(i, i + 200));
    if (error) throw new Error(`rollup scope: ${error.message}`);
    for (const row of data ?? []) dates.add(row.local_date as string);
  }

  return [...dates];
}

/** The days a set of workout ids sit on. Used after a retirement is applied. */
export async function daysForWorkoutIds(
  db: Db,
  userId: string,
  workoutIds: string[],
): Promise<string[]> {
  if (workoutIds.length === 0) return [];
  const dates = new Set<string>();
  for (let i = 0; i < workoutIds.length; i += 200) {
    const { data, error } = await db
      .from("strength_workouts")
      .select("local_date")
      .eq("user_id", userId)
      .in("id", workoutIds.slice(i, i + 200));
    if (error) throw new Error(`rollup scope: ${error.message}`);
    for (const row of data ?? []) dates.add(row.local_date as string);
  }
  return [...dates];
}

/**
 * Drains the queue.
 *
 * Reclaims abandoned claims first, so a worker that died mid-scope does not
 * leave that scope stranded. Recomputation is atomic and idempotent, so a
 * reclaimed scope needs no repair: running it again is the repair.
 */
export async function drainRollupQueue(
  db: Db,
  limit = ROLLUP_BATCH_SCOPES,
): Promise<RollupResult & { reclaimed: number }> {
  const { data: reclaimed, error: reclaimError } = await db.rpc("rollup_reclaim_stale", {
    p_older_than: ROLLUP_STALE_CLAIM,
  });
  if (reclaimError) throw new Error(`rollup reclaim: ${reclaimError.message}`);

  const { data, error } = await db.rpc("rollup_process_pending", {
    p_limit: limit,
    p_worker: "api/worker",
  });
  if (error) throw new Error(`rollup drain: ${error.message}`);

  const result = (data ?? { processed: 0, failed: 0, errors: [] }) as RollupResult;
  return { ...result, reclaimed: Number(reclaimed ?? 0) };
}
