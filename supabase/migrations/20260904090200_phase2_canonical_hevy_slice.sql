-- ============================================================================
-- 20260904090200_phase2_canonical_hevy_slice.sql
-- Phase 2 - Data foundation: canonical tables for the first slice only.
--
-- Scope is fixed by ruling R1: metrics, strength_workouts, strength_exercises,
-- strength_sets. No activities, sleep, labs or custom events.
--
-- Specification:
--   v2 section 2.3   the four table definitions and their index sets
--   v2 section 7.1   natural key strategy (value never participates)
--   v2 section 7.2   upsert and revision strategy
--   v3 section 4.4   retired_by_import_id for permanent retirement undo
--
-- Invariants, and where this file tightens the v2 DDL to satisfy them
-- (recorded as RD-1 in docs/phase-2-reconciliation-audit.md):
--   I-1  Every canonical row originates from a raw_record. v2 section 2.3
--        declares raw_record_id nullable; here it is NOT NULL, and
--        strength_exercises gains one, which v2 omits.
--   I-6  Every exercise resolves to a registry row. v2 section 2.3 declares
--        exercise_definition_id nullable; here it is NOT NULL.
--   I-7  Measured values are NUMERIC(18,6). The single exception is
--        strength_sets.rpe, which is NUMERIC(4,2) by ruling R5; see the
--        comment on that column.
--   I-8  user_id on every table, including child tables.
--   I-4  Application code never updates a canonical table. Enforced by
--        privilege in the RLS migration: the authenticated role is granted
--        SELECT only on all four tables.
--
-- Cross-user integrity is enforced structurally rather than by per-row
-- triggers, because these tables take bulk inserts. Every parent carries a
-- UNIQUE (id, user_id) and every child references it compositely, so a row
-- can never point at another user's row and no policy needs a join.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- metrics
--   v2 section 2.3. The universal scalar fact table. Created in Phase 2 by R1;
--   the Hevy slice does not write to it (Hevy is the 'strength' template).
--
--   is_derived and formula_version are present because v2's own index set
--   (metrics_nk_uq, metrics_derived_uq) is defined in terms of them. Derived
--   metric behaviour is Phase 7 and is not implemented.
--   value_text and value_bool are present per decision D4 / ADR-D4: the schema
--   carries all value types, the MVP implements numeric only.
-- ---------------------------------------------------------------------------

create table public.metrics (
  id                    bigserial primary key,
  user_id               uuid not null references auth.users (id) on delete cascade,
  metric_definition_id  uuid not null references public.metric_definitions (id) on delete restrict,
  metric_key            text not null,
  qualifier             text,
  timestamp_utc         timestamptz not null,
  tz_offset_minutes     integer not null,
  tz_name               text,
  local_date            date not null,
  value_num             numeric(18,6),
  value_text            text,
  value_bool            boolean,
  unit_id               uuid references public.units (id) on delete restrict,
  unit                  text,
  source_key            text not null,
  source_value_num      numeric(18,6),
  source_unit           text,
  is_derived            boolean not null default false,
  formula_version       integer,
  natural_key           text not null,
  revision              integer not null default 1,
  raw_record_id         bigint not null,
  import_id             uuid not null,
  retired_at            timestamptz,
  retired_by_import_id  uuid,
  updated_at            timestamptz not null default now(),
  created_at            timestamptz not null default now(),
  constraint metrics_tz_offset_range
    check (tz_offset_minutes between -1080 and 1080),
  constraint metrics_revision_positive
    check (revision >= 1),
  constraint metrics_derived_needs_formula_version
    check (is_derived = false or formula_version is not null),
  -- ADR-11 / v3 section 4.4: a retired row records which import retired it.
  constraint metrics_retirement_consistent
    check ((retired_at is null) = (retired_by_import_id is null)),
  constraint metrics_raw_record_fk
    foreign key (raw_record_id, user_id)
    references public.raw_records (id, user_id) on delete restrict,
  constraint metrics_import_fk
    foreign key (import_id, user_id)
    references public.data_imports (id, user_id) on delete restrict
);

-- v2 section 2.3 index set, verbatim.
create unique index metrics_nk_uq on public.metrics (natural_key) where is_derived = false;
create unique index metrics_derived_uq
  on public.metrics (user_id, metric_key, local_date, formula_version) where is_derived = true;
create index metrics_query on public.metrics (user_id, metric_key, local_date) where retired_at is null;
create index metrics_ts on public.metrics (user_id, metric_key, timestamp_utc desc) where retired_at is null;
create index metrics_raw_record_idx on public.metrics (raw_record_id);
create index metrics_import_idx on public.metrics (import_id);

comment on column public.metrics.local_date is
  'v2 section 8.1. Computed once at normalization and stored, never derived at query time.';
comment on column public.metrics.natural_key is
  'v2 section 7.1. Value never participates, so a source correcting a value is an update rather than a phantom duplicate.';
comment on column public.metrics.unit_id is
  'RD-2. Referential integrity for the canonical unit. v2 section 2.3 writes this as unit TEXT REFERENCES units(code); the units registry is keyed by UUID and is user-extensible (ruling R6), so the reference is by id and the text code is denormalized alongside it.';
comment on column public.metrics.source_unit is
  'v2 section 2.3. Provenance only, deliberately no foreign key: this is whatever the source called its unit.';

-- ---------------------------------------------------------------------------
-- strength_workouts
--   v2 section 2.3. Ruling R3 makes this the retirement root for the whole
--   strength hierarchy.
-- ---------------------------------------------------------------------------

create table public.strength_workouts (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references auth.users (id) on delete cascade,
  start_utc             timestamptz not null,
  tz_offset_minutes     integer not null,
  local_date            date not null,
  duration_s            integer,
  title                 text,
  source_key            text not null,
  external_id           text,
  natural_key           text not null,
  revision              integer not null default 1,
  raw_record_id         bigint not null,
  import_id             uuid not null,
  retired_at            timestamptz,
  retired_by_import_id  uuid,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint strength_workouts_tz_offset_range
    check (tz_offset_minutes between -1080 and 1080),
  constraint strength_workouts_duration_non_negative
    check (duration_s is null or duration_s >= 0),
  constraint strength_workouts_revision_positive
    check (revision >= 1),
  constraint strength_workouts_retirement_consistent
    check ((retired_at is null) = (retired_by_import_id is null)),
  constraint strength_workouts_raw_record_fk
    foreign key (raw_record_id, user_id)
    references public.raw_records (id, user_id) on delete restrict,
  constraint strength_workouts_import_fk
    foreign key (import_id, user_id)
    references public.data_imports (id, user_id) on delete restrict,
  constraint strength_workouts_id_user_uq unique (id, user_id)
);

create unique index strength_workouts_nk_uq on public.strength_workouts (natural_key);
create index strength_workouts_query
  on public.strength_workouts (user_id, local_date desc) where retired_at is null;
create index strength_workouts_user_id_idx on public.strength_workouts (user_id);
create index strength_workouts_import_idx on public.strength_workouts (import_id);
create index strength_workouts_raw_record_idx on public.strength_workouts (raw_record_id);
-- v2 section 7.4 retirement scope: source_key plus local_date within a range.
create index strength_workouts_retire_scope_idx
  on public.strength_workouts (user_id, source_key, local_date) where retired_at is null;

comment on table public.strength_workouts is
  'Ruling R3: the retirement root of the strength hierarchy. Retiring a workout hides its exercises and sets through the canonical views; children carry no duplicated parent retirement state.';

-- ---------------------------------------------------------------------------
-- strength_exercises
--   v2 section 2.3. Ruling R3: no retired_at column. Retirement is inherited
--   from the workout and applied by v_strength_exercises.
-- ---------------------------------------------------------------------------

create table public.strength_exercises (
  id                      uuid primary key default gen_random_uuid(),
  user_id                 uuid not null references auth.users (id) on delete cascade,
  workout_id              uuid not null,
  exercise_definition_id  uuid not null references public.exercise_definitions (id) on delete restrict,
  exercise_name_raw       text not null,
  order_index             integer not null,
  raw_record_id           bigint not null,
  import_id               uuid not null,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  constraint strength_exercises_order_index_non_negative
    check (order_index >= 0),
  constraint strength_exercises_name_raw_not_blank
    check (length(btrim(exercise_name_raw)) > 0),
  constraint strength_exercises_workout_fk
    foreign key (workout_id, user_id)
    references public.strength_workouts (id, user_id) on delete cascade,
  constraint strength_exercises_raw_record_fk
    foreign key (raw_record_id, user_id)
    references public.raw_records (id, user_id) on delete restrict,
  constraint strength_exercises_import_fk
    foreign key (import_id, user_id)
    references public.data_imports (id, user_id) on delete restrict,
  constraint strength_exercises_workout_order_uq unique (workout_id, order_index),
  constraint strength_exercises_id_user_uq unique (id, user_id)
);

create index strength_exercises_user_id_idx on public.strength_exercises (user_id);
create index strength_exercises_workout_idx on public.strength_exercises (workout_id);
create index strength_exercises_definition_idx on public.strength_exercises (exercise_definition_id);
create index strength_exercises_raw_record_idx on public.strength_exercises (raw_record_id);

comment on column public.strength_exercises.exercise_definition_id is
  'NOT NULL by I-6. v2 section 2.3 declares this nullable, but v2 section 4.2 step 3 makes an unresolved exercise a hard error, so no null case exists. Tightened deliberately (RD-1).';
comment on column public.strength_exercises.exercise_name_raw is
  'Provenance only: what the source file called this exercise. Never an analytical identifier (I-6).';

-- The registry parent may be a shared system row (user_id IS NULL) or the
-- user's own, so a composite foreign key cannot express the rule. Reuse the
-- Phase 1 ownership guard. One statement per exercise row, not per set.
create trigger strength_exercises_definition_ownership
  before insert or update on public.strength_exercises
  for each row execute function public.registry_assert_parent_ownership('exercise_definitions', 'exercise_definition_id');

-- ---------------------------------------------------------------------------
-- strength_sets
--   v2 section 2.3. retired_at is kept because v2 gives it: it expresses
--   row-level retirement of an individual set. It is NOT the mechanism for
--   parent retirement, which ruling R3 assigns to the views.
-- ---------------------------------------------------------------------------

create table public.strength_sets (
  id                    bigserial primary key,
  user_id               uuid not null references auth.users (id) on delete cascade,
  exercise_id           uuid not null,
  set_number            integer not null,
  set_type              text not null default 'working',
  weight_kg             numeric(18,6),
  reps                  integer,
  rpe                   numeric(4,2),
  duration_s            integer,
  distance_m            numeric(18,6),
  volume_kg             numeric(18,6)
                          generated always as (coalesce(weight_kg, 0) * coalesce(reps, 0)) stored,
  natural_key           text not null,
  revision              integer not null default 1,
  raw_record_id         bigint not null,
  retired_at            timestamptz,
  retired_by_import_id  uuid,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint strength_sets_set_type_allowed
    check (set_type in ('warmup', 'working', 'drop', 'failure')),
  constraint strength_sets_set_number_positive
    check (set_number >= 1),
  constraint strength_sets_reps_non_negative
    check (reps is null or reps >= 0),
  constraint strength_sets_weight_non_negative
    check (weight_kg is null or weight_kg >= 0),
  constraint strength_sets_duration_non_negative
    check (duration_s is null or duration_s >= 0),
  constraint strength_sets_distance_non_negative
    check (distance_m is null or distance_m >= 0),
  -- RPE is a bounded 0-10 domain score, not a physical measurement.
  constraint strength_sets_rpe_range
    check (rpe is null or (rpe >= 0 and rpe <= 10)),
  constraint strength_sets_revision_positive
    check (revision >= 1),
  constraint strength_sets_retirement_consistent
    check ((retired_at is null) = (retired_by_import_id is null)),
  constraint strength_sets_exercise_fk
    foreign key (exercise_id, user_id)
    references public.strength_exercises (id, user_id) on delete cascade,
  constraint strength_sets_raw_record_fk
    foreign key (raw_record_id, user_id)
    references public.raw_records (id, user_id) on delete restrict,
  constraint strength_sets_exercise_set_number_uq unique (exercise_id, set_number)
);

create unique index strength_sets_nk_uq on public.strength_sets (natural_key);
create index strength_sets_user_id_idx on public.strength_sets (user_id);
create index strength_sets_exercise_idx on public.strength_sets (exercise_id);
create index strength_sets_raw_record_idx on public.strength_sets (raw_record_id);

comment on column public.strength_sets.rpe is
  'NUMERIC(4,2) by ruling R5, an explicit and deliberate exception to I-7. RPE is a bounded 0-10 domain score, not a physical measurement, and does not need six decimal places. Every other measured value on this table is NUMERIC(18,6). Do not widen this column.';
comment on column public.strength_sets.volume_kg is
  'v2 section 2.3. Generated, never written by application code.';
comment on column public.strength_sets.retired_at is
  'Row-level retirement of this individual set only. Retirement inherited from the workout is applied by v_strength_sets, not duplicated here (ruling R3).';
