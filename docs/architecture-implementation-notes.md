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
