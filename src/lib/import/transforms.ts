import type { TransformName, TransformRef } from "./types";

/**
 * The closed transform library (v3 section 3.2, ADR-12).
 *
 * A purely declarative column-to-field mapping hits a wall on real vendor files
 * almost immediately: durations arrive as "1:24:33" or "84 min", weights as
 * "182.1 lb" in a single cell, reference ranges as "3.5 - 5.1". The answer is
 * not arbitrary code in profiles. It is this: a closed, versioned, unit-tested
 * set of named parameterised functions that profiles reference by name.
 *
 * Every function here is pure and total: same input, same output, no clock, no
 * randomness, no I/O. Profiles never contain executable expressions and are
 * never evaluated. Adding a vendor whose format needs something genuinely new
 * means adding a primitive here, with tests, not a branch in the pipeline.
 */

export type TransformState = {
  groupCounters: Map<string, number>;
};

export function createTransformState(): TransformState {
  return { groupCounters: new Map() };
}

export type TransformInput = {
  /** Values of the columns the binding named, in order. */
  values: (string | null)[];
  /** The whole source row, for transforms that need sibling columns. */
  row: Record<string, string>;
  /** Zero-based index of this row within the file. */
  rowIndex: number;
  /** Mutable scratch space shared across a single file's rows. */
  state: TransformState;
  params: Record<string, unknown>;
};

export type TransformOutput = string | number | boolean | null | Record<string, unknown>;

export class TransformError extends Error {
  constructor(
    readonly transform: TransformName,
    message: string,
  ) {
    super(`${transform}: ${message}`);
    this.name = "TransformError";
  }
}

function first(input: TransformInput): string | null {
  const value = input.values[0];
  return value === undefined ? null : value;
}

function nonBlank(input: TransformInput): string | null {
  const value = first(input);
  if (value === null) return null;
  const trimmed = value.trim();
  return trimmed === "" ? null : trimmed;
}

function param<T>(input: TransformInput, key: string, fallback?: T): T {
  const value = input.params[key];
  if (value === undefined) {
    if (fallback !== undefined) return fallback;
    throw new TransformError(
      (input.params.__name as TransformName) ?? "map_values",
      `missing required parameter "${key}"`,
    );
  }
  return value as T;
}

/**
 * "1:24:33", "84 min", "1h 24m", "90s", bare seconds -> seconds.
 * Blank input yields null. An unparseable non-blank value throws: silently
 * coercing an unrecognised duration to zero would corrupt a workout.
 */
const parseDuration = (input: TransformInput): TransformOutput => {
  const raw = nonBlank(input);
  if (raw === null) return null;

  const clock = raw.match(/^(\d+):([0-5]?\d)(?::([0-5]?\d))?$/);
  if (clock) {
    const a = Number(clock[1]);
    const b = Number(clock[2]);
    const c = clock[3] === undefined ? null : Number(clock[3]);
    // Three parts is h:mm:ss, two is mm:ss.
    return c === null ? a * 60 + b : a * 3600 + b * 60 + c;
  }

  if (/^\d+(\.\d+)?$/.test(raw)) return Math.round(Number(raw));

  const unitPattern = /(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b/gi;
  let match: RegExpExecArray | null;
  let total = 0;
  let matched = false;
  while ((match = unitPattern.exec(raw)) !== null) {
    matched = true;
    const amount = Number(match[1]);
    const unit = (match[2] ?? "").toLowerCase();
    if (unit.startsWith("h")) total += amount * 3600;
    else if (unit.startsWith("m")) total += amount * 60;
    else total += amount;
  }
  if (matched) return Math.round(total);

  throw new TransformError("parse_duration", `cannot parse duration "${raw}"`);
};

/** Separate date and time columns into one timestamp string. */
const concatDatetime = (input: TransformInput): TransformOutput => {
  const separator = param<string>(input, "separator", " ");
  const parts = input.values.map((v) => (v ?? "").trim()).filter((v) => v !== "");
  if (parts.length === 0) return null;
  return parts.join(separator);
};

/** "182.1 lb" into { value: 182.1, unit: "lb" }. */
const extractNumberAndUnit = (input: TransformInput): TransformOutput => {
  const raw = nonBlank(input);
  if (raw === null) return null;
  const match = raw.match(/^\s*(-?\d+(?:[.,]\d+)?)\s*([A-Za-z%/]+)?\s*$/);
  if (!match) {
    throw new TransformError("extract_number_and_unit", `cannot split "${raw}"`);
  }
  const decimalSeparator = param<string>(input, "decimal_separator", ".");
  const captured = match[1] ?? "";
  const numberText = decimalSeparator === "," ? captured.replace(",", ".") : captured.replace(",", "");
  return { value: Number(numberText), unit: match[2] ?? null };
};

/** "3.5 - 5.1" into { low: 3.5, high: 5.1 }. */
const splitReferenceRange = (input: TransformInput): TransformOutput => {
  const raw = nonBlank(input);
  if (raw === null) return null;
  const match = raw.match(/^\s*(-?\d+(?:\.\d+)?)\s*(?:-|to)\s*(-?\d+(?:\.\d+)?)\s*$/i);
  if (!match) {
    throw new TransformError("split_reference_range", `cannot split range "${raw}"`);
  }
  return { low: Number(match[1]), high: Number(match[2]) };
};

/** Dictionary lookup with a declared default. */
const mapValues = (input: TransformInput): TransformOutput => {
  const table = param<Record<string, string>>(input, "map");
  const value = first(input);
  const key = (value ?? "").trim();
  if (key === "") {
    return (input.params.blank as TransformOutput) ?? null;
  }
  const direct = table[key] ?? table[key.toLowerCase()];
  if (direct !== undefined) return direct;
  if ("default" in input.params) return input.params.default as TransformOutput;
  throw new TransformError("map_values", `no mapping for "${key}" and no default declared`);
};

/**
 * A 1-based ordinal derived from row order within a group (v2 section 6.2).
 * Used when a source does not emit a set number. Derived ordering is a
 * natural-key input, so callers must record set_number_derived.
 */
const rowIndexWithinGroup = (input: TransformInput): TransformOutput => {
  const groupBy = param<string[]>(input, "group_by");
  const key = groupBy.map((column) => input.row[column] ?? "").join("");
  const next = (input.state.groupCounters.get(key) ?? 0) + 1;
  input.state.groupCounters.set(key, next);
  return next;
};

/** "5:32 /km" into seconds per unit distance. */
const parsePace = (input: TransformInput): TransformOutput => {
  const raw = nonBlank(input);
  if (raw === null) return null;
  const match = raw.match(/^(\d+):([0-5]\d)/);
  if (!match) throw new TransformError("parse_pace", `cannot parse pace "${raw}"`);
  return Number(match[1]) * 60 + Number(match[2]);
};

/** First non-empty of an ordered list of columns. */
const coalesceColumns = (input: TransformInput): TransformOutput => {
  for (const value of input.values) {
    if (value !== null && value.trim() !== "") return value.trim();
  }
  return null;
};

/** Multiply by a declared constant. */
const scale = (input: TransformInput): TransformOutput => {
  const raw = nonBlank(input);
  if (raw === null) return null;
  const factor = param<number>(input, "factor");
  const decimalSeparator = param<string>(input, "decimal_separator", ".");
  const numberText = decimalSeparator === "," ? raw.replace(/\./g, "").replace(",", ".") : raw;
  const value = Number(numberText);
  if (!Number.isFinite(value)) throw new TransformError("scale", `"${raw}" is not numeric`);
  return value * factor;
};

/** Treat declared sentinel values as null. */
const blankAsNull = (input: TransformInput): TransformOutput => {
  const sentinels = param<string[]>(input, "values", ["-", "N/A", "n/a", "--", ""]);
  const value = first(input);
  if (value === null) return null;
  const trimmed = value.trim();
  if (trimmed === "" || sentinels.includes(trimmed)) return null;
  return trimmed;
};

/** "Yes", "No", "1", "0", "true", "false" into a boolean. */
const booleanMap = (input: TransformInput): TransformOutput => {
  const raw = nonBlank(input);
  if (raw === null) return null;
  const truthy = param<string[]>(input, "true", ["yes", "y", "true", "1"]);
  const falsy = param<string[]>(input, "false", ["no", "n", "false", "0"]);
  const value = raw.toLowerCase();
  if (truthy.map((v) => v.toLowerCase()).includes(value)) return true;
  if (falsy.map((v) => v.toLowerCase()).includes(value)) return false;
  throw new TransformError("boolean_map", `"${raw}" is neither true nor false`);
};

const LIBRARY: Record<TransformName, (input: TransformInput) => TransformOutput> = {
  parse_duration: parseDuration,
  concat_datetime: concatDatetime,
  extract_number_and_unit: extractNumberAndUnit,
  split_reference_range: splitReferenceRange,
  map_values: mapValues,
  row_index_within_group: rowIndexWithinGroup,
  parse_pace: parsePace,
  coalesce_columns: coalesceColumns,
  scale,
  blank_as_null: blankAsNull,
  boolean_map: booleanMap,
};

export function isTransformName(name: string): name is TransformName {
  return name in LIBRARY;
}

/** Applies a named transform. Unknown names are rejected: the library is closed. */
export function applyTransform(
  ref: TransformRef,
  input: Omit<TransformInput, "params">,
): TransformOutput {
  const fn = LIBRARY[ref.name];
  if (!fn) {
    throw new TransformError(ref.name, "is not in the transform library");
  }
  return fn({ ...input, params: { ...ref.params, __name: ref.name } });
}

export const TRANSFORM_LIBRARY = LIBRARY;
