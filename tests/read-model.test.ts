import { describe, expect, it } from "vitest";

import {
  daysBetween,
  formatAxisDate,
  formatCount,
  formatDateSpan,
  formatDistanceM,
  formatDuration,
  formatLocalDate,
  formatRpe,
  formatVolumeKg,
  formatWeightKg,
  toInt,
  toNumber,
} from "@/lib/read-model/format";
import {
  MIN_PROGRESSION_SESSIONS,
  buildProgressionSeries,
  volumeSeriesIsChartable,
  type ExerciseSession,
  type TrainingWeek,
} from "@/lib/read-model/training";

/**
 * The presentation and derivation rules of the training read model.
 *
 * The database side of the read model is asserted against real canonical rows
 * in tests/phase4/10_read_model.sql. This file covers the parts that run in
 * the application: wire-format coercion, formatting, and the decision about
 * whether a comparison is legitimate at all.
 */

describe("wire format coercion", () => {
  it("accepts the JSON number PostgREST normally sends for numeric", () => {
    expect(toNumber(12610)).toBe(12610);
    expect(toNumber(0)).toBe(0);
  });

  it("accepts the string form without concatenating it", () => {
    expect(toNumber("60.000000")).toBe(60);
    expect(toNumber("60.000000")! + 1).toBe(61);
  });

  it("keeps null distinct from zero", () => {
    expect(toNumber(null)).toBeNull();
    expect(toNumber(undefined)).toBeNull();
    expect(toNumber("not a number")).toBeNull();
    expect(toInt(null)).toBe(0);
  });
});

describe("formatting", () => {
  it("renders counts, weights and RPE", () => {
    expect(formatCount(1234)).toBe("1,234");
    expect(formatCount(null)).toBe("—");
    expect(formatWeightKg(62.5)).toBe("62.5 kg");
    expect(formatWeightKg(null)).toBe("—");
    expect(formatRpe(9.5)).toBe("9.5");
  });

  it("switches volume to tonnes past ten thousand kilos", () => {
    expect(formatVolumeKg(480)).toBe("480 kg");
    expect(formatVolumeKg(9999)).toBe("9,999 kg");
    expect(formatVolumeKg(12610)).toBe("12.6 t");
    expect(formatVolumeKg(null)).toBe("—");
  });

  it("switches distance to kilometres past a thousand metres", () => {
    expect(formatDistanceM(40)).toBe("40 m");
    expect(formatDistanceM(1500)).toBe("1.5 km");
  });

  it("renders durations as a person would say them", () => {
    expect(formatDuration(45)).toBe("45s");
    expect(formatDuration(2880)).toBe("48m");
    expect(formatDuration(4320)).toBe("1h 12m");
    expect(formatDuration(7200)).toBe("2h");
    expect(formatDuration(null)).toBe("—");
  });

  it("formats a local_date as the calendar date it is, not as an instant", () => {
    // The bug this guards: parsing "2026-01-05" in a zone behind UTC yields the
    // 4th. local_date is stored precisely so the user-experienced date survives.
    expect(formatLocalDate("2026-01-05")).toBe("5 Jan 2026");
    expect(formatLocalDate("2026-01-05", "long")).toBe("5 January 2026");
    expect(formatAxisDate("2026-01-05")).toBe("5 Jan");
    expect(formatLocalDate(null)).toBe("—");
  });

  it("collapses a one-day span to a single date", () => {
    expect(formatDateSpan("2026-01-05", "2026-01-05")).toBe("5 Jan 2026");
    expect(formatDateSpan("2026-01-05", "2026-02-01")).toBe("5 Jan 2026 – 1 Feb 2026");
    expect(daysBetween("2026-01-05", "2026-01-12")).toBe(7);
  });
});

describe("volume series chartability", () => {
  const week = (weekStart: string, volumeKg: number | null): TrainingWeek => ({
    weekStart,
    workoutCount: volumeKg === null ? 0 : 1,
    setCount: volumeKg === null ? 0 : 3,
    volumeSets: volumeKg === null ? 0 : 3,
    volumeKg,
    totalReps: volumeKg === null ? null : 15,
  });

  it("refuses to draw a trend through a single observation", () => {
    expect(volumeSeriesIsChartable([week("2026-01-05", 900), week("2026-01-12", null)])).toBe(
      false,
    );
  });

  it("draws once two weeks carry a real observation", () => {
    expect(volumeSeriesIsChartable([week("2026-01-05", 900), week("2026-01-12", 950)])).toBe(true);
  });

  it("refuses a window where nothing loaded was ever recorded", () => {
    expect(
      volumeSeriesIsChartable([week("2026-01-05", null), week("2026-01-12", null)]),
    ).toBe(false);
  });
});

describe("progression series", () => {
  const session = (
    localDate: string,
    overrides: Partial<ExerciseSession> = {},
  ): ExerciseSession => ({
    workoutId: `w-${localDate}`,
    workoutTitle: "Session",
    localDate,
    setCount: 3,
    volumeSets: 0,
    totalVolumeKg: null,
    topWeightKg: null,
    totalReps: null,
    totalDistanceM: null,
    totalDurationS: null,
    bestSetReps: null,
    bestSetWeight: null,
    ...overrides,
  });

  const loaded = ["2026-01-05", "2026-01-12", "2026-01-19"].map((date, index) =>
    session(date, {
      volumeSets: 3,
      totalVolumeKg: 900 + index * 30,
      topWeightKg: 60 + index,
      totalReps: 15,
      bestSetWeight: 60 + index,
      bestSetReps: 5,
    }),
  );

  it("charts load for an exercise whose sets carry weight and reps", () => {
    const series = buildProgressionSeries("load", loaded);
    expect(series.chartable).toBe(true);
    if (!series.chartable) return;
    expect(series.unit).toBe("kg");
    expect(series.points.map((point) => point.value)).toEqual([60, 61, 62]);
    expect(series.secondary?.metricLabel).toBe("Session volume");
    expect(series.secondary?.points.map((point) => point.value)).toEqual([900, 930, 960]);
  });

  it("charts distance for a distance exercise, and never on the load axis", () => {
    const carries = ["2026-01-05", "2026-01-12", "2026-01-19"].map((date, index) =>
      session(date, { totalDistanceM: 40 + index * 5 }),
    );
    const series = buildProgressionSeries("distance", carries);
    expect(series.chartable).toBe(true);
    if (!series.chartable) return;
    expect(series.unit).toBe("m");
    expect(series.metricLabel).toBe("Distance per session");
    expect(series.secondary).toBeNull();
    expect(series.points.map((point) => point.value)).toEqual([40, 45, 50]);
  });

  it("charts duration for a duration exercise", () => {
    const planks = ["2026-01-05", "2026-01-12", "2026-01-19"].map((date, index) =>
      session(date, { totalDurationS: 90 + index * 10 }),
    );
    const series = buildProgressionSeries("duration", planks);
    expect(series.chartable).toBe(true);
    if (!series.chartable) return;
    expect(series.unit).toBe("s");
  });

  it("refuses an exercise whose sets record no measurement at all", () => {
    const series = buildProgressionSeries("none", [session("2026-01-05")]);
    expect(series.chartable).toBe(false);
    if (series.chartable) return;
    expect(series.reason).toMatch(/nothing to compare/);
  });

  it("refuses to draw a progression through fewer than the minimum sessions", () => {
    const series = buildProgressionSeries("load", loaded.slice(0, MIN_PROGRESSION_SESSIONS - 1));
    expect(series.chartable).toBe(false);
    if (series.chartable) return;
    expect(series.reason).toContain(String(MIN_PROGRESSION_SESSIONS));
  });

  it("counts only the sessions that carry the measurement, not every session", () => {
    // Six sessions, but only two of them recorded a load: that is two points,
    // not six, and it is below the floor.
    const sparse = [
      ...loaded.slice(0, 2),
      session("2026-01-26"),
      session("2026-02-02"),
      session("2026-02-09"),
      session("2026-02-16"),
    ];
    const series = buildProgressionSeries("load", sparse);
    expect(series.chartable).toBe(false);
    if (series.chartable) return;
    expect(series.reason).toContain("2 of 6");
  });

  it("omits the secondary volume series when too few sessions carry volume", () => {
    const mixed = loaded.map((s, index) =>
      index === 0 ? s : { ...s, volumeSets: 0, totalVolumeKg: null },
    );
    const series = buildProgressionSeries("load", mixed);
    expect(series.chartable).toBe(true);
    if (!series.chartable) return;
    expect(series.secondary).toBeNull();
  });
});
