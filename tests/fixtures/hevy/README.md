# Hevy fixture

`hevy-export.csv` reproduces the Hevy workout-export CSV contract exactly:
the same fourteen columns, in the same order, with the same value conventions
(`set_index` zero-based, `set_type` as `normal`/`warmup`/`failure`/`dropset`,
`weight_kg` in kilograms, `distance_km` in kilometres, blank cells for absent
values, one row per set).

`hevy-export-truncated.csv` is the same file with later workouts removed, for
the Phase 3 Test B snapshot-safety gate.

## Provenance, stated plainly

These are **faithful reconstructions of the export format**, not an anonymized
copy of a real user's export, because no real Hevy export was available to this
build. Exercise titles are the strings Hevy actually emits; the workout content
is synthetic.

`CLAUDE.md` section 5 requires that "every import profile ships with a committed
anonymized real export" and that "a profile is not complete until its fixture
test passes against a real file". By that standard the Hevy profile is
**provisionally complete only**: the engine, the mapping, the transforms and
both hard gates are verified against this fixture, but the final acceptance step
needs a real export dropped in at `hevy-export.csv`, after which the same suite
re-runs unchanged.

## Phase 5 addition

`hevy-export-minus-one.csv` is `hevy-export.csv` with one session from the
MIDDLE of its range (Legs, 9 January) removed: four of five workouts, spanning
the same dates as the original. The session has to come from the middle rather
than from either end, because reconciliation scopes itself to the file's own
date span (v2 §7.4, G5/G7) — a session dropped from the end simply falls
outside the scope and is correctly left alone. A `full_snapshot` import of this
file therefore covers 80% of what exists in scope and proposes retiring exactly
one workout. That is deliberately **inside** every reconciliation guard — above
G4's 70% coverage floor and below G6's 25% retirement ratio — so it exercises
the ordinary confirmed-retirement path that `hevy-export-truncated.csv`, which
is designed to be blocked, cannot reach. `tests/e2e/phase-5-analytics.spec.ts`
uses it to prove that a retirement taken through the product's own confirmation
flow removes that data from the derived metrics.

## Phase 4 addition

`hevy-export-extended.csv` is `hevy-export.csv` plus six further sessions
(19, 21, 23, 26, 28 and 30 January), used only by
`tests/e2e/phase-4-product.spec.ts`. It exists because the Phase 4 product
surface has to be exercised with exercises that reach the three sessions a
progression chart requires, and the Phase 3 fixture is deliberately small —
no exercise in it is performed more than twice. It carries the same provenance
caveat as the file it extends, and it enters through the same profile,
transforms and mapping engine as any other Hevy file.

None of these files is loaded by the application. Nothing in the product seeds,
generates or fabricates health data.
