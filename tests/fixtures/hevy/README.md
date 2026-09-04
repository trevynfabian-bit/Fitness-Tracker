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
