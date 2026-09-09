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

---

## N-8. G4 is a safety gate with an audited override, not a prohibition

**Status:** accepted for Phase 5.1. Authority: v3 §4.3, which always described
G4 and G6 as overridable; explicit user direction on the resolution.

**The contradiction this closes.** Phase 3 built three quarters of an override.
The engine reported G4 as overridable, the UI offered "Override G4 and retire"
with a typed confirmation, and `retirement_overrides` existed to record it. The
persistence layer disagreed, in three places: a CHECK constraint
(`reconciliation_plans_blocked_is_never_confirmed`), the retiring-status
trigger, and the retirement guard all required `verdict <> 'blocked'`. The
decision route sealed it by returning 409 for any confirmation of a blocked
plan before it looked at the override fields. The product therefore offered an
action the system could not complete.

**The model now.** A blocked plan is confirmable exactly when **every** guard
that blocked it carries an acknowledged override row belonging to the plan's
owner. That predicate,
`public.reconciliation_plan_override_is_complete(plan_id)`, is the single
definition, consulted by the confirmation trigger, the retiring-status trigger
and the retirement guard.

**Why the distinction is relational rather than a flag.** The question "was
this retired normally, or through an explicit override of a safety block?" is
answered by two existing facts — the plan's `verdict`, and whether override
rows exist for it — not by a new boolean that could drift from them.
`v_retirement_audit` derives `was_safety_override` from those facts. The
verdict is never rewritten: a plan G4 blocked still reads `blocked` after an
override, forever.

**Why G9 needs no special case.** `retirement_overrides_guard_overridable`
already makes an override row unwritable for any guard outside {G4, G6}. A plan
G9 blocked therefore can never satisfy "every blocking guard has an override".
The absolute guard stays absolute because the audit table refuses to record the
thing that would excuse it — and the retirement guard evaluates G9 a second
time, on the row's own provenance, with no override path at all.

**Where the requirements live.** In the database. The client holds INSERT on
`retirement_overrides` because the row is the user's own typed confirmation, so
the requirements are enforced by a BEFORE INSERT trigger rather than by the
route: the guard must really have blocked this plan, the typed confirmation is
checked against the plan's own `retire_count`, the acknowledgement must be
given, a reason of at least ten characters is required, and the guard evidence
is copied from the plan rather than accepted from the caller. A client that
skips the API gains nothing.

**What an override does not buy.** Only permission to proceed past a blocked
verdict. It does not relax G9, the persisted key set, plan immutability, the
one-confirmed-plan-per-import rule, the 24-hour staleness window, or the
retirement guard. There is no second retirement implementation: the override
path executes the same lifecycle, and the same analytics invalidation follows.

**The signal to revisit.** A guard becoming overridable that is not a coverage
or volume heuristic. The overridable set is a deliberate list, and widening it
is a decision about what the guards are for, not a configuration change.

---

## N-9. `metric_daily` is written by two domains, partitioned by the registry

*Phase 7. Not a deviation from v2 §9; a consequence of it that Phase 5 could
defer while training was the only domain.*

**The problem.** Phase 5's `rollup_recompute_training_day` deleted its scope
with `where user_id = $1 and local_date = $2` and no `metric_key` filter. That
was correct while `metric_daily` held training aggregates and nothing else.
Phase 7 adds a second writer, and two whole-day deletes over one table means
each domain silently erases the other's rows for every day a person both
trained and measured themselves — repaired by the next rebuild of the surviving
domain, and re-broken by the next run of the other. Invisible either way.

**The resolution.** v2 §9.2's own tier-1 statement is scoped per metric
(`WHERE user_id = $1 AND metric_key = $2 AND local_date = $3`). Phase 5 widened
it because one domain made that safe; Phase 7 narrows it back. Both recompute
functions now delete and rebuild exactly the keys their own domain owns.

**Where the partition lives.** `metric_definitions.rollup_domain`, `NOT NULL`
with a two-value check, so the domains are exhaustive and disjoint by
construction and no metric key can be unowned. It is a registry column and not
a key list in SQL for the reason I-6 exists: a list of metric keys written into
engine code is a free-text identifier, and it would be wrong the moment a
metric is seeded.

**What did not change.** The queue scope is still `(user_id, domain,
local_date)`, per ADR-19. One scan of `v_metrics` for a user-day produces every
metric's tier-1 rows, exactly as one scan of the `v_strength_*` views produces
every training metric's, so a metric-grain scope would make the worker rescan
the same day once per metric for no correctness gain. `rollup_queue` gained one
value in its domain check and nothing else.

**The signal to revisit.** A third domain whose grain is not a user-day, or a
metric that genuinely belongs to both domains. Neither exists, and the second
would be a contradiction rather than a configuration: a metric is either
observed or computed.

---

## N-10. `contributing_metric_ids`, and why the provenance column is not shared

*Phase 7.*

`metric_daily_source.contributing_workout_ids` answers "which canonical records
produced this figure" from the row itself. A metrics-domain row has no
workouts; its contributing records are `metrics`, whose ids are `bigint` rather
than `uuid`. Reusing the column was not possible and widening it to `text[]`
would have made both grains' provenance untyped, so the table carries a second,
correctly typed column and each domain fills its own. The alternative — leaving
the metrics grain with no provenance — would have made it the one part of the
analytics layer that cannot say where its numbers came from.

---

## N-11. `day_attribution = 'wake_date'` is inert for scalar sleep

*Phase 7. A boundary, recorded so it is a decision rather than an oversight.*

Seed 0002 sets `sleep_duration.day_attribution = 'wake_date'`, from v2 §8.4 and
decision D7. Nothing reads it: `metrics.local_date` is computed once at
normalize time from the observation's own timestamp
(`src/lib/import/timestamps.ts`), and the metrics rollup groups by that date.

This is not a gap in Phase 7. A scalar `sleep_duration` observation is a point
in time with no session behind it, so there is no start-of-sleep to attribute
away from: the date it was recorded on **is** the wake date. Wake-date
attribution becomes meaningful only when a sleep **session** carries a start
and an end that straddle midnight, and sleep sessions are out of scope
(`CLAUDE.md` §6).

**The signal to revisit.** The phase that lands sleep sessions. At that point
`day_attribution` must be read — most naturally in normalization, where
`local_date` is decided — and this note becomes a requirement rather than a
boundary.

---

## N-12. The minimum-observation threshold is an implementation decision

*Phase 7.*

`MIN_CHART_OBSERVATIONS = 3` in `src/lib/read-model/charts.ts` is **not**
architecture-defined. No authoritative document states a value: v2 §12 Phase 9
and v3 §5 Phase 9 place minimum-N gates and `INSUFFICIENT_DATA` in a later
phase and specify no number, and `CLAUDE.md` Phase 7 requires
"minimum-observation checks" without one. Three is taken from this
repository's own precedent, `MIN_PROGRESSION_SESSIONS` in the Phase 4 training
read model, which refuses to draw a progression through fewer than three
sessions for the same reason.

It is passed to `body_metric_summary` as a parameter rather than duplicated in
SQL, so there is one definition of it and the database withholds the change
columns below it rather than trusting every caller to hide them. Phase 9 is
where a considered threshold per metric belongs, alongside coverage checks and
`INSUFFICIENT_DATA` as a first-class result; until then this is a defensible
default, not a specification.

---

## N-13. The inline rollup drain is user-scoped, because it runs in a request

*Phase 7. A defect found by the Phase 6 end-to-end suite during Phase 7, and
the reason `rollup_process_scopes` exists.*

Phase 6 drains import jobs inline so a person sees the measurement they just
typed. Phase 7 extended that to the rollup for the same reason: a measurement
that is in the list but not yet on the chart reads as a bug.

The first implementation called the ordinary `rollup_process_pending`, which is
**global** — it claims any pending scope, for any user, up to its limit. Inside
a cron tick that is exactly right. Inside a person's request it is not: one
typed number then waits on every other user's import backlog. The Phase 6
end-to-end suite caught it as a timeout, because by the time it runs the queue
holds the scopes of every earlier spec's users.

The claim loop is therefore `rollup_process_scopes(limit, worker, user_id)`,
with `user_id` NULL meaning "any". Two wrappers preserve both call sites and
both signatures:

- `rollup_process_pending(limit, worker)` — the cron worker, unchanged.
- `rollup_process_user_pending(user_id, limit, worker)` — manual entry, bounded
  at 50 scopes.

The inline path deliberately does **not** reclaim stale claims. Reclaiming is
global maintenance, and a user's request is the wrong place to perform it.

Anything past the inline bound stays queued. That is not a compromise; it is
what the queue is for, and ADR-19's eventual consistency already covers it.

**The signal to revisit.** An inline drain appearing anywhere else. Only manual
entry has a person waiting on the result; every other producer should enqueue
and let the worker drain.

---

## N-14. Manual entry reloads the route; it does not `router.refresh()` it

*Phase 7. A real product defect, found by the Phase 6 end-to-end suite while
Phase 7 was being built, and worth recording because the failure mode is
silent and the wrong fix looks right.*

`MeasurementForm` posted the measurement and then called `router.refresh()`.
That is a best-effort transition, and the App Router aborts its RSC fetch when
another update or a pending prefetch for the same route intervenes — silently.
The trace of the failing run shows it exactly:
`GET /body?_rsc=… → net::ERR_ABORTED`.

The consequence is the worst outcome this form has. The POST returns 201, the
measurement is written, normalized and rolled up correctly, and the page goes
on showing the list without it. The person concludes nothing happened and
records it again.

Whether the race is lost depends on the payload size and on what the router
already has in flight, so this was survivable while `/body` was a form and a
list, and became reproducible the moment Phase 7 put nine chart cards on the
same route. The bug was always there; Phase 7 made it deterministic.

**Two fixes were tried and rejected**, and they are recorded because both look
correct. Moving `setBusy(false)` ahead of the refresh does not help: React
batches every update in the handler into one render, so the plain updates still
land with the transition. Yielding a task before refreshing does not help
either: an aborted prefetch for the same route, issued when the nav link came
into view on the previous page, is enough on its own.

**What it does instead** is `window.location.reload()`. A reload costs one
render of a page the person is already looking at, and it cannot fail to show
what was just written. For a form whose entire purpose is recording a
measurement, that trade is not close.

**The signal to revisit.** A Server Action would be the idiomatic fix: the
action's own response carries the revalidated payload, so there is no separate
fetch to abort. That is a worthwhile refactor of the write path and it is not
Phase 7's job.

**The rule meanwhile.** Do not depend on `router.refresh()` to show a user
their own write.

---

## N-15. `mapping_spec.timestamp.format` was declared but never read

*Phase 3.1. A real product defect: the shipped Hevy profile could not import a
real Hevy export.*

The mapping spec has always carried an optional `timestamp.format`. The schema
validated it, the Hevy profile declared `yyyy-MM-dd HH:mm:ss`, and no code path
ever looked at it. `resolveTimestamp` went straight to a set of built-in shapes
and, failing those, to `Date.parse`.

That is a silent contract: a profile could describe one shape and the engine
would accept a different one, so the declared format proved nothing. The Hevy
profile shipped that way. Its fixture was a faithful reconstruction of the
column contract but not of the timestamp shape — the reconstruction wrote
`2026-01-05 18:03:00`, and Hevy emits `5 Jan 2026, 18:03`. Every gate in
Phase 3, Phase 4, Phase 5 and Phase 5.1 passed against the reconstruction, and a
real export failed on its first row with `cannot parse timestamp`.

**What changed.** `parseByFormat(text, format)` compiles a declared format into
an anchored pattern over a closed token set (`yyyy`, `MMM`, `MM`, `dd`, `d`,
`HH`, `mm`, `ss`) and validates the parts against a real calendar, so
`29 Feb 2025` is refused rather than rolled into 1 March. `resolveTimestamp`
takes the format as a fourth argument and, **when one is declared, that format
governs**: a value that does not match it throws, with no fallback to the
built-in shapes. A profile that declares a shape and receives another now fails
loudly at the row, which is the behaviour the field always implied.

Profiles that declare no format keep the previous inference path unchanged.

**Why the format governs rather than merely being tried first.** A fallback
would have made this defect invisible again: the Hevy profile's wrong format
would have been skipped and the correct shape inferred, and the profile would
still be claiming something untrue about the file it reads. Ingestion is the
one place where guessing is a data-integrity problem (I-6 is the same instinct
applied to identifiers).

**The signal to revisit.** A vendor that emits more than one timestamp shape in
one file. Today no profile does, and the answer would be a per-column format,
not a fallback chain.

---

## N-16. The Hevy profile does not map workout duration

*Phase 3.1. Found while verifying the profile against a real export. Recorded,
not fixed.*

Hevy writes `start_time` and `end_time` on every row. The profile maps
`start_time` to the workout timestamp and, for `strength.workout`, maps only
`title`. Nothing maps `end_time`, so `strength_workouts.duration_s` is null for
every imported Hevy workout, and the product's workout screens show no
duration for real training data.

This is a mapping gap, not an engine gap: `duration_s` exists in the canonical
model, the normalizer writes it when the spec supplies it, and the transform
library already has what a `start_time`/`end_time` difference needs. It is
recorded here rather than fixed because Phase 3.1's scope is the timestamp
contract that made the profile unusable, and widening a corrective phase into
mapping improvements is how corrective phases stop being verifiable.

`tests/import/real-hevy-export.test.ts` asserts the null explicitly, so the day
the mapping is added the assertion fails and this note is what explains why.

**The signal to revisit.** The first phase that touches the Hevy profile for any
other reason, or the first product surface that needs session duration.
