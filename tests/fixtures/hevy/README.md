# Hevy fixtures

Six columns of context before the files: everything here enters the product
through the ordinary import engine — the same profile JSON, the same detection,
the same declarative transforms, the same mapping. None of it is loaded by the
application, and nothing in the product seeds, generates or fabricates health
data.

## `hevy-export-real.csv` — the real export

**A slice of a real Hevy export, anonymized.** Five sessions, 15 exercises, 61
set rows. It is the file `CLAUDE.md` §5 requires ("every import profile ships
with a committed anonymized real export … a profile is not complete until its
fixture test passes against a real file"), and
`tests/import/real-hevy-export.test.ts` is the acceptance suite that reads it.

It is a **slice, not the whole export**, by explicit decision: the full export
is years of one person's training and there is no reason to commit it to a
public repository to prove a parser works. The five sessions were chosen by a
greedy set cover over the real file so that between them they carry every
distinct value shape the export contains — `normal`, `warmup`, `failure` and
`dropset` set types, superset grouping, a populated `rpe`, a blank `weight_kg`,
a real distance (4.15 km) and a real duration (1800 s), and the literal `0`
that Hevy writes into `distance_km` and `duration_seconds` rather than leaving
those cells blank.

**What was changed, and nothing else was:**

- Workout titles replaced with `Session 1` … `Session 5`.
- `description` and `exercise_notes` blanked. Those are the two free-text
  columns a person writes into.
- Dates shifted as a block to begin on Monday 2024-03-04, preserving the
  spacing between sessions and the time of day.

Set values, exercise titles, set types, superset ids, ordering, the column set,
the quoting and the timestamp shape are all exactly as Hevy emitted them. The
anonymization is asserted by the suite, not merely claimed: the last test
re-reads the committed file and fails if a title, a description or a note ever
carries user-authored text again.

**Why this file exists at all.** Until Phase 3.1 the Hevy fixture was a
reconstruction of the column contract, and it differed from reality in exactly
the field that broke the importer: the reconstruction wrote
`2026-01-05 18:03:00`, Hevy emits `5 Jan 2026, 18:03`, and the profile's
declared `timestamp.format` described the former and was read by no code. Every
gate from Phase 3 through Phase 5.1 passed, and a real export failed on its
first row. See `docs/architecture-implementation-notes.md` N-15.

## The pipeline fixtures

These four reproduce the Hevy export contract — the same fourteen columns in the
same order, `set_index` zero-based, `set_type` as
`normal`/`warmup`/`failure`/`dropset`, `weight_kg` in kilograms, `distance_km`
in kilometres, blank cells for absent values, one row per set — with **synthetic
workout content**, because each is shaped for a specific gate rather than for
fidelity.

| File | What it is for |
|---|---|
| `hevy-export.csv` | The Phase 3 Test A end-to-end import |
| `hevy-export-truncated.csv` | Phase 3 Test B: the snapshot-safety gate. Deliberately below G4's coverage floor, so retirement must be blocked |
| `hevy-export-minus-one.csv` | Phase 5: `hevy-export.csv` with one session from the **middle** of its range (Legs, 9 January) removed. The session has to come from the middle because reconciliation scopes itself to the file's own date span (v2 §7.4, G5/G7) — one dropped from the end falls outside scope and is correctly left alone. 80% coverage and exactly one proposed retirement is deliberately **inside** every guard, above G4's 70% floor and below G6's 25% ratio, so it exercises the ordinary confirmed-retirement path that the truncated file, designed to be blocked, cannot reach |
| `hevy-export-extended.csv` | Phase 4: `hevy-export.csv` plus six further sessions (19, 21, 23, 26, 28, 30 January), because a progression chart needs an exercise performed three times and the Phase 3 fixture is deliberately small |

In Phase 3.1 all four were converted from the reconstruction's ISO timestamps to
the shape Hevy actually emits. The conversion is **lossless**: every timestamp
in every one of them ended in `:00`, so the resolved instants — and therefore
the natural keys, and therefore every canonical row and every gate result —
are unchanged from what Phases 3, 4, 5 and 5.1 were verified against.

Their content stays synthetic on purpose. A gate fixture has to hold a
specific, stated relationship to a guard threshold, and the honest way to get
one is to construct it and say so.
