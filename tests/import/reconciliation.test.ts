import { describe, expect, it } from "vitest";

import {
  availableDecisions,
  blockingGuards,
  evaluateGuards,
  OVERRIDABLE_GUARDS,
  OVERRIDE_MIN_REASON_LENGTH,
  overrideAvailability,
  retireDateHistogram,
  retireKeySample,
  type ReconciliationInput,
} from "@/lib/import/reconciliation";

/** A complete, healthy snapshot: every guard passes. */
const healthy: ReconciliationInput = {
  hadFatalErrors: false,
  rowsTotal: 100,
  recordsInvalid: 0,
  validRowCount: 100,
  addCount: 10,
  updateCount: 2,
  unchangedCount: 88,
  retireCount: 1,
  existingInScopeCount: 100,
  incomingInScopeCount: 100,
  fileDateFrom: "2026-01-01",
  fileDateTo: "2026-03-01",
  existingDateFrom: "2026-01-01",
  existingDateTo: "2026-03-01",
  retirementsOutsideFileSpan: 0,
  retirementsFromOtherSources: 0,
  retirementsFromManual: 0,
  reducedBucketsSkipped: 0,
};

const guard = (input: Partial<ReconciliationInput>) => evaluateGuards({ ...healthy, ...input });

describe("a healthy snapshot", () => {
  it("passes every guard and may be confirmed", () => {
    const { results, verdict } = guard({});
    expect(verdict).toBe("safe");
    expect(results).toHaveLength(10);
    expect(results.every((r) => r.outcome === "pass")).toBe(true);
    expect(availableDecisions(results).canConfirm).toBe(true);
  });
});

describe("G4, the truncated-export guard", () => {
  it("blocks when the file covers less than 70% of what exists in scope", () => {
    const { results, verdict } = guard({ incomingInScopeCount: 33, existingInScopeCount: 100 });
    expect(verdict).toBe("blocked");
    const g4 = results.find((r) => r.id === "G4")!;
    expect(g4.outcome).toBe("blocked");
    expect(g4.detail).toContain("33%");
    expect(g4.detail).toContain("partial rather than complete");
  });

  it("passes at exactly the floor", () => {
    expect(guard({ incomingInScopeCount: 70, existingInScopeCount: 100 }).results.find((r) => r.id === "G4")!.outcome).toBe("pass");
  });

  it("is overridable, and the append-only fallback is always offered", () => {
    const { results } = guard({ incomingInScopeCount: 10, existingInScopeCount: 100 });
    const decisions = availableDecisions(results);
    expect(decisions.canConfirm).toBe(false);
    expect(decisions.canOverride).toContain("G4");
    expect(decisions.appendOnlyAvailable).toBe(true);
  });
});

describe("G9 is absolute", () => {
  it("blocks any retirement targeting a manual record", () => {
    const { results, verdict } = guard({ retirementsFromManual: 1 });
    expect(verdict).toBe("blocked");
    expect(results.find((r) => r.id === "G9")!.outcome).toBe("blocked");
  });

  it("is not in the overridable set, and its presence removes every override", () => {
    expect(OVERRIDABLE_GUARDS.has("G9")).toBe(false);
    const { results } = guard({ retirementsFromManual: 1, incomingInScopeCount: 10 });
    expect(availableDecisions(results).canOverride).toEqual([]);
  });
});

describe("the other blocking guards", () => {
  it("G1 blocks a partly failed parse", () => {
    expect(guard({ recordsInvalid: 6, rowsTotal: 100 }).verdict).toBe("blocked");
    expect(guard({ hadFatalErrors: true }).verdict).toBe("blocked");
    expect(guard({ recordsInvalid: 5, rowsTotal: 100 }).results.find((r) => r.id === "G1")!.outcome).toBe("pass");
  });

  it("G2 blocks a file with fewer than ten valid rows", () => {
    expect(guard({ validRowCount: 9 }).results.find((r) => r.id === "G2")!.outcome).toBe("blocked");
    expect(guard({ validRowCount: 10 }).results.find((r) => r.id === "G2")!.outcome).toBe("pass");
  });

  it("G3 blocks a file that matches nothing but wants to retire", () => {
    expect(
      guard({ addCount: 0, updateCount: 0, unchangedCount: 0, retireCount: 5 }).results.find((r) => r.id === "G3")!.outcome,
    ).toBe("blocked");
  });

  it("G7 blocks a retirement outside the file's own date range", () => {
    expect(guard({ retirementsOutsideFileSpan: 1 }).results.find((r) => r.id === "G7")!.outcome).toBe("blocked");
  });

  it("G8 blocks a scope leak into another source", () => {
    expect(guard({ retirementsFromOtherSources: 1 }).results.find((r) => r.id === "G8")!.outcome).toBe("blocked");
  });

  it("none of G1, G2, G3, G7, G8 or G9 is overridable", () => {
    for (const id of ["G1", "G2", "G3", "G7", "G8", "G9"] as const) {
      expect(OVERRIDABLE_GUARDS.has(id)).toBe(false);
    }
  });
});

describe("the warning guards", () => {
  it("G5 warns and narrows scope when the file span is much shorter", () => {
    const g5 = guard({ fileDateFrom: "2026-01-01", fileDateTo: "2026-01-05" }).results.find((r) => r.id === "G5")!;
    expect(g5.outcome).toBe("warn");
    expect(g5.detail).toContain("scope narrowed");
  });

  it("G6 warns on a large retirement and is overridable", () => {
    const { results, verdict } = guard({ retireCount: 40, existingInScopeCount: 100 });
    expect(results.find((r) => r.id === "G6")!.outcome).toBe("warn");
    expect(verdict).toBe("warn");
    expect(OVERRIDABLE_GUARDS.has("G6")).toBe(true);
  });

  it("a warn verdict may still be confirmed", () => {
    const { results } = guard({
      retireCount: 600,
      existingInScopeCount: 10000,
      incomingInScopeCount: 10000,
    });
    expect(availableDecisions(results).canConfirm).toBe(true);
  });
});

describe("what the confirmation screen is given", () => {
  it("caps the retirement examples at fifty", () => {
    expect(retireKeySample(Array.from({ length: 1243 }, (_, i) => i))).toHaveLength(50);
  });

  it("shapes retirements into a per-month histogram", () => {
    expect(retireDateHistogram(["2026-01-05", "2026-01-19", "2026-02-02"])).toEqual({
      "2026-01": 2,
      "2026-02": 1,
    });
  });

  it("reports the guards that actually blocked", () => {
    const { results } = guard({ incomingInScopeCount: 1, retirementsFromManual: 2 });
    expect(blockingGuards(results).map((r) => r.id).sort()).toEqual(["G4", "G9"]);
  });
});

describe("override availability (Phase 5.1)", () => {
  const guard = (id: string, outcome: string, overridable: boolean) =>
    ({ id, outcome, detail: `${id} ${outcome}`, overridable }) as never;

  it("offers no override when nothing blocked", () => {
    const availability = overrideAvailability([guard("G4", "pass", true)]);
    expect(availability.available).toBe(false);
    expect(availability.overridable).toEqual([]);
  });

  it("offers an override when every blocking guard has one", () => {
    const availability = overrideAvailability([
      guard("G4", "blocked", true),
      guard("G6", "warn", true),
    ]);
    expect(availability.available).toBe(true);
    expect(availability.overridable).toEqual(["G4"]);
    expect(availability.nonOverridable).toEqual([]);
  });

  it("requires an override to cover EVERY blocking guard", () => {
    // Overriding one of two would leave the plan blocked while implying the
    // user had dealt with it. The database enforces the same rule.
    const availability = overrideAvailability([
      guard("G4", "blocked", true),
      guard("G6", "blocked", true),
    ]);
    expect(availability.available).toBe(true);
    expect(availability.overridable).toEqual(["G4", "G6"]);
  });

  it("offers nothing when a non-overridable guard is among the blockers", () => {
    const availability = overrideAvailability([
      guard("G4", "blocked", true),
      guard("G9", "blocked", false),
    ]);
    expect(availability.available).toBe(false);
    expect(availability.nonOverridable).toEqual(["G9"]);
    expect(availableDecisions([
      guard("G4", "blocked", true),
      guard("G9", "blocked", false),
    ]).canOverride).toEqual([]);
  });

  it("G9 is never overridable, whatever a guard result claims", () => {
    expect(OVERRIDABLE_GUARDS.has("G9" as never)).toBe(false);
  });

  it("names a minimum reason length the database also enforces", () => {
    expect(OVERRIDE_MIN_REASON_LENGTH).toBeGreaterThanOrEqual(10);
  });
});
