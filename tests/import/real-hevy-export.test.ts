import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

import { parseCsv } from "@/lib/import/csv";
import { detectProfiles, isDecisive, toCandidate } from "@/lib/import/detection";
import { BUILT_IN_PROFILES, findBuiltInProfile } from "@/lib/import/profiles";
import { computeDerivedFields, normalize, normalizeAliasLikeDatabase, NORMALIZE_VERSION, DERIVED_KEY } from "@/lib/import/normalize";
import { profileRows } from "@/lib/import/profiling";
import { parseByFormat, resolveTimestamp } from "@/lib/import/timestamps";
import { timestampSpecSchema } from "@/lib/import/types";
import type { RegistrySnapshot, SourceRow } from "@/lib/import/types";

/**
 * Phase 3.1 — the Hevy profile against a REAL Hevy export.
 *
 * `CLAUDE.md` §5 requires that every import profile ships with a committed
 * anonymized real export and that "a profile is not complete until its fixture
 * test passes against a real file". Until Phase 3.1 the Hevy fixture was a
 * reconstruction, and it differed from reality in exactly the field that broke
 * the importer: the reconstruction wrote `2026-01-05 18:03:00`, Hevy emits
 * `5 Jan 2026, 18:03`, and the profile's declared format described the former.
 *
 * `hevy-export-real.csv` is a slice of a real export, anonymized. This suite is
 * the acceptance step that caveat named.
 */

const REAL = readFileSync("tests/fixtures/hevy/hevy-export-real.csv", "utf8");
const USER = "11111111-1111-4111-8111-111111111111";

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

const parsed = parseCsv(REAL);
const profile = findBuiltInProfile("hevy.strength.v1")!;
const spec = profile.mapping_spec;
const registry = registryFor([...new Set(parsed.rows.map((r) => r.exercise_title ?? ""))]);

function normalizeAll(rows: SourceRow[]) {
  const derived = computeDerivedFields(spec, rows);
  return rows.map((row, index) =>
    normalize(
      { id: index + 1, userId: USER, sourceKey: "hevy", payload: { ...row, [DERIVED_KEY]: derived[index] } },
      spec,
      registry,
      NORMALIZE_VERSION,
    ),
  );
}

// ---------------------------------------------------------------------------
// The declared format, which used to be inert
// ---------------------------------------------------------------------------

describe("mapping_spec.timestamp.format", () => {
  it("reads the shape Hevy actually emits", () => {
    expect(parseByFormat("5 Sep 2026, 19:03", "d MMM yyyy, HH:mm")).toEqual({
      year: 2026, month: 9, day: 5, hour: 19, minute: 3, second: 0,
    });
    // Two-digit day, and a month whose name is not the first three letters of
    // anything else.
    expect(parseByFormat("15 Dec 2024, 07:45", "d MMM yyyy, HH:mm")).toEqual({
      year: 2024, month: 12, day: 15, hour: 7, minute: 45, second: 0,
    });
  });

  it("still reads the ISO shape, so no existing profile changes meaning", () => {
    expect(parseByFormat("2026-01-05 18:03:00", "yyyy-MM-dd HH:mm:ss")).toEqual({
      year: 2026, month: 1, day: 5, hour: 18, minute: 3, second: 0,
    });
  });

  it("separates month from minute by case, not by position", () => {
    expect(parseByFormat("2026-11-05 18:03:00", "yyyy-MM-dd HH:mm:ss")).toMatchObject({ month: 11, minute: 3 });
  });

  it("refuses a value that does not match the declared shape", () => {
    expect(parseByFormat("2026-01-05 18:03:00", "d MMM yyyy, HH:mm")).toBeNull();
    expect(parseByFormat("5 Sep 2026, 19:03", "yyyy-MM-dd HH:mm:ss")).toBeNull();
    expect(parseByFormat("5 Xyz 2026, 19:03", "d MMM yyyy, HH:mm")).toBeNull();
    expect(parseByFormat("", "d MMM yyyy, HH:mm")).toBeNull();
  });

  it("refuses a date that does not exist rather than rolling it over", () => {
    // 2025 is not a leap year. Date.UTC would silently make this 1 March.
    expect(parseByFormat("29 Feb 2025, 10:00", "d MMM yyyy, HH:mm")).toBeNull();
    expect(parseByFormat("31 Apr 2025, 10:00", "d MMM yyyy, HH:mm")).toBeNull();
    // A real leap day is accepted.
    expect(parseByFormat("29 Feb 2024, 10:00", "d MMM yyyy, HH:mm")).toMatchObject({ month: 2, day: 29 });
  });

  it("governs resolution: a value that contradicts the declared format is refused", () => {
    // This is the regression guard for the whole class of bug. Before Phase 3.1
    // the declared format was ignored, so a profile could describe one shape and
    // silently accept another — which is how the Hevy profile shipped claiming
    // ISO while Hevy emitted something else.
    expect(() =>
      resolveTimestamp("2026-01-05 18:03:00", { mode: "fixed", tz_name: "UTC" }, {}, "d MMM yyyy, HH:mm"),
    ).toThrow(/does not match the profile's declared format/);
  });

  it("is rejected at the profile door if the parser could not read it", () => {
    // A format now governs, so an unreadable one would refuse every row of an
    // import. Catching it when the profile is validated turns that into an
    // authoring error rather than a failed import.
    const withFormat = (format: string) =>
      timestampSpecSchema.safeParse({
        columns: ["start_time"],
        format,
        timezone: { mode: "fixed", tz_name: "UTC" },
      }).success;

    expect(withFormat("d MMM yyyy, HH:mm")).toBe(true);
    expect(withFormat("yyyy-MM-dd HH:mm:ss")).toBe(true);
    // No day, so it can never resolve to an instant.
    expect(withFormat("yyyy-MM")).toBe(false);
    // Minutes are not months: case is the only thing separating them.
    expect(withFormat("yyyy-mm-dd")).toBe(false);
    expect(withFormat("nonsense")).toBe(false);
    // Declaring nothing stays legal, and keeps the inference path.
    expect(
      timestampSpecSchema.safeParse({
        columns: ["start_time"],
        timezone: { mode: "fixed", tz_name: "UTC" },
      }).success,
    ).toBe(true);
  });

  it("resolves a real Hevy timestamp to the same instant the ISO form would", () => {
    const viaFormat = resolveTimestamp("5 Jan 2026, 18:03", { mode: "fixed", tz_name: "UTC" }, {}, "d MMM yyyy, HH:mm");
    const viaIso = resolveTimestamp("2026-01-05 18:03:00", { mode: "fixed", tz_name: "UTC" }, {});
    expect(viaFormat).toEqual(viaIso);
  });
});

// ---------------------------------------------------------------------------
// The real export, end to end through the engine
// ---------------------------------------------------------------------------

describe("a real Hevy export", () => {
  it("parses, with the quoted header the real file uses", () => {
    expect(parsed.headers).toEqual([
      "title", "start_time", "end_time", "description", "exercise_title",
      "superset_id", "exercise_notes", "set_index", "set_type", "weight_kg",
      "reps", "distance_km", "duration_seconds", "rpe",
    ]);
    expect(parsed.rows.length).toBe(61);
  });

  it("is detected as the Hevy profile, decisively", () => {
    const matches = detectProfiles(profileRows(parsed.headers, parsed.rows), BUILT_IN_PROFILES.map(toCandidate));
    expect(matches[0]!.profileId).toBe("hevy.strength.v1");
    expect(matches[0]!.confidence).toBe("high");
    expect(matches[0]!.missingRequiredColumns).toEqual([]);
    expect(isDecisive(matches)).toBe(true);
  });

  it("normalizes every row — none rejected", () => {
    const results = normalizeAll(parsed.rows);
    const failures = results.filter((r) => r.sets.length === 0 && r.workouts.length === 0);
    expect(failures).toHaveLength(0);
    expect(results).toHaveLength(61);
  });

  it("produces the five real sessions, on the days the file names", () => {
    const results = normalizeAll(parsed.rows);
    const workouts = new Map(results.flatMap((r) => r.workouts).map((w) => [w.naturalKey, w]));
    expect(workouts.size).toBe(5);

    const dates = [...workouts.values()].map((w) => w.localDate).sort();
    expect(dates).toEqual(["2024-03-04", "2024-03-06", "2024-03-08", "2024-03-10", "2024-03-12"]);
    // Every session resolves to a real instant, which is the thing that was
    // broken before Phase 3.1.
    expect([...workouts.values()].every((w) => !Number.isNaN(Date.parse(w.startUtc)))).toBe(true);
  });

  it("leaves workout duration unmapped, which the profile does not claim to map", () => {
    // Recorded rather than asserted away. Hevy puts end_time in every row and
    // the profile maps only the title, so a Hevy workout carries no duration.
    // That is a pre-existing omission this suite makes visible, not a Phase 3.1
    // regression. See docs/architecture-implementation-notes.md N-16.
    const results = normalizeAll(parsed.rows);
    expect(results.flatMap((r) => r.workouts).every((w) => w.durationS === null)).toBe(true);
  });

  it("carries every set type the real file contains, mapped to the canonical vocabulary", () => {
    const results = normalizeAll(parsed.rows);
    const types = new Set(results.flatMap((r) => r.sets).map((s) => s.setType));
    // 'dropset' and 'failure' exist in real Hevy data and are absent from the
    // reconstruction that Phase 3 was verified against.
    expect(types).toContain("working");
    expect(types).toContain("warmup");
    expect(types).toContain("drop");
    expect(types).toContain("failure");
  });

  it("keeps a set with no load, rather than inventing a zero", () => {
    const results = normalizeAll(parsed.rows);
    const sets = results.flatMap((r) => r.sets);
    const unloaded = sets.filter((s) => s.weightKg === null);
    expect(unloaded.length).toBeGreaterThan(0);
    expect(unloaded.every((s) => s.weightKg === null)).toBe(true);
  });

  it("converts the real distance column from kilometres to metres", () => {
    const sets = normalizeAll(parsed.rows).flatMap((r) => r.sets);
    const distances = sets.filter((s) => s.distanceM !== null).map((s) => Number(s.distanceM));
    // One genuine distance in the slice: a 4.15 km treadmill set, which must
    // reach canonical storage as 4150 metres.
    expect(distances).toEqual([4150]);
  });

  it("carries the real duration column through unchanged, in seconds", () => {
    const sets = normalizeAll(parsed.rows).flatMap((r) => r.sets);
    const durations = sets.filter((s) => s.durationS !== null).map((s) => Number(s.durationS));
    expect(durations.filter((d) => d > 0)).toEqual([1800]);
  });

  it("numbers sets within their own exercise, not across the session", () => {
    const results = normalizeAll(parsed.rows);
    const sets = results.flatMap((r) => r.sets);
    // A set belongs to (workout, exercise slot), so that is the grouping.
    const byExercise = new Map<string, number[]>();
    for (const s of sets) {
      const slot = `${s.workoutNaturalKey}#${s.exerciseOrderIndex}`;
      byExercise.set(slot, [...(byExercise.get(slot) ?? []), s.setNumber]);
    }
    expect(byExercise.size).toBeGreaterThan(1);
    for (const numbers of byExercise.values()) {
      expect(numbers).toEqual(numbers.map((_, i) => i + 1));
    }
  });

  it("is reproducible: normalizing twice yields identical canonical rows", () => {
    expect(JSON.stringify(normalizeAll(parsed.rows))).toBe(JSON.stringify(normalizeAll(parsed.rows)));
  });

  it("contains no free text the person wrote", () => {
    // The anonymisation contract, asserted rather than trusted: workout titles
    // are replaced, descriptions and per-exercise notes are removed.
    for (const row of parsed.rows) {
      expect(row.title).toMatch(/^Session \d+$/);
      expect((row.description ?? "").trim()).toBe("");
      expect((row.exercise_notes ?? "").trim()).toBe("");
    }
  });
});
