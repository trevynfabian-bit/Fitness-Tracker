# Personal Longitudinal Health Platform — Technical Architecture v2

Status: pre-implementation design. No production code to be written until Section 13 decisions are closed.

---

## 0. Critical review of the revised direction

The pivot to a Universal Import Engine is correct. It removes vendor coupling from the core and makes the ingestion surface finite and testable. But several assumptions in the revised spec are still weak, and two of them will cause data corruption rather than mere inconvenience.

### 0.1 The Apple Health problem was moved, not solved

"Apple Health exports converted to CSV/XLSX" hides a dependency. Nothing in Apple's export produces CSV. The conversion is done by a third-party tool (Health Auto Export, Simple Health Export CSV, or a custom script), which means the schema you actually support is that tool's schema, not Apple's. State this explicitly and pick the converter now, because the column contract comes from it.

The file size problem also survives the pivot. A per-minute heart-rate CSV for two years is still 1 to 5 million rows. So the ingestion pipeline must be chunked and resumable from day one regardless of format. This is designed in below (Section 5), but do not assume "it's CSV now, so it's small."

### 0.2 Immutable raw layer + manual corrections is a silent data-loss trap

The spec says normalized data must be fully reproducible from raw records, and separately that users can enter data manually. These two requirements conflict the moment a user corrects a bad value. If a correction is applied as an `UPDATE` on the normalized table, the next normalization rebuild reverts it silently, and the user has no way to know.

Resolution, adopted throughout this document: **there is exactly one write path into normalized data, and it starts at `raw_records`.** Manual entry and manual correction both create raw records under a synthetic import (`source_key = 'manual'`). A correction carries `supersedes_natural_key` and a higher `precedence_rank`. Normalization resolves conflicts deterministically, so a rebuild produces the identical result. No `UPDATE` is ever issued against normalized tables by application code.

### 0.3 Deterministic natural keys break on timestamp corrections

The revised spec correctly removes `value` from duplicate identity, but a key of `hash(user, source, metric, timestamp)` still fails when the source corrects the *timestamp* itself, and it cannot represent deletion at the source. Re-importing a corrected export then leaves an orphan row that no rule will ever remove, and every trend line silently carries a phantom data point.

Resolution: introduce **import modes**. Most consumer exports (Hevy, WHOOP, Strava, smart scales) are full-history snapshots, not deltas. A profile declares `import_mode = full_snapshot` or `append`. In `full_snapshot` mode, the pipeline computes the set of natural keys within the file's declared scope and retires anything in that scope not present in the file. This handles corrections, deletions, and re-timestamping with one mechanism.

### 0.4 "Custom Events" is a trapdoor back into unstructured data

If custom events accept a free-text name plus a note, the system violates Principle 4.3 within a month and those records become permanently unanalyzable. Custom events must resolve to a registered `event_definitions` row with a declared `value_type` and unit, exactly like metrics. The registry can be created inline during import, but it must be created.

### 0.5 Lab results as canonical scalar metrics is right, with one caveat

Unit conversion across labs is safe for anything measured in mass or concentration with a fixed factor (LDL mg/dL to mmol/L). It is *not* safe to draw a single trend line across labs for assay-dependent analytes such as TSH, ferritin, vitamin D, and most hormones, where different labs use different methods and reference ranges. Storing the reference range per observation, as the PRD already requires, is necessary but not sufficient. Analytics must flag any trend computed across more than one `laboratory` value with a "mixed method" warning rather than presenting it as a clean series.

### 0.6 Strength data needs its own registry, and the spec omits it

`metric_definitions` solves metric-name drift. Exercise names have exactly the same problem and it is worse: Hevy writes "Bench Press (Barbell)", a manual entry writes "Barbell Bench Press", and Strong writes "Bench Press: Barbell". Without `exercise_definitions` with aliases, per-exercise progression and PR detection, which are core success criteria, silently split into three unrelated series. Same argument applies to `activity_types`.

### 0.7 Import Profile matching by column signature is fragile

Vendors add columns without warning. Exact signature hashing will stop matching after one WHOOP update, and the user is dropped back into full manual mapping. Profiles need: a stable signature hash for the fast path, plus token-set similarity scoring for the fallback, plus profile versioning so a re-map extends the profile rather than creating a duplicate. Match confidence thresholds are specified in Section 6.

### 0.8 Unresolved before code

The largest genuinely open question is data granularity policy. Storing per-minute heart rate for years is technically feasible in Postgres but it dominates storage, rollups, and cost, and the product's analytical questions ("am I improving?") are answered at daily resolution. This decision is not deferrable, because it determines whether `raw_records` holds tens of thousands or tens of millions of rows. See Section 13, Decision D1.

---

## 1. Revised system architecture

### 1.1 Layer model

```
┌─────────────────────────────────────────────────────────┐
│ CLIENT (Next.js / React, browser)                       │
│  • Direct-to-storage upload via signed URL              │
│  • Client-side file profiling (headers, sample rows)    │
│  • Mapping wizard, preview, job progress polling        │
└───────────────┬─────────────────────────────────────────┘
                │
┌───────────────▼─────────────────────────────────────────┐
│ APPLICATION API (Next.js Route Handlers on Vercel)      │
│  • Auth, profile CRUD, job enqueue, read APIs           │
│  • NEVER receives large file bodies                     │
└───────────────┬─────────────────────────────────────────┘
                │
┌───────────────▼─────────────────────────────────────────┐
│ WORKER (batch, resumable, stateless)                    │
│  Stage A  Ingest      file → raw_records                │
│  Stage B  Normalize   raw_records → canonical tables    │
│  Stage C  Retire      full_snapshot reconciliation      │
│  Stage D  Rollup      dirty days → metric_daily         │
│  Stage E  Derive      derived metrics                   │
│  Stage F  Timeline    timeline_events                   │
│  Stage G  Insights    rule evaluation                   │
└───────────────┬─────────────────────────────────────────┘
                │
┌───────────────▼─────────────────────────────────────────┐
│ SUPABASE                                                │
│  Postgres (RLS on every table)                          │
│  Storage (private bucket, original files)               │
│  Auth                                                   │
└─────────────────────────────────────────────────────────┘
```

### 1.2 Non-negotiable architectural rules

1. **Single write path.** Every canonical row originates from a `raw_record`. No exceptions, including manual entry, corrections, and seed data.
2. **Normalization is a pure function.** `normalize(raw_record, mapping_spec, registry_snapshot, version) → canonical rows`. No hidden reads of current canonical state, no clock reads, no randomness. This is what makes rebuild trustworthy and unit-testing possible.
3. **The API layer never parses files.** It issues signed URLs and enqueues jobs.
4. **Every long operation is a job with checkpoints.** No request-scoped work over 10 seconds.
5. **Derived data is disposable.** `metric_daily`, derived metrics, `timeline_events`, and `insights` can all be dropped and regenerated. Only `raw_records`, `data_imports`, the original files, and the registries are precious.
6. **RLS from day one**, with `user_id` denormalized onto every table including child tables, so no policy requires a join.

### 1.3 Where the worker runs

For a single user, a Vercel Cron route invoked every minute, processing one checkpointed batch per invocation, is adequate and free. The worker is written as a pure function over `(job, batch)` so it can be lifted to a long-running container (Fly.io, Railway, Cloud Run) without rewriting, once file sizes justify it. Do not build the worker as an inline Next.js request handler with the batching logic entangled in HTTP code.

Connection handling: use the Supabase transaction pooler for the worker, session pooler only where prepared statements are needed. Bulk insert via `COPY` where the driver supports it, otherwise multi-row `INSERT` at 1,000 rows per statement.

---

## 2. Final database schema

Conventions: all tables have `id UUID PRIMARY KEY DEFAULT gen_random_uuid()`, `created_at TIMESTAMPTZ NOT NULL DEFAULT now()`. All tables have `user_id UUID NOT NULL REFERENCES auth.users(id)` and an RLS policy `user_id = auth.uid()`. Money-like precision: all measured values use `NUMERIC(18,6)`, never `float8`.

### 2.1 Registries

```sql
-- Source is metadata, not architecture.
CREATE TABLE sources (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  source_key TEXT NOT NULL,          -- 'whoop', 'hevy', 'strava', 'manual', 'omron_scale'
  display_name TEXT NOT NULL,
  kind TEXT NOT NULL,                -- 'wearable' | 'app' | 'device' | 'lab' | 'manual'
  active BOOLEAN NOT NULL DEFAULT true,
  UNIQUE (user_id, source_key)
);

CREATE TABLE units (
  code TEXT PRIMARY KEY,             -- 'kg', 'lb', 'ms', 'bpm', 'mg/dL', 'mmol/L'
  dimension TEXT NOT NULL,           -- 'mass','length','time','frequency','concentration','count','ratio','none'
  display_name TEXT NOT NULL
);

-- Linear conversion only: canonical = (value * factor) + offset
CREATE TABLE unit_conversions (
  from_unit TEXT NOT NULL REFERENCES units(code),
  to_unit   TEXT NOT NULL REFERENCES units(code),
  factor NUMERIC(24,12) NOT NULL,
  offset  NUMERIC(24,12) NOT NULL DEFAULT 0,
  analyte_key TEXT,                  -- NULL = generic; set for molar conversions (LDL mg/dL→mmol/L)
  PRIMARY KEY (from_unit, to_unit, COALESCE(analyte_key, ''))
);

CREATE TABLE metric_definitions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID,                      -- NULL = system-provided definition
  canonical_key TEXT NOT NULL,       -- 'resting_heart_rate'
  display_name TEXT NOT NULL,
  category TEXT NOT NULL,            -- 'body','recovery','activity','lab','sleep','custom'
  subcategory TEXT,                  -- for labs: 'lipids','metabolic','cbc'
  canonical_unit TEXT REFERENCES units(code),
  value_type TEXT NOT NULL,          -- 'numeric','duration_s','ratio','text','boolean','ordinal'
  aggregation_rule TEXT NOT NULL,    -- 'avg','sum','last','min','max','count'
  higher_is_better BOOLEAN,          -- NULL = neutral / context dependent
  volatility_class TEXT NOT NULL DEFAULT 'normal',  -- 'stable','normal','volatile'
  is_derived BOOLEAN NOT NULL DEFAULT false,
  formula_version INT,               -- required when is_derived
  active BOOLEAN NOT NULL DEFAULT true,
  UNIQUE (COALESCE(user_id, '00000000-0000-0000-0000-000000000000'::uuid), canonical_key)
);

CREATE TABLE metric_aliases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID,
  metric_definition_id UUID NOT NULL REFERENCES metric_definitions(id),
  alias_normalized TEXT NOT NULL,    -- lowercased, punctuation stripped: 'resting hr'
  source_key TEXT,                   -- optional scoping
  UNIQUE (COALESCE(user_id,'00000000-0000-0000-0000-000000000000'::uuid), alias_normalized, COALESCE(source_key,''))
);

CREATE TABLE exercise_definitions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID,
  canonical_key TEXT NOT NULL,       -- 'barbell_bench_press'
  display_name TEXT NOT NULL,
  primary_muscle_group TEXT,
  equipment TEXT,                    -- 'barbell','dumbbell','machine','bodyweight','cable'
  is_unilateral BOOLEAN NOT NULL DEFAULT false,
  active BOOLEAN NOT NULL DEFAULT true,
  UNIQUE (COALESCE(user_id,'00000000-0000-0000-0000-000000000000'::uuid), canonical_key)
);

CREATE TABLE exercise_aliases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID,
  exercise_definition_id UUID NOT NULL REFERENCES exercise_definitions(id),
  alias_normalized TEXT NOT NULL,
  UNIQUE (COALESCE(user_id,'00000000-0000-0000-0000-000000000000'::uuid), alias_normalized)
);

CREATE TABLE activity_types (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  canonical_key TEXT UNIQUE NOT NULL,  -- 'run','ride','swim','walk','strength','hike'
  display_name TEXT NOT NULL,
  family TEXT NOT NULL                 -- 'endurance','strength','mobility','other'
);

CREATE TABLE event_definitions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  canonical_key TEXT NOT NULL,       -- 'creatine_mono', 'vitamin_d3'
  display_name TEXT NOT NULL,
  category TEXT NOT NULL,            -- 'supplement','medication','treatment','protocol','other'
  value_type TEXT NOT NULL DEFAULT 'numeric',
  default_unit TEXT REFERENCES units(code),
  active BOOLEAN NOT NULL DEFAULT true,
  UNIQUE (user_id, canonical_key)
);
```

### 2.2 Import layer

```sql
CREATE TABLE import_profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  name TEXT NOT NULL,                     -- 'WHOOP Physiological Cycles'
  template TEXT NOT NULL,                 -- 'metrics','activities','strength','labs','events'
  source_key TEXT NOT NULL,
  signature_hash TEXT NOT NULL,           -- sha256 of sorted normalized header tokens
  header_tokens TEXT[] NOT NULL,          -- for similarity fallback
  mapping_spec JSONB NOT NULL,            -- see Section 6
  import_mode TEXT NOT NULL DEFAULT 'append',   -- 'append' | 'full_snapshot'
  snapshot_scope JSONB,                   -- required when full_snapshot; see Section 7.4
  profile_version INT NOT NULL DEFAULT 1,
  times_used INT NOT NULL DEFAULT 0,
  last_used_at TIMESTAMPTZ
);
CREATE INDEX ON import_profiles (user_id, signature_hash);

CREATE TABLE data_imports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  source_key TEXT NOT NULL,
  template TEXT NOT NULL,
  profile_id UUID REFERENCES import_profiles(id),
  storage_path TEXT,                      -- NULL for synthetic/manual imports
  file_name TEXT,
  file_type TEXT,                         -- 'csv','xlsx','manual'
  file_bytes BIGINT,
  file_sha256 TEXT,                       -- exact-file re-upload detection
  mapping_spec_snapshot JSONB NOT NULL,   -- frozen copy; profile may change later
  normalize_version INT NOT NULL,
  import_mode TEXT NOT NULL,
  status TEXT NOT NULL,                   -- see Section 5
  rows_total INT, rows_ingested INT,
  records_added INT, records_updated INT,
  duplicates_skipped INT, records_retired INT, records_invalid INT,
  error_log JSONB,
  imported_at TIMESTAMPTZ,
  rolled_back_at TIMESTAMPTZ
);

CREATE TABLE import_jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  import_id UUID NOT NULL REFERENCES data_imports(id),
  stage TEXT NOT NULL,                    -- 'ingest','normalize','retire','rollup','derive','timeline','insights'
  state TEXT NOT NULL,                    -- 'queued','running','paused','done','failed','cancelled'
  cursor JSONB NOT NULL DEFAULT '{}',     -- {"last_row": 48000} or {"last_raw_id": "..."}
  attempts INT NOT NULL DEFAULT 0,
  last_error TEXT,
  started_at TIMESTAMPTZ, finished_at TIMESTAMPTZ,
  heartbeat_at TIMESTAMPTZ
);
CREATE INDEX ON import_jobs (state, stage) WHERE state IN ('queued','running');

CREATE TABLE raw_records (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID NOT NULL,
  import_id UUID NOT NULL REFERENCES data_imports(id),
  source_key TEXT NOT NULL,
  row_number INT,
  external_id TEXT,
  payload JSONB NOT NULL,                 -- the source row, verbatim
  row_hash TEXT NOT NULL,                 -- sha256 of canonicalized payload
  precedence_rank SMALLINT NOT NULL DEFAULT 0,  -- 0 imported, 10 manual entry, 20 manual correction
  supersedes_natural_key TEXT,            -- set by corrections
  observed_at TIMESTAMPTZ NOT NULL DEFAULT now(),  -- when this raw row entered the system
  processed_at TIMESTAMPTZ,
  normalize_version INT,
  normalize_status TEXT,                  -- 'pending','ok','invalid','skipped'
  normalize_error TEXT
);
CREATE INDEX ON raw_records (import_id, id);
CREATE INDEX ON raw_records (user_id, normalize_status) WHERE normalize_status = 'pending';
CREATE UNIQUE INDEX ON raw_records (import_id, row_hash);   -- intra-file duplicate guard
```

`raw_records` is append-only. Enforce with a `BEFORE UPDATE OR DELETE` trigger that raises, allowing updates only to `processed_at`, `normalize_version`, `normalize_status`, `normalize_error`.

### 2.3 Canonical fact tables

```sql
CREATE TABLE metrics (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID NOT NULL,
  metric_definition_id UUID NOT NULL REFERENCES metric_definitions(id),
  metric_key TEXT NOT NULL,               -- denormalized for query ergonomics
  qualifier TEXT,                         -- 'left','right','deep_sleep'; part of identity
  timestamp_utc TIMESTAMPTZ NOT NULL,
  tz_offset_minutes INT NOT NULL,
  tz_name TEXT,                           -- IANA where known
  local_date DATE NOT NULL,               -- computed at normalization, never at query time
  value_num NUMERIC(18,6),
  value_text TEXT,
  value_bool BOOLEAN,
  unit TEXT REFERENCES units(code),       -- canonical unit
  source_key TEXT NOT NULL,
  source_value_num NUMERIC(18,6),         -- provenance: pre-conversion
  source_unit TEXT,
  is_derived BOOLEAN NOT NULL DEFAULT false,
  formula_version INT,
  natural_key TEXT NOT NULL,
  revision INT NOT NULL DEFAULT 1,
  raw_record_id BIGINT REFERENCES raw_records(id),
  import_id UUID REFERENCES data_imports(id),
  retired_at TIMESTAMPTZ,                 -- soft delete for snapshot reconciliation
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX metrics_nk_uq ON metrics (natural_key) WHERE is_derived = false;
CREATE UNIQUE INDEX metrics_derived_uq
  ON metrics (user_id, metric_key, local_date, formula_version) WHERE is_derived = true;
CREATE INDEX metrics_query ON metrics (user_id, metric_key, local_date) WHERE retired_at IS NULL;
CREATE INDEX metrics_ts ON metrics (user_id, metric_key, timestamp_utc DESC) WHERE retired_at IS NULL;
```

```sql
-- One row per source's observation of a real-world activity.
CREATE TABLE activity_observations (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID NOT NULL,
  canonical_activity_id UUID REFERENCES canonical_activities(id),
  activity_type_key TEXT NOT NULL REFERENCES activity_types(canonical_key),
  start_utc TIMESTAMPTZ NOT NULL,
  end_utc TIMESTAMPTZ,
  tz_offset_minutes INT NOT NULL,
  local_date DATE NOT NULL,
  duration_s INT,
  distance_m NUMERIC(18,6),
  elevation_gain_m NUMERIC(18,6),
  calories NUMERIC(18,6),
  avg_hr NUMERIC(18,6), max_hr NUMERIC(18,6),
  avg_cadence NUMERIC(18,6),
  source_key TEXT NOT NULL,
  external_id TEXT,
  natural_key TEXT NOT NULL,
  revision INT NOT NULL DEFAULT 1,
  raw_record_id BIGINT REFERENCES raw_records(id),
  import_id UUID REFERENCES data_imports(id),
  retired_at TIMESTAMPTZ,
  metadata JSONB NOT NULL DEFAULT '{}'
);
CREATE UNIQUE INDEX ON activity_observations (natural_key);

-- The real-world event. MVP writes 1:1; resolution merges later.
CREATE TABLE canonical_activities (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  activity_type_key TEXT NOT NULL,
  start_utc TIMESTAMPTZ NOT NULL,
  local_date DATE NOT NULL,
  duration_s INT,
  distance_m NUMERIC(18,6),
  primary_observation_id BIGINT,          -- winning source, per source_precedence
  observation_count INT NOT NULL DEFAULT 1,
  resolution_method TEXT NOT NULL DEFAULT 'singleton',  -- 'singleton','auto_merge','user_merge'
  resolved_at TIMESTAMPTZ
);
```

```sql
CREATE TABLE strength_workouts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  start_utc TIMESTAMPTZ NOT NULL,
  tz_offset_minutes INT NOT NULL,
  local_date DATE NOT NULL,
  duration_s INT,
  title TEXT,
  source_key TEXT NOT NULL,
  external_id TEXT,
  natural_key TEXT NOT NULL,
  raw_record_id BIGINT, import_id UUID REFERENCES data_imports(id),
  retired_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX ON strength_workouts (natural_key);

CREATE TABLE strength_exercises (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  workout_id UUID NOT NULL REFERENCES strength_workouts(id) ON DELETE CASCADE,
  exercise_definition_id UUID REFERENCES exercise_definitions(id),
  exercise_name_raw TEXT NOT NULL,
  order_index INT NOT NULL,
  UNIQUE (workout_id, order_index)
);

CREATE TABLE strength_sets (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID NOT NULL,
  exercise_id UUID NOT NULL REFERENCES strength_exercises(id) ON DELETE CASCADE,
  set_number INT NOT NULL,
  set_type TEXT NOT NULL DEFAULT 'working',   -- 'warmup','working','drop','failure'
  weight_kg NUMERIC(18,6),
  reps INT,
  rpe NUMERIC(4,2),
  duration_s INT,                              -- planks, carries
  distance_m NUMERIC(18,6),
  volume_kg NUMERIC(18,6) GENERATED ALWAYS AS (COALESCE(weight_kg,0) * COALESCE(reps,0)) STORED,
  natural_key TEXT NOT NULL,
  raw_record_id BIGINT,
  retired_at TIMESTAMPTZ,
  UNIQUE (exercise_id, set_number)
);
CREATE UNIQUE INDEX ON strength_sets (natural_key);
```

```sql
-- Lab value lives in metrics. This is the sidecar for lab-only context.
CREATE TABLE lab_observation_meta (
  metric_id BIGINT PRIMARY KEY REFERENCES metrics(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  laboratory TEXT,
  panel_name TEXT,
  specimen TEXT,
  method TEXT,
  reference_low NUMERIC(18,6),
  reference_high NUMERIC(18,6),
  reference_text TEXT,
  reference_unit TEXT,
  flag TEXT                                    -- as reported: 'H','L','normal'
);

CREATE TABLE health_protocols (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  name TEXT NOT NULL,
  category TEXT NOT NULL,
  start_date DATE, end_date DATE,
  notes TEXT
);

CREATE TABLE custom_events (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID NOT NULL,
  event_definition_id UUID NOT NULL REFERENCES event_definitions(id),
  protocol_id UUID REFERENCES health_protocols(id),
  timestamp_utc TIMESTAMPTZ NOT NULL,
  tz_offset_minutes INT NOT NULL,
  local_date DATE NOT NULL,
  amount NUMERIC(18,6), unit TEXT REFERENCES units(code),
  source_key TEXT NOT NULL,
  natural_key TEXT NOT NULL,
  raw_record_id BIGINT, import_id UUID REFERENCES data_imports(id),
  retired_at TIMESTAMPTZ,
  metadata JSONB NOT NULL DEFAULT '{}',
  notes TEXT
);
CREATE UNIQUE INDEX ON custom_events (natural_key);
```

### 2.4 Analytics layer (all regenerable)

```sql
CREATE TABLE source_precedence (
  user_id UUID NOT NULL,
  metric_key TEXT NOT NULL,           -- '*' allowed as fallback
  source_key TEXT NOT NULL,
  priority INT NOT NULL,              -- lower wins
  PRIMARY KEY (user_id, metric_key, source_key)
);

-- Tier 1: per source per day. Recomputing precedence never re-reads metrics.
CREATE TABLE metric_daily_source (
  user_id UUID NOT NULL,
  metric_key TEXT NOT NULL,
  source_key TEXT NOT NULL,
  local_date DATE NOT NULL,
  avg NUMERIC(18,6), min NUMERIC(18,6), max NUMERIC(18,6),
  sum NUMERIC(18,6), last_value NUMERIC(18,6), count INT NOT NULL,
  PRIMARY KEY (user_id, metric_key, source_key, local_date)
);

-- Tier 2: the series analytics reads. One row per metric per day.
CREATE TABLE metric_daily (
  user_id UUID NOT NULL,
  metric_key TEXT NOT NULL,
  local_date DATE NOT NULL,
  value NUMERIC(18,6) NOT NULL,       -- per aggregation_rule, from winning source
  min NUMERIC(18,6), max NUMERIC(18,6), count INT NOT NULL,
  winning_source TEXT NOT NULL,
  source_count INT NOT NULL,
  contributing_sources JSONB NOT NULL DEFAULT '[]',
  computed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, metric_key, local_date)
);

CREATE TABLE rollup_queue (
  user_id UUID NOT NULL,
  metric_key TEXT NOT NULL,
  local_date DATE NOT NULL,
  enqueued_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, metric_key, local_date)
);

CREATE TABLE metric_baselines (
  user_id UUID NOT NULL,
  metric_key TEXT NOT NULL,
  as_of_date DATE NOT NULL,
  window_days INT NOT NULL,           -- 60 or 90
  mean NUMERIC(18,6), sd NUMERIC(18,6),
  n_observations INT NOT NULL,
  coverage_ratio NUMERIC(6,4) NOT NULL,   -- days with data / window_days
  PRIMARY KEY (user_id, metric_key, as_of_date, window_days)
);

CREATE TABLE timeline_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  local_date DATE NOT NULL,
  domain TEXT NOT NULL,               -- 'fitness','body','recovery','labs','records','system'
  event_type TEXT NOT NULL,           -- 'pr','import','protocol_start','lab_panel','trend_shift'
  title TEXT NOT NULL,
  summary TEXT,
  ref_table TEXT, ref_id TEXT,
  importance SMALLINT NOT NULL DEFAULT 50,
  generator_id TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  generated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ON timeline_events (user_id, fingerprint);
CREATE INDEX ON timeline_events (user_id, local_date DESC, importance DESC);

CREATE TABLE insights (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  rule_id TEXT NOT NULL,
  rule_version INT NOT NULL,
  fingerprint TEXT NOT NULL,
  category TEXT NOT NULL,             -- 'progress','trend','correlation','attention','recommendation'
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  evidence JSONB NOT NULL,            -- metrics used, values, n, baseline, z-score
  confidence TEXT NOT NULL,           -- 'high','moderate','low','insufficient_data'
  period_start DATE NOT NULL, period_end DATE NOT NULL,
  status TEXT NOT NULL DEFAULT 'new', -- 'new','acknowledged','dismissed','stale'
  ai_narrative TEXT,                  -- optional, generated on top of evidence
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ON insights (user_id, fingerprint);
```

---

## 3. Entity relationship explanation

**Registry spine.** `metric_definitions`, `exercise_definitions`, `activity_types`, `event_definitions`, and `units` are the vocabulary. Nothing enters a canonical table without resolving to a registry row. Aliases are the only place fuzzy string matching is permitted, and matches are always confirmed by the user during mapping, never applied silently.

**Provenance chain.** `metrics.raw_record_id → raw_records.import_id → data_imports.storage_path → original file in Storage`. Every canonical row can produce its source spreadsheet cell. `source_value_num` and `source_unit` on the metric mean a user can see "82.6 kg (imported as 182.1 lb)" without re-reading the raw row.

**Import spine.** `import_profiles` is the reusable template; `data_imports` freezes a copy of the mapping in `mapping_spec_snapshot` so that editing the profile later cannot retroactively change what a past import meant; `import_jobs` are the execution records, one per stage, so a failure in rollup does not require re-ingesting the file.

**Metrics is the universal fact table.** Weight, waist, HRV, RHR, sleep duration, LDL, and glucose are all `metrics` rows differing only in `metric_definition_id`. This is what lets one chart component, one baseline engine, and one trend detector serve every scalar in the product. Lab-specific context hangs off it 1:1 via `lab_observation_meta`.

**Typed tables exist only where structure is genuinely different.** Activities are one event with many attributes. Strength is a three-level hierarchy. Both are irreducible to `(timestamp, value)`.

**Two-level activity model.** `activity_observations` is what a source said. `canonical_activities` is what happened. Analytics reads only canonical. In the MVP the normalizer creates one canonical per observation, so behavior is identical to a single-table design, but the join is already in place, which means enabling entity resolution later is an `UPDATE` of foreign keys rather than a schema migration.

**Two-tier rollup mirrors that model for scalars.** `metric_daily_source` records what each source said per day; `metric_daily` records the resolved series. Changing `source_precedence` only recomputes tier 2, which is milliseconds, not a full re-scan of `metrics`.

**Analytics tables are leaves.** Nothing depends on `metric_daily`, `metric_baselines`, `timeline_events`, or `insights` except the UI. They can all be truncated and rebuilt.

---

## 4. Raw → normalized pipeline

### 4.1 Contract

```
normalize(
  raw_record,
  mapping_spec_snapshot,
  registry_snapshot,
  normalize_version
) → { canonical_rows[], warnings[], errors[] }
```

Pure. Deterministic. No database reads inside. The registry snapshot is loaded once per batch and passed in, which is what makes it unit-testable against fixture files.

### 4.2 Steps

1. **Extract** fields from `payload` per `mapping_spec.bindings`.
2. **Parse timestamp.** Combine date and time columns, apply the profile's timezone policy (Section 8), produce `timestamp_utc`, `tz_offset_minutes`, `tz_name`, `local_date`.
3. **Resolve identity.** Column value → alias table → `metric_definition_id`. Unresolved and not confirmed at mapping time is a hard error, never a silent free-text insert.
4. **Parse value** per `value_type`. Reject non-numeric into a numeric metric; do not coerce. Locale hazard: reject ambiguous decimal separators unless the profile declares one.
5. **Convert units.** `canonical = value * factor + offset`, looked up by `(source_unit, canonical_unit, analyte_key)`. Preserve originals in `source_value_num` / `source_unit`. Missing conversion is a hard error, never a pass-through.
6. **Validate range.** Per-metric plausibility bounds (weight 20 to 400 kg, HR 20 to 250 bpm). Out-of-range becomes `normalize_status = 'invalid'` with the row retained in raw. Do not drop.
7. **Compute natural key** (Section 7).
8. **Emit** canonical rows plus rollup-queue entries.

### 4.3 Conflict resolution across raw records

When multiple raw records map to the same `natural_key`, the winner is chosen by:

```
ORDER BY precedence_rank DESC, observed_at DESC, id DESC
```

`precedence_rank`: 0 = imported, 10 = manual entry, 20 = manual correction. A manual correction therefore always beats a later re-import of the same bad value, and a rebuild reproduces the same winner because all three sort keys are stored in immutable columns.

### 4.4 Rebuild procedure

```
1. Bump NORMALIZE_VERSION in code.
2. DELETE FROM metrics WHERE user_id = $1 AND is_derived = false;   (and peer tables)
3. UPDATE raw_records SET normalize_status='pending', processed_at=NULL WHERE user_id=$1;
4. Enqueue a normalize job per import, in ascending imported_at order.
5. Re-run retire, rollup, derive, timeline, insights.
```

Ordering by `imported_at` matters: `full_snapshot` retirement must replay in the original sequence or a later snapshot will not correctly retire what an earlier one added. This ordering requirement is why `data_imports.imported_at` must never be mutated.

---

## 5. Import job lifecycle

### 5.1 States

```
draft ──► profiling ──► awaiting_mapping ──► validating ──► preview_ready
                                                                  │
                                          ┌───────────────────────┤
                                          ▼                       ▼
                                     cancelled                 queued
                                                                  │
                                                                  ▼
                                                              ingesting
                                                                  │
                                                              normalizing
                                                                  │
                                                              retiring
                                                                  │
                                                              aggregating
                                                                  │
                              ┌───────────────────┬───────────────┤
                              ▼                   ▼               ▼
                          completed    completed_with_errors   failed
                              │
                              ▼
                        rolled_back
```

### 5.2 Stage detail

**Upload.** Client requests a signed upload URL, PUTs directly to a private Supabase Storage bucket at `{user_id}/{import_id}/{filename}`. The API never sees the bytes. Compute `file_sha256` client-side; an exact match against a prior `data_imports.file_sha256` warns "this exact file was imported on [date]" before any work is done.

**Profiling.** Client-side for files under ~20 MB using PapaParse streaming or SheetJS; server-side worker above that. Produces: headers, row count, per-column inferred type, date-format candidates, distinct-value samples, null ratio, and the signature hash. Profiling never writes canonical data.

**Mapping and preview.** The wizard runs entirely against a sample (first 200 valid rows plus 100 random rows). Preview shows: rows that will insert, rows that will update an existing record, rows that will be skipped as unchanged duplicates, rows that will be retired under snapshot mode, invalid rows with reasons, and every unit conversion with a worked example. Nothing is written until the user confirms.

**Ingest.** Streams the file in 5,000-row chunks, writing `raw_records`. Checkpoint after each chunk to `import_jobs.cursor.last_row`. On re-invocation the worker resumes from the cursor. The unique index on `(import_id, row_hash)` makes chunk replay idempotent.

**Normalize.** Batches of 5,000 pending raw records. Upserts canonical rows. Checkpoint on `cursor.last_raw_id`.

**Retire.** Snapshot mode only. See Section 7.4.

**Aggregate, derive, timeline, insights.** Drained from `rollup_queue` and dirty-day sets. These stages are shared infrastructure, not import-specific, and also run on a nightly schedule.

### 5.3 Failure handling

Each stage is independently retryable with exponential backoff, max 5 attempts. A stuck job is detected by `heartbeat_at` older than 5 minutes and returned to `queued`. Partial completion is a valid terminal state: `completed_with_errors` with `records_invalid > 0` is normal and expected, and invalid rows remain queryable in `raw_records` so the user can fix a mapping and re-normalize without re-uploading.

**Rollback.** `DELETE FROM raw_records WHERE import_id = $1` (the one permitted deletion, gated behind an explicit user action) cascades logically to canonical rows via `raw_record_id`, then triggers a re-normalize of any natural key whose winning raw record was removed. Mark `data_imports.rolled_back_at`. Keep the original file.

---

## 6. Universal column mapping architecture

### 6.1 `mapping_spec` shape

```jsonc
{
  "template": "metrics",
  "layout": "wide",                    // "wide" | "long"
  "timestamp": {
    "columns": ["Cycle start time"],
    "format": "yyyy-MM-dd HH:mm:ss",
    "timezone": { "mode": "column", "column": "Cycle timezone" }
  },
  "external_id": { "column": "Cycle ID" },

  // wide layout: one binding per metric column
  "bindings": [
    { "column": "Recovery score %", "metric_key": "recovery_score", "unit": "percent" },
    { "column": "Heart rate variability (ms)", "metric_key": "hrv_rmssd", "unit": "ms" },
    { "column": "Resting heart rate (bpm)", "metric_key": "resting_heart_rate", "unit": "bpm" },
    { "column": "Asleep duration (min)", "metric_key": "sleep_duration", "unit": "min" }
  ],

  // long layout instead of bindings:
  // "metric_column": "Metric", "value_column": "Value", "unit_column": "Unit",
  // "metric_value_map": { "RHR": "resting_heart_rate", "Weight": "body_weight" },
  // "unit_value_map": { "lbs": "lb" },

  "qualifier": { "column": null, "constant": null },
  "row_filters": [ { "column": "Recovery score %", "op": "not_empty" } ],
  "constants": { "source_key": "whoop" },
  "decimal_separator": ".",
  "on_unmapped_column": "ignore"
}
```

The critical design point: **a mapping is a list of bindings, not a field-to-field dictionary.** Wide format is N bindings against one timestamp; long format is one binding parameterized by a metric column. Both compile to the same emit loop. Using a flat `{source_column: canonical_field}` dictionary, which is the obvious first implementation, cannot express wide layout and will have to be thrown away.

### 6.2 Template-specific required fields

| Template | Required | Optional |
|---|---|---|
| metrics | timestamp, ≥1 binding or (metric_column + value_column) | unit, qualifier, external_id |
| activities | timestamp, activity_type | duration, distance, calories, avg_hr, elevation, external_id |
| strength | timestamp, exercise, set_number or implied order, (weight and reps) or duration | workout_title, rpe, set_type, external_id |
| labs | test_date, test_name, value | unit, reference_low/high/text, laboratory, panel |
| events | timestamp, event_key | amount, unit, protocol, notes |

Note on strength: not all sources emit `set_number`. If absent, derive it from row order within `(workout, exercise)` and record `set_number_derived: true` in raw metadata, because derived ordering is a natural-key input and must be flagged as unstable if the source ever reorders rows.

### 6.3 Profile matching

```
1. Exact match on signature_hash               → confidence HIGH, auto-apply, show summary
2. Jaccard(header_tokens) ≥ 0.85               → confidence MEDIUM, pre-fill, require confirmation
3. 0.60 ≤ Jaccard < 0.85                       → confidence LOW, pre-fill mapped columns only,
                                                  highlight new/missing columns
4. < 0.60                                      → no match, full manual mapping
```

Header tokens are normalized: lowercased, punctuation and unit suffixes stripped, whitespace collapsed. On a case-2 or case-3 match where the user confirms, increment `profile_version` and update `signature_hash` and `header_tokens` in place rather than creating a second profile. Otherwise every vendor column addition spawns a duplicate profile and the list becomes unusable within a year.

### 6.4 Mapping suggestion

Auto-suggest by exact alias hit first, then by normalized-string similarity above 0.8 against `metric_aliases`. Every suggestion is presented as a proposal with the matched alias visible. When the user accepts a suggestion for a previously unknown column, write the new alias to `metric_aliases`. The registry gets smarter with use, and no fuzzy match is ever committed without a human confirming it once.

---

## 7. Deduplication and revision strategy

### 7.1 Natural key construction

Two strategies, selected per row:

**A. External ID present** (preferred, used whenever the source emits a stable ID):
```
natural_key = sha256(user_id | source_key | template | metric_key | qualifier | external_id)
```
Timestamp is deliberately excluded. A source correcting the timestamp is then an update, not a new record.

**B. No external ID:**
```
natural_key = sha256(user_id | source_key | template | metric_key | qualifier | timestamp_utc_truncated)
```
Truncation granularity comes from `metric_definitions`: daily metrics truncate to `local_date`, intraday metrics to the second. Truncating a daily weight to the second would create a new record every time the scale reports a slightly different sync time.

`value` never appears in either key.

### 7.2 Upsert

```sql
INSERT INTO metrics (...) VALUES (...)
ON CONFLICT (natural_key) WHERE is_derived = false
DO UPDATE SET
  value_num = EXCLUDED.value_num,
  unit = EXCLUDED.unit,
  source_value_num = EXCLUDED.source_value_num,
  source_unit = EXCLUDED.source_unit,
  timestamp_utc = EXCLUDED.timestamp_utc,
  local_date = EXCLUDED.local_date,
  raw_record_id = EXCLUDED.raw_record_id,
  import_id = EXCLUDED.import_id,
  retired_at = NULL,
  revision = metrics.revision + 1,
  updated_at = now()
WHERE metrics.value_num IS DISTINCT FROM EXCLUDED.value_num
   OR metrics.timestamp_utc IS DISTINCT FROM EXCLUDED.timestamp_utc
   OR metrics.retired_at IS NOT NULL;
```

The `WHERE` clause on the `DO UPDATE` is important: without it, every re-import bumps `revision` and `updated_at` on every unchanged row, which destroys the accuracy of the import summary and makes "what actually changed" unanswerable. Rows that fail the `WHERE` are counted as `duplicates_skipped`.

### 7.3 Revision history

The normalized row is a projection and carries only a counter. Full history lives in `raw_records`, which already holds every version of every row with `observed_at`. History for any data point is:

```sql
SELECT r.payload, r.observed_at, r.import_id, r.precedence_rank
FROM raw_records r
JOIN metrics m ON m.raw_record_id = r.id
WHERE m.natural_key = $1;
-- plus: all raw_records whose normalization produced this natural_key
```

To make that second clause cheap, persist the computed natural key back onto the raw record during normalization in a `normalized_keys TEXT[]` column, indexed with GIN. This is the one place worth denormalizing.

### 7.4 Snapshot reconciliation

`snapshot_scope` declares what the file is authoritative for:

```jsonc
{
  "source_key": "hevy",
  "templates": ["strength"],
  "date_range": "derive_from_file",     // or {"from":"2024-01-01","to":"2026-09-01"}
  "metric_keys": null                    // null = all within template
}
```

After normalization completes:

```sql
UPDATE strength_workouts
SET retired_at = now()
WHERE user_id = $1
  AND source_key = 'hevy'
  AND local_date BETWEEN $2 AND $3
  AND retired_at IS NULL
  AND natural_key <> ALL($4);   -- keys present in this import
```

Retirement is soft. Retired rows are excluded from every analytics query but remain visible in an audit view. `date_range: derive_from_file` uses min and max observed local_date in the file, which prevents a partial export from wiping history outside its range. This is the single most dangerous operation in the system and must be shown explicitly in preview with a count before confirmation.

---

## 8. Timezone strategy

### 8.1 Storage

Every timestamped row stores three things: `timestamp_utc` (the instant), `tz_offset_minutes` (the offset in effect), and `local_date` (the calendar date the user experienced). `tz_name` is stored when an IANA zone is known.

`local_date` is computed once at normalization and stored, never derived at query time. Every rollup, chart, and comparison keys on `local_date`. Deriving it in a query would make it impossible to index and would recompute travel history on every page load.

### 8.2 Resolution order in the mapping spec

```jsonc
"timezone": { "mode": "..." }
```

1. `column` — the file carries a zone or offset per row (WHOOP does). Highest fidelity, always prefer.
2. `embedded` — the timestamp string itself carries an offset (`2026-03-14T06:12:00+07:00`). Parse and keep.
3. `fixed` — the profile declares one zone for the whole file, e.g. `Asia/Jakarta`. Correct for locally-generated exports where the user was home.
4. `travel_aware` — resolve per row against the `user_travel_periods` table (below), falling back to home zone.
5. `home` — the user's default zone from settings. Last resort.

Never store a naive local timestamp with no offset. If the file provides none and the mode is `fixed`, the offset is computed from the IANA zone at that instant, which correctly handles DST for zones that observe it.

### 8.3 Travel

```sql
CREATE TABLE user_travel_periods (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  tz_name TEXT NOT NULL,
  start_date DATE NOT NULL,
  end_date DATE,
  source TEXT NOT NULL   -- 'manual','inferred_activity'
);
```

Manual entry in MVP. Later, a period can be inferred from activity timezone columns where several consecutive days report a non-home zone. Changing travel periods requires re-deriving `local_date` for affected rows, which is a normalize rebuild scoped by date range, and is therefore cheap because the raw layer is intact.

### 8.4 Day boundary for sleep

Sleep spanning midnight is a genuine modeling decision, not an edge case. Rule: **sleep metrics are attributed to the wake date**, matching how WHOOP and Apple Health present them. Encode this as `metric_definitions.day_attribution = 'wake_date' | 'event_date'` rather than hardcoding it, because the user may disagree and because other overnight metrics will need it.

---

## 9. Daily rollup strategy

### 9.1 Mechanism

Normalization inserts into `rollup_queue` for every touched `(user_id, metric_key, local_date)` using `ON CONFLICT DO NOTHING`. A worker stage drains the queue in batches.

Do not use database triggers. Bulk import would fire millions of trigger executions inside the insert transaction and turn a 30-second import into an hour.

### 9.2 Tier 1

```sql
INSERT INTO metric_daily_source (user_id, metric_key, source_key, local_date, avg, min, max, sum, last_value, count)
SELECT user_id, metric_key, source_key, local_date,
       avg(value_num), min(value_num), max(value_num), sum(value_num),
       (array_agg(value_num ORDER BY timestamp_utc DESC))[1],
       count(*)
FROM metrics
WHERE user_id = $1 AND metric_key = $2 AND local_date = $3
  AND retired_at IS NULL AND is_derived = false
GROUP BY user_id, metric_key, source_key, local_date
ON CONFLICT (user_id, metric_key, source_key, local_date) DO UPDATE SET ...;
```

If the group is empty (everything was retired), delete the tier-1 row instead.

### 9.3 Tier 2

Select the winning source by `source_precedence` (metric-specific priority first, then `'*'`, then alphabetical as a deterministic tiebreak), then project the column named by `metric_definitions.aggregation_rule`:

| aggregation_rule | `metric_daily.value` |
|---|---|
| avg | tier-1 `avg` |
| sum | tier-1 `sum` |
| last | tier-1 `last_value` |
| min / max | tier-1 `min` / `max` |

Record `source_count` and `contributing_sources` so the UI can surface "3 sources reported weight on this day; showing Withings."

### 9.4 Gaps

`metric_daily` stores only days with observations. Missing days are absent rows, not zeros. Gap filling is a presentation and analysis concern, and the policy differs by metric: training volume gaps are genuine zeros, weight gaps are carry-forward or interpolate, HRV gaps are simply missing. Encode as `metric_definitions.gap_policy = 'zero' | 'carry_forward' | 'null'` and apply it in the analytics layer, never in storage.

### 9.5 Weekly and monthly

Do not build separate weekly and monthly tables in the MVP. Aggregate from `metric_daily` at query time. With daily granularity, five years is under 2,000 rows per metric, which is trivial. Revisit only if a real query is measurably slow.

---

## 10. Cross-source duplication strategy

### 10.1 Scalar metrics

Handled entirely by the two-tier rollup. Multiple sources coexist in `metrics`; `metric_daily` picks one. No merging, no data loss, no double counting. Changing preference is a settings edit plus a tier-2 recompute.

### 10.2 Activities

Every observation gets a `canonical_activity_id` from day one. In MVP the normalizer creates a singleton canonical per observation. All analytics query `canonical_activities`, never `activity_observations`. This means enabling resolution later changes zero query code.

Resolution algorithm, when enabled:

```
Candidate pair (A, B) matches if ALL:
  • same user
  • activity_type family matches
  • |A.start_utc - B.start_utc| ≤ 10 minutes
  • duration within 15% of each other
  • AND ( both distances null
          OR distance within 10% )
  • different source_key
```

On match: keep the earlier canonical, repoint both observations, set `resolution_method = 'auto_merge'`, `observation_count = 2`, and set `primary_observation_id` from `source_precedence`. Canonical field values are copied from the primary observation, per field, falling back to any non-null observation for fields the primary lacks. Merges are recorded in an `activity_merges` audit table and are reversible.

Ambiguous pairs (matching on time but conflicting on distance by more than 10%) are not auto-merged. They surface in a review queue with a user-facing "same activity? / different activities?" decision, and the decision is persisted so re-running resolution respects it.

### 10.3 Strength

Cross-source duplication is unlikely (one gym app in practice) but the natural key already prevents intra-source duplication. If it becomes real, apply the same canonical/observation pattern. Not designed further now, and this is a deliberate scope decision, not an oversight.

---

## 11. Migration strategy

### 11.1 Schema migrations

Forward-only numbered SQL files (`supabase/migrations/0001_init.sql`) under version control. Never edit an applied migration. Expand-contract for every breaking change: add the new column, backfill, dual-write, switch reads, drop the old column in a later migration. Every migration is tested against a restored production snapshot before being applied, even with one user.

### 11.2 Reference data

`units`, `unit_conversions`, `activity_types`, and system `metric_definitions` are seeded via idempotent upserts in versioned seed files, separate from schema migrations. Adding a metric definition must never require a schema change.

### 11.3 Normalization versions

`NORMALIZE_VERSION` is an application constant, incremented whenever normalization output changes for identical input. `data_imports.normalize_version` and `raw_records.normalize_version` record what produced each row. A dashboard query surfaces rows below current version, and rebuild can be run selectively per import rather than globally.

### 11.4 Formula versions

Same pattern for derived metrics. Bumping `formula_version` invalidates and regenerates only the affected derived rows, and the derived unique index includes `formula_version` so two versions can coexist during verification.

### 11.5 Backup

Supabase point-in-time recovery covers the database. The original files in Storage are the true disaster backstop: with them plus the migration files and the mapping profiles, the entire database can be reconstructed. Include `import_profiles` in a scheduled JSON export, because a profile is the only thing in the system that is neither derivable nor re-uploadable.

### 11.6 Multi-user

Nothing is required later. RLS and `user_id` on every table from day one make multi-user a matter of removing the single-user assumption from the UI. The only shared entities are system registry rows with `user_id IS NULL`, which are already modeled.

---

## 12. Recommended implementation order

The revised 10-phase plan is close. Three changes: pull the metric registry admin UI earlier, put manual entry before charts (it is the fastest source of real data), and split derived metrics out of general analytics.

**Phase 1 — Foundation**
Next.js, Supabase, auth, RLS policies, migration tooling. `units`, `unit_conversions`, `metric_definitions`, `activity_types` seeded. A minimal registry admin screen.
*Exit:* an authenticated user can view the metric registry and no table is readable cross-user in a manual RLS test.

**Phase 2 — Raw layer and job runner**
Signed-URL upload, Storage bucket, `data_imports`, `import_jobs`, `raw_records`, append-only trigger, chunked resumable ingest, cron worker.
*Exit:* a 200k-row CSV lands in `raw_records` with correct row count and survives a mid-ingest worker kill without duplication.

**Phase 3 — Universal Import Engine**
Profiling, template selection, mapping wizard, unit mapping, preview, normalization framework, natural keys, database-level dedupe, import summary. Validated end to end on one real Hevy export.
*Exit:* importing the same Hevy file twice adds zero records the second time and reports it accurately.

**Phase 4 — Import profiles and manual entry**
Signature matching, similarity fallback, profile versioning. Manual entry and manual correction routed through synthetic imports. Body measurements UI.
*Exit:* re-importing an updated Hevy export auto-applies the profile; a manual correction survives a full normalize rebuild.

**Phase 5 — Rollups and charts**
`rollup_queue`, both rollup tiers, `source_precedence`, period selection, period comparison, `metric_daily` reads only.
*Exit:* a 1-year chart renders from `metric_daily` with a single indexed query.

**Phase 6 — More datasets**
WHOOP CSV, Strava CSV, a smart-scale export. Each with a committed fixture file and a regression test.
*Exit:* three profiles coexist; no metric-name drift in the registry.

**Phase 7 — Derived metrics**
Tonnage, training volume, rolling baselines, e1RM, pace. `formula_version` and regeneration.
*Exit:* bumping a formula version regenerates only affected rows.

**Phase 8 — Timeline**
`timeline_events` generators, fingerprinting, domain filters, materialized writes on the dirty-day pattern.

**Phase 9 — Deterministic analytics and eligibility**
Trend detection, z-score against baseline, coverage checks, minimum-N gates, `INSUFFICIENT_DATA` as a first-class result.
*Exit:* on a deliberately sparse metric, the system returns insufficient data rather than a percentage.

**Phase 10 — Insights**
Rule engine with `rule_id`, `fingerprint`, evidence payloads, status transitions, idempotent regeneration.

**Phase 11 — Cross-source entity resolution**
Activity matching, review queue, persisted user decisions.

**Phase 12 — AI interpretation**
Narrative generation strictly on top of `insights.evidence`. The model receives structured analytics output only, never raw rows, and never performs arithmetic. Safety boundaries from PRD Section 17 enforced in the prompt and in a post-generation check.

**Apple Health is deliberately last**, and only after a converter tool has been chosen and its output treated as just another CSV profile.

---

## 13. Decisions that must be closed before writing code

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D1 | Granularity policy for high-frequency data | (a) store everything raw, (b) store raw but normalize only daily aggregates, (c) reject sub-hourly at import | **(b)** Keep raw for reprocessing, normalize to daily. Revisit only if a real question needs intraday. This single choice is the difference between 10⁴ and 10⁷ canonical rows. |
| D2 | Where the worker runs | Vercel cron, Supabase Edge Function, dedicated container | **Vercel cron with checkpointing** for MVP; keep the worker a pure function so it can be lifted. |
| D3 | Are lab values `metrics` rows or their own table | unified vs separate | **Unified**, with `lab_observation_meta` sidecar. Separating means writing the analytics engine twice. |
| D4 | Non-numeric metric support in MVP | numeric only vs numeric + text + boolean + ordinal | **Schema supports all four; MVP implements numeric only.** Adding the columns later is a migration; adding them now is free. |
| D5 | Import mode default | append vs full_snapshot | **Default `append`**, require explicit opt-in to `full_snapshot` with a preview count of retirements. Wrong default here destroys history. |
| D6 | Timeline: computed or materialized | on-read vs materialized | **Materialized**, dirty-day driven. On-read across six domains cannot paginate or sort coherently. |
| D7 | Sleep day attribution | wake date vs sleep-onset date | **Wake date**, but store the policy in `metric_definitions.day_attribution`. |
| D8 | Cross-lab trend policy | one line vs segmented with warning | **Segment and warn** when `laboratory` differs within a series. |
| D9 | Delete semantics for an import | hard delete raw vs soft delete | **Hard delete raw records for an explicit rollback only**; everything else is soft retirement. Keep the original file in Storage regardless. |
| D10 | Numeric type | `NUMERIC` vs `double precision` | **`NUMERIC(18,6)`**. Float accumulation errors in sums over years are not acceptable in a system whose whole claim is evidence-based. |
| D11 | Apple Health converter | Health Auto Export vs Simple Health Export vs custom script | Pick one before Phase 6 and treat its output as a fixed profile contract. Unresolved. |
| D12 | Client-side vs server-side XLSX parsing threshold | 10 MB / 20 MB / always server | **20 MB client-side**, above that server. Client parsing keeps the wizard instant for typical files. |

D1 and D11 are the two that genuinely block. The rest have defensible defaults above and can be confirmed rather than debated.

---

## 14. What is deliberately not being built

Stating these prevents scope drift and makes the omissions decisions rather than gaps.

- PDF and OCR lab parsing. Out of MVP, confirmed.
- Direct vendor API integrations. The universal engine makes them optional forever, which is the point of the pivot.
- Real-time sync. Everything is batch.
- Weekly and monthly rollup tables. Aggregated from daily on read.
- Cross-source resolution for strength data.
- Mobile application.
- Multi-user UI, though the schema supports it.
- An AI chat interface over the database. Phase 12 produces narratives over verified analytics only; a free-form query interface is a separate product decision with its own safety surface.
