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
