import { describe, expect, it } from "vitest";

import {
  TRANSFORM_LIBRARY,
  applyTransform,
  createTransformState,
  isTransformName,
  TransformError,
} from "@/lib/import/transforms";
import { TRANSFORM_NAMES } from "@/lib/import/types";

/**
 * The transform library is closed and every primitive is unit tested (v3 §3.2).
 * These are the shared primitives every future profile will lean on, so a
 * regression here is a regression in every vendor at once.
 */

function run(name: string, params: Record<string, unknown>, values: (string | null)[], row = {}) {
  return applyTransform(
    { name: name as (typeof TRANSFORM_NAMES)[number], params },
    { values, row, rowIndex: 0, state: createTransformState() },
  );
}

describe("the library is closed", () => {
  it("implements exactly the eleven declared transforms and no others", () => {
    expect(Object.keys(TRANSFORM_LIBRARY).sort()).toEqual([...TRANSFORM_NAMES].sort());
  });

  it("rejects a name that is not in the library", () => {
    expect(isTransformName("exec_arbitrary_code")).toBe(false);
    expect(() => run("exec_arbitrary_code", {}, ["x"])).toThrow();
  });
});

describe("parse_duration", () => {
  it.each([
    ["1:24:33", 5073],
    ["24:33", 1473],
    ["84 min", 5040],
    ["1h 24m", 5040],
    ["90s", 90],
    ["45", 45],
    ["2 hours 30 minutes", 9000],
  ])("parses %s to %i seconds", (input, expected) => {
    expect(run("parse_duration", {}, [input])).toBe(expected);
  });

  it("returns null for a blank cell", () => {
    expect(run("parse_duration", {}, [""])).toBeNull();
    expect(run("parse_duration", {}, [null])).toBeNull();
  });

  it("throws rather than coercing an unparseable duration to zero", () => {
    expect(() => run("parse_duration", {}, ["about an hour"])).toThrow(TransformError);
  });
});

describe("extract_number_and_unit", () => {
  it("splits an embedded unit", () => {
    expect(run("extract_number_and_unit", {}, ["182.1 lb"])).toEqual({ value: 182.1, unit: "lb" });
  });
  it("handles a bare number", () => {
    expect(run("extract_number_and_unit", {}, ["75"])).toEqual({ value: 75, unit: null });
  });
  it("honours a declared comma decimal separator", () => {
    expect(run("extract_number_and_unit", { decimal_separator: "," }, ["82,6 kg"])).toEqual({
      value: 82.6,
      unit: "kg",
    });
  });
  it("throws on something that is not a measurement", () => {
    expect(() => run("extract_number_and_unit", {}, ["heavy"])).toThrow(TransformError);
  });
});

describe("split_reference_range", () => {
  it.each([
    ["3.5 - 5.1", { low: 3.5, high: 5.1 }],
    ["3.5-5.1", { low: 3.5, high: 5.1 }],
    ["10 to 20", { low: 10, high: 20 }],
  ])("splits %s", (input, expected) => {
    expect(run("split_reference_range", {}, [input])).toEqual(expected);
  });
});

describe("map_values", () => {
  const params = { map: { normal: "working", warmup: "warmup" }, default: "working" };

  it("looks a value up", () => {
    expect(run("map_values", params, ["warmup"])).toBe("warmup");
  });
  it("is case tolerant", () => {
    expect(run("map_values", params, ["Normal"])).toBe("working");
  });
  it("falls back to the declared default", () => {
    expect(run("map_values", params, ["dropset"])).toBe("working");
  });
  it("throws when there is no mapping and no default", () => {
    expect(() => run("map_values", { map: { a: "b" } }, ["z"])).toThrow(TransformError);
  });
  it("uses the declared blank value for an empty cell", () => {
    expect(run("map_values", { ...params, blank: "working" }, [""])).toBe("working");
  });
});

describe("row_index_within_group", () => {
  it("numbers rows 1-based within each group and restarts per group", () => {
    const state = createTransformState();
    const ref = { name: "row_index_within_group" as const, params: { group_by: ["w", "e"] } };
    const seen = [
      { w: "A", e: "bench" },
      { w: "A", e: "bench" },
      { w: "A", e: "press" },
      { w: "B", e: "bench" },
      { w: "A", e: "bench" },
    ].map((row, rowIndex) => applyTransform(ref, { values: [], row, rowIndex, state }));
    expect(seen).toEqual([1, 2, 1, 1, 3]);
  });
});

describe("coalesce_columns", () => {
  it("returns the first non-empty value", () => {
    expect(run("coalesce_columns", {}, ["", "  ", "third"])).toBe("third");
  });
  it("returns null when everything is empty", () => {
    expect(run("coalesce_columns", {}, ["", null])).toBeNull();
  });
});

describe("scale, blank_as_null, boolean_map, concat_datetime, parse_pace", () => {
  it("scales by a declared constant", () => {
    expect(run("scale", { factor: 1000 }, ["1.5"])).toBe(1500);
  });
  it("treats declared sentinels as null", () => {
    expect(run("blank_as_null", { values: ["-", "N/A"] }, ["-"])).toBeNull();
    expect(run("blank_as_null", { values: ["-"] }, ["7"])).toBe("7");
  });
  it("maps booleans both ways", () => {
    expect(run("boolean_map", {}, ["Yes"])).toBe(true);
    expect(run("boolean_map", {}, ["0"])).toBe(false);
    expect(() => run("boolean_map", {}, ["maybe"])).toThrow(TransformError);
  });
  it("joins a date and a time column", () => {
    expect(run("concat_datetime", {}, ["2026-01-05", "18:03:00"])).toBe("2026-01-05 18:03:00");
  });
  it("parses a pace into seconds", () => {
    expect(run("parse_pace", {}, ["5:32 /km"])).toBe(332);
  });
});

describe("purity", () => {
  it("gives the same answer for the same input every time", () => {
    for (let i = 0; i < 5; i += 1) {
      expect(run("parse_duration", {}, ["1:24:33"])).toBe(5073);
      expect(run("extract_number_and_unit", {}, ["182.1 lb"])).toEqual({ value: 182.1, unit: "lb" });
    }
  });
});
