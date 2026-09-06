import type { SupabaseClient } from "@supabase/supabase-js";

import { toInt, toNumber } from "./format";

/**
 * The body-measurement read model (Phase 6).
 *
 * Reads only. Manual entry writes through the import pipeline like everything
 * else; this is what the screens read back afterwards, and like the training
 * read model it takes no user id — row level security scopes every read to the
 * caller.
 */

type Row = Record<string, unknown>;

export type ReadResult<T> = { data: T; error: null } | { data: null; error: string };

const ok = <T,>(data: T): ReadResult<T> => ({ data, error: null });
const fail = <T,>(message: string): ReadResult<T> => ({ data: null, error: message });

export const MEASUREMENT_PAGE_SIZE = 25;

/** A metric a person can meaningfully measure and type, per the registry. */
export type MeasurableMetric = {
  key: string;
  displayName: string;
  description: string | null;
  canonicalUnit: string;
  /** Units the value may be entered in: the canonical one and its dimension. */
  units: string[];
};

export type Measurement = {
  id: number;
  /** What a correction names. The client cannot write a metric row, but it can
   *  record a raw record that supersedes one, and this is how it says which. */
  naturalKey: string;
  metricKey: string;
  displayName: string;
  qualifier: string | null;
  timestampUtc: string;
  localDate: string;
  valueNum: number | null;
  unit: string;
  sourceValueNum: number | null;
  sourceUnit: string;
  revision: number;
  precedenceRank: number;
  /** The row in force came from a correction, not from the original entry. */
  corrected: boolean;
  recordedAt: string;
};

export type MeasurementPage = {
  measurements: Measurement[];
  totalCount: number;
  offset: number;
  limit: number;
  hasPrevious: boolean;
  hasNext: boolean;
};

function mapMeasurement(row: Row): Measurement {
  return {
    id: toInt(row.id),
    naturalKey: row.natural_key as string,
    metricKey: row.metric_key as string,
    displayName: row.display_name as string,
    qualifier: (row.qualifier as string | null) ?? null,
    timestampUtc: row.timestamp_utc as string,
    localDate: row.local_date as string,
    valueNum: toNumber(row.value_num),
    unit: row.unit as string,
    sourceValueNum: toNumber(row.source_value_num),
    sourceUnit: row.source_unit as string,
    revision: toInt(row.revision),
    precedenceRank: toInt(row.precedence_rank),
    corrected: row.corrected === true,
    recordedAt: row.recorded_at as string,
  };
}

export async function getMeasurements(
  supabase: SupabaseClient,
  options: { limit?: number; offset?: number; metricKey?: string | null } = {},
): Promise<ReadResult<MeasurementPage>> {
  const limit = Math.max(1, Math.min(options.limit ?? MEASUREMENT_PAGE_SIZE, 200));
  const offset = Math.max(0, options.offset ?? 0);

  const { data, error } = await supabase.rpc("body_measurements", {
    p_limit: limit,
    p_offset: offset,
    p_metric_key: options.metricKey ?? null,
  });
  if (error) return fail(error.message);

  const rows = (data ?? []) as Row[];
  const first = rows[0];
  const totalCount = first ? toInt(first.total_count) : 0;

  return ok({
    measurements: rows.map(mapMeasurement),
    totalCount,
    offset,
    limit,
    hasPrevious: offset > 0,
    hasNext: offset + rows.length < totalCount,
  });
}

/**
 * What may be recorded, and in what units.
 *
 * Both answers come from the registry: `manual_entry` says which metrics a
 * person can measure, and a unit is offered when it shares the canonical
 * unit's dimension, so a weight can be typed in kg or lb and never in seconds.
 * Neither is a list held in the UI.
 */
export async function getMeasurableMetrics(
  supabase: SupabaseClient,
): Promise<ReadResult<MeasurableMetric[]>> {
  const [definitions, units] = await Promise.all([
    supabase
      .from("metric_definitions")
      .select("key, display_name, description, canonical_unit_id")
      .eq("manual_entry", true)
      .eq("is_active", true)
      .order("display_name"),
    supabase.from("units").select("id, key, dimension"),
  ]);

  const error = definitions.error ?? units.error;
  if (error) return fail(error.message);

  const unitById = new Map(
    (units.data ?? []).map((u) => [u.id as string, { key: u.key as string, dimension: u.dimension as string }]),
  );
  const byDimension = new Map<string, string[]>();
  for (const unit of units.data ?? []) {
    const dimension = unit.dimension as string;
    byDimension.set(dimension, [...(byDimension.get(dimension) ?? []), unit.key as string]);
  }

  return ok(
    (definitions.data ?? []).flatMap((definition) => {
      const canonical = unitById.get(definition.canonical_unit_id as string);
      if (!canonical) return [];
      const siblings = byDimension.get(canonical.dimension) ?? [canonical.key];
      return [
        {
          key: definition.key as string,
          displayName: definition.display_name as string,
          description: (definition.description as string | null) ?? null,
          canonicalUnit: canonical.key,
          // Canonical first: it is the default, and the one that needs no
          // conversion and therefore cannot fail for a missing one.
          units: [canonical.key, ...siblings.filter((u) => u !== canonical.key).sort()],
        },
      ];
    }),
  );
}
