import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

import { parseCsv } from "@/lib/import/csv";
import { detectProfiles, isDecisive, toCandidate } from "@/lib/import/detection";
import { BUILT_IN_PROFILES, findBuiltInProfile } from "@/lib/import/profiles";
import {
  computeDerivedFields,
  normalize,
  normalizeAliasLikeDatabase,
  NORMALIZE_VERSION,
  DERIVED_KEY,
} from "@/lib/import/normalize";
import { setNaturalKey, workoutNaturalKey, rowHash } from "@/lib/import/natural-key";
import { jaccard, normalizeHeaderToken, profileRows, signatureHash } from "@/lib/import/profiling";
import { resolveTimestamp } from "@/lib/import/timestamps";
import type { RegistrySnapshot, SourceRow } from "@/lib/import/types";

const FIXTURE = readFileSync("tests/fixtures/hevy/hevy-export.csv", "utf8");
const TRUNCATED = readFileSync("tests/fixtures/hevy/hevy-export-truncated.csv", "utf8");
const USER = "11111111-1111-4111-8111-111111111111";

/** A registry snapshot standing in for the batch read the worker performs. */
function registryFor(exerciseTitles: string[]): RegistrySnapshot {
  const exerciseDefinitions = new Map<string, { id: string; key: string }>();
  const exerciseAliases = new Map<string, string>();
  exerciseTitles.forEach((title, index) => {
    const id = `def-${index}`;
    const key = normalizeAliasLikeDatabase(title).replace(/\s+/g, "_");
    exerciseDefinitions.set(id, { id, key });
    exerciseAliases.set(normalizeAliasLikeDatabase(title), id);
  });
  return {
    exerciseAliases,
    exerciseDefinitions,
    metricAliases: new Map(),
    metricDefinitions: new Map(),
    units: new Map([
      ["kg", { id: "u-kg", key: "kg", dimension: "mass" }],
      ["m", { id: "u-m", key: "m", dimension: "length" }],
      ["km", { id: "u-km", key: "km", dimension: "length" }],
    ]),
    unitConversions: new Map([
      ["km->m", { factor: "1000", offset: "0" }],
      ["m->km", { factor: "0.001", offset: "0" }],
    ]),
  };
}

const parsed = parseCsv(FIXTURE);
const profile = findBuiltInProfile("hevy.strength.v1")!;
const spec = profile.mapping_spec;
const registry = registryFor([...new Set(parsed.rows.map((r) => r.exercise_title ?? ""))]);

function normalizeAll(rows: SourceRow[]) {
  const derived = computeDerivedFields(spec, rows);
  return rows.map((row, index) =>
    normalize(
      {
        id: index + 1,
        userId: USER,
        sourceKey: "hevy",
        payload: { ...row, [DERIVED_KEY]: derived[index] },
      },
      spec,
      registry,
      NORMALIZE_VERSION,
    ),
  );
}

describe("profiling", () => {
  it("normalizes header tokens by dropping punctuation and bracketed units", () => {
    expect(normalizeHeaderToken("Weight (kg)")).toBe("weight");
    expect(normalizeHeaderToken("Heart Rate Variability [ms]")).toBe("heart rate variability");
    expect(normalizeHeaderToken("set_index")).toBe("set index");
  });

  it("produces a signature that is order independent and stable", () => {
    expect(signatureHash(["b", "a"])).toBe(signatureHash(["a", "b"]));
    expect(signatureHash(["Weight (kg)"])).toBe(signatureHash(["weight"]));
  });

  it("profiles the fixture without touching the database", () => {
    const fileProfile = profileRows(parsed.headers, parsed.rows);
    expect(fileProfile.rowCount).toBe(20);
    expect(fileProfile.headers).toHaveLength(14);
    expect(fileProfile.columns.find((c) => c.name === "reps")?.inferredType).toBe("number");
    expect(fileProfile.columns.find((c) => c.name === "description")?.inferredType).toBe("empty");
    expect(fileProfile.columns.find((c) => c.name === "rpe")?.nullRatio).toBeGreaterThan(0);
  });

  it("computes Jaccard similarity", () => {
    expect(jaccard(["a", "b"], ["a", "b"])).toBe(1);
    expect(jaccard(["a", "b"], ["a", "c"])).toBeCloseTo(1 / 3);
  });
});

describe("detection", () => {
  const candidates = BUILT_IN_PROFILES.map(toCandidate);

  it("matches the fixture at high confidence and calls it decisive", () => {
    const matches = detectProfiles(profileRows(parsed.headers, parsed.rows), candidates);
    expect(matches[0]?.confidence).toBe("high");
    expect(matches[0]?.profileId).toBe("hevy.strength.v1");
    expect(isDecisive(matches)).toBe(true);
  });

  it("degrades to medium when the vendor adds a column, instead of failing", () => {
    const withExtra = profileRows([...parsed.headers, "new_vendor_column"], parsed.rows);
    const matches = detectProfiles(withExtra, candidates);
    expect(matches[0]?.confidence).toBe("medium");
    expect(matches[0]?.newColumns).toContain("new vendor column");
    expect(isDecisive(matches)).toBe(false);
  });

  it("refuses a file missing a required column whatever its similarity", () => {
    const headers = parsed.headers.filter((h) => h !== "exercise_title");
    const matches = detectProfiles(profileRows(headers, parsed.rows), candidates);
    expect(matches[0]?.confidence).toBe("none");
    expect(matches[0]?.missingRequiredColumns).toContain("exercise_title");
  });

  it("does not match an unrelated file", () => {
    const matches = detectProfiles(profileRows(["date", "weight", "notes"], []), candidates);
    expect(matches[0]?.confidence).toBe("none");
  });
});

describe("timestamps", () => {
  it("resolves a naive timestamp against a declared fixed zone", () => {
    const r = resolveTimestamp("2026-01-05 18:03:00", { mode: "fixed", tz_name: "UTC" }, {});
    expect(r.timestampUtc).toBe("2026-01-05T18:03:00.000Z");
    expect(r.tzOffsetMinutes).toBe(0);
    expect(r.localDate).toBe("2026-01-05");
  });

  it("honours an embedded offset and derives the local date from it", () => {
    const r = resolveTimestamp("2026-01-05T23:30:00+07:00", { mode: "embedded" }, {});
    expect(r.timestampUtc).toBe("2026-01-05T16:30:00.000Z");
    expect(r.tzOffsetMinutes).toBe(420);
    expect(r.localDate).toBe("2026-01-05");
  });

  it("applies a zone offset so the local date differs from the UTC date", () => {
    const r = resolveTimestamp("2026-01-05 08:00:00", { mode: "fixed", tz_name: "Asia/Jakarta" }, {});
    expect(r.timestampUtc).toBe("2026-01-05T01:00:00.000Z");
    expect(r.tzOffsetMinutes).toBe(420);
  });

  it("refuses a timestamp it cannot parse rather than inventing an instant", () => {
    expect(() => resolveTimestamp("last tuesday", { mode: "fixed", tz_name: "UTC" }, {})).toThrow();
  });
});

describe("normalization is a pure function", () => {
  it("produces byte-identical output for the same input, every time", () => {
    const a = JSON.stringify(normalizeAll(parsed.rows));
    const b = JSON.stringify(normalizeAll(parsed.rows));
    expect(a).toBe(b);
  });

  it("rejects a version it was not built for", () => {
    expect(() =>
      normalize({ id: 1, userId: USER, sourceKey: "hevy", payload: parsed.rows[0]! }, spec, registry, 99),
    ).toThrow(/normalize version/);
  });

  it("refuses an exercise that does not resolve to a registry row (I-6)", () => {
    const orphan = { ...parsed.rows[0]!, exercise_title: "Some Unregistered Lift" };
    expect(() =>
      normalize({ id: 1, userId: USER, sourceKey: "hevy", payload: orphan }, spec, registry, NORMALIZE_VERSION),
    ).toThrow(/does not resolve to a registry row/);
  });

  it("refuses a non-numeric value rather than coercing it", () => {
    const bad = { ...parsed.rows[1]!, weight_kg: "heavy" };
    expect(() =>
      normalize({ id: 1, userId: USER, sourceKey: "hevy", payload: bad }, spec, registry, NORMALIZE_VERSION),
    ).toThrow(/not numeric/);
  });

  it("declines a template whose normalizer is not implemented", () => {
    expect(() =>
      normalize(
        { id: 1, userId: USER, sourceKey: "x", payload: {} },
        { ...spec, template: "labs" },
        registry,
        NORMALIZE_VERSION,
      ),
    ).toThrow(/not implemented/);
  });
});

describe("the Hevy fixture through the engine", () => {
  const results = normalizeAll(parsed.rows);
  const workouts = new Map(results.flatMap((r) => r.workouts).map((w) => [w.naturalKey, w]));
  const sets = results.flatMap((r) => r.sets);
  const exercises = results.flatMap((r) => r.exercises);

  it("resolves 20 set rows into 5 workouts and 20 sets", () => {
    expect(parsed.rows).toHaveLength(20);
    expect(workouts.size).toBe(5);
    expect(sets).toHaveLength(20);
  });

  it("resolves an interleaved superset to two exercises, not four", () => {
    const pullDay = results.filter((r) => r.workouts[0]?.title === "Pull Day");
    const jan7 = pullDay.filter((r) => r.workouts[0]?.localDate === "2026-01-07");
    const orders = new Set(jan7.flatMap((r) => r.exercises).map((e) => e.orderIndex));
    expect(orders).toEqual(new Set([0, 1]));
  });

  it("numbers sets 1-based within each exercise and flags the derivation", () => {
    const bench = sets.filter(
      (s) => s.workoutNaturalKey === [...workouts.values()][0]?.naturalKey && s.exerciseOrderIndex === 0,
    );
    expect(bench.map((s) => s.setNumber)).toEqual([1, 2, 3, 4]);
    expect(bench.every((s) => s.setNumberDerived)).toBe(true);
  });

  it("maps vendor set types onto the canonical vocabulary", () => {
    expect(new Set(sets.map((s) => s.setType))).toEqual(
      new Set(["warmup", "working", "failure", "drop"]),
    );
  });

  it("stores weights at NUMERIC(18,6) and converts distance km to metres", () => {
    expect(sets[1]?.weightKg).toBe("60.000000");
    const carry = sets.find((s) => s.distanceM !== null);
    expect(carry?.distanceM).toBe("40.000000");
    expect(carry?.durationS).toBe(45);
  });

  it("keeps rpe inside its bounded domain at two decimals", () => {
    const rpes = sets.map((s) => s.rpe).filter((v): v is string => v !== null);
    expect(rpes).toContain("9.50");
    expect(rpes.every((v) => Number(v) >= 0 && Number(v) <= 10)).toBe(true);
  });

  it("leaves a blank cell as null instead of zero", () => {
    const carry = sets.find((s) => s.distanceM !== null);
    expect(carry?.reps).toBeNull();
    expect(sets[0]?.rpe).toBeNull();
  });

  it("gives every canonical row a natural key that excludes the value (ADR-08)", () => {
    const changedValue = parsed.rows.map((r) => ({ ...r, weight_kg: "999" }));
    const before = normalizeAll(parsed.rows).flatMap((r) => r.sets).map((s) => s.naturalKey);
    const after = normalizeAll(changedValue).flatMap((r) => r.sets).map((s) => s.naturalKey);
    expect(after).toEqual(before);
  });

  it("derives natural keys that are stable across runs and unique per set", () => {
    const keys = sets.map((s) => s.naturalKey);
    expect(new Set(keys).size).toBe(keys.length);
    expect(keys[0]).toBe(
      setNaturalKey({
        userId: USER,
        sourceKey: "hevy",
        workoutIdentity: "2026-01-05T18:03:00Z",
        exerciseOrderIndex: 0,
        exerciseKey: registry.exerciseDefinitions.get(
          registry.exerciseAliases.get("bench press barbell")!,
        )!.key,
        setNumber: 1,
      }),
    );
  });

  it("gives the truncated export a strict subset of the full export's keys", () => {
    const full = new Set(normalizeAll(parseCsv(FIXTURE).rows).flatMap((r) => r.sets).map((s) => s.naturalKey));
    const short = normalizeAll(parseCsv(TRUNCATED).rows).flatMap((r) => r.sets).map((s) => s.naturalKey);
    // Every key the truncated export produces must already exist in the full
    // one: that is what makes the difference a retirement candidate set rather
    // than a set of unrelated rows.
    expect(short).toHaveLength(12);
    expect(short.every((k) => full.has(k))).toBe(true);
    expect(full.size - short.length).toBe(8);
  });

  it("hashes rows so an identical row is caught as a duplicate", () => {
    expect(rowHash(parsed.rows[0]!)).toBe(rowHash({ ...parsed.rows[0]! }));
    expect(rowHash(parsed.rows[0]!)).not.toBe(rowHash(parsed.rows[1]!));
  });

  it("keys a workout by its start instant when the source emits no external id", () => {
    expect([...workouts.values()][0]?.naturalKey).toBe(
      workoutNaturalKey({
        userId: USER,
        sourceKey: "hevy",
        externalId: null,
        startUtc: "2026-01-05T18:03:00.000Z",
      }),
    );
  });
});
