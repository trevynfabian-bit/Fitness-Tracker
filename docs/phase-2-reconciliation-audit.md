# Phase 2 Reconciliation Audit

Date: 2026-09-04
Branch: `claude/phase-1-foundation-zwjvhy`
Status: **No architectural blockers remain for Phase 2.**

Supersedes the open questions in `docs/phase-2-architecture-consistency-audit.md`.
Rulings R1 to R7 are treated as authoritative and are not re-argued here.

---

## A. Architecture status

| Document | Readable | Sections reviewed |
|---|---|---|
| `CLAUDE.md` | yes | all; §3 invariants, §4 Phase 2/3, §5 conventions, §6 scope, §7 stop conditions |
| `docs/prd.md` | yes (21,834 bytes, 1,037 lines) | §4 principles, §6.1–6.3, §7.4, §9, §10, §11, §12, §13, §15.2–15.4, §16, §17, §19, §20 |
| `docs/architecture/health-platform-architecture-v2.md` | yes (59,285 bytes, 1,066 lines) | §1.2, §2.1, §2.2, §2.3, §4, §5, §6.2, §7, §8.4, §9.4, §11 |
| `docs/architecture/health-platform-architecture-v3.md` | yes (43,907 bytes, 689 lines) | §2.2, §2.3, §2.7, §2.8, §4.1–4.4, §6 ADR, §7 |

### Cross-document findings relevant to Phases 1–5

Only genuine contradictions and unresolved ambiguities are listed. Items already
settled by R1 to R7 are excluded.

| ID | Finding | Disposition |
|---|---|---|
| X1 | PRD §16 Phase 2 lists "canonical strength data structures" and does not mention `metrics`. `CLAUDE.md` Phase 2 and R1 both include `metrics`. | Not a contradiction of substance. R1 governs; `metrics` is created in Phase 2 and is not populated by the Hevy slice. |
| X2 | `CLAUDE.md` Phase 2's object list omits `reconciliation_plans` and `retirement_overrides` (v3 §4.2, §4.3), which I-10 and PRD §11 require before any retirement can occur. Phase 3's hard gate (PRD §15.4, `CLAUDE.md` Phase 3 Test B) is part of the Hevy vertical slice. | R1 fixes the Phase 2 table list at nine tables, so those two tables are **not** built now. Consequence recorded: Phase 3 will require one additional forward-only migration for them. This is a known, accepted consequence of R1, not a blocker for Phase 2. |
| X3 | v2 §2.3 declares `strength_exercises.exercise_definition_id` nullable, and `raw_record_id` nullable on `metrics`, `strength_workouts`, `strength_sets`. I-1 and I-6 forbid both states. | Resolved by invariant precedence: the columns are created `NOT NULL`. Tightening a nullability constraint is not a schema redesign. Recorded as RD-1. |
| X4 | v2 §2.1 models `units` as a global table keyed `code TEXT PRIMARY KEY`, and v2 §2.3 declares `metrics.unit TEXT REFERENCES units(code)`. R6 blesses the Phase 1 shape, in which `units` is user-extensible and keyed by UUID, so a global text primary key is not available. | Resolved by R2 plus R6: the Phase 1 `units` shape stands. `metrics` carries `unit_id UUID REFERENCES units(id)` for referential integrity plus the denormalized `unit TEXT` column v2 names. Recorded as RD-2. |
| X5 | Three distinct precedence concepts share similar names: `raw_records.precedence_rank` (v2 §4.3, higher wins, 0/10/20), `sources.precedence_rank` (Phase 1, higher wins), and `source_precedence.priority` (v2 §2.4 and §9.3, **lower wins**, Phase 5). | Not a contradiction. Recorded here so the inverted direction of the Phase 5 table is not mistaken for a bug later. `sources.precedence_rank` is unchanged per R7. |
| X6 | v2 §12 and v3 §5 place a "minimal registry admin screen" in Phase 1. `CLAUDE.md` §4 and PRD §16 do not. Phase 1 shipped a read-only registry view on the dashboard. | Outstanding Phase 1 item against v2/v3 only. Not a Phase 2 dependency. No action taken. |
| X7 | v2 §2.1's `units.dimension` vocabulary includes `concentration` and omits `energy`; Phase 1 has `energy` and omits `concentration`. | `concentration` is only needed for laboratory data, which PRD §17 excludes from Phases 1–5. No action, per R2's instruction not to add future-phase fields. |
| X8 | v2 §2 states "all tables have `id UUID PRIMARY KEY`" while its own DDL uses `BIGSERIAL` for `raw_records`, `metrics`, `strength_sets`, `activity_observations`, `custom_events`, and v2 §2.3 declares `raw_record_id BIGINT`. | Documentation defect. The DDL governs; Phase 2 uses `BIGSERIAL` for those tables. |
| X9 | v2 §2.1 DDL is not directly executable: `offset` is a reserved word and is unquoted, and `UNIQUE (COALESCE(...), ...)` is not valid Postgres syntax. | Documentation defect only. Phase 1 already handled both correctly. |

No item above prevents Phase 2 from starting.

---

## B. Resolved items

| Item | Final resolution |
|---|---|
| **Phase 2 scope** | R1. `CLAUDE.md` Phase 2 governs. Exactly nine tables: `import_profiles`, `data_imports`, `import_jobs`, `raw_records`, `import_coverage`, `metrics`, `strength_workouts`, `strength_exercises`, `strength_sets`. No storage bucket, no ingest worker, no importer UI, no sleep, labs, custom events, activities, timeline, insights or derived metrics. Exit criterion: the schema supports a complete Hevy import pipeline with no further schema changes required for the Hevy vertical slice. |
| **Phase 1 registry reconciliation** | R2. Phase 1's schema stands. One additive, forward-only migration adds five columns to `metric_definitions`. Nothing is renamed, dropped or retyped. Full diff in section C.1. |
| **A6 strength retirement** | R3. `strength_workouts` is the retirement root. `strength_exercises` gains no `retired_at`. `strength_sets` keeps the `retired_at` v2 §2.3 already gives it, for row-level retirement only, not for parent propagation. Propagation is enforced by `v_strength_workouts`, `v_strength_exercises` and `v_strength_sets`, each of which excludes descendants of a retired workout. |
| **A7 plausibility bounds** | R4. `plausibility_min` and `plausibility_max`, both `NUMERIC(18,6)` and nullable, on `metric_definitions`, with a `min <= max` check. Seeded only where an authoritative document states a value: `weight` 20 to 400 kg and `resting_heart_rate` 20 to 250 bpm, both from v2 §4.2 step 6. No other bound is invented. Enforcement is a Phase 3 normalization behaviour; Phase 2 provides storage only. |
| **A9 RPE precision** | R5. `strength_sets.rpe NUMERIC(4,2)`, documented in the migration as an explicit domain exception. Not widened. |
| **A2 `user_id` on registries** | R6. The Phase 1 model is already correct: `user_id IS NULL` is a shared system row, `user_id = auth.uid()` is a private extension row, writes are restricted to the owner, and system rows are read-only through the client API. No per-user duplication of reference data. No change required. |
| **Numeric precision** | R7. `unit_conversions.factor` and `offset` stay `NUMERIC(30,15)`. Measured values are `NUMERIC(18,6)`. `rpe` is `NUMERIC(4,2)` by exception. Counts, ranks and ordinals stay integer types. `sources.precedence_rank INTEGER` unchanged. The stale "deviation" comment was already corrected in commit `6ec3a2b`. |

---

## C. Required migrations

### C.1 Phase 1 registry reconciliation diff (R2)

Evaluated column by column against v2 §2.1, v3 §2.8 and the `CLAUDE.md` invariants.
"Required yet" means required by Phase 2's object list or by an invariant, per R2's
instruction not to add fields that only a future phase needs.

| Existing Phase 1 schema | Required architecture state | Action |
|---|---|---|
| `metric_definitions` has no `retention_tier` | v3 §2.8 mandates `retention_tier TEXT NOT NULL DEFAULT 'daily' CHECK IN ('event','daily','reduced')`; R2 names v3 §2.8 as an alignment target; `raw_records.granularity` in Phase 2 derives from it | **additive migration** |
| no `day_attribution` | v3 §2.8 mandates `day_attribution TEXT NOT NULL DEFAULT 'event_date' CHECK IN ('event_date','wake_date')` | **additive migration** |
| no `gap_policy` | v3 §2.8 mandates `gap_policy TEXT NOT NULL DEFAULT 'null' CHECK IN ('zero','carry_forward','null')` | **additive migration** |
| no plausibility bounds | R4 mandates `plausibility_min` / `plausibility_max NUMERIC(18,6)` nullable | **additive migration** |
| `metric_definitions.key` | v2 §2.1 names it `canonical_key` | **no action.** A rename is not additive and R2 forbids a wholesale rewrite. Nothing in Phase 2 or 3 depends on the registry's own column name: mapping specs bind `metric_key`, and `metrics` carries `metric_key` denormalized. Recorded as an accepted naming divergence. |
| `metric_definitions.default_aggregation` (`sum,mean,min,max,first,last,count`) | v2 §2.1 names it `aggregation_rule` (`avg,sum,last,min,max,count`) | **no action now.** Consumed only by v2 §9.3 tier-2 rollups, which is Phase 5. The `mean` vs `avg` vocabulary difference must be settled before Phase 5. |
| no `value_type`, `category`, `subcategory`, `higher_is_better`, `volatility_class` | v2 §2.1 lists them | **no action.** Consumed by Phase 3 normalization and later. R2: do not add future-phase fields. |
| `units` keyed by UUID with `user_id` | v2 §2.1 keys it `code TEXT PRIMARY KEY` with no `user_id` | **no action.** R6 blesses the user-extensible shape. See RD-2. |
| `unit_conversions` has no `analyte_key` | v2 §2.1 includes it for molar lab conversions | **no action.** Laboratory data is excluded from Phases 1–5 by PRD §17. |
| `exercise_definitions` has no `equipment`, `primary_muscle_group`, `is_unilateral` | v2 §2.1 lists them | **no action.** The Hevy slice resolves exercise identity through `exercise_aliases`; none of these columns participate. |
| `activity_types` has no `family`; not seeded | v2 §2.1 requires `family`; v2 §12 / v3 §5 seed six types in Phase 1 | **no action.** Activities are excluded from Phase 2 by R1. Outstanding Phase 1 item. |
| `event_definitions` has no `category`, `value_type`, `default_unit` | v2 §2.1 lists them | **no action.** Custom events excluded by PRD §17. |
| `sources` has no `kind`; has `precedence_rank` | v2 §2.1 has `kind`; precedence lives in `source_precedence` (Phase 5) | **no action.** R7 fixes `precedence_rank` as correct. `kind` has no Phase 2 consumer; `data_imports.source_key` is plain text with no FK in v2 §2.2. |
| `metric_aliases.alias` | v2 §2.1 names it `alias_normalized` and requires punctuation stripping | **no action now.** Consumed by v2 §6.4 mapping suggestion, which is Phase 3. Must be settled before Phase 3 alias matching. |
| Ownership model, RLS, join-free policies | I-8, R6 | **already compliant, no action** |
| `unit_conversions.factor/offset NUMERIC(30,15)` | R7 | **already compliant, no action** |

No row evaluates to STOP.

### C.2 Migrations to be added

| # | File | Contents |
|---|---|---|
| 3 | `20260904090000_phase1_registry_reconciliation.sql` | The five additive `metric_definitions` columns from C.1 |
| 4 | `20260904090100_phase2_import_layer.sql` | `import_profiles`, `data_imports`, `import_jobs`, `raw_records`, `import_coverage`; append-only trigger; constraints and indexes |
| 5 | `20260904090200_phase2_canonical_hevy_slice.sql` | `metrics`, `strength_workouts`, `strength_exercises`, `strength_sets`; natural keys, revision columns, constraints and indexes |
| 6 | `20260904090300_phase2_views_and_rls.sql` | `v_metrics`, `v_strength_workouts`, `v_strength_exercises`, `v_strength_sets`; RLS and grants for every Phase 2 table |

Reference data: `supabase/seeds/0002_metric_registry_policy.sql`, idempotent upserts
setting the new registry policy columns on the nine system metrics. Seed `0001` is not
edited. No applied migration is edited.

### C.3 Reconciliation decisions recorded

| ID | Decision |
|---|---|
| RD-1 | `metrics.raw_record_id`, `strength_workouts.raw_record_id`, `strength_sets.raw_record_id` and `strength_exercises.exercise_definition_id` are `NOT NULL`, tightening v2 §2.3, because I-1 and I-6 admit no null case. `strength_exercises` also gains `raw_record_id NOT NULL` and `import_id`, which v2 §2.3 omits, so that I-1 holds uniformly across the strength hierarchy. |
| RD-2 | `metrics` carries `unit_id UUID REFERENCES units(id)` alongside the denormalized `unit TEXT` that v2 §2.3 names, because R6's user-extensible `units` table has no global text key to reference. `source_unit TEXT` carries no foreign key, exactly as v2 specifies. |
| RD-3 | I-4 is enforced by privilege rather than by convention: the `authenticated` role is granted `SELECT` only on the four canonical tables, so application code cannot `UPDATE` or `DELETE` them at all. Writes require the elevated connection the normalization worker uses. |
| RD-4 | The append-only trigger permits `DELETE` only when the session sets `app.raw_records_deletion_reason` to `import_rollback` or `tier_r_re_reduce`, the two paths sanctioned by I-2 and v2 §5.3. Every other delete raises. |

---

## D. Remaining blockers

**No architectural blockers remain for Phase 2.**

Two consequences are recorded for the owner's awareness. Neither blocks Phase 2:

1. Under R1, `reconciliation_plans` and `retirement_overrides` are not built in Phase 2.
   Phase 3's hard gate requires them, so Phase 3 will open with one additional
   forward-only migration.
2. Two naming divergences must be settled before the phases that consume them:
   `aggregation_rule` versus `default_aggregation` and its `avg`/`mean` vocabulary
   before Phase 5, and `alias_normalized` versus `alias` before Phase 3 alias matching.
