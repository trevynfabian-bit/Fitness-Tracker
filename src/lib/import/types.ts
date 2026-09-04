import { z } from "zod";

/**
 * Universal Import Engine — the shared vocabulary.
 *
 * Nothing in this file, or anywhere else under src/lib/import, may branch on a
 * vendor (I-9). Vendor knowledge lives entirely in profile JSON and in the
 * closed transform library, both of which are data and named primitives
 * respectively. `source_key` is metadata written onto rows.
 */

/** v2 §6.2. The five canonical file shapes the engine understands. */
export const TEMPLATES = ["metrics", "activities", "strength", "labs", "events"] as const;
export type Template = (typeof TEMPLATES)[number];

/** v3 §3.2. The closed, named, parameterised transform library. */
export const TRANSFORM_NAMES = [
  "parse_duration",
  "concat_datetime",
  "extract_number_and_unit",
  "split_reference_range",
  "map_values",
  "row_index_within_group",
  "parse_pace",
  "coalesce_columns",
  "scale",
  "blank_as_null",
  "boolean_map",
] as const;
export type TransformName = (typeof TRANSFORM_NAMES)[number];

export const transformRefSchema = z.object({
  name: z.enum(TRANSFORM_NAMES),
  params: z.record(z.string(), z.unknown()).default({}),
});
export type TransformRef = z.infer<typeof transformRefSchema>;

/**
 * A binding, never a column-to-field dictionary (v2 §6.1).
 *
 * A binding says where a value comes from and how it is derived: one column,
 * several columns, a declared constant, or a named transform over them. That
 * is what lets one model express a wide layout (N bindings against one
 * timestamp), a long layout (one binding parameterised by a metric column) and
 * a hierarchical layout (strength) without three different mapping shapes.
 */
export const bindingSchema = z.object({
  column: z.string().optional(),
  columns: z.array(z.string()).optional(),
  constant: z.union([z.string(), z.number(), z.boolean(), z.null()]).optional(),
  transform: transformRefSchema.optional(),
  /** Unit the source reports this value in. Resolved against the units registry. */
  unit: z.string().optional(),
  unit_column: z.string().optional(),
});
export type Binding = z.infer<typeof bindingSchema>;

export const timezoneSpecSchema = z.discriminatedUnion("mode", [
  z.object({ mode: z.literal("column"), column: z.string() }),
  z.object({ mode: z.literal("embedded") }),
  z.object({ mode: z.literal("fixed"), tz_name: z.string() }),
  z.object({ mode: z.literal("home") }),
]);
export type TimezoneSpec = z.infer<typeof timezoneSpecSchema>;

export const timestampSpecSchema = z.object({
  columns: z.array(z.string()).min(1),
  format: z.string().optional(),
  timezone: timezoneSpecSchema,
});
export type TimestampSpec = z.infer<typeof timestampSpecSchema>;

export const rowFilterSchema = z.object({
  column: z.string(),
  op: z.enum(["not_empty", "empty", "equals", "not_equals"]),
  value: z.string().optional(),
});
export type RowFilter = z.infer<typeof rowFilterSchema>;

/** v2 §6.1, wide layout: one binding per metric column. */
export const metricBindingSchema = bindingSchema.extend({
  metric_key: z.string(),
  qualifier: z.string().nullable().optional(),
});

/** The strength template's field bindings (v2 §6.2 required/optional set). */
export const strengthMappingSchema = z.object({
  workout: z.object({
    title: bindingSchema.optional(),
    external_id: bindingSchema.optional(),
    duration_s: bindingSchema.optional(),
  }),
  exercise: z.object({
    name: bindingSchema,
  }),
  set: z.object({
    set_number: bindingSchema.optional(),
    set_type: bindingSchema.optional(),
    weight: bindingSchema.optional(),
    reps: bindingSchema.optional(),
    duration_s: bindingSchema.optional(),
    distance: bindingSchema.optional(),
    rpe: bindingSchema.optional(),
  }),
});

export const mappingSpecSchema = z.object({
  template: z.enum(TEMPLATES),
  layout: z.enum(["wide", "long"]).default("wide"),
  timestamp: timestampSpecSchema,
  external_id: bindingSchema.optional(),
  /** metrics template, wide layout */
  bindings: z.array(metricBindingSchema).optional(),
  /** metrics template, long layout */
  metric_column: z.string().optional(),
  value_column: z.string().optional(),
  unit_column: z.string().optional(),
  metric_value_map: z.record(z.string(), z.string()).optional(),
  unit_value_map: z.record(z.string(), z.string()).optional(),
  /** strength template */
  strength: strengthMappingSchema.optional(),
  row_filters: z.array(rowFilterSchema).default([]),
  constants: z.record(z.string(), z.string()).default({}),
  decimal_separator: z.enum([".", ","]).default("."),
  on_unmapped_column: z.enum(["ignore", "error"]).default("ignore"),
});
export type MappingSpec = z.infer<typeof mappingSpecSchema>;

/** v3 §3.1. A profile is data. The engine never branches on its contents. */
export const profileDescriptorSchema = z.object({
  profile_id: z.string().min(1),
  name: z.string().min(1),
  source_key: z.string().regex(/^[a-z0-9]+(_[a-z0-9]+)*$/),
  template: z.enum(TEMPLATES),
  detection: z.object({
    required_columns: z.array(z.string()).default([]),
    signature_tokens: z.array(z.string()).default([]),
    min_similarity: z.number().min(0).max(1).default(0.85),
  }),
  import_mode: z.enum(["append", "full_snapshot"]).default("append"),
  snapshot_scope: z
    .object({
      source_key: z.string(),
      templates: z.array(z.enum(TEMPLATES)),
      date_range: z.union([
        z.literal("derive_from_file"),
        z.object({ from: z.string(), to: z.string() }),
      ]),
      metric_keys: z.array(z.string()).nullable().default(null),
    })
    .nullable()
    .default(null),
  retention_overrides: z.record(z.string(), z.enum(["event", "daily", "reduced"])).default({}),
  mapping_spec: mappingSpecSchema,
});
export type ProfileDescriptor = z.infer<typeof profileDescriptorSchema>;

/** One parsed source row: header -> raw cell text. */
export type SourceRow = Record<string, string>;

/** How many rows the client profiles and posts as a sample (v2 §5.2). */
export const PROFILE_SAMPLE_SIZE = 200;

/** Output of client-side profiling (v2 §5.2). */
export type ColumnProfile = {
  name: string;
  inferredType: "number" | "date" | "boolean" | "text" | "empty";
  nullRatio: number;
  distinctSample: string[];
};

export type FileProfile = {
  headers: string[];
  headerTokens: string[];
  signatureHash: string;
  rowCount: number;
  columns: ColumnProfile[];
  sampleRows: SourceRow[];
};

/** v2 §6.3 match confidence bands. */
export type MatchConfidence = "high" | "medium" | "low" | "none";

export type ProfileMatch = {
  profileId: string;
  name: string;
  template: Template;
  sourceKey: string;
  confidence: MatchConfidence;
  similarity: number;
  missingRequiredColumns: string[];
  newColumns: string[];
  missingColumns: string[];
};

/** The registry snapshot passed into normalization. No database reads inside (I-3). */
export type RegistrySnapshot = {
  exerciseAliases: Map<string, string>;
  exerciseDefinitions: Map<string, { id: string; key: string }>;
  metricAliases: Map<string, string>;
  metricDefinitions: Map<string, { id: string; key: string; canonicalUnitId: string }>;
  units: Map<string, { id: string; key: string; dimension: string }>;
  unitConversions: Map<string, { factor: string; offset: string }>;
};

export type NormalizedWorkout = {
  naturalKey: string;
  startUtc: string;
  tzOffsetMinutes: number;
  localDate: string;
  durationS: number | null;
  title: string | null;
  externalId: string | null;
};

export type NormalizedExercise = {
  workoutNaturalKey: string;
  exerciseDefinitionId: string;
  exerciseNameRaw: string;
  orderIndex: number;
};

export type NormalizedSet = {
  naturalKey: string;
  workoutNaturalKey: string;
  exerciseOrderIndex: number;
  setNumber: number;
  setType: string;
  weightKg: string | null;
  reps: number | null;
  rpe: string | null;
  durationS: number | null;
  distanceM: string | null;
  setNumberDerived: boolean;
};

export type NormalizeResult = {
  workouts: NormalizedWorkout[];
  exercises: NormalizedExercise[];
  sets: NormalizedSet[];
  naturalKeys: string[];
  warnings: string[];
  errors: string[];
};
