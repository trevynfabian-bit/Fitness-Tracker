# Architecture Consistency Audit (pre-Phase 2)

Date: 2026-09-03
Branch: `claude/phase-1-foundation-zwjvhy`
Sources read in full: `CLAUDE.md`, `docs/architecture/health-platform-architecture-v2.md`,
`docs/architecture/health-platform-architecture-v3.md`

**Verdict: the specifications are NOT yet internally consistent. Phase 2 must not start.**
Five items require a decision from the owner. No application or database code was
modified during this audit beyond the authorized comment-only precision-policy
correction.

---

## 0. Document availability

| Document | Status |
|---|---|
| `docs/architecture/health-platform-architecture-v2.md` | PRESENT (59,285 bytes, 1,066 lines) |
| `docs/architecture/health-platform-architecture-v3.md` | PRESENT (43,907 bytes, 689 lines) |
| `docs/prd.md` | **MISSING** |

The PRD is named as authoritative by `CLAUDE.md` §2 and is load-bearing in v2 and v3:

- v2 §0.4 cites "Principle 4.3" of the PRD as the rule custom events must not violate
- v2 §0.5 cites the PRD's requirement to store a reference range per lab observation
- v3 §2.6 justifies `sleep_sessions` on the grounds that "the PRD explicitly lists
  sleep consistency as a tracked metric"
- v3 §5 Phase 12 and ADR references depend on "PRD §17 safety boundaries"

None of those four are Phase 2 objects. The PRD is therefore **not a schema blocker for
Phase 2**, but it is a blocker on the owner's own gate ("read all three documents"), and
it is the only remaining source for per-metric plausibility bounds (see §4, A7).

---

## 1. Phase 2 requirements extracted from the documents

### 1.1 The two specifications disagree on what Phase 2 is

`CLAUDE.md` §2 states that v3 supersedes v2 in §12 (implementation order), so v3 §5 is
the authoritative order between the two architecture documents. But `CLAUDE.md` §4's own
Phase 2 does not match v3 §5's Phase 2.

| Item | `CLAUDE.md` §4 Phase 2 | v3 §5 Phase 2 |
|---|---|---|
| Storage bucket, signed-URL upload | absent | **required** |
| Chunked resumable ingest | absent | **required** |
| Cron worker | absent | **required** |
| `import_profiles` | **required** | v3 Phase 4 |
| `import_coverage` | **required** | v3 Phase 6 |
| `metrics`, `strength_workouts`, `strength_exercises`, `strength_sets` | **required** | v3 Phase 3 |
| Importer UI | explicitly excluded | not mentioned |
| Exit criterion | schema supports a complete Hevy pipeline with no further schema changes; demonstrated by raw SQL inserts against a sample row | a 200k-row CSV ingests correctly and survives a mid-ingest worker kill with no duplication |

Both are coherent plans. They are different plans. `CLAUDE.md` is schema-first with the
pipeline deferred to Phase 3; v3 is raw-layer-and-worker first with normalization in
Phase 3. The exit criteria are not merely differently worded, they test different
artifacts: one tests constraint completeness, the other tests runtime durability.

This is the condition `CLAUDE.md` §7 requires be raised rather than decided unilaterally.

### 1.2 Requirements common to both readings

These hold whichever plan governs, and are fully specified with no inference required:

| Concern | Authority |
|---|---|
| `raw_records` append-only, updatable columns enumerated | v2 §2.2 prose, `CLAUDE.md` I-2 |
| `raw_records` unique `(import_id, row_hash)` intra-file duplicate guard | v2 §2.2, v3 §2.8 (confirmed valid for both granularities) |
| `normalized_keys TEXT[]` with GIN index | v2 §7.3, v3 §2.8 |
| `mapping_spec_snapshot` frozen per import | v2 §2.2, §3 |
| `data_imports.imported_at` never mutated (rebuild replay order) | v2 §4.4 |
| Natural key strategies A (external id) and B (truncated timestamp), `value` excluded | v2 §7.1, ADR-08 |
| Upsert with the `WHERE ... IS DISTINCT FROM` guard on `DO UPDATE` | v2 §7.2 |
| `precedence_rank` 0 / 10 / 20 and `ORDER BY precedence_rank DESC, observed_at DESC, id DESC` | v2 §2.2, §4.3, ADR-07 |
| Import modes `append` (default) and `full_snapshot` (opt-in) | v2 §7.4, ADR-09, D5 |
| Job status lifecycle | v2 §5.1 **superseded by** v3 §4.1 |
| `NUMERIC(18,6)` for every measured value | v2 §2 conventions, D10, ADR-21 |
| RLS and `user_id` on every table | v2 §1.2.6, ADR-23, `CLAUDE.md` I-8 |

---

## 2. Every schema object Phase 2 requires

Under `CLAUDE.md` §4's reading (schema-first), the complete object list is below. Each
row cites its specification. Objects marked **OMITTED** are required by the exit
criterion but absent from `CLAUDE.md`'s own Phase 2 list.

### 2.1 Import layer

| Object | Authority | Notes |
|---|---|---|
| `import_profiles` | v2 §2.2 | plus `retention_overrides JSONB NOT NULL DEFAULT '{}'` (v3 §2.8) |
| `data_imports` | v2 §2.2 | plus `raw_granularity`, `reduction_version`, `reduction_spec`, `file_required` (v3 §2.8) |
| `import_jobs` | v2 §2.2 | stage/state vocabulary per v3 §4.1, not v2 §5.1 |
| `raw_records` | v2 §2.2 | `BIGSERIAL` id; plus `granularity`, `bucket_metric_key`, `bucket_local_date`, `bucket_sample_count`, `normalized_keys` (v3 §2.8) |
| `import_coverage` | v3 §2.7 | `CLAUDE.md` places this in Phase 2; v3 places it in Phase 6 |
| append-only trigger on `raw_records` | v2 §2.2, `CLAUDE.md` I-2 | permits updates only to `processed_at`, `normalize_version`, `normalize_status`, `normalize_error`, `normalized_keys` |
| `reconciliation_plans` | v3 §4.2 | **OMITTED** from `CLAUDE.md` Phase 2 |
| `retirement_overrides` | v3 §4.3 | **OMITTED** from `CLAUDE.md` Phase 2 |

### 2.2 Canonical tables, Hevy slice only

| Object | Authority | Notes |
|---|---|---|
| `metrics` | v2 §2.3 | `BIGSERIAL`; 3 indexes incl. `metrics_nk_uq` partial on `is_derived = false`; plus `retired_by_import_id` (v3 §4.4) |
| `strength_workouts` | v2 §2.3 | plus `retired_by_import_id` (v3 §4.4) |
| `strength_exercises` | v2 §2.3 | no `retired_at`, no `natural_key` in v2; `UNIQUE (workout_id, order_index)` |
| `strength_sets` | v2 §2.3 | generated `volume_kg`; `UNIQUE (exercise_id, set_number)` and unique `natural_key`; plus `retired_by_import_id` (v3 §4.4) |
| `v_metrics`, `v_strength_sets` | v3 §7.2, `CLAUDE.md` I-5 | views applying `retired_at IS NULL`; **OMITTED** from `CLAUDE.md` Phase 2's list but required by I-5 before any application query exists |

### 2.3 The exit-criterion contradiction inside CLAUDE.md

`CLAUDE.md` Phase 2 exit requires that the schema support a complete Hevy pipeline
**with no further schema changes required**. `CLAUDE.md` Phase 3 is a hard gate whose
Test B requires Guard G4 to block retirement, and `CLAUDE.md` I-10 requires that no
retirement occur without **a persisted `reconciliation_plan`**. `reconciliation_plans`
and `retirement_overrides` are not in `CLAUDE.md`'s Phase 2 object list.

Therefore Phase 3 would require schema changes, and Phase 2's exit criterion is
unsatisfiable as written. The same applies to `retired_by_import_id` (v3 §4.4) and to
the `v_*` views required by I-5. This is an inconsistency inside `CLAUDE.md` itself, not
between `CLAUDE.md` and the architecture documents, and it is resolved simply by adding
those objects to Phase 2.

---

## 3. Invariants affecting Phase 2

| Invariant | Phase 2 consequence |
|---|---|
| **I-1** single write path | Every canonical row carries `raw_record_id NOT NULL`-in-practice. v2 §2.3 declares it nullable; the invariant is stricter than the DDL. Decide whether to enforce `NOT NULL`. |
| **I-2** `raw_records` append-only | `BEFORE UPDATE OR DELETE` trigger. Note `normalized_keys` is in `CLAUDE.md`'s permitted-update list but not in v2 §2.2's, because v2 §7.3 introduces the column later in the document. `CLAUDE.md` is the wider and correct list. |
| **I-3** normalization is pure | No Phase 2 schema consequence, but `registry_snapshot` must be loadable as a single batch read, which the registry shape must support. |
| **I-4** never `UPDATE` a canonical table from app code | v3 §7.1 requires this be enforced **by a database trigger rejecting application-role writes**, not by convention. Phase 2 must create that trigger. Not mentioned in `CLAUDE.md` Phase 2. |
| **I-5** app queries views, not canonical tables | `v_metrics` and `v_strength_sets` are Phase 2 objects. |
| **I-6** no free-text identifiers | `strength_exercises.exercise_definition_id` is nullable in v2 §2.3 alongside `exercise_name_raw TEXT NOT NULL`. A nullable registry reference is in tension with I-6. Decide. |
| **I-7** `NUMERIC(18,6)` | Applies to `metrics.value_num`, `metrics.source_value_num`, `strength_sets.weight_kg`, `distance_m`, `volume_kg`. Note `strength_sets.rpe NUMERIC(4,2)` in v2 §2.3 is a measured value at a different precision. Flagged in §4, A9. |
| **I-8** `user_id` + join-free RLS on every table | Straightforward for all Phase 2 tables. |
| **I-9** no vendor names in engine code | Phase 2 is schema only, so no exposure. `source_key` is a data column. |
| **I-10** retirement requires a persisted plan, guards, confirmation | Forces `reconciliation_plans` and `retirement_overrides` into Phase 2 (see §2.3). |

---

## 4. Contradictions and ambiguities

### A. Within v2 and v3

| ID | Finding | Severity for Phase 2 |
|---|---|---|
| A1 | v2 §2 conventions state "all tables have `id UUID PRIMARY KEY`", but the DDL for `raw_records`, `metrics`, `activity_observations`, `strength_sets`, `custom_events` uses `BIGSERIAL`. The DDL is self-evidently authoritative (v2 §2.3 declares `raw_record_id BIGINT`). | Low. Follow the DDL. |
| A2 | v2 §2 conventions state "All tables have `user_id UUID NOT NULL`", but `units`, `unit_conversions` and `activity_types` have no `user_id` in the DDL, and the registry definition tables have it nullable ("NULL = system", confirmed by v2 §11.6). `CLAUDE.md` I-8 requires it on every table. | **Medium.** Affects Phase 1 reconciliation, not Phase 2 tables. Needs a ruling. |
| A3 | v2 §2.1 `unit_conversions` declares a column named `offset` unquoted. `OFFSET` is reserved in Postgres; that DDL will not execute as written. | Low. Quote it, as Phase 1 already does. |
| A4 | v2 §2.1 uses `UNIQUE (COALESCE(user_id, '000...'::uuid), canonical_key)`. Postgres does not accept an expression in a `UNIQUE` table constraint; it must be a unique index. | Low. Phase 1 used paired partial unique indexes, which is equivalent and executable. |
| A5 | v2 §2.3 declares `activity_observations.canonical_activity_id REFERENCES canonical_activities(id)` before `canonical_activities` is created. | Low. Ordering only. Phase 6+. |
| A6 | **Retirement semantics for the strength hierarchy are undefined.** v2 §7.4's snapshot example retires `strength_workouts` only. `strength_exercises` has no `retired_at`; `strength_sets` has its own. Nothing states whether retiring a workout retires its exercises and sets. Under I-5, `v_strength_sets` filtering only `strength_sets.retired_at` would still surface the sets of a retired workout. | **HIGH.** Phase 2 must define the retirement contract for the three-level hierarchy. Not inferable. |
| A7 | **Per-metric plausibility bounds have no home.** v2 §4.2 step 6 mandates them ("weight 20 to 400 kg, HR 20 to 250 bpm") and makes out-of-range a first-class `normalize_status = 'invalid'`. No table in v2 or v3 stores them; `metric_definitions` has no min/max columns. | **HIGH.** Either they are `metric_definitions` columns (a Phase 1 registry change) or a separate table or code constants. The PRD may specify them. Not inferable. |
| A8 | v2 §2.1's `units.dimension` vocabulary is `'mass','length','time','frequency','concentration','count','ratio','none'`. It omits energy, yet `active_energy` (kcal) is a Phase 1 seeded metric and `activity_observations.calories` exists. | Medium. Vocabulary gap. |
| A9 | Ratio-typed and small-scale numerics sit outside the two approved precision classes: `strength_sets.rpe NUMERIC(4,2)`, `reconciliation_plans.retire_ratio NUMERIC(6,4)`, `metric_baselines.coverage_ratio NUMERIC(6,4)`, `sleep_sessions.efficiency NUMERIC(6,3)`. `rpe` is a measured value and is not `NUMERIC(18,6)`. | Medium. `rpe` lands in Phase 2 (`strength_sets`). Needs confirmation that v2's literal `NUMERIC(4,2)` governs over the blanket I-7 rule. |
| A10 | v2 §2.2 `raw_records.precedence_rank SMALLINT`; v2 §4.3 and ADR-07 treat it as the primary sort key. No contradiction, but note the type is `SMALLINT`, not `INTEGER`. | Low. |

### B. Between the documents and the delivered Phase 1

Phase 1 was built before v2 and v3 were available, from `CLAUDE.md` alone. Its registry
schema is functionally sound, fully RLS-tested, and correct on the ownership model
(nullable `user_id` = system, which v2 §11.6 confirms). But **its column names and
several required columns do not match v2 §2.1**, and Phase 2's specified artifacts are
written against v2's names.

| # | v2 / v3 requires | Phase 1 has | Impact |
|---|---|---|---|
| B1 | `metric_definitions.canonical_key` | `key` | v2 §6.1 `mapping_spec` bindings, §7.1 natural keys, §9 rollups and `metrics.metric_key` are all written against the v2 name. |
| B2 | `metric_definitions.aggregation_rule` with values `avg,sum,last,min,max,count` | `default_aggregation` with values `sum,mean,min,max,first,last,count` | v2 §9.3 projects the tier-1 column named by `aggregation_rule`. Name **and** vocabulary differ (`avg` vs `mean`; Phase 1 adds `first`). |
| B3 | `metric_definitions.value_type` (`numeric,duration_s,ratio,text,boolean,ordinal`) | absent | v2 §4.2 step 4 parses per `value_type`. ADR-D4 depends on it. |
| B4 | `metric_definitions.category` NOT NULL, `subcategory`, `higher_is_better`, `volatility_class`, `is_derived`, `formula_version` | absent | `is_derived` and `formula_version` are required by `metrics_derived_uq` and v2 §11.4. |
| B5 | **`metric_definitions.retention_tier`** (`event,daily,reduced`), `day_attribution` (`event_date,wake_date`), `gap_policy` (`zero,carry_forward,null`) | absent | v3 §2.8 mandates all three. **v3 §5 names `retention_tier` explicitly as Phase 1 content.** This is a Phase 1 gap against v3, and `retention_tier` drives the entire Tier E/D/R policy that Phase 2's `raw_records.granularity` depends on. |
| B6 | `units.code TEXT PRIMARY KEY`; `metrics.unit TEXT REFERENCES units(code)`, `custom_events.unit`, `event_definitions.default_unit` all FK to a text code | `units.id UUID` + `key TEXT` | Every downstream unit reference in v2 §2.3 assumes a text primary key. Phase 2's `metrics` table cannot be built to v2 §2.3 against a UUID-keyed `units`. |
| B7 | `unit_conversions` PK `(from_unit, to_unit, COALESCE(analyte_key,''))` with `analyte_key TEXT` | UUID `id`, no `analyte_key` | v2 §4.2 step 5 looks conversions up by `(source_unit, canonical_unit, analyte_key)`. Molar lab conversions are impossible without it. |
| B8 | `unit_conversions.factor / offset NUMERIC(24,12)` | `NUMERIC(30,15)` | See §5, item 5. Scale 12 is sufficient for all 22 seeded factors. |
| B9 | `units.dimension` includes `concentration` | absent | Required for `mg/dL`, `mmol/L`. Labs are later, but the registry is Phase 1. |
| B10 | `metric_aliases.alias_normalized` (stored lowercased, punctuation stripped) | `alias` stored raw, normalized only inside the unique index | v2 §6.4 matches against the normalized column. Punctuation is not stripped by the Phase 1 index expression. |
| B11 | `exercise_definitions.canonical_key`, `primary_muscle_group`, `equipment`, `is_unilateral` | `key`, no others | `equipment` matters for Hevy ("Bench Press (Barbell)"), which is the Phase 3 gate. |
| B12 | `exercise_aliases` has no `source_key` | has `source_key` | Additive divergence, harmless, but not the frozen shape. |
| B13 | `activity_types.family TEXT NOT NULL`, global (`canonical_key` UNIQUE, no `user_id`) | no `family`, has `user_id` | v2 §10.2's resolution algorithm matches on `activity_type` family. |
| B14 | `activity_types` **seeded** in Phase 1 (`run,ride,swim,walk,strength,hike`) | seeded empty | v2 §12 and v3 §5 both list `activity_types` among Phase 1 seeds. `CLAUDE.md` Phase 1 lists metric seeds only. |
| B15 | `event_definitions.category` NOT NULL, `value_type`, `default_unit`, `user_id NOT NULL` | none of the three, `user_id` nullable | v2 §0.4 makes `value_type` and unit the whole point of the registry. |
| B16 | `sources.kind` NOT NULL (`wearable,app,device,lab,manual`), `user_id NOT NULL` | no `kind`, `user_id` nullable | |
| B17 | Source precedence lives in `source_precedence (user_id, metric_key, source_key, priority)` where **lower priority wins** (v2 §2.4, §9.3) | `sources.precedence_rank INTEGER`, documented as **higher wins** | Wrong location and inverted direction. `source_precedence` is a Phase 5 table; `sources.precedence_rank` is not in v2 at all. |
| B18 | "A minimal registry admin screen"; v2 §12 Phase 1 exit is "an authenticated user can **view the metric registry**" | dashboard displays `metric_definitions` read-only | The read-only view satisfies "view"; it is not an admin screen. |

B1, B2, B3, B5, B6, B7 and B17 are **blocking for Phase 2**: Phase 2's canonical tables
and the normalization contract reference these exact names and types.

---

## 5. Confirmation on inference

**Phase 2's own schema requires no inference.** With v2 and v3 in hand, every Phase 2
object is specified verbatim: the import layer in v2 §2.2 plus v3 §2.8; the Hevy-slice
canonical tables in v2 §2.3; natural keys in v2 §7.1; the upsert in v2 §7.2; import
modes in v2 §7.4 and v3 §4; the status lifecycle in v3 §4.1; the reconciliation objects
in v3 §4.2 and §4.3.

Three items would require inference and therefore must be decided by the owner, not by
me: A6 (strength retirement semantics), A7 (plausibility bounds), and A2 (`user_id` on
`units` / `unit_conversions` / `activity_types`).

Separately, Phase 2 **cannot be built on the Phase 1 registry as it stands** without
either reconciling it to v2 §2.1 or amending v2. That is a decision, not an inference.

---

## 6. What is required before Phase 2 begins

1. **`docs/prd.md`.** Still missing. It is the owner's own gate and the likely source for A7.
2. **Rule on the Phase 2 scope conflict** (§1.1). Does `CLAUDE.md` §4 Phase 2 govern (schema first, pipeline in Phase 3), or v3 §5 Phase 2 (upload, ingest, worker; canonical tables in Phase 3)? The exit criterion follows from the answer.
3. **Rule on Phase 1 registry reconciliation** (§4.B). Either an expand-contract migration bringing the registries to v2 §2.1 names and types plus the three v3 §2.8 columns, or an explicit amendment recording that the Phase 1 shape stands and v2 §2.1 is superseded. B5 (`retention_tier`) is not optional under any reading: v3 §5 places it in Phase 1 and Phase 2's `raw_records.granularity` depends on it.
4. **Rule on A6, A7 and A9** (strength retirement, plausibility bounds, `rpe` precision).
5. **Confirm `NUMERIC(30,15)` against v2's `NUMERIC(24,12)`** (B8). The precision policy was approved before v2 was readable. v2 §2.1 specifies `NUMERIC(24,12)` for `unit_conversions.factor` and `offset`. Scale 12 represents every one of the 22 seeded factors without loss, including `1/3600000 = 0.000000277778`. The frozen document and the approved policy disagree, and the document is narrower.

Items 2, 3 and 5 are amendments to a frozen architecture. They are the owner's to make.
