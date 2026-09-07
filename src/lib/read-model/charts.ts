import type { SupabaseClient } from "@supabase/supabase-js";

import { toInt, toNumber } from "./format";

/**
 * The body and recovery chart read model (Phase 7).
 *
 * Charts read `metric_daily` and nothing else. The canonical `metrics` table is
 * never queried from here: the analytics layer exists to answer "what was this
 * metric's value on this day", and a chart that fell back to canonical rows
 * would be a second answer to that question, differing from the first exactly
 * when it mattered.
 *
 * Reads only, no user id parameter, row level security scopes every call —
 * the same shape as the Phase 4 and Phase 5 read models.
 */

type Row = Record<string, unknown>;

export type ReadResult<T> = { data: T; error: null } | { data: null; error: string };

const ok = <T,>(data: T): ReadResult<T> => ({ data, error: null });
const fail = <T,>(message: string): ReadResult<T> => ({ data: null, error: message });

// ---------------------------------------------------------------------------
// Ranges
// ---------------------------------------------------------------------------

export const CHART_RANGES = ["7D", "30D", "90D", "1Y", "ALL"] as const;
export type ChartRange = (typeof CHART_RANGES)[number];

export const DEFAULT_CHART_RANGE: ChartRange = "90D";

/**
 * How many days each fixed range covers, inclusive of today.
 *
 * 1Y is 365 days rather than a calendar year so every range is a fixed number
 * of days and a leap year does not silently change what "1Y" means between two
 * runs of the same query.
 */
export const RANGE_DAYS: Record<Exclude<ChartRange, "ALL">, number> = {
  "7D": 7,
  "30D": 30,
  "90D": 90,
  "1Y": 365,
};

export const RANGE_LABEL: Record<ChartRange, string> = {
  "7D": "7 days",
  "30D": "30 days",
  "90D": "90 days",
  "1Y": "1 year",
  ALL: "All time",
};

export function isChartRange(value: unknown): value is ChartRange {
  return typeof value === "string" && (CHART_RANGES as readonly string[]).includes(value);
}

export function parseChartRange(value: unknown): ChartRange {
  return isChartRange(value) ? value : DEFAULT_CHART_RANGE;
}

/** An ISO date (YYYY-MM-DD), which is the form `local_date` takes everywhere. */
export type IsoDate = string;

export function toIsoDate(date: Date): IsoDate {
  const y = date.getUTCFullYear();
  const m = `${date.getUTCMonth() + 1}`.padStart(2, "0");
  const d = `${date.getUTCDate()}`.padStart(2, "0");
  return `${y}-${m}-${d}`;
}

export function addDays(date: IsoDate, days: number): IsoDate {
  const parsed = new Date(`${date}T00:00:00Z`);
  parsed.setUTCDate(parsed.getUTCDate() + days);
  return toIsoDate(parsed);
}

export type ResolvedRange = { range: ChartRange; from: IsoDate; to: IsoDate };

/**
 * Turns a range name into two concrete dates.
 *
 * Anchored on today, not on the last observation. A "7 days" chart that
 * silently showed a week from a month ago because that is where the data
 * happens to be would be answering a question nobody asked; a person looking at
 * the last seven days is entitled to see that they recorded nothing in them.
 *
 * `earliest` is where an all-time range starts, and comes from
 * `body_metric_bounds`. When a metric has no history at all, an all-time range
 * collapses to today and the series is empty, which the page renders as an
 * empty state rather than a flat line.
 */
export function resolveRange(
  range: ChartRange,
  today: IsoDate,
  earliest: IsoDate | null,
): ResolvedRange {
  if (range === "ALL") {
    const from = earliest && earliest < today ? earliest : today;
    return { range, from, to: today };
  }
  return { range, from: addDays(today, -(RANGE_DAYS[range] - 1)), to: today };
}

// ---------------------------------------------------------------------------
// The observation gate
// ---------------------------------------------------------------------------

/**
 * Below this many observations in the window, a change or a trend is not shown.
 *
 * THIS IS AN IMPLEMENTATION DECISION, NOT AN ARCHITECTURE-DEFINED THRESHOLD.
 * No authoritative document states a value. v2 §12 Phase 9 and v3 §5 Phase 9
 * put minimum-N gates and `INSUFFICIENT_DATA` in a later phase and specify
 * neither number; `CLAUDE.md` Phase 7 requires "minimum-observation checks"
 * without one. Three is taken from this repository's own precedent —
 * `MIN_PROGRESSION_SESSIONS` in the Phase 4 training read model, which refuses
 * to draw a progression through fewer than three sessions for the same reason.
 *
 * It is passed to `body_metric_summary` rather than duplicated in SQL, so
 * changing it here changes it everywhere, and the database refuses to compute
 * a change below it rather than trusting every caller to hide one.
 */
export const MIN_CHART_OBSERVATIONS = 3;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type GapPolicy = "zero" | "carry_forward" | "null";

export type SeriesPoint = {
  localDate: IsoDate;
  /** NULL where the gap policy is `null` and the day has no measurement. */
  value: number | null;
  /** True when this day carries a real measurement. */
  observed: boolean;
  /** True when the value was produced by the gap policy, not measured. */
  filled: boolean;
};

export type MetricSummary = {
  metricKey: string;
  observationCount: number;
  firstDate: IsoDate | null;
  firstValue: number | null;
  lastDate: IsoDate | null;
  lastValue: number | null;
  minValue: number | null;
  maxValue: number | null;
  meanValue: number | null;
  /** The observation gate. False means no change or trend may be shown. */
  sufficient: boolean;
  /** NULL below the gate. */
  changeAbsolute: number | null;
  /** NULL below the gate, and NULL when the baseline is zero. */
  changePercent: number | null;
};

export type MetricBounds = {
  metricKey: string;
  firstDate: IsoDate | null;
  lastDate: IsoDate | null;
  observationCount: number;
};

/** One metric's chart, ready to render or ready to explain why it is not one. */
export type MetricChart = {
  metricKey: string;
  displayName: string;
  unit: string;
  gapPolicy: GapPolicy;
  series: SeriesPoint[];
  summary: MetricSummary;
} & (
  | { chartable: true }
  | { chartable: false; reason: string }
);

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

export async function getMetricBounds(
  supabase: SupabaseClient,
  metricKeys: string[],
): Promise<ReadResult<MetricBounds[]>> {
  if (metricKeys.length === 0) return ok([]);
  const { data, error } = await supabase.rpc("body_metric_bounds", {
    p_metric_keys: metricKeys,
  });
  if (error) return fail(error.message);

  return ok(
    ((data ?? []) as Row[]).map((row) => ({
      metricKey: row.metric_key as string,
      firstDate: (row.first_date as string | null) ?? null,
      lastDate: (row.last_date as string | null) ?? null,
      observationCount: toInt(row.observation_count),
    })),
  );
}

export async function getMetricSeries(
  supabase: SupabaseClient,
  metricKeys: string[],
  from: IsoDate,
  to: IsoDate,
): Promise<ReadResult<Map<string, SeriesPoint[]>>> {
  if (metricKeys.length === 0) return ok(new Map());
  const { data, error } = await supabase.rpc("body_metric_series", {
    p_metric_keys: metricKeys,
    p_from: from,
    p_to: to,
  });
  if (error) return fail(error.message);

  const byMetric = new Map<string, SeriesPoint[]>();
  for (const key of metricKeys) byMetric.set(key, []);
  for (const row of (data ?? []) as Row[]) {
    const key = row.metric_key as string;
    const points = byMetric.get(key);
    if (!points) continue;
    points.push({
      localDate: row.local_date as string,
      value: toNumber(row.value),
      observed: row.observed === true,
      filled: row.filled === true,
    });
  }
  return ok(byMetric);
}

export async function getMetricSummaries(
  supabase: SupabaseClient,
  metricKeys: string[],
  from: IsoDate,
  to: IsoDate,
  minObservations = MIN_CHART_OBSERVATIONS,
): Promise<ReadResult<Map<string, MetricSummary>>> {
  if (metricKeys.length === 0) return ok(new Map());
  const { data, error } = await supabase.rpc("body_metric_summary", {
    p_metric_keys: metricKeys,
    p_from: from,
    p_to: to,
    p_min_observations: minObservations,
  });
  if (error) return fail(error.message);

  const byMetric = new Map<string, MetricSummary>();
  for (const row of (data ?? []) as Row[]) {
    byMetric.set(row.metric_key as string, {
      metricKey: row.metric_key as string,
      observationCount: toInt(row.observation_count),
      firstDate: (row.first_date as string | null) ?? null,
      firstValue: toNumber(row.first_value),
      lastDate: (row.last_date as string | null) ?? null,
      lastValue: toNumber(row.last_value),
      minValue: toNumber(row.min_value),
      maxValue: toNumber(row.max_value),
      meanValue: toNumber(row.mean_value),
      sufficient: row.sufficient === true,
      changeAbsolute: toNumber(row.change_absolute),
      changePercent: toNumber(row.change_percent),
    });
  }
  return ok(byMetric);
}

// ---------------------------------------------------------------------------
// Assembly
// ---------------------------------------------------------------------------

/**
 * Why a metric is not chartable in this window, in the person's terms.
 *
 * Separate from the gate itself so the reason can be specific: "you have not
 * recorded this" and "you have recorded this twice" are different situations
 * and deserve different sentences.
 */
export function chartRefusal(
  summary: MetricSummary,
  rangeLabel: string,
  minObservations = MIN_CHART_OBSERVATIONS,
): string | null {
  if (summary.observationCount === 0) {
    return `No ${rangeLabel.toLowerCase()} of this measurement has been recorded.`;
  }
  if (summary.observationCount < minObservations) {
    return `${summary.observationCount} ${
      summary.observationCount === 1 ? "measurement" : "measurements"
    } in this range. A trend needs at least ${minObservations}.`;
  }
  return null;
}

export function buildMetricChart(
  metric: { key: string; displayName: string; unit: string; gapPolicy: GapPolicy },
  series: SeriesPoint[],
  summary: MetricSummary,
  rangeLabel: string,
  minObservations = MIN_CHART_OBSERVATIONS,
): MetricChart {
  const base = {
    metricKey: metric.key,
    displayName: metric.displayName,
    unit: metric.unit,
    gapPolicy: metric.gapPolicy,
    series,
    summary,
  };
  const reason = chartRefusal(summary, rangeLabel, minObservations);
  return reason === null ? { ...base, chartable: true } : { ...base, chartable: false, reason };
}

/**
 * The metrics a person can chart, and how each one should be drawn.
 *
 * Registry-driven, exactly as Phase 6's entry form is. `manual_entry` is the
 * property that distinguishes a measurement from an aggregation the system
 * computes, and a hard-coded list of six keys in the UI is the free-text
 * identifier I-6 exists to forbid.
 *
 * Ordered by how much of it the person has, then by name: the measurement you
 * track most is the one you opened the page to see. Metrics with no history at
 * all are returned last and render as an empty state rather than being hidden,
 * so the page says what could be tracked instead of silently offering nothing.
 */
export type ChartableMetric = {
  key: string;
  displayName: string;
  description: string | null;
  unit: string;
  gapPolicy: GapPolicy;
};

export async function getChartableMetrics(
  supabase: SupabaseClient,
): Promise<ReadResult<ChartableMetric[]>> {
  const [definitions, units] = await Promise.all([
    supabase
      .from("metric_definitions")
      .select("key, display_name, description, canonical_unit_id, gap_policy")
      .eq("manual_entry", true)
      .eq("is_active", true)
      .order("display_name"),
    supabase.from("units").select("id, key"),
  ]);

  const error = definitions.error ?? units.error;
  if (error) return fail(error.message);

  const unitById = new Map((units.data ?? []).map((u) => [u.id as string, u.key as string]));

  return ok(
    (definitions.data ?? []).flatMap((definition) => {
      const unit = unitById.get(definition.canonical_unit_id as string);
      if (!unit) return [];
      return [
        {
          key: definition.key as string,
          displayName: definition.display_name as string,
          description: (definition.description as string | null) ?? null,
          unit,
          gapPolicy: definition.gap_policy as GapPolicy,
        },
      ];
    }),
  );
}

export type BodyCharts = {
  range: ResolvedRange;
  charts: MetricChart[];
  /** True when the account has no observations of any chartable metric. */
  empty: boolean;
};

/**
 * The whole chart surface for one range, in three round trips.
 *
 * Bounds first, because an all-time range cannot be resolved without them;
 * then the series and the summaries together, both scoped to the resolved
 * window. Six metrics do not become twelve queries.
 */
export async function getBodyCharts(
  supabase: SupabaseClient,
  range: ChartRange,
  today: IsoDate,
): Promise<ReadResult<BodyCharts>> {
  const metricsResult = await getChartableMetrics(supabase);
  if (metricsResult.error !== null) return fail(metricsResult.error);
  const metrics = metricsResult.data;
  const keys = metrics.map((m) => m.key);

  const boundsResult = await getMetricBounds(supabase, keys);
  if (boundsResult.error !== null) return fail(boundsResult.error);
  const bounds = new Map(boundsResult.data.map((b) => [b.metricKey, b]));

  const earliest = boundsResult.data
    .map((b) => b.firstDate)
    .filter((d): d is IsoDate => d !== null)
    .sort()[0];
  const resolved = resolveRange(range, today, earliest ?? null);

  const [seriesResult, summaryResult] = await Promise.all([
    getMetricSeries(supabase, keys, resolved.from, resolved.to),
    getMetricSummaries(supabase, keys, resolved.from, resolved.to),
  ]);
  if (seriesResult.error !== null) return fail(seriesResult.error);
  if (summaryResult.error !== null) return fail(summaryResult.error);

  const emptySummary = (key: string): MetricSummary => ({
    metricKey: key,
    observationCount: 0,
    firstDate: null,
    firstValue: null,
    lastDate: null,
    lastValue: null,
    minValue: null,
    maxValue: null,
    meanValue: null,
    sufficient: false,
    changeAbsolute: null,
    changePercent: null,
  });

  const charts = metrics
    .map((metric) =>
      buildMetricChart(
        metric,
        seriesResult.data.get(metric.key) ?? [],
        summaryResult.data.get(metric.key) ?? emptySummary(metric.key),
        RANGE_LABEL[range],
      ),
    )
    .sort((a, b) => {
      const lifetimeA = bounds.get(a.metricKey)?.observationCount ?? 0;
      const lifetimeB = bounds.get(b.metricKey)?.observationCount ?? 0;
      if (lifetimeA !== lifetimeB) return lifetimeB - lifetimeA;
      return a.displayName.localeCompare(b.displayName);
    });

  return ok({
    range: resolved,
    charts,
    empty: boundsResult.data.every((b) => b.observationCount === 0),
  });
}
