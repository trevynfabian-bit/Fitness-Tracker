/**
 * The training read model (Phase 4, step 1).
 *
 * One place where "what a workout's volume is", "what counts as a session" and
 * "what an exercise's data can be compared on" are defined. The SQL functions
 * in 20260905090000_phase4_training_read_model.sql do the aggregation; this
 * module types them, coerces the wire format once, and derives the few things
 * that are genuinely presentation decisions.
 *
 * Rules this layer exists to keep:
 *
 *  - No UI component aggregates canonical data itself. If a screen needs a
 *    number, it comes from here.
 *  - Nothing takes a user id. The RPCs are SECURITY INVOKER over the
 *    security_invoker v_* views, so RLS scopes every read to the caller. There
 *    is no parameter with which to ask for someone else's data.
 *  - Read only. Phase 4 is a product layer; canonical rows are written by the
 *    import pipeline and by nothing else (I-1, I-4).
 */

import type { SupabaseClient } from "@supabase/supabase-js";

import { toInt, toNumber } from "./format";

export type ReadResult<T> = { data: T; error: null } | { data: null; error: string };

function ok<T>(data: T): ReadResult<T> {
  return { data, error: null };
}

function fail<T>(message: string): ReadResult<T> {
  return { data: null, error: message };
}

type Row = Record<string, unknown>;

/** How many workouts a history page shows. */
export const HISTORY_PAGE_SIZE = 25;
/** How many exercises the explorer shows per page. */
export const EXERCISE_PAGE_SIZE = 30;
/** How many weeks the dashboard charts cover. */
export const DASHBOARD_WEEKS = 12;
/** How many workouts the dashboard's recent-activity panel shows. */
export const RECENT_WORKOUT_COUNT = 5;
/**
 * Below this many sessions a progression line is a shape drawn through noise.
 * The UI says so rather than drawing it.
 */
export const MIN_PROGRESSION_SESSIONS = 3;

// ---------------------------------------------------------------------------
// Overview
// ---------------------------------------------------------------------------

export type TrainingOverview = {
  totalWorkouts: number;
  totalExerciseSlots: number;
  distinctExercises: number;
  totalSets: number;
  volumeSets: number;
  nonVolumeSets: number;
  totalVolumeKg: number | null;
  firstWorkoutDate: string | null;
  lastWorkoutDate: string | null;
  workoutsLast28Days: number;
  /** True when this user has imported nothing yet: the empty-state signal. */
  isEmpty: boolean;
};

function mapOverview(row: Row): TrainingOverview {
  const totalWorkouts = toInt(row.total_workouts);
  return {
    totalWorkouts,
    totalExerciseSlots: toInt(row.total_exercise_slots),
    distinctExercises: toInt(row.distinct_exercises),
    totalSets: toInt(row.total_sets),
    volumeSets: toInt(row.volume_sets),
    nonVolumeSets: toInt(row.non_volume_sets),
    totalVolumeKg: toNumber(row.total_volume_kg),
    firstWorkoutDate: (row.first_workout_date as string | null) ?? null,
    lastWorkoutDate: (row.last_workout_date as string | null) ?? null,
    workoutsLast28Days: toInt(row.workouts_last_28_days),
    isEmpty: totalWorkouts === 0,
  };
}

export async function getTrainingOverview(
  supabase: SupabaseClient,
): Promise<ReadResult<TrainingOverview>> {
  const { data, error } = await supabase.rpc("training_overview");
  if (error) return fail(error.message);
  const row = (Array.isArray(data) ? data[0] : data) as Row | undefined;
  if (!row) {
    return ok(
      mapOverview({
        total_workouts: 0,
        total_exercise_slots: 0,
        distinct_exercises: 0,
        total_sets: 0,
        volume_sets: 0,
        non_volume_sets: 0,
      }),
    );
  }
  return ok(mapOverview(row));
}

// ---------------------------------------------------------------------------
// Workout summaries
// ---------------------------------------------------------------------------

export type WorkoutSummary = {
  id: string;
  title: string | null;
  localDate: string;
  startUtc: string;
  durationS: number | null;
  sourceKey: string;
  exerciseCount: number;
  setCount: number;
  volumeSets: number;
  totalVolumeKg: number | null;
  totalReps: number | null;
};

export type WorkoutPage = {
  workouts: WorkoutSummary[];
  totalCount: number;
  offset: number;
  limit: number;
  hasPrevious: boolean;
  hasNext: boolean;
  pageIndex: number;
  pageCount: number;
};

function mapWorkoutSummary(row: Row): WorkoutSummary {
  return {
    id: row.id as string,
    title: (row.title as string | null) ?? null,
    localDate: row.local_date as string,
    startUtc: row.start_utc as string,
    durationS: toNumber(row.duration_s),
    sourceKey: row.source_key as string,
    exerciseCount: toInt(row.exercise_count),
    setCount: toInt(row.set_count),
    volumeSets: toInt(row.volume_sets),
    totalVolumeKg: toNumber(row.total_volume_kg),
    totalReps: toNumber(row.total_reps),
  };
}

export async function getWorkoutPage(
  supabase: SupabaseClient,
  options: {
    limit?: number;
    offset?: number;
    from?: string | null;
    to?: string | null;
    search?: string | null;
  } = {},
): Promise<ReadResult<WorkoutPage>> {
  const limit = Math.max(1, Math.min(options.limit ?? HISTORY_PAGE_SIZE, 100));
  const offset = Math.max(0, options.offset ?? 0);

  const { data, error } = await supabase.rpc("training_workout_summaries", {
    p_limit: limit,
    p_offset: offset,
    p_from: options.from ?? null,
    p_to: options.to ?? null,
    p_search: options.search ?? null,
  });
  if (error) return fail(error.message);

  const rows = (data ?? []) as Row[];
  // total_count rides on every row (count(*) over ()), so pagination never
  // costs a second query. An empty page carries no rows and therefore no
  // count, which is only reachable past the end of the result set.
  const first = rows[0];
  const totalCount = first ? toInt(first.total_count) : 0;
  const pageCount = Math.max(1, Math.ceil(totalCount / limit));

  return ok({
    workouts: rows.map(mapWorkoutSummary),
    totalCount,
    offset,
    limit,
    hasPrevious: offset > 0,
    hasNext: offset + rows.length < totalCount,
    pageIndex: Math.floor(offset / limit),
    pageCount,
  });
}

// ---------------------------------------------------------------------------
// Workout detail
// ---------------------------------------------------------------------------

export type WorkoutSet = {
  id: string;
  setNumber: number;
  setType: string | null;
  weightKg: number | null;
  reps: number | null;
  rpe: number | null;
  durationS: number | null;
  distanceM: number | null;
  volumeKg: number | null;
};

/**
 * has* flags come from the data, not from a vendor or a template name. An
 * exercise whose sets carry distance renders a distance table; one whose sets
 * carry load renders a load table. Nothing forces strength columns onto a
 * future cardio import.
 */
export type WorkoutExercise = {
  id: string;
  orderIndex: number;
  exerciseDefinitionId: string;
  displayName: string;
  definitionKey: string;
  nameRaw: string | null;
  hasLoad: boolean;
  hasReps: boolean;
  hasDistance: boolean;
  hasDuration: boolean;
  hasRpe: boolean;
  setCount: number;
  volumeKg: number | null;
  topWeightKg: number | null;
  sets: WorkoutSet[];
};

export type WorkoutDetail = {
  id: string;
  title: string | null;
  localDate: string;
  startUtc: string;
  durationS: number | null;
  sourceKey: string;
  importId: string | null;
  exercises: WorkoutExercise[];
  setCount: number;
  volumeSets: number;
  totalVolumeKg: number | null;
  totalReps: number | null;
};

function mapSet(row: Row): WorkoutSet {
  return {
    id: row.id as string,
    setNumber: toInt(row.set_number),
    setType: (row.set_type as string | null) ?? null,
    weightKg: toNumber(row.weight_kg),
    reps: toNumber(row.reps),
    rpe: toNumber(row.rpe),
    durationS: toNumber(row.duration_s),
    distanceM: toNumber(row.distance_m),
    volumeKg: toNumber(row.volume_kg),
  };
}

function mapExercise(row: Row): WorkoutExercise {
  const sets = ((row.sets as Row[] | null) ?? []).map(mapSet);
  return {
    id: row.id as string,
    orderIndex: toInt(row.order_index),
    exerciseDefinitionId: row.exercise_definition_id as string,
    displayName: row.display_name as string,
    definitionKey: row.definition_key as string,
    nameRaw: (row.name_raw as string | null) ?? null,
    hasLoad: row.has_load === true,
    hasReps: row.has_reps === true,
    hasDistance: row.has_distance === true,
    hasDuration: row.has_duration === true,
    hasRpe: row.has_rpe === true,
    setCount: toInt(row.set_count),
    volumeKg: toNumber(row.volume_kg),
    topWeightKg: toNumber(row.top_weight_kg),
    sets,
  };
}

export async function getWorkoutDetail(
  supabase: SupabaseClient,
  workoutId: string,
): Promise<ReadResult<WorkoutDetail | null>> {
  const { data, error } = await supabase.rpc("training_workout_detail", {
    p_workout_id: workoutId,
  });
  if (error) return fail(error.message);
  if (!data) return ok(null);

  const row = data as Row;
  const exercises = ((row.exercises as Row[] | null) ?? []).map(mapExercise);

  // Workout totals are folded from the exercise rows the same query returned:
  // one round trip, and the same volume rule (loaded sets only) as everywhere.
  let setCount = 0;
  let volumeSets = 0;
  let volume: number | null = null;
  let reps: number | null = null;
  for (const exercise of exercises) {
    setCount += exercise.setCount;
    for (const set of exercise.sets) {
      if (set.weightKg !== null && set.reps !== null) {
        volumeSets += 1;
        volume = (volume ?? 0) + (set.volumeKg ?? 0);
      }
      if (set.reps !== null) reps = (reps ?? 0) + set.reps;
    }
  }

  return ok({
    id: row.id as string,
    title: (row.title as string | null) ?? null,
    localDate: row.local_date as string,
    startUtc: row.start_utc as string,
    durationS: toNumber(row.duration_s),
    sourceKey: row.source_key as string,
    importId: (row.import_id as string | null) ?? null,
    exercises,
    setCount,
    volumeSets,
    totalVolumeKg: volume,
    totalReps: reps,
  });
}

// ---------------------------------------------------------------------------
// Weekly series
// ---------------------------------------------------------------------------

export type TrainingWeek = {
  weekStart: string;
  workoutCount: number;
  setCount: number;
  volumeSets: number;
  /** NULL when the week recorded no loaded set. Never coerced to zero. */
  volumeKg: number | null;
  totalReps: number | null;
};

export async function getWeeklySeries(
  supabase: SupabaseClient,
  weeks = DASHBOARD_WEEKS,
): Promise<ReadResult<TrainingWeek[]>> {
  const { data, error } = await supabase.rpc("training_weekly_series", {
    p_weeks: Math.max(1, Math.min(weeks, 260)),
  });
  if (error) return fail(error.message);
  return ok(
    ((data ?? []) as Row[]).map((row) => ({
      weekStart: row.week_start as string,
      workoutCount: toInt(row.workout_count),
      setCount: toInt(row.set_count),
      volumeSets: toInt(row.volume_sets),
      volumeKg: toNumber(row.volume_kg),
      totalReps: toNumber(row.total_reps),
    })),
  );
}

/**
 * Whether a volume trend can honestly be drawn. A single observed week is a
 * dot, not a trend, and a span with no loaded set at all is not a volume
 * series regardless of how many weeks it covers.
 */
export function volumeSeriesIsChartable(weeks: TrainingWeek[]): boolean {
  return weeks.filter((week) => week.volumeKg !== null).length >= 2;
}

// ---------------------------------------------------------------------------
// Exercise summaries
// ---------------------------------------------------------------------------

/** What an exercise's own data supports being compared on, over time. */
export type ProgressionKind = "load" | "distance" | "duration" | "reps" | "none";

export type ExerciseSummary = {
  exerciseDefinitionId: string;
  displayName: string;
  definitionKey: string;
  sessionCount: number;
  setCount: number;
  volumeSets: number;
  totalVolumeKg: number | null;
  topWeightKg: number | null;
  totalReps: number | null;
  firstPerformed: string | null;
  lastPerformed: string | null;
  progressionKind: ProgressionKind;
};

export type ExercisePage = {
  exercises: ExerciseSummary[];
  totalCount: number;
  offset: number;
  limit: number;
  hasPrevious: boolean;
  hasNext: boolean;
  pageIndex: number;
  pageCount: number;
};

function mapExerciseSummary(row: Row): ExerciseSummary {
  return {
    exerciseDefinitionId: row.exercise_definition_id as string,
    displayName: row.display_name as string,
    definitionKey: row.definition_key as string,
    sessionCount: toInt(row.session_count),
    setCount: toInt(row.set_count),
    volumeSets: toInt(row.volume_sets),
    totalVolumeKg: toNumber(row.total_volume_kg),
    topWeightKg: toNumber(row.top_weight_kg),
    totalReps: toNumber(row.total_reps),
    firstPerformed: (row.first_performed as string | null) ?? null,
    lastPerformed: (row.last_performed as string | null) ?? null,
    progressionKind: (row.progression_kind as ProgressionKind) ?? "none",
  };
}

export async function getExercisePage(
  supabase: SupabaseClient,
  options: { limit?: number; offset?: number; search?: string | null } = {},
): Promise<ReadResult<ExercisePage>> {
  const limit = Math.max(1, Math.min(options.limit ?? EXERCISE_PAGE_SIZE, 200));
  const offset = Math.max(0, options.offset ?? 0);

  const { data, error } = await supabase.rpc("training_exercise_summaries", {
    p_limit: limit,
    p_offset: offset,
    p_search: options.search ?? null,
  });
  if (error) return fail(error.message);

  const rows = (data ?? []) as Row[];
  const firstRow = rows[0];
  const totalCount = firstRow ? toInt(firstRow.total_count) : 0;

  return ok({
    exercises: rows.map(mapExerciseSummary),
    totalCount,
    offset,
    limit,
    hasPrevious: offset > 0,
    hasNext: offset + rows.length < totalCount,
    pageIndex: Math.floor(offset / limit),
    pageCount: Math.max(1, Math.ceil(totalCount / limit)),
  });
}

/**
 * One exercise by id, aggregated by the same rules as the explorer row so the
 * two never disagree. Returns null for an exercise the signed-in user has
 * never performed, which is also what another user's exercise looks like.
 */
export async function getExerciseSummary(
  supabase: SupabaseClient,
  exerciseDefinitionId: string,
): Promise<ReadResult<ExerciseSummary | null>> {
  const { data, error } = await supabase.rpc("training_exercise_detail", {
    p_exercise_definition_id: exerciseDefinitionId,
  });
  if (error) return fail(error.message);
  const row = (Array.isArray(data) ? data[0] : data) as Row | undefined;
  return ok(row ? mapExerciseSummary(row) : null);
}

// ---------------------------------------------------------------------------
// Exercise progression
// ---------------------------------------------------------------------------

export type ExerciseSession = {
  workoutId: string;
  workoutTitle: string | null;
  localDate: string;
  setCount: number;
  volumeSets: number;
  totalVolumeKg: number | null;
  topWeightKg: number | null;
  totalReps: number | null;
  totalDistanceM: number | null;
  totalDurationS: number | null;
  bestSetReps: number | null;
  bestSetWeight: number | null;
};

export async function getExerciseProgression(
  supabase: SupabaseClient,
  exerciseDefinitionId: string,
  limit = 60,
): Promise<ReadResult<ExerciseSession[]>> {
  const { data, error } = await supabase.rpc("training_exercise_progression", {
    p_exercise_definition_id: exerciseDefinitionId,
    p_limit: Math.max(1, Math.min(limit, 365)),
  });
  if (error) return fail(error.message);
  return ok(
    ((data ?? []) as Row[]).map((row) => ({
      workoutId: row.workout_id as string,
      workoutTitle: (row.workout_title as string | null) ?? null,
      localDate: row.local_date as string,
      setCount: toInt(row.set_count),
      volumeSets: toInt(row.volume_sets),
      totalVolumeKg: toNumber(row.total_volume_kg),
      topWeightKg: toNumber(row.top_weight_kg),
      totalReps: toNumber(row.total_reps),
      totalDistanceM: toNumber(row.total_distance_m),
      totalDurationS: toNumber(row.total_duration_s),
      bestSetReps: toNumber(row.best_set_reps),
      bestSetWeight: toNumber(row.best_set_weight),
    })),
  );
}

export type ProgressionPoint = { date: string; value: number };

export type ProgressionUnit = "kg" | "m" | "s" | "reps";

export type ProgressionTrack = {
  /** What the y axis measures, in words the reader will recognise. */
  metricLabel: string;
  unit: ProgressionUnit;
  points: ProgressionPoint[];
};

export type ProgressionSeries =
  | ({
      chartable: true;
      kind: ProgressionKind;
      /** A second series where the data supports one, on its own chart. */
      secondary: ProgressionTrack | null;
    } & ProgressionTrack)
  | { chartable: false; kind: ProgressionKind; reason: string };

/**
 * Turns sessions into the one series this exercise's data can honestly be
 * compared on, or refuses.
 *
 * This is the rule the phase brief asks for: a weighted set and a distance
 * interval do not share a progress chart. `progression_kind` is decided by the
 * database from the sets themselves, so a future non-strength template lands
 * here as 'distance' or 'duration' without any code here knowing what produced
 * it (I-9).
 */
export function buildProgressionSeries(
  kind: ProgressionKind,
  sessions: ExerciseSession[],
): ProgressionSeries {
  if (kind === "none") {
    return {
      chartable: false,
      kind,
      reason:
        "These sets record no load, distance, duration or rep count, so there is nothing to compare across sessions.",
    };
  }

  const pick = (
    read: (session: ExerciseSession) => number | null,
  ): ProgressionPoint[] =>
    sessions
      .map((session) => ({ date: session.localDate, value: read(session) }))
      .filter((point): point is ProgressionPoint => point.value !== null);

  let metricLabel: string;
  let unit: ProgressionUnit;
  let points: ProgressionPoint[];
  let secondary: ProgressionTrack | null = null;

  if (kind === "load") {
    metricLabel = "Heaviest set";
    unit = "kg";
    points = pick((session) => session.topWeightKg);
    const volume = pick((session) => session.totalVolumeKg);
    secondary =
      volume.length >= MIN_PROGRESSION_SESSIONS
        ? { metricLabel: "Session volume", unit: "kg", points: volume }
        : null;
  } else if (kind === "distance") {
    metricLabel = "Distance per session";
    unit = "m";
    points = pick((session) => session.totalDistanceM);
  } else if (kind === "duration") {
    metricLabel = "Time under load per session";
    unit = "s";
    points = pick((session) => session.totalDurationS);
  } else {
    metricLabel = "Reps per session";
    unit = "reps";
    points = pick((session) => session.totalReps);
  }

  if (points.length < MIN_PROGRESSION_SESSIONS) {
    return {
      chartable: false,
      kind,
      reason: `${points.length} of ${sessions.length} recorded ${
        sessions.length === 1 ? "session carries" : "sessions carry"
      } this measurement. A progression needs at least ${MIN_PROGRESSION_SESSIONS}.`,
    };
  }

  return { chartable: true, kind, metricLabel, unit, points, secondary };
}

/** How a progression kind reads in a badge on the explorer. */
export const PROGRESSION_KIND_LABEL: Record<ProgressionKind, string> = {
  load: "Load × reps",
  distance: "Distance",
  duration: "Duration",
  reps: "Reps only",
  none: "Not comparable",
};
