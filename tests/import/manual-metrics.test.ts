import { describe, expect, it } from "vitest";

import { normalize, NORMALIZE_VERSION, NormalizeError } from "@/lib/import/normalize";
import { metricNaturalKey } from "@/lib/import/natural-key";
import { MANUAL_METRICS_PROFILE, BUILT_IN_PROFILES } from "@/lib/import/profiles";
import type { RegistrySnapshot } from "@/lib/import/types";

/**
 * The metrics template, as manual entry uses it.
 *
 * normalize() is pure, so it can be tested exactly: same inputs, same rows,
 * no database and no clock. These assertions are the contract the rebuild
 * depends on — if replaying a raw record ever produced a different row, the
 * canonical layer would stop being reproducible.
 */

const USER = "22222222-2222-4222-8222-222222222222";
const SPEC = MANUAL_METRICS_PROFILE.mapping_spec;

const registry: RegistrySnapshot = {
  exerciseAliases: new Map(),
  exerciseDefinitions: new Map(),
  metricAliases: new Map([["body mass", "def-weight"]]),
  metricDefinitions: new Map([
    ["def-weight", { id: "def-weight", key: "weight", canonicalUnitId: "u-kg" }],
    ["def-waist", { id: "def-waist", key: "waist_circumference", canonicalUnitId: "u-cm" }],
    ["def-hrv", { id: "def-hrv", key: "heart_rate_variability", canonicalUnitId: "u-ms" }],
  ]),
  units: new Map([
    ["kg", { id: "u-kg", key: "kg", dimension: "mass" }],
    ["lb", { id: "u-lb", key: "lb", dimension: "mass" }],
    ["cm", { id: "u-cm", key: "cm", dimension: "length" }],
    ["in", { id: "u-in", key: "in", dimension: "length" }],
    ["ms", { id: "u-ms", key: "ms", dimension: "time" }],
  ]),
  unitConversions: new Map([
    ["lb->kg", { factor: "0.45359237", offset: "0" }],
    ["in->cm", { factor: "2.54", offset: "0" }],
  ]),
};

function record(payload: Record<string, string>, overrides: Record<string, unknown> = {}) {
  return normalize(
    { id: 1, userId: USER, sourceKey: "manual", payload, ...overrides },
    SPEC,
    registry,
    NORMALIZE_VERSION,
  );
}

const WEIGHT = {
  metric_key: "weight",
  value: "82.4",
  unit: "kg",
  measured_at: "2026-08-03T07:30:00+01:00",
  qualifier: "",
};

describe("the manual entry profile", () => {
  it("is not offered to file detection", () => {
    // It describes no file. Matching it against an upload would be a category
    // error, and a profile with no required columns would match anything.
    expect(BUILT_IN_PROFILES.map((p) => p.profile_id)).not.toContain("manual.metrics.v1");
    expect(MANUAL_METRICS_PROFILE.source_key).toBe("manual");
    expect(MANUAL_METRICS_PROFILE.template).toBe("metrics");
  });
});

describe("the metrics template, long layout", () => {
  it("normalizes one observation into one canonical metric", () => {
    const result = record(WEIGHT);
    expect(result.metrics).toHaveLength(1);
    expect(result.workouts).toEqual([]);
    expect(result.sets).toEqual([]);

    const metric = result.metrics[0]!;
    expect(metric.metricKey).toBe("weight");
    expect(metric.metricDefinitionId).toBe("def-weight");
    expect(metric.valueNum).toBe("82.400000");
    expect(metric.unit).toBe("kg");
    expect(metric.qualifier).toBeNull();
    expect(metric.supersedes).toBe(false);
  });

  it("stores the canonical value and keeps what was actually typed", () => {
    const result = record({ ...WEIGHT, value: "181.7", unit: "lb" });
    const metric = result.metrics[0]!;
    // 181.7 lb -> kg, at NUMERIC(18,6).
    expect(metric.valueNum).toBe((181.7 * 0.45359237).toFixed(6));
    expect(metric.unit).toBe("kg");
    // The source figure survives, so the value can be shown back in pounds.
    expect(metric.sourceValueNum).toBe("181.700000");
    expect(metric.sourceUnit).toBe("lb");
  });

  it("records the instant, the offset, and the date the person experienced", () => {
    const metric = record(WEIGHT).metrics[0]!;
    expect(metric.timestampUtc).toBe("2026-08-03T06:30:00.000Z");
    expect(metric.tzOffsetMinutes).toBe(60);
    // 07:30 local on the 3rd is what was lived, whatever UTC says.
    expect(metric.localDate).toBe("2026-08-03");
  });

  it("is deterministic: the same raw record always produces the same row", () => {
    expect(record(WEIGHT).metrics[0]).toEqual(record(WEIGHT).metrics[0]);
  });

  it("gives identity to the instant and never to the value", () => {
    const first = record(WEIGHT).metrics[0]!;
    const heavier = record({ ...WEIGHT, value: "83.9" }).metrics[0]!;
    // A different reading of the same observation is the same record, which is
    // what makes a correction an update rather than a phantom second weigh-in.
    expect(heavier.naturalKey).toBe(first.naturalKey);

    const later = record({ ...WEIGHT, measured_at: "2026-08-03T19:00:00+01:00" }).metrics[0]!;
    expect(later.naturalKey).not.toBe(first.naturalKey);
  });

  it("matches the natural key the rest of the system computes", () => {
    const metric = record(WEIGHT).metrics[0]!;
    expect(metric.naturalKey).toBe(
      metricNaturalKey({
        userId: USER,
        sourceKey: "manual",
        metricKey: "weight",
        qualifier: null,
        timestampUtc: "2026-08-03T06:30:00.000Z",
        granularity: "minute",
      }),
    );
  });

  it("takes its identity from the observation a correction supersedes", () => {
    const original = record(WEIGHT).metrics[0]!;
    const correction = record(
      { ...WEIGHT, value: "81.9", measured_at: "2026-08-04T09:00:00+01:00" },
      { precedenceRank: 20, supersedesNaturalKey: original.naturalKey },
    ).metrics[0]!;

    // Even though the correction was recorded on a different day, it names the
    // observation it replaces, so it updates that record rather than creating
    // a new one beside it.
    expect(correction.naturalKey).toBe(original.naturalKey);
    expect(correction.supersedes).toBe(true);
    expect(correction.valueNum).toBe("81.900000");
  });

  it("resolves a metric through the alias table as well as by key", () => {
    const metric = record({ ...WEIGHT, metric_key: "Body Mass" }).metrics[0]!;
    expect(metric.metricKey).toBe("weight");
  });

  it("treats a qualifier as part of identity", () => {
    const left = record({ ...WEIGHT, metric_key: "waist_circumference", unit: "cm", qualifier: "left" });
    const plain = record({ ...WEIGHT, metric_key: "waist_circumference", unit: "cm" });
    expect(left.metrics[0]!.qualifier).toBe("left");
    expect(left.metrics[0]!.naturalKey).not.toBe(plain.metrics[0]!.naturalKey);
  });

  it("refuses an unresolved metric rather than inventing one (I-6)", () => {
    expect(() => record({ ...WEIGHT, metric_key: "vibes" })).toThrow(NormalizeError);
    expect(() => record({ ...WEIGHT, metric_key: "vibes" })).toThrow(/does not resolve/);
  });

  it("refuses a unit that measures the wrong thing", () => {
    expect(() => record({ ...WEIGHT, unit: "cm" })).toThrow(/measures length/);
  });

  it("refuses a unit with no conversion rather than passing the number through", () => {
    // No in->cm entry is missing here, but ms->cm has none and never should.
    expect(() => record({ ...WEIGHT, metric_key: "heart_rate_variability", unit: "kg" })).toThrow(
      NormalizeError,
    );
  });

  it("rejects a value that is not a number", () => {
    expect(() => record({ ...WEIGHT, value: "about eighty" })).toThrow(/not numeric/);
  });

  it("rejects an empty value rather than storing a null measurement", () => {
    expect(() => record({ ...WEIGHT, value: "" })).toThrow(/no value/);
  });

  it("rejects a naive timestamp, because the profile records an instant", () => {
    expect(() => record({ ...WEIGHT, measured_at: "2026-08-03 07:30" })).toThrow(
      /carries no offset/,
    );
  });

  it("still refuses a template whose normalizer does not exist", () => {
    expect(() =>
      normalize(
        { id: 1, userId: USER, sourceKey: "manual", payload: WEIGHT },
        { ...SPEC, template: "labs" },
        registry,
        NORMALIZE_VERSION,
      ),
    ).toThrow(/not implemented yet/);
  });

  it("refuses the wide layout instead of half-implementing it", () => {
    expect(() =>
      normalize(
        { id: 1, userId: USER, sourceKey: "manual", payload: WEIGHT },
        { ...SPEC, layout: "wide" },
        registry,
        NORMALIZE_VERSION,
      ),
    ).toThrow(/long layout only/);
  });
});
