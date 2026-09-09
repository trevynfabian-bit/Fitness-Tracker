# Technical Architecture v3 — Amendment and Architecture Decision Record

This document amends **Technical Architecture v2**. v2 remains the base specification. Everything not superseded here stands unchanged, in particular the schema in v2 §2, the normalization contract in v2 §4, the natural-key strategy in v2 §7, the timezone strategy in v2 §8, and the rollup strategy in v2 §9.

Superseded sections: v2 §2.2 (`raw_records`), v2 §5 (job lifecycle), v2 §7.4 (snapshot reconciliation), v2 §12 (implementation order), v2 §13 (open decisions).

---

## 0. Summary of changes

| Change | Effect |
|---|---|
| D1 closed: hybrid granularity | Canonical row volume drops from an estimated 10⁷ to under 10⁵ for a multi-year dataset |
| D11 deferred correctly | Apple Health no longer appears anywhere in the critical path; profiles become data, not code |
| Tiered raw storage adopted, but **restructured** | Tier 3 stores reduced raw records rather than no raw records, preserving the provenance invariant |
| New table: `sleep_sessions` | Sleep is event-level, not a scalar; without this, sleep consistency is uncomputable |
| New tables: `import_coverage`, `reconciliation_plans`, `retirement_overrides` | Reprocessing addressability, snapshot safety, audit |
| New job state: `awaiting_retirement_confirmation` | Retirement can no longer occur inside an unattended job |
| New: declarative transform library | Mapping stays data-only while still handling real vendor formats |

---

## 1. Critical evaluation of the tiered raw storage proposal

You asked me not to accept this blindly. I accept the direction and reject the specific shape.

### 1.1 The cost argument is the weaker half of the case

Storage dollars are not the real problem. At roughly 500 bytes to 1 KB per `raw_record` including tuple overhead and two indexes, ten million rows is about 10 GB. On Supabase Pro that is a small monthly line item. What actually hurts at that volume is operational: backup and point-in-time-recovery size, restore duration, autovacuum pressure, index bloat, and the fact that every schema migration on a 10 GB table becomes an event requiring planning. Those costs are real, but they are second-order.

### 1.2 The strong argument is that D1 already eliminated the consumer

Once minute-level heart rate is never normalized into canonical metrics, nothing in the system ever reads its `raw_records`. Row-level provenance exists to answer "which spreadsheet cell produced this canonical value." If no canonical value is produced per sample, there is nothing to trace. Storing a million JSONB rows that no query will ever join to is not conservative engineering, it is inventory.

So D1 and the raw storage question are the same decision, and once D1 is settled the tiering follows from it rather than from cost.

### 1.3 Where your proposal is unsafe as written

Tier 3 as you described it processes high-frequency data in chunks and writes canonical daily metrics **without permanently storing raw rows**. That breaks the invariant that every canonical row has a `raw_record_id`. Once broken, that invariant is broken everywhere: the provenance UI needs a special case, rollback needs a special case, the conflict-resolution rule in v2 §4.3 has nothing to sort on, and the rebuild procedure in v2 §4.4 cannot regenerate Tier 3 data at all without re-reading and re-parsing files. Special cases in the one part of the system that must be trustworthy is a bad trade for saved bytes.

### 1.4 Recommended shape: reduce, then store raw

Insert a **reduction step before raw storage** rather than skipping raw storage.

```
Original file (Tier 1, object storage, immutable, retained)
        │
        ▼
   Streaming parse in chunks
        │
        ▼
   ┌────────────────────────────────────────┐
   │ Reduction (Tier 3 metrics only)        │
   │ group samples by (metric, local_date)  │
   │ emit one bucket per group              │
   └────────────────────────────────────────┘
        │
        ▼
   raw_records                        ← invariant intact, one row per bucket
   payload = { n, sum, min, max, first, last, first_ts, last_ts, src_rows }
        │
        ▼
   Normalization (unchanged pure function)
        │
        ▼
   metrics (one row per metric per day)
```

Two years of minute-level heart rate becomes roughly 730 raw records instead of about one million. Every downstream mechanism, provenance, rollback, dedupe, conflict resolution, and rebuild, works unmodified because the only thing that changed is what a "raw row" means for that import, and that is declared per import in a new `raw_granularity` column.

Reduction is a pure, versioned function like normalization. `reduction_version` is stored on the import. A change to reduction logic requires re-reading the original file, which is exactly the difference between Tier 2 and Tier 3 and must be stated plainly: **Tier 2 can be rebuilt from the database alone; Tier 3 can only be rebuilt from the original file.** That is the price of the reduction and it is acceptable only because Tier 1 retention is mandatory and enforced.

### 1.5 The overlap defect this introduces, and its mitigation

Bucket-level natural keys create a failure mode that sample-level keys do not have. Suppose file A covers 1 to 15 January with complete days, and file B is exported mid-day on 15 January. Both produce a bucket for 15 January. A naive upsert lets B's partial-day bucket overwrite A's complete one, and the day's average silently degrades.

Mitigation, mandatory:

1. Every bucket carries `n` (sample count) and `first_ts` / `last_ts` (coverage window).
2. On natural-key conflict, the incoming bucket wins only if `n_incoming >= n_existing`. Otherwise the write is skipped and counted as `duplicates_skipped`.
3. If `n_incoming < n_existing * 0.5`, log a warning to the import summary naming the affected dates. A materially thinner bucket for a day that already has data is nearly always a partial export.
4. Buckets are never merged across files. Overlapping samples cannot be deduplicated after reduction, so merging would double-count. Highest-coverage-wins is the only sound rule.

This is a real limitation of reduction and it should be documented in the product, not hidden.

### 1.6 A Tier 2 optimization, deliberately deferred

`raw_records.payload` as key-value JSONB repeats every column name on every row. Storing the payload as a JSON array of values plus a `column_manifest` on `data_imports` cuts Tier 2 storage by roughly 50 to 65 percent. This is a genuine saving but it makes raw records unreadable without their manifest, which harms exactly the debuggability the raw layer exists for. Defer. Revisit only if Tier 2 exceeds two million rows, which under this granularity policy is unlikely.

---

## 2. Data Granularity and Retention Policy

This section is normative and replaces the informal treatment in v2.

### 2.1 Tier definitions

| Tier | Name | Canonical storage | Raw storage | Rebuildable from DB |
|---|---|---|---|---|
| **E** | Event-level | One canonical row per real-world event | One raw record per source row | Yes |
| **D** | Daily-level | One canonical row per metric per local date | One raw record per source row | Yes |
| **R** | Reduced | One canonical row per metric per local date | One raw record per (metric, day) bucket | No — requires original file |

Tier 1 in your proposal (original file in object storage) is not a tier of this table. It applies universally to every import and is described in §2.4.

### 2.2 Assignment

**Tier E — event-level.** Always. These are low volume and high analytical value.

- Activities: running, cycling, swimming, walking, hiking, and all other workouts
- Strength workouts, exercises, and sets
- **Sleep sessions** (see §2.6)
- Laboratory observations
- Custom events: supplements, medications, protocols, treatments

Volume estimate: an intensive user generates roughly 1,500 to 3,000 event rows per year across all of these. Five years is well under 20,000 rows. There is no reason to reduce any of it.

**Tier D — daily-level, source already daily.** The source file already contains one row per day per metric, so no reduction occurs; the row-to-day mapping is one to one.

- HRV, resting heart rate, recovery score, respiratory rate, blood oxygen (WHOOP-style nightly exports)
- Weight, body fat, muscle mass, lean mass
- Waist, hip, chest, neck, arm, thigh, abdominal circumference
- Daily step totals, daily active energy, daily distance
- Any manual entry

**Tier R — reduced.** The source contains many samples per day for a metric that the product consumes at daily resolution.

- Minute or second-level heart rate
- Continuous HRV sampling
- Intraday step or energy samples
- Continuous glucose monitoring, unless and until an explicit intraday feature exists
- Any imported metric whose observed samples-per-day exceeds the trigger in §2.3

Tier R metrics never store per-sample rows in Postgres. They exist as daily aggregates whose lineage is a bucket, and as raw samples inside the retained original file.

### 2.3 Tier selection: declared, overridable, and guarded

Selection is **not** based on file size. It is based on declared intent, with an automatic backstop.

1. **Declared.** `metric_definitions.retention_tier` holds the default for each canonical metric (`event`, `daily`, `reduced`). This is the primary mechanism.
2. **Overridable per profile.** `import_profiles.retention_overrides` maps `metric_key → tier` for that specific file shape, because the same metric can arrive daily from one source and intraday from another.
3. **Automatic backstop.** During profiling, the engine estimates rows per (metric, day). If the estimate exceeds **24 samples per day** for a metric whose declared tier is `daily`, the engine forces `reduced`, states this in the preview, and requires acknowledgement. If the total projected `raw_records` for the import exceeds **250,000**, the engine forces `reduced` for every eligible metric in the file and blocks confirmation until the user acknowledges.

The backstop exists because the failure it prevents (an unattended import writing five million rows) is far worse than the failure it causes (a user having to click through a warning).

### 2.4 Original file retention (universal)

- Every uploaded file is stored in a private Supabase Storage bucket at `{user_id}/{import_id}/{sha256}.{ext}`, gzip-compressed at rest for CSV.
- Retention is **indefinite by default**. There is no automatic expiry.
- A file whose import contains any Tier R data is **non-deletable while that import is active**. Enforce with `data_imports.file_required = true` and a guard in the delete path. Deleting it would make that data permanently unrebuildable, and the system must not offer an action that silently destroys reproducibility.
- Tier E and Tier D files are deletable after successful normalization, since the database can rebuild them. Do not surface this as a feature in the MVP; it exists only as a cost lever if storage ever becomes material.
- `data_imports.file_sha256` is verified before any reprocessing read. A checksum mismatch aborts the reprocess rather than producing quietly different results.

### 2.5 Raw archive retention

- `raw_records` are retained for the lifetime of their import. There is no time-based purge.
- The only deletion path is an explicit user-initiated import rollback, which is audited.
- Estimated steady-state volume under this policy: 15,000 to 40,000 raw records per year for a heavily instrumented user. Five years is well under a quarter million rows. Postgres handles this without any partitioning, and partitioning should therefore not be built.

### 2.6 Sleep is event-level, not a scalar

This corrects an assumption in your D1 list. Your policy classes sleep as a daily metric. Sleep duration is, but a night of sleep is an event with a start, an end, an efficiency, a latency, and a stage breakdown. The PRD explicitly lists **sleep consistency** as a tracked metric, and consistency is the variance of bed and wake times, which is uncomputable from a duration scalar. Model sleep as an event and project scalars from it.

```sql
CREATE TABLE sleep_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  start_utc TIMESTAMPTZ NOT NULL,
  end_utc TIMESTAMPTZ NOT NULL,
  tz_offset_minutes INT NOT NULL,
  local_date DATE NOT NULL,            -- wake date, per metric_definitions.day_attribution
  time_in_bed_s INT,
  asleep_s INT,
  awake_s INT,
  latency_s INT,
  light_s INT, deep_s INT, rem_s INT,
  efficiency NUMERIC(6,3),
  disturbances INT,
  is_nap BOOLEAN NOT NULL DEFAULT false,
  source_key TEXT NOT NULL,
  external_id TEXT,
  natural_key TEXT NOT NULL,
  raw_record_id BIGINT REFERENCES raw_records(id),
  import_id UUID REFERENCES data_imports(id),
  retired_by_import_id UUID,
  retired_at TIMESTAMPTZ,
  metadata JSONB NOT NULL DEFAULT '{}'
);
CREATE UNIQUE INDEX ON sleep_sessions (natural_key);
CREATE INDEX ON sleep_sessions (user_id, local_date DESC) WHERE retired_at IS NULL;
```

Normalization projects `sleep_duration`, `sleep_efficiency`, and `sleep_latency` into `metrics` as derived rows keyed to the session, so charts and baselines work through the single scalar path. Sleep consistency is computed in the analytics layer from `start_utc` and `end_utc` variance over a rolling window.

### 2.7 Reprocessing strategy

Three distinct operations, with different costs. Keep them separate in code and in the UI.

**Re-normalize (Tier E and D).** Cheapest. Raw records are in Postgres. Bump `NORMALIZE_VERSION`, mark raw records pending, replay in `imported_at` order. No file access. Follows v2 §4.4 unchanged.

**Re-reduce (Tier R).** Requires the original file. Procedure:

```
1. Bump REDUCTION_VERSION.
2. Identify affected imports:
     SELECT * FROM data_imports
     WHERE raw_granularity = 'reduced' AND reduction_version < $current;
3. Verify file_sha256 against the stored object. Abort the import on mismatch.
4. Delete that import's reduced raw_records (the one sanctioned deletion besides rollback).
5. Re-stream the file, re-reduce, re-write raw_records, re-normalize.
6. Enqueue affected days into rollup_queue.
```

**Re-tier (Tier R → Tier E).** The case where a future feature needs intraday data. This is a re-reduce with a different target granularity, run against the retained files, and it is the entire reason Tier 1 retention is mandatory. It requires no schema change: the metric's `retention_tier` flips to `event`, affected imports are re-processed, and canonical rows appear at sample granularity. Plan for it, do not build it.

`import_coverage` makes step 2 addressable without scanning:

```sql
CREATE TABLE import_coverage (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  import_id UUID NOT NULL REFERENCES data_imports(id) ON DELETE CASCADE,
  template TEXT NOT NULL,
  metric_key TEXT,
  granularity TEXT NOT NULL,           -- 'event','daily','reduced'
  date_from DATE NOT NULL,
  date_to DATE NOT NULL,
  source_row_count INT NOT NULL,
  canonical_row_count INT NOT NULL
);
CREATE INDEX ON import_coverage (user_id, metric_key, date_from, date_to);
```

This answers "which file contains raw samples for HRV in March 2026" in one indexed query, which is required for re-tiering and useful for the provenance UI.

### 2.8 Schema changes for this policy

```sql
ALTER TABLE metric_definitions
  ADD COLUMN retention_tier TEXT NOT NULL DEFAULT 'daily'
    CHECK (retention_tier IN ('event','daily','reduced')),
  ADD COLUMN day_attribution TEXT NOT NULL DEFAULT 'event_date'
    CHECK (day_attribution IN ('event_date','wake_date')),
  ADD COLUMN gap_policy TEXT NOT NULL DEFAULT 'null'
    CHECK (gap_policy IN ('zero','carry_forward','null'));

ALTER TABLE data_imports
  ADD COLUMN raw_granularity TEXT NOT NULL DEFAULT 'row'
    CHECK (raw_granularity IN ('row','reduced','mixed')),
  ADD COLUMN reduction_version INT,
  ADD COLUMN reduction_spec JSONB,
  ADD COLUMN file_required BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE raw_records
  ADD COLUMN granularity TEXT NOT NULL DEFAULT 'row'
    CHECK (granularity IN ('row','reduced')),
  ADD COLUMN bucket_metric_key TEXT,
  ADD COLUMN bucket_local_date DATE,
  ADD COLUMN bucket_sample_count INT,
  ADD COLUMN normalized_keys TEXT[];
CREATE INDEX ON raw_records USING GIN (normalized_keys);

ALTER TABLE import_profiles
  ADD COLUMN retention_overrides JSONB NOT NULL DEFAULT '{}';
```

The unique index `raw_records (import_id, row_hash)` from v2 remains correct for both granularities, since a bucket's hash is computed over its canonicalized bucket payload.

---

## 3. Import Profile interface (D11 resolution)

The requirement is that no vendor appears in the ingestion code path. The mechanism is that **a profile is data, not code**, plus a closed library of named transforms.

### 3.1 Profile descriptor

Built-in profiles ship as versioned JSON files in `profiles/`, seeded into `import_profiles` with `user_id IS NULL`. User-created profiles are ordinary rows. Both use the identical schema, so a community profile and a built-in one are indistinguishable to the engine.

```jsonc
{
  "profile_id": "whoop.physiological_cycles.v3",
  "name": "WHOOP — Physiological Cycles",
  "source_key": "whoop",
  "template": "metrics",
  "detection": {
    "required_columns": ["Cycle start time", "Recovery score %"],
    "signature_tokens": ["cycle start time", "recovery score", "heart rate variability", "resting heart rate"],
    "min_similarity": 0.85
  },
  "import_mode": "full_snapshot",
  "snapshot_scope": { "templates": ["metrics"], "date_range": "derive_from_file" },
  "retention_overrides": { "heart_rate": "reduced" },
  "mapping_spec": { /* v2 §6.1 */ }
}
```

The engine's contract is exactly: given a descriptor and a file, produce raw records. It contains no branch on `source_key`. `source_key` is written to rows as metadata and is used only by `source_precedence` at rollup time.

### 3.2 The transform library (this is the part that makes it work)

A purely declarative column-to-field mapping hits a wall on real vendor files within the first three profiles: durations arrive as `"1:24:33"` or `"84 min"`, weights as `"182.1 lb"` in a single cell, lab reference ranges as `"3.5 - 5.1"` in one column, and strength sets with no set number at all. The answer is not to allow arbitrary code in profiles. It is a **closed, versioned, unit-tested library of named parameterized transforms** referenced by name.

| Transform | Purpose | Example |
|---|---|---|
| `parse_duration` | `"1:24:33"`, `"84 min"`, `"1h 24m"`, bare seconds → seconds | Strava, Hevy |
| `concat_datetime` | separate date and time columns → one timestamp | scales, lab exports |
| `extract_number_and_unit` | `"182.1 lb"` → `{value: 182.1, unit: "lb"}` | Apple Health converters |
| `split_reference_range` | `"3.5 - 5.1"` → `{low, high}` | every lab CSV |
| `map_values` | dictionary lookup with a declared default | activity type names |
| `row_index_within_group` | derive `set_number` from row order within (workout, exercise) | Hevy, Strong |
| `parse_pace` | `"5:32 /km"` → seconds per km | Strava, Garmin |
| `coalesce_columns` | first non-empty of an ordered list | multi-column exports |
| `scale` | multiply by a declared constant | unit edge cases |
| `blank_as_null` | treat sentinel values (`"-"`, `"N/A"`, `0`) as null | almost everything |
| `boolean_map` | `"Yes"`/`"No"`/`"1"`/`"0"` → boolean | flags |

Each transform is a pure function with its own fixture tests. Adding a vendor whose format needs something genuinely new means adding a transform to the library, which is a code change, but it is a change to a shared, tested primitive rather than to the ingestion pipeline. Profiles never contain executable expressions and are never `eval`'d.

### 3.3 Profile lifecycle and testing

Every built-in profile ships with a committed anonymized fixture file and a snapshot test asserting the exact canonical output. Vendor format changes are then caught by CI rather than by a corrupted import. A profile is not considered complete until its fixture test passes against a real export.

### 3.4 Consequence for the build

Apple Health, Garmin, Fitbit, Oura, Withings, and anything else are now Phase 6+ content additions: one JSON file, one fixture, one test. None of them appear in Phases 1 through 5. **D11 is deferred and non-blocking**, as you specified, and the interface above is what makes that claim true rather than aspirational.

---

## 4. Snapshot reconciliation safety (supersedes v2 §7.4)

### 4.1 Lifecycle change

Retirement can no longer occur inside an unattended job. The retire stage now **computes a plan, persists it, and halts**.

```
... ingesting → normalizing → planning_reconciliation
                                      │
                    ┌─────────────────┴──────────────────┐
                    │ retire_count = 0                   │ retire_count > 0
                    ▼                                    ▼
                aggregating              awaiting_retirement_confirmation
                                                         │
                                     ┌───────────────────┼──────────────────┐
                                     ▼                   ▼                  ▼
                                 confirmed          skip_retirement      cancelled
                                     │                   │
                                     ▼                   ▼
                                 retiring            aggregating
                                     │
                                     ▼
                                aggregating
```

`skip_retirement` completes the import as a pure append, adding and updating records without retiring anything. This is the correct escape hatch for a partial export and must be a single click.

### 4.2 The reconciliation plan

```sql
CREATE TABLE reconciliation_plans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  import_id UUID NOT NULL REFERENCES data_imports(id) ON DELETE CASCADE,
  computed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  scope JSONB NOT NULL,                -- source_key, templates, metric_keys, date_from, date_to
  add_count INT NOT NULL,
  update_count INT NOT NULL,
  unchanged_count INT NOT NULL,
  retire_count INT NOT NULL,
  existing_in_scope_count INT NOT NULL,
  retire_ratio NUMERIC(6,4) NOT NULL,
  retire_key_sample JSONB NOT NULL,    -- up to 50 examples with date and label, for the UI
  retire_date_histogram JSONB NOT NULL,-- retirements per month, so the user sees the shape
  guard_results JSONB NOT NULL,        -- see §4.3
  verdict TEXT NOT NULL,               -- 'safe','warn','blocked'
  decision TEXT,                       -- 'confirmed','skipped','cancelled'
  decided_at TIMESTAMPTZ,
  decided_reason TEXT
);
```

Retirement executes **against the persisted plan's key set**, not against a freshly recomputed one. This closes the time-of-check-to-time-of-use gap where a concurrent import changes the data between preview and confirmation. If the plan is older than 24 hours at confirmation time, it is invalidated and must be recomputed.

### 4.3 Guard rules

Evaluated in order. The most severe outcome wins.

| ID | Rule | Outcome |
|---|---|---|
| **G1** | Import produced fatal errors, or `records_invalid / rows_total > 0.05` | **BLOCKED** — a partly-failed parse must never drive retirement |
| **G2** | File contains fewer than 10 valid rows | **BLOCKED** — an empty or truncated export can retire nothing, ever |
| **G3** | `retire_count > 0` and `add_count + update_count + unchanged_count = 0` | **BLOCKED** — a file that matches nothing is not a snapshot of this data |
| **G4** | Incoming in-scope record count < 70% of `existing_in_scope_count` | **BLOCKED**, override available with typed confirmation |
| **G5** | File date span covers < 80% of the existing data's span within scope | **WARN**, and scope is narrowed to the file's own span before planning |
| **G6** | `retire_ratio > 0.25` or `retire_count > 500` | **WARN**, requires typed confirmation |
| **G7** | Retirements fall outside the file's own min/max date | **BLOCKED** — a structural bug, never a user decision |
| **G8** | Any retirement targets records from a different `source_key` than the profile declares | **BLOCKED** — scope leak |
| **G9** | Any retirement targets manually entered records (`source_key = 'manual'`) | **BLOCKED**, always, with no override — a vendor export can never retire what the user typed |
| **G10** | Reduced-tier bucket with `n_incoming < n_existing` | Skipped as duplicate, listed in warnings (§1.5) |

`BLOCKED` means the retire stage will not run. Where an override exists, it requires the user to type the retire count to proceed, and the override is recorded:

```sql
CREATE TABLE retirement_overrides (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  plan_id UUID NOT NULL REFERENCES reconciliation_plans(id),
  guard_id TEXT NOT NULL,
  overridden_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  typed_confirmation TEXT NOT NULL
);
```

G9 deserves emphasis. Manual entries are the only data in the system that cannot be re-obtained from anywhere. No vendor snapshot may ever touch them, and this is not overridable.

### 4.4 Confirmation UI contract

The confirmation screen must render, in this order:

```
SNAPSHOT IMPORT — CONFIRMATION REQUIRED

Source:  WHOOP            File: physiological_cycles.csv
Scope:   metrics · whoop · 2025-01-01 to 2026-09-03

  Add       420
  Update     15
  Unchanged 118
  RETIRE  1,243     ← 71% of existing records in this scope

  Retirements by month:
    2025-01 ▇▇▇▇▇▇▇▇ 104     2025-02 ▇▇▇▇▇▇▇ 98   ...

  Examples of what will be retired:
    2025-03-14  resting_heart_rate  52 bpm
    2025-03-14  hrv_rmssd           68 ms
    ... 1,241 more

⚠ GUARD G4 TRIGGERED
  This file contains 553 records; 1,376 exist in scope.
  This usually means the export is partial rather than complete.

  [ Import without retiring (recommended) ]
  [ Cancel ]
  [ Retire anyway — type 1243 to confirm ]
```

Retirement remains **soft**. `retired_by_import_id` is recorded on every affected row, which makes undo a single indexed update:

```sql
ALTER TABLE metrics                ADD COLUMN retired_by_import_id UUID;
ALTER TABLE activity_observations  ADD COLUMN retired_by_import_id UUID;
ALTER TABLE strength_workouts      ADD COLUMN retired_by_import_id UUID;
ALTER TABLE strength_sets          ADD COLUMN retired_by_import_id UUID;
ALTER TABLE custom_events          ADD COLUMN retired_by_import_id UUID;
```

"Undo this import's retirements" is offered in the import history for the life of the import, not for a fixed window. There is no reason to expire an operation this cheap.

---

## 5. Updated implementation order

Changed from v2: Apple Health removed from the critical path entirely; reduction pipeline added to Phase 3; snapshot safety promoted into Phase 3 rather than treated as polish; sleep sessions added to Phase 6.

| Phase | Content | Exit criterion |
|---|---|---|
| **1** | Next.js, Supabase, auth, RLS, migrations, registries seeded (`units`, `unit_conversions`, `metric_definitions` with `retention_tier`, `activity_types`), registry admin screen | Cross-user read fails in a manual RLS test |
| **2** | Signed-URL upload, Storage bucket, `data_imports`, `import_jobs`, `raw_records` with append-only trigger, chunked resumable ingest, cron worker | A 200k-row CSV ingests correctly and survives a mid-ingest worker kill with no duplication |
| **3** | Universal Import Engine: profiling, template selection, mapping wizard, transform library, unit mapping, reduction pipeline, preview, normalization, natural keys, DB-level dedupe, **reconciliation plan and guards G1–G10** | Real Hevy export imports; second import of the same file adds zero rows; a truncated copy of that file is BLOCKED by G4 and offers append-only |
| **4** | Import profiles (signature and similarity matching, versioning), manual entry and correction via synthetic imports, body measurements UI | Manual correction survives a full normalize rebuild unchanged |
| **5** | `rollup_queue`, both rollup tiers, `source_precedence`, charts, period comparison | One-year chart renders from `metric_daily` in a single indexed query |
| **6** | WHOOP profile, Strava profile, smart-scale profile, `sleep_sessions`, `import_coverage`, each with committed fixture and snapshot test | Three profiles coexist with no metric-name drift; a reduced-tier import of intraday HR produces daily rows and roughly one raw record per day |
| **7** | Derived metrics: tonnage, training volume, rolling baselines, e1RM, pace, sleep consistency; `formula_version` regeneration | Bumping a formula version regenerates only affected rows |
| **8** | Timeline generators, fingerprinting, domain filters | Regenerating the timeline twice produces identical rows |
| **9** | Deterministic analytics: trend detection, z-scores against baseline, coverage checks, minimum-N gates, `INSUFFICIENT_DATA` as a first-class result | A deliberately sparse metric returns insufficient data, not a percentage |
| **10** | Insight rule engine with `rule_id`, `fingerprint`, evidence payloads, status transitions | Running the engine twice creates no duplicate insights |
| **11** | Cross-source entity resolution for activities, review queue, persisted user decisions | Merging a Strava and Apple Health run yields one canonical activity and no double-counted distance |
| **12** | AI interpretation over `insights.evidence` only, with PRD §17 safety boundaries enforced in prompt and in a post-generation check | Model output contains no arithmetic it performed itself |
| **Content** | Apple Health converter profile, Garmin, Oura, Fitbit, Withings | Added any time from Phase 6 onward; one JSON, one fixture, one test each |

---

## 6. Architecture Decision Record

Status values: **CONFIRMED** (decided, build to it), **DEFERRED** (deliberately unresolved, does not block, has a named trigger), **FUTURE FEATURE** (out of scope now, schema accommodates it).

### CONFIRMED

**ADR-01 — Universal CSV/XLSX ingestion, not vendor importers**
*Rationale:* Vendor coupling makes every new source a code change and every vendor format change an outage. Five canonical templates bound the problem.
*Consequence:* Users perform a one-time mapping per file shape. Import Profiles reduce this to near zero on repeat. Some vendor-specific convenience is lost.
*Proceed:* Yes.

**ADR-02 — Hybrid granularity policy (D1)**
*Rationale:* The product's questions are longitudinal. Minute-level sensor data has no consumer in any planned feature.
*Consequence:* Canonical volume stays under ~10⁵ rows over five years. No partitioning, no time-series extension, no performance engineering needed. Intraday features require re-processing from retained files, which is a planned operation, not a migration.
*Proceed:* Yes.

**ADR-03 — Tier R stores reduced raw records, not zero raw records**
*Rationale:* Preserves the invariant that every canonical row has a `raw_record_id`. Skipping raw storage would force special cases into provenance, rollback, conflict resolution, and rebuild.
*Consequence:* Roughly 730 raw rows per metric-year instead of ~525,000. Tier R is rebuildable only from the original file, which makes Tier 1 retention mandatory and enforced via `file_required`.
*Proceed:* Yes.

**ADR-04 — Tier assignment by declaration with an automatic backstop**
*Rationale:* File size is a bad proxy. Declared intent per metric is precise; the samples-per-day and total-row backstops prevent an unattended catastrophic import.
*Consequence:* Thresholds (24 samples/day, 250,000 projected rows) are tunable constants, validated against real files in Phase 6.
*Proceed:* Yes.

**ADR-05 — Original files retained indefinitely, non-deletable when Tier R depends on them**
*Rationale:* The file is the only remaining copy of reduced samples.
*Consequence:* Storage grows monotonically. At realistic export sizes this is a few gigabytes over years, gzip-compressed. Acceptable.
*Proceed:* Yes.

**ADR-06 — Single write path: everything enters through `raw_records`**
*Rationale:* Manual corrections applied as `UPDATE` are silently reverted by any rebuild.
*Consequence:* Manual entry and correction create synthetic imports. Slightly more machinery for a simple form; complete reproducibility in exchange.
*Proceed:* Yes.

**ADR-07 — Deterministic conflict resolution by `(precedence_rank, observed_at, id)`**
*Rationale:* Rebuild must be deterministic, and manual corrections must outrank re-imported source values.
*Consequence:* All three sort keys live in immutable columns. Corrections are permanent without being destructive.
*Proceed:* Yes.

**ADR-08 — Natural keys exclude `value`; external ID preferred; timestamp truncated per metric granularity**
*Rationale:* Value-based identity turns every source correction into a phantom duplicate.
*Consequence:* Corrections become updates. Deletions at source require snapshot mode.
*Proceed:* Yes.

**ADR-09 — Import modes: `append` (default) and `full_snapshot` (opt-in)**
*Rationale:* Consumer exports are full-history snapshots, so reconciliation is the only correct way to handle deletions and re-timestamping.
*Consequence:* Snapshot mode is destructive by nature and therefore fully gated by ADR-10.
*Proceed:* Yes.

**ADR-10 — Retirement requires an explicit plan, guard evaluation, and human confirmation**
*Rationale:* A partial or malformed export must never silently delete history.
*Consequence:* Snapshot imports are not fully unattended. The retire stage halts at `awaiting_retirement_confirmation`. G9 (manual data is never retirable) has no override.
*Proceed:* Yes.

**ADR-11 — Retirement is soft, with `retired_by_import_id` and permanent undo**
*Rationale:* Cheap insurance against the one operation that can lose data.
*Consequence:* Every analytics query must filter `retired_at IS NULL`. Enforce with database views, not developer discipline.
*Proceed:* Yes.

**ADR-12 — Profiles are data; transforms are a closed, named library**
*Rationale:* Purely declarative mapping cannot express duration strings, embedded units, or reference ranges. Arbitrary expressions in profiles would be executable user content.
*Consequence:* Adding a vendor is a JSON file plus a fixture. Adding a genuinely novel format primitive is a small, tested addition to a shared library.
*Proceed:* Yes.

**ADR-13 — Hybrid data model: one `metrics` fact table, typed tables only where structure demands**
*Rationale:* One analytics engine, one chart component, one baseline calculator serve every scalar.
*Consequence:* Typed tables limited to activities, strength hierarchy, sleep sessions, and custom events. Lab context is a 1:1 sidecar on `metrics`.
*Proceed:* Yes.

**ADR-14 — Sleep is event-level with projected scalars**
*Rationale:* Sleep consistency, a PRD-listed metric, is uncomputable from a duration scalar.
*Consequence:* `sleep_sessions` table added; three scalars projected into `metrics` per session.
*Proceed:* Yes.

**ADR-15 — Two-tier rollups (`metric_daily_source` → `metric_daily`)**
*Rationale:* Cross-source scalar duplication is a precedence problem, not a merge problem. Two tiers make precedence changes cost milliseconds.
*Consequence:* More rows in an already-small table. Negligible.
*Proceed:* Yes.

**ADR-16 — Observation/canonical split for activities from day one**
*Rationale:* Retrofitting entity resolution onto a single-table design is a destructive migration.
*Consequence:* An extra join and a singleton canonical per observation in the MVP, for zero query-code change when resolution ships.
*Proceed:* Yes.

**ADR-17 — Registries for metrics, exercises, activity types, and custom events**
*Rationale:* Free-text identifiers drift across sources and silently split analytical series.
*Consequence:* Mapping requires resolving every column to a registry entry. Aliases learn from confirmed user choices.
*Proceed:* Yes.

**ADR-18 — Timezone: store `timestamp_utc` + `tz_offset_minutes` + precomputed `local_date`**
*Rationale:* Every aggregation keys on local date; deriving it at query time is unindexable and recomputes travel history per request.
*Consequence:* Changing travel periods requires a scoped re-normalize, which is cheap because the raw layer is intact.
*Proceed:* Yes.

**ADR-19 — Dirty-day rollup queue, never database triggers**
*Rationale:* Triggers would fire per row inside bulk import transactions.
*Consequence:* Rollups are eventually consistent within one worker cycle. Acceptable for a personal analytics product.
*Proceed:* Yes.

**ADR-20 — Timeline and insights are materialized and fingerprinted**
*Rationale:* On-read union across six domains cannot paginate or rank coherently; unfingerprinted insight generation floods the user.
*Consequence:* Both are regenerable leaves and can be truncated at will.
*Proceed:* Yes.

**ADR-21 — `NUMERIC(18,6)` for all measured values**
*Rationale:* Float accumulation error over multi-year sums is unacceptable in a system whose central claim is evidence-based analysis.
*Consequence:* Marginally slower arithmetic. Irrelevant at this volume.
*Proceed:* Yes.

**ADR-22 — Worker as a pure function over `(job, batch)`, on Vercel Cron initially**
*Rationale:* Keeps the compute location a deployment detail rather than an architectural one.
*Consequence:* Lifting to a container later requires no rewrite. Ingest throughput is capped by cron frequency in the interim, which is fine for a single user.
*Proceed:* Yes.

**ADR-23 — RLS and denormalized `user_id` on every table from day one**
*Rationale:* Retrofitting isolation onto health data is a security incident waiting to happen.
*Consequence:* Multi-user becomes a UI change, not a data change.
*Proceed:* Yes.

**ADR-24 — Schema migrations forward-only, expand-contract; reference data seeded idempotently and separately**
*Rationale:* Adding a metric definition must never require a schema change.
*Consequence:* Two seeding mechanisms to maintain.
*Proceed:* Yes.

**ADR-25 — Apple Health converter is a Phase 6+ profile, not an architectural dependency (D11)**
*Rationale:* ADR-12 makes any converter's output just another CSV shape.
*Consequence:* Phases 1 through 5 contain no Apple Health work. If the chosen converter later proves inadequate, the cost is one JSON file, not a redesign.
*Proceed:* Yes.

### DEFERRED

**ADR-D1 — Reduction and backstop threshold values**
*Current default:* 24 samples/day; 250,000 projected raw rows.
*Trigger to resolve:* Phase 6, validated against a real intraday export.
*Blocking:* No. Constants, not architecture.

**ADR-D2 — Tier 2 payload compaction (array + column manifest)**
*Rationale for deferral:* 50 to 65% storage saving at the cost of raw-record readability, which is the layer's main purpose.
*Trigger:* `raw_records` exceeding 2,000,000 rows.
*Blocking:* No.

**ADR-D3 — Cross-lab trend policy**
*Current default:* Segment the series and warn when `laboratory` differs within a window.
*Trigger:* First multi-lab dataset, likely Phase 9.
*Blocking:* No. Analytics-layer presentation, not storage.

**ADR-D4 — Non-numeric metric value types**
*Current state:* Schema carries `value_text`, `value_bool`, `value_type`. Only numeric is implemented.
*Trigger:* First ordinal or categorical metric requirement.
*Blocking:* No. Columns already exist.

**ADR-D5 — Travel period inference**
*Current state:* `user_travel_periods` is manual-entry only.
*Trigger:* First import whose file carries a per-row timezone, likely WHOOP in Phase 6.
*Blocking:* No.

**ADR-D6 — Insight rule catalogue and confidence thresholds**
*Trigger:* Phase 9/10, and it should be written against real accumulated data rather than guessed now.
*Blocking:* No.

**ADR-D7 — AI provider, prompt design, and post-generation safety check implementation**
*Trigger:* Phase 12.
*Blocking:* No.

**ADR-D8 — Deletion policy for Tier E/D original files**
*Current default:* retain indefinitely; capability exists but is not exposed.
*Trigger:* Storage cost becoming material.
*Blocking:* No.

**ADR-D9 — Worker relocation off Vercel Cron**
*Trigger:* Ingest of a single file taking more than ~30 minutes of wall-clock across cron invocations.
*Blocking:* No (ADR-22).

### FUTURE FEATURE

| ID | Feature | Schema accommodation already in place |
|---|---|---|
| F-01 | Intraday analysis (HR zones within a workout, CGM curves) | Tier re-processing from retained files; `retention_tier` flip; `import_coverage` for addressability |
| F-02 | Cross-source entity resolution for activities | `canonical_activities` / `activity_observations` split (ADR-16), Phase 11 |
| F-03 | Cross-source resolution for strength | Same pattern available; deliberately not designed |
| F-04 | Direct vendor API integrations | An API sync is a synthetic import writing raw records; no new architecture |
| F-05 | Multi-user | RLS and `user_id` everywhere (ADR-23) |
| F-06 | Mobile application | Read APIs are already separate from ingestion |
| F-07 | PDF/OCR lab parsing | Would emit rows into the existing labs template |
| F-08 | AI chat over the personal database | Requires its own safety surface; separate product decision |
| F-09 | Weekly and monthly rollup tables | Aggregate from `metric_daily` on read until measurably slow |
| F-10 | Table partitioning / TimescaleDB | Unnecessary under ADR-02; would only become relevant under F-01 at scale |

---

## 7. Remaining architecture blockers

**None for Phases 1 through 5.**

Both previously blocking decisions are closed. D1 is resolved by ADR-02 through ADR-05. D11 is resolved by ADR-12 and ADR-25, which make it a content decision rather than an architectural one. Every remaining open item in the DEFERRED list has a working default, a named resolution trigger, and no schema consequence.

Three things are worth stating plainly before you start, none of which are blockers but all of which are ways this design can still be undermined in implementation:

1. **The invariant is the product.** Every canonical row has a `raw_record_id`; every raw record is append-only; normalization is pure. The first time an engineer writes an `UPDATE` directly against `metrics` to fix something quickly, the reproducibility guarantee is gone and nothing in the system will report that it is gone. Enforce it with a database trigger that rejects application-role writes to canonical tables outside the normalization role, not with a code review convention.

2. **`retired_at IS NULL` will be forgotten.** It will be forgotten in a chart query, and a retired record will reappear in a trend line, and it will not be obvious. Create `v_metrics`, `v_activities`, `v_strength_sets`, and `v_sleep_sessions` views with the filter applied, and let application code query only the views.

3. **Phase 3's exit criterion is the real gate.** Import a real Hevy export, then import a deliberately truncated copy of it and verify guard G4 blocks retirement and offers append-only. If that specific test does not pass, the safety design is decorative. Do not proceed to Phase 4 before it does.

Implementation can begin on Phase 1.
