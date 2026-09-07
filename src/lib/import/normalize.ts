import { applyTransform, createTransformState, type TransformState } from "./transforms";
import { metricNaturalKey, setNaturalKey, truncateForKey, workoutNaturalKey } from "./natural-key";
import { resolveTimestamp } from "./timestamps";
import type {
  Binding,
  MappingSpec,
  NormalizedMetric,
  NormalizeResult,
  RegistrySnapshot,
  RowFilter,
  SourceRow,
} from "./types";

/**
 * Normalization (v2 section 4, I-3).
 *
 *   normalize(raw_record, mapping_spec, registry_snapshot, version) -> rows
 *
 * Pure and deterministic. No database reads, no clock reads, no randomness.
 * That is what makes rebuild trustworthy and this function unit-testable
 * against fixtures.
 *
 * The engine branches on template, never on source_key. source_key is metadata
 * carried onto rows and read only by precedence resolution (I-9).
 */

export const NORMALIZE_VERSION = 1;

/**
 * Reserved payload key holding values that can only be derived from row order,
 * computed once at ingest where file order is known (v2 section 6.2).
 * Normalization stays per-row and therefore pure.
 */
export const DERIVED_KEY = "__derived";

export type RawRecordInput = {
  id: number;
  userId: string;
  sourceKey: string;
  payload: Record<string, unknown>;
  /**
   * v2 §4.3, ADR-07. 0 imported, 10 manual entry, 20 manual correction. The
   * normalizer does not resolve conflicts — that needs the existing row, which
   * is a database read and therefore not its business (I-3) — but it is part
   * of the raw record, and normalize() takes the raw record.
   */
  precedenceRank?: number;
  /**
   * Set on a correction: the natural key of the observation being superseded.
   * Identity comes from it, so a correction updates the record it names rather
   * than creating a second one beside it.
   */
  supersedesNaturalKey?: string | null;
};

export class NormalizeError extends Error {}

function cell(row: SourceRow, column: string): string | null {
  const value = row[column];
  return value === undefined ? null : value;
}

/** Resolves one binding to a scalar. Bindings are never a field dictionary. */
function resolveBinding(
  binding: Binding | undefined,
  row: SourceRow,
  spec: MappingSpec,
  context: { rowIndex: number; state: TransformState; derived: Record<string, unknown> },
  path: string,
): unknown {
  if (!binding) return null;

  if (binding.constant !== undefined) return binding.constant;

  // A value that depends on row order was computed at ingest.
  if (binding.transform && ORDER_DEPENDENT.has(binding.transform.name)) {
    const value = context.derived[path];
    return value === undefined ? null : value;
  }

  const columns = binding.columns ?? (binding.column ? [binding.column] : []);
  const values = columns.map((column) => cell(row, column));

  if (binding.transform) {
    return applyTransform(binding.transform, {
      values,
      row,
      rowIndex: context.rowIndex,
      state: context.state,
    });
  }

  const value = values[0];
  return value === undefined || value === null || value.trim() === "" ? null : value.trim();
}

/** Transforms whose output depends on where the row sits in the file. */
export const ORDER_DEPENDENT = new Set(["row_index_within_group"]);

export function passesRowFilters(row: SourceRow, filters: RowFilter[]): boolean {
  return filters.every((filter) => {
    const value = (row[filter.column] ?? "").trim();
    switch (filter.op) {
      case "not_empty":
        return value !== "";
      case "empty":
        return value === "";
      case "equals":
        return value === (filter.value ?? "");
      case "not_equals":
        return value !== (filter.value ?? "");
    }
  });
}

function toNumber(value: unknown, spec: MappingSpec, label: string): number | null {
  if (value === null || value === undefined || value === "") return null;
  if (typeof value === "number") return Number.isFinite(value) ? value : null;
  const text = String(value).trim();
  if (text === "") return null;
  const normalized =
    spec.decimal_separator === "," ? text.replace(/\./g, "").replace(",", ".") : text;
  const parsed = Number(normalized);
  if (!Number.isFinite(parsed)) {
    // v2 section 4.2 step 4: reject, never coerce.
    throw new NormalizeError(`${label}: "${text}" is not numeric`);
  }
  return parsed;
}

/** Fixed-point decimal string at NUMERIC(18,6), the storage precision (I-7). */
function toNumeric18x6(value: number): string {
  return value.toFixed(6);
}

/**
 * Unit conversion (v2 section 4.2 step 5): canonical = value * factor + offset,
 * looked up in the registry snapshot. A missing conversion is a hard error, never
 * a pass-through.
 */
function convert(
  value: number,
  fromUnit: string,
  toUnit: string,
  registry: RegistrySnapshot,
): number {
  if (fromUnit === toUnit) return value;
  const conversion = registry.unitConversions.get(`${fromUnit}->${toUnit}`);
  if (!conversion) {
    throw new NormalizeError(
      `no unit conversion from "${fromUnit}" to "${toUnit}" in the registry`,
    );
  }
  return value * Number(conversion.factor) + Number(conversion.offset);
}

function resolveExercise(
  rawName: string,
  registry: RegistrySnapshot,
): { id: string; key: string } {
  const normalized = normalizeAliasLikeDatabase(rawName);
  const definitionId = registry.exerciseAliases.get(normalized);
  if (!definitionId) {
    // v2 section 4.2 step 3: an unresolved identity is a hard error, never a
    // silent free-text insert (I-6).
    throw new NormalizeError(
      `exercise "${rawName}" (normalized "${normalized}") does not resolve to a registry row`,
    );
  }
  const definition = registry.exerciseDefinitions.get(definitionId);
  if (!definition) {
    throw new NormalizeError(`exercise definition ${definitionId} missing from the snapshot`);
  }
  return definition;
}

/**
 * Resolves a metric identifier to its registry row (I-6).
 *
 * The key is tried first, then the alias table, so a profile may name a metric
 * either by its canonical key or by whatever the source calls it. An
 * unresolved identifier is a hard error: a free-text metric key would silently
 * split an analytical series in two.
 */
function resolveMetric(
  rawKey: string,
  registry: RegistrySnapshot,
): { id: string; key: string; canonicalUnitId: string } {
  const direct = [...registry.metricDefinitions.values()].find((d) => d.key === rawKey.trim());
  if (direct) return direct;

  const normalized = normalizeAliasLikeDatabase(rawKey);
  const definitionId = registry.metricAliases.get(normalized);
  const viaAlias = definitionId ? registry.metricDefinitions.get(definitionId) : undefined;
  if (viaAlias) return viaAlias;

  throw new NormalizeError(
    `metric "${rawKey}" (normalized "${normalized}") does not resolve to a registry row`,
  );
}

/**
 * The alias normalization contract, mirrored from public.normalize_alias so the
 * stored form and the lookup form cannot diverge: lowercase, punctuation to
 * space, whitespace collapsed, trimmed.
 */
export function normalizeAliasLikeDatabase(value: string): string {
  return value
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]+/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * Computes the values that depend on file order, once, over the whole file.
 * Returns one record per row, keyed by binding path.
 */
export function computeDerivedFields(
  spec: MappingSpec,
  rows: SourceRow[],
): Record<string, unknown>[] {
  const state = createTransformState();
  const strength = spec.strength;
  if (!strength) return rows.map(() => ({}));

  const setNumber = strength.set.set_number;
  const setNumberIsDerived =
    setNumber?.transform !== undefined && ORDER_DEPENDENT.has(setNumber.transform.name);

  // Grouping keys come from the mapping spec, not from any vendor knowledge:
  // a workout is identified by its external id when declared and otherwise by
  // its timestamp columns, and an exercise by the column the profile binds.
  const workoutColumns = spec.external_id?.column
    ? [spec.external_id.column]
    : spec.timestamp.columns;
  const exerciseColumn = strength.exercise.name.column;

  const workoutKeyOf = (row: SourceRow) =>
    workoutColumns.map((column) => (row[column] ?? "").trim()).join(" ");
  const exerciseKeyOf = (row: SourceRow) =>
    exerciseColumn ? (row[exerciseColumn] ?? "").trim() : "";

  /**
   * order_index is assigned by first appearance of a distinct exercise within a
   * workout, in file order, and reused if that exercise appears again later.
   * Reuse is what makes an interleaved superset resolve to two exercises rather
   * than four, and it is what keeps UNIQUE (workout_id, order_index) satisfiable.
   */
  const orderByWorkout = new Map<string, Map<string, number>>();

  return rows.map((row, rowIndex) => {
    const derived: Record<string, unknown> = {};

    const workoutKey = workoutKeyOf(row);
    const exerciseKey = exerciseKeyOf(row);
    let orders = orderByWorkout.get(workoutKey);
    if (!orders) {
      orders = new Map<string, number>();
      orderByWorkout.set(workoutKey, orders);
    }
    let orderIndex = orders.get(exerciseKey);
    if (orderIndex === undefined) {
      orderIndex = orders.size;
      orders.set(exerciseKey, orderIndex);
    }
    derived["exercise.order_index"] = orderIndex;

    if (setNumberIsDerived && setNumber?.transform) {
      derived["set.set_number"] = applyTransform(setNumber.transform, {
        values: [],
        row,
        rowIndex,
        state,
      });
      derived["set.set_number_derived"] = true;
    }

    return derived;
  });
}

/**
 * Normalizes one raw record into canonical rows.
 *
 * The strength template is the implemented vertical slice. The other four
 * templates are declared in the mapping model and rejected here with a clear
 * error rather than half-implemented, so nothing can appear to work when it
 * does not.
 */
export function normalize(
  raw: RawRecordInput,
  spec: MappingSpec,
  registry: RegistrySnapshot,
  version: number,
): NormalizeResult {
  if (version !== NORMALIZE_VERSION) {
    throw new NormalizeError(
      `normalize version ${version} requested but this build is ${NORMALIZE_VERSION}`,
    );
  }
  if (spec.template !== "strength" && spec.template !== "metrics") {
    throw new NormalizeError(
      `template "${spec.template}" is declared in the mapping model but its normalizer is not implemented yet`,
    );
  }
  if (spec.template === "metrics") {
    return normalizeMetrics(raw, spec, registry);
  }

  const strength = spec.strength;
  if (!strength) {
    throw new NormalizeError("strength template requires a strength mapping block");
  }

  const payload = raw.payload;
  const derived = (payload[DERIVED_KEY] as Record<string, unknown> | undefined) ?? {};
  const row: SourceRow = Object.fromEntries(
    Object.entries(payload)
      .filter(([key]) => key !== DERIVED_KEY)
      .map(([key, value]) => [key, value === null || value === undefined ? "" : String(value)]),
  );

  const result: NormalizeResult = {
    workouts: [],
    exercises: [],
    sets: [],
    metrics: [],
    naturalKeys: [],
    warnings: [],
    errors: [],
  };

  if (!passesRowFilters(row, spec.row_filters)) return result;

  const context = { rowIndex: 0, state: createTransformState(), derived };
  const sourceKey = spec.constants.source_key ?? raw.sourceKey;

  // 2. Parse timestamp.
  const timestampRaw = spec.timestamp.columns
    .map((column) => (row[column] ?? "").trim())
    .filter((v) => v !== "")
    .join(" ");
  const stamp = resolveTimestamp(timestampRaw, spec.timestamp.timezone, row, spec.timestamp.format);

  // 3. Resolve identity.
  const externalIdValue = resolveBinding(spec.external_id, row, spec, context, "external_id");
  const externalId = externalIdValue === null ? null : String(externalIdValue);

  const workoutIdentity = externalId ?? truncateForKey(stamp.timestampUtc, "second");
  const wkKey = workoutNaturalKey({
    userId: raw.userId,
    sourceKey,
    externalId,
    startUtc: stamp.timestampUtc,
  });

  const titleValue = resolveBinding(strength.workout.title, row, spec, context, "workout.title");
  const durationValue = resolveBinding(
    strength.workout.duration_s,
    row,
    spec,
    context,
    "workout.duration_s",
  );

  result.workouts.push({
    naturalKey: wkKey,
    startUtc: stamp.timestampUtc,
    tzOffsetMinutes: stamp.tzOffsetMinutes,
    localDate: stamp.localDate,
    durationS: durationValue === null ? null : Math.round(Number(durationValue)),
    title: titleValue === null ? null : String(titleValue),
    externalId,
  });

  // 4. Exercise identity resolves to a registry row or the row fails (I-6).
  const exerciseNameValue = resolveBinding(
    strength.exercise.name,
    row,
    spec,
    context,
    "exercise.name",
  );
  if (exerciseNameValue === null) {
    throw new NormalizeError("exercise name is empty");
  }
  const exerciseNameRaw = String(exerciseNameValue);
  const definition = resolveExercise(exerciseNameRaw, registry);

  // The exercise's position within its workout. Derived at ingest alongside the
  // set ordinal, because both depend on file order.
  const orderIndex = Number(derived["exercise.order_index"] ?? 0);

  result.exercises.push({
    workoutNaturalKey: wkKey,
    exerciseDefinitionId: definition.id,
    exerciseNameRaw,
    orderIndex,
  });

  // 5. Set fields.
  const setNumberValue = resolveBinding(
    strength.set.set_number,
    row,
    spec,
    context,
    "set.set_number",
  );
  const setNumber = setNumberValue === null ? 1 : Math.round(Number(setNumberValue));
  if (!Number.isFinite(setNumber) || setNumber < 1) {
    throw new NormalizeError(`set number "${String(setNumberValue)}" is not a positive integer`);
  }

  const setTypeValue = resolveBinding(strength.set.set_type, row, spec, context, "set.set_type");
  const setType = setTypeValue === null ? "working" : String(setTypeValue);

  const weightBinding = strength.set.weight;
  const weightRaw = toNumber(
    resolveBinding(weightBinding, row, spec, context, "set.weight"),
    spec,
    "weight",
  );
  const weightKg =
    weightRaw === null
      ? null
      : toNumeric18x6(convert(weightRaw, weightBinding?.unit ?? "kg", "kg", registry));

  const distanceBinding = strength.set.distance;
  const distanceRaw = toNumber(
    resolveBinding(distanceBinding, row, spec, context, "set.distance"),
    spec,
    "distance",
  );
  const distanceM =
    distanceRaw === null
      ? null
      : toNumeric18x6(convert(distanceRaw, distanceBinding?.unit ?? "m", "m", registry));

  const reps = toNumber(resolveBinding(strength.set.reps, row, spec, context, "set.reps"), spec, "reps");
  const rpeRaw = toNumber(resolveBinding(strength.set.rpe, row, spec, context, "set.rpe"), spec, "rpe");
  const durationS = toNumber(
    resolveBinding(strength.set.duration_s, row, spec, context, "set.duration_s"),
    spec,
    "set duration",
  );

  if (rpeRaw !== null && (rpeRaw < 0 || rpeRaw > 10)) {
    throw new NormalizeError(`rpe ${rpeRaw} is outside the 0 to 10 domain`);
  }

  const stKey = setNaturalKey({
    userId: raw.userId,
    sourceKey,
    workoutIdentity,
    exerciseOrderIndex: orderIndex,
    exerciseKey: definition.key,
    setNumber,
  });

  result.sets.push({
    naturalKey: stKey,
    workoutNaturalKey: wkKey,
    exerciseOrderIndex: orderIndex,
    setNumber,
    setType,
    weightKg,
    reps: reps === null ? null : Math.round(reps),
    rpe: rpeRaw === null ? null : rpeRaw.toFixed(2),
    durationS: durationS === null ? null : Math.round(durationS),
    distanceM,
    setNumberDerived: derived["set.set_number_derived"] === true,
  });

  result.naturalKeys = [wkKey, stKey];
  return result;
}

/**
 * The metrics template, long layout: one row carries one observation, naming
 * its metric, its value and the unit that value is in.
 *
 * This is the layout a manual entry uses, and it is the same code path a future
 * long-format export would use — the engine sees a raw record and a mapping
 * spec, and cannot tell which produced it (I-9).
 *
 * The wide layout (one column per metric, driven by spec.bindings) is declared
 * in the mapping model and is not implemented. It is rejected explicitly rather
 * than half-built, so nothing can appear to work when it does not.
 */
function normalizeMetrics(
  raw: RawRecordInput,
  spec: MappingSpec,
  registry: RegistrySnapshot,
): NormalizeResult {
  const result: NormalizeResult = {
    workouts: [],
    exercises: [],
    sets: [],
    metrics: [],
    naturalKeys: [],
    warnings: [],
    errors: [],
  };

  if (spec.layout !== "long") {
    throw new NormalizeError(
      "the metrics template currently implements the long layout only; the wide layout is declared in the mapping model but not implemented",
    );
  }
  if (!spec.metric_column || !spec.value_column) {
    throw new NormalizeError(
      "the metrics long layout requires metric_column and value_column",
    );
  }

  const row: SourceRow = Object.fromEntries(
    Object.entries(raw.payload)
      .filter(([key]) => key !== DERIVED_KEY)
      .map(([key, value]) => [key, value === null || value === undefined ? "" : String(value)]),
  );

  if (!passesRowFilters(row, spec.row_filters)) return result;

  const sourceKey = spec.constants.source_key ?? raw.sourceKey;

  const timestampRaw = spec.timestamp.columns
    .map((column) => (row[column] ?? "").trim())
    .filter((value) => value !== "")
    .join(" ");
  const stamp = resolveTimestamp(timestampRaw, spec.timestamp.timezone, row, spec.timestamp.format);

  // The metric identifier, mapped through the profile's own vocabulary first so
  // a source that says "Gewicht" resolves without the registry needing to.
  const rawMetric = (row[spec.metric_column] ?? "").trim();
  if (rawMetric === "") throw new NormalizeError("metric key is empty");
  const mappedMetric = spec.metric_value_map?.[rawMetric] ?? rawMetric;
  const definition = resolveMetric(mappedMetric, registry);

  const valueRaw = (row[spec.value_column] ?? "").trim();
  if (valueRaw === "") throw new NormalizeError(`metric "${mappedMetric}" has no value`);
  const sourceValue = toNumber(valueRaw, spec, `metric ${mappedMetric}`);
  if (sourceValue === null) {
    throw new NormalizeError(`metric "${mappedMetric}" has no value`);
  }

  // The unit the source recorded in. Falling back to the canonical unit is a
  // decision the profile makes by omitting unit_column, not a guess made here.
  const canonicalUnit = [...registry.units.values()].find(
    (unit) => unit.id === definition.canonicalUnitId,
  );
  if (!canonicalUnit) {
    throw new NormalizeError(
      `metric "${definition.key}" has canonical unit ${definition.canonicalUnitId}, which is missing from the registry snapshot`,
    );
  }

  const rawUnit = spec.unit_column ? (row[spec.unit_column] ?? "").trim() : "";
  const mappedUnit = rawUnit === "" ? canonicalUnit.key : (spec.unit_value_map?.[rawUnit] ?? rawUnit);
  const sourceUnit = registry.units.get(mappedUnit);
  if (!sourceUnit) {
    throw new NormalizeError(`unit "${mappedUnit}" does not resolve to a registry row`);
  }
  if (sourceUnit.dimension !== canonicalUnit.dimension) {
    throw new NormalizeError(
      `unit "${sourceUnit.key}" measures ${sourceUnit.dimension}, but metric "${definition.key}" is recorded in ${canonicalUnit.dimension}`,
    );
  }

  const canonicalValue = convert(sourceValue, sourceUnit.key, canonicalUnit.key, registry);

  // Part of identity, not of the value: a left/right measurement or a site.
  const qualifierRaw = (row.qualifier ?? "").trim();
  const qualifier = qualifierRaw === "" ? null : qualifierRaw;

  // A correction takes the identity of the observation it supersedes, so it
  // updates that record rather than standing beside it as a second reading.
  const naturalKey =
    raw.supersedesNaturalKey ??
    metricNaturalKey({
      userId: raw.userId,
      sourceKey,
      metricKey: definition.key,
      qualifier,
      timestampUtc: stamp.timestampUtc,
      granularity: spec.identity_granularity,
    });

  const metric: NormalizedMetric = {
    naturalKey,
    metricDefinitionId: definition.id,
    metricKey: definition.key,
    qualifier,
    timestampUtc: stamp.timestampUtc,
    tzOffsetMinutes: stamp.tzOffsetMinutes,
    tzName: stamp.tzName,
    localDate: stamp.localDate,
    valueNum: toNumeric18x6(canonicalValue),
    unitId: canonicalUnit.id,
    unit: canonicalUnit.key,
    sourceValueNum: toNumeric18x6(sourceValue),
    sourceUnit: sourceUnit.key,
    supersedes: raw.supersedesNaturalKey != null,
  };

  result.metrics.push(metric);
  result.naturalKeys.push(naturalKey);
  return result;
}
