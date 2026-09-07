import { describe, expect, it } from "vitest";

import {
  addDays,
  buildMetricChart,
  chartRefusal,
  CHART_RANGES,
  isChartRange,
  MIN_CHART_OBSERVATIONS,
  parseChartRange,
  RANGE_DAYS,
  resolveRange,
  toIsoDate,
  type MetricSummary,
} from "@/lib/read-model/charts";

/**
 * The chart read model's pure half.
 *
 * Range arithmetic and the observation gate are decisions, not queries, so
 * they are tested here rather than against a database. Everything that touches
 * metric_daily is proved in tests/phase7 against a real Postgres.
 */

const summary = (over: Partial<MetricSummary> = {}): MetricSummary => ({
  metricKey: "weight",
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
  ...over,
});

describe("range parsing", () => {
  it("accepts every declared range and nothing else", () => {
    for (const range of CHART_RANGES) expect(isChartRange(range)).toBe(true);
    expect(isChartRange("6M")).toBe(false);
    expect(isChartRange("")).toBe(false);
    expect(isChartRange(undefined)).toBe(false);
    expect(isChartRange(7)).toBe(false);
  });

  it("falls back to the default rather than throwing on junk", () => {
    expect(parseChartRange("30D")).toBe("30D");
    expect(parseChartRange("../../etc/passwd")).toBe("90D");
    expect(parseChartRange(undefined)).toBe("90D");
  });
});

describe("date arithmetic", () => {
  it("adds days across a month boundary", () => {
    expect(addDays("2026-02-28", 1)).toBe("2026-03-01");
    expect(addDays("2026-03-01", -1)).toBe("2026-02-28");
  });

  it("adds days across a leap day", () => {
    expect(addDays("2024-02-28", 1)).toBe("2024-02-29");
    expect(addDays("2024-02-29", 1)).toBe("2024-03-01");
  });

  it("adds days across a year boundary", () => {
    expect(addDays("2025-12-31", 1)).toBe("2026-01-01");
    expect(addDays("2026-01-01", -1)).toBe("2025-12-31");
  });

  it("formats a date in UTC, not in the runner's timezone", () => {
    expect(toIsoDate(new Date("2026-03-09T23:30:00Z"))).toBe("2026-03-09");
    expect(toIsoDate(new Date("2026-03-09T00:30:00Z"))).toBe("2026-03-09");
  });
});

describe("resolveRange", () => {
  it("makes each fixed range exactly that many days, inclusive of today", () => {
    for (const range of ["7D", "30D", "90D", "1Y"] as const) {
      const { from, to } = resolveRange(range, "2026-03-09", "2020-01-01");
      expect(to).toBe("2026-03-09");
      // from..to inclusive spans RANGE_DAYS days, so from is (days - 1) back.
      expect(from).toBe(addDays("2026-03-09", -(RANGE_DAYS[range] - 1)));
    }
  });

  it("anchors on today rather than on the last observation", () => {
    // The most recent measurement is months old. A 7-day window must still be
    // the last seven days, showing that nothing was recorded in them.
    const { from, to } = resolveRange("7D", "2026-03-09", "2025-11-01");
    expect(from).toBe("2026-03-03");
    expect(to).toBe("2026-03-09");
  });

  it("starts an all-time range at the first observation", () => {
    expect(resolveRange("ALL", "2026-03-09", "2025-11-01")).toEqual({
      range: "ALL",
      from: "2025-11-01",
      to: "2026-03-09",
    });
  });

  it("collapses an all-time range to today when there is no history", () => {
    expect(resolveRange("ALL", "2026-03-09", null)).toEqual({
      range: "ALL",
      from: "2026-03-09",
      to: "2026-03-09",
    });
  });

  it("never produces a range that starts after it ends", () => {
    // A first observation dated in the future (a clock skew, a bad import)
    // must not invert the window.
    const { from, to } = resolveRange("ALL", "2026-03-09", "2027-01-01");
    expect(from <= to).toBe(true);
  });
});

describe("the observation gate", () => {
  it("distinguishes nothing recorded from not enough recorded", () => {
    expect(chartRefusal(summary({ observationCount: 0 }), "30 days")).toMatch(/No 30 days/);
    expect(chartRefusal(summary({ observationCount: 1 }), "30 days")).toBe(
      "1 measurement in this range. A trend needs at least 3.",
    );
    expect(chartRefusal(summary({ observationCount: 2 }), "30 days")).toBe(
      "2 measurements in this range. A trend needs at least 3.",
    );
  });

  it("stops refusing at the threshold", () => {
    expect(chartRefusal(summary({ observationCount: 3 }), "30 days")).toBeNull();
    expect(chartRefusal(summary({ observationCount: 90 }), "30 days")).toBeNull();
  });

  it("uses the threshold it is given", () => {
    expect(chartRefusal(summary({ observationCount: 2 }), "30 days", 2)).toBeNull();
    expect(chartRefusal(summary({ observationCount: 4 }), "30 days", 5)).toMatch(
      /at least 5\.$/,
    );
  });

  it("defaults to the repository's own precedent of three", () => {
    expect(MIN_CHART_OBSERVATIONS).toBe(3);
  });
});

describe("buildMetricChart", () => {
  const metric = {
    key: "weight",
    displayName: "Weight",
    unit: "kg",
    gapPolicy: "carry_forward" as const,
  };

  it("marks a metric with enough observations chartable", () => {
    const chart = buildMetricChart(
      metric,
      [{ localDate: "2026-03-02", value: 80, observed: true, filled: false }],
      summary({ observationCount: 3, sufficient: true, changeAbsolute: -1.6 }),
      "30 days",
    );
    expect(chart.chartable).toBe(true);
    expect(chart.metricKey).toBe("weight");
  });

  it("refuses one without, and says why", () => {
    const chart = buildMetricChart(
      metric,
      [{ localDate: "2026-03-02", value: 80, observed: true, filled: false }],
      summary({ observationCount: 1, lastValue: 80 }),
      "30 days",
    );
    expect(chart.chartable).toBe(false);
    if (!chart.chartable) expect(chart.reason).toMatch(/at least 3/);
  });

  it("keeps the measured facts even when it refuses the trend", () => {
    // The gate withholds the trend, not the measurement: a person who recorded
    // one weight is entitled to see it.
    const chart = buildMetricChart(
      metric,
      [],
      summary({ observationCount: 1, lastValue: 80, lastDate: "2026-03-02" }),
      "30 days",
    );
    expect(chart.chartable).toBe(false);
    expect(chart.summary.lastValue).toBe(80);
    expect(chart.summary.changeAbsolute).toBeNull();
  });
});
