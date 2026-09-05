# Architecture implementation notes

Accepted deviations, boundaries and decisions that are not visible from the
schema alone. Each entry names the authority that settled it.

---

## N-1. `reconciliation_plans.retire_natural_keys` has a cardinality boundary

**Status:** accepted for Phase 3 and the current Hevy scope. Not authorization
to redesign.

v3 §4.2 requires that "retirement executes against the persisted plan's key
set, not against a freshly recomputed one", which is what closes the
time-of-check-to-time-of-use window between preview and confirmation. Its DDL
stores only `retire_key_sample`, capped at "up to 50 examples ... for the UI",
which cannot serve that purpose. `retire_natural_keys text[]` was added to hold
the actual set, with `retire_count` constrained to equal its length and a GIN
index supporting the membership test in the retirement guard.

**The boundary.** One plan row holds the entire target set inline. That is
correct and cheap at strength-import scale: a full Hevy history is on the order
of thousands of sets, and v3 §2.5 projects 15,000 to 40,000 raw records per
year across all sources. It stops being appropriate if reconciliation ever
produces a high-cardinality target set, for example a multi-year daily metric
snapshot across many metrics, where a single row could grow toward or past the
Postgres 1 GB per-value TOAST ceiling and where every plan read would drag the
whole array with it.

**The signal to revisit.** A `retire_count` in the high tens of thousands, or a
plan row whose stored size becomes material. At that point the persisted target
set moves to a child table, for example `reconciliation_plan_targets
(plan_id, user_id, natural_key)` with a unique key on `(plan_id, natural_key)`.
The retirement guard's membership test becomes an indexed lookup against that
table instead of an array containment test, and `retire_count` becomes a count
of child rows. Nothing else in the design changes: the guard, the confirmation
flow and G9 are unaffected.

**Not doing it now** because the child table costs a join on every retirement
check and an extra write path, for a scale the current phases cannot reach.

---

## N-2. Precision classes

Settled by ruling R7 and confirmed after v2 became readable.

| Class | Type | Examples |
|---|---|---|
| Stored measurement values | `NUMERIC(18,6)` | `metrics.value_num`, `strength_sets.weight_kg`, `distance_m`, `volume_kg` |
| Conversion coefficients | `NUMERIC(30,15)` | `unit_conversions.factor`, `unit_conversions."offset"` |
| Architecture-specified bounded values | as specified | `strength_sets.rpe NUMERIC(4,2)` (R5), `reconciliation_plans.retire_ratio NUMERIC(6,4)` (v3 §4.2) |
| Counts, ranks, ordinals | integer types | `sources.precedence_rank`, `raw_records.precedence_rank` |

`tests/phase2/10_pipeline_constraints.sql` asserts this matrix over every
numeric column in the schema, so a new column outside these classes fails the
suite rather than passing unnoticed.

---

## N-3. Ownership integrity: foreign key where possible, trigger only where not

A composite foreign key is used wherever the parent's `user_id` is `NOT NULL`.
Where the parent is a registry whose `user_id` may be `NULL` (a shared system
row), a composite foreign key cannot express the rule at all: a child with
`user_id = X` can never match the parent tuple `(id, NULL)`, so every system row
would become unreferenceable. Those references, and only those, use
`registry_assert_parent_ownership`.

| Mechanism | References |
|---|---|
| Composite FK | `raw_record_id`, `import_id`, `retired_by_import_id`, `workout_id`, `exercise_id`, `plan_id` |
| Ownership trigger | `metric_definition_id`, `unit_id`, `exercise_definition_id`, `canonical_unit_id`, `from_unit_id`, `to_unit_id`, `profile_id` |

---

## N-4. Naming divergences still open

| Divergence | Deferred until |
|---|---|
| `metric_definitions.default_aggregation` vs v2 §2.1 `aggregation_rule`, and the `mean` / `avg` vocabulary | Phase 5, where v2 §9.3 projects the tier-1 column named by it |
| `metric_definitions.key` vs v2 §2.1 `canonical_key` | Accepted naming divergence; nothing consumes the registry's own column name |

`alias` vs `alias_normalized` was closed in Phase 3 Step 0.

---

## N-5. The analytics layer has two grains, and they have different shapes

**Status:** accepted for Phase 5. Authority: v2 §2.4 and §9 for `metric_daily`;
the shape of the exercise grain is an implementation decision recorded here.

v2 §2.4 defines `metric_daily` in long format — one row per
`(user_id, metric_key, local_date)`. That is right and unchanged: the table has
to hold weight, HRV, steps, sleep and every other scalar that Phases 6 and 7
produce, and a long format is the only one that accepts a metric it has never
heard of. The seven training metrics Phase 5 writes are scalars per day and fit
it exactly.

The exercise grain does not fit it. Its measures are a closed set —
sessions, sets, loaded sets, volume, reps, top weight, distance, duration, and
the three "how many sets carried this measurement" counts that
`progression_kind` is derived from — and they are always computed together from
one scan of the same day. Two ways of forcing it into `metric_daily` were
considered and rejected:

1. **Add `exercise_definition_id` to `metric_daily`.** It would be NULL on every
   scalar row the table will ever hold, which is a meaningless dimension on the
   majority of the table and a nullable column in a primary key.
2. **Long format at the exercise grain.** Eleven measures per exercise-day
   multiplies the row count by eleven for no gain: nothing queries one measure
   of one exercise on one day in isolation, and the explorer reads all of them
   at once.

So `exercise_daily` and `exercise_daily_source` are wide fact tables at
`(user_id, exercise_definition_id, local_date)`. They keep the two-tier
structure of ADR-15 — a per-source tier and a resolved tier — because the
resolution question is identical at both grains; only the row shape differs.

**The signal to revisit.** A second strength source, or an exercise-grain
measure that is genuinely open-ended rather than closed. Either would make the
wide table the wrong shape, and the migration is mechanical: the tier-1 table
is regenerable from canonical truth, so it can be rebuilt in any shape.

---

## N-6. `training_volume_kg` has gap policy `null`, not `zero`

**Status:** accepted for Phase 5. Deviates from an example in v2 §9.4, not from
a rule.

v2 §9.4 requires `gap_policy` and gives "training volume gaps are genuine
zeros" as its example of the `zero` case. For a day on which the user did not
train, that is right. The training model has a second case v2's example does
not distinguish:

| Day | `training_workouts` row | `training_volume_kg` row | What the gap means |
|---|---|---|---|
| No training | absent | absent | zero volume, genuinely |
| Planks and carries only | present | absent | no load was recorded |

Both produce an absent volume row, and the volume series alone cannot tell them
apart. Calling both zero states a measurement — "this person lifted zero
kilograms" — where only one of them is a measurement; the other is an absence
of observation. So the policy is `null`, the series carries a gap, and the
Phase 4 product surface already says so on the chart: *"Volume is weight ×
reps, summed over sets recording both. N of M weeks recorded a loaded set; the
rest are drawn as gaps, not as zero."*

`training_workouts`, `training_exercise_slots`, `training_sets` and
`training_volume_sets` do use `zero`, because for those an absent day is
unambiguous: nothing happened, and zero is the true count.

**The signal to revisit.** A consumer that genuinely needs "volume per calendar
day including rest days" as a dense series — a rolling weekly average, say.
That consumer should join against `training_workouts` to tell the two absences
apart, rather than the storage layer flattening them.

---

## N-7. Cross-source resolution for training counts is a pass-through today

**Status:** accepted for Phase 5. Authority: v2 §9.3 and §10.1, ADR-15.

Tier 2 resolves several sources reporting the same metric on the same day by
picking a winning source, per v2 §9.3. For a scalar two devices both measure —
body weight from a scale and a watch — that is exactly right, and it is the
case v2 §10.1 was written about.

Training counts are not that case. If two strength apps each held *different*
sessions on the same day, picking one source would drop the other's sessions;
summing both would double-count any session present in both. Neither is
correct without entity resolution, which v3 §5 places at Phase 11 and
`CLAUDE.md` §6 keeps out of scope.

Today the question cannot arise: one strength source exists, tier 2 is a
pass-through, and `CLAUDE.md` §6 forbids adding another vendor. `source_count`
and `contributing_sources` are written on every tier-2 row so that the day a
second source appears, the situation is visible in the data rather than silent.

**The signal to revisit.** The first `metric_daily` or `exercise_daily` row with
`source_count > 1`. That is the moment to decide, deliberately, between
precedence and resolution — not before.
