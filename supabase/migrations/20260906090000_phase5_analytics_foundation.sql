-- ============================================================================
-- 20260906090000_phase5_analytics_foundation.sql
-- Phase 5: the analytics foundation.
--
-- WHAT THIS IS
--
-- v2 section 9 and v3 ADR-15/ADR-19, implemented: a dirty-day queue, two
-- rollup tiers, source precedence, and an idempotent recomputation that
-- rebuilds a scope from canonical truth rather than adjusting it by
-- arithmetic delta.
--
-- Phase 4 answered every dashboard question by aggregating the user's whole
-- canonical set history on every request. That is correct and it is what made
-- the semantics reviewable, but it does not scale and it recomputes the same
-- answer for the same unchanged days forever. Phase 5 moves the aggregation to
-- write time, keyed on the day, and leaves the read a range scan over an
-- indexed daily series.
--
-- WHAT THIS IS NOT
--
-- Not v3 Phase 7. Nothing here writes a derived row into public.metrics, there
-- is no formula_version, and no canonical row is created, updated or deleted
-- by anything in this file. Everything created here is a disposable leaf: it
-- can be truncated and rebuilt from the canonical tables (v2 section 1.4).
--
-- Not a second write path. The canonical model remains the only source of
-- truth. These tables are a cache with a proven invalidation path.
--
-- TWO GRAINS, AND WHY THEY HAVE DIFFERENT SHAPES
--
-- metric_daily is v2 section 2.4's table, unchanged in shape: long format,
-- one row per (user, metric_key, day), because it must eventually hold weight,
-- HRV, steps and every other scalar Phase 6 and 7 produce. Training figures
-- are scalars per day and fit it exactly.
--
-- exercise_daily is a wide fact table at (user, exercise, day). The exercise
-- grain has a closed, fixed set of measures that are always computed together
-- from one scan, and the two alternatives are both worse: a nullable
-- exercise_definition_id on metric_daily would be a meaningless column on
-- every scalar row, and long format at this grain multiplies the row count by
-- the number of measures for no benefit. See docs/architecture-implementation-notes.md N-5.
--
-- CROSS-SOURCE RESOLUTION, STATED PLAINLY
--
-- Tier 2 picks a winning source per v2 section 9.3. For a scalar that two
-- devices both report, that is exactly right. For training counts it is right
-- only while the two sources are reporting the same sessions. Today one source
-- exists and CLAUDE.md section 6 keeps additional vendors out of scope, so
-- tier 2 is a pass-through. When a second strength source arrives, this is the
-- decision to revisit, and source_count and contributing_sources are recorded
-- on every row so the situation is visible rather than silent.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. metric_definitions.gap_policy
--
-- Already present: 20260904090000_phase1_registry_reconciliation.sql added it
-- with the same domain v2 section 9.4 specifies. Phase 5 is the first thing to
-- read it. Seed 0003 sets it per training metric and explains each choice.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. source_precedence (v2 section 2.4)
--
-- A user setting, not derived data, so the user owns it and may edit it.
-- metric_key '*' is the fallback for every metric.
-- ---------------------------------------------------------------------------

create table public.source_precedence (
  user_id    uuid not null references auth.users (id) on delete cascade,
  metric_key text not null,
  source_key text not null,
  priority   integer not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, metric_key, source_key),
  constraint source_precedence_priority_non_negative check (priority >= 0)
);

comment on table public.source_precedence is
  'v2 section 2.4. Which source wins when several report the same metric on the same day. Lower priority wins; metric_key ''*'' is the fallback.';

-- ---------------------------------------------------------------------------
-- 2. metric_daily_source — tier 1 (v2 section 2.4, ADR-15)
--
-- What ONE source said about ONE metric on ONE day, plus the canonical records
-- it said it from. Recomputing precedence never re-reads canonical data
-- because tier 1 already holds the per-source answer.
--
-- contributing_workout_ids is the provenance layer Phase 5 owes: it answers
-- "which canonical records produced this figure" directly from the row. Set
-- ids are deliberately not stored — a set belongs to an exercise belongs to a
-- workout, so the workout ids reach every contributing set through the
-- canonical model, and storing 30,000 set ids per user would be storing the
-- canonical model twice.
-- ---------------------------------------------------------------------------

create table public.metric_daily_source (
  user_id      uuid not null references auth.users (id) on delete cascade,
  metric_key   text not null,
  source_key   text not null,
  local_date   date not null,
  avg          numeric(18,6),
  min          numeric(18,6),
  max          numeric(18,6),
  sum          numeric(18,6),
  first_value  numeric(18,6),
  last_value   numeric(18,6),
  count        integer not null,
  contributing_workout_ids uuid[] not null default '{}',
  computed_at  timestamptz not null default now(),
  primary key (user_id, metric_key, source_key, local_date),
  constraint metric_daily_source_count_positive check (count > 0)
);

create index metric_daily_source_scope_idx
  on public.metric_daily_source (user_id, local_date);

comment on table public.metric_daily_source is
  'Tier 1 (ADR-15). One row per user, metric, source and day, carrying the canonical workout ids it was computed from.';

-- ---------------------------------------------------------------------------
-- 3. metric_daily — tier 2 (v2 section 2.4)
--
-- The series the read model reads. One row per metric per day, resolved from
-- tier 1 by source_precedence and projected through the metric's own
-- default_aggregation.
--
-- Only days with observations exist. A missing day is an absent row, never a
-- stored zero (v2 section 9.4).
-- ---------------------------------------------------------------------------

create table public.metric_daily (
  user_id              uuid not null references auth.users (id) on delete cascade,
  metric_key           text not null,
  local_date           date not null,
  value                numeric(18,6) not null,
  min                  numeric(18,6),
  max                  numeric(18,6),
  count                integer not null,
  winning_source       text not null,
  source_count         integer not null,
  contributing_sources jsonb not null default '[]',
  computed_at          timestamptz not null default now(),
  primary key (user_id, metric_key, local_date),
  constraint metric_daily_count_positive check (count > 0),
  constraint metric_daily_source_count_positive check (source_count > 0)
);

create index metric_daily_scope_idx on public.metric_daily (user_id, local_date);

comment on table public.metric_daily is
  'Tier 2 (v2 section 2.4). The resolved daily series analytics reads. Regenerable: truncating it and re-running the rollup reproduces it exactly.';

-- ---------------------------------------------------------------------------
-- 4. exercise_daily_source / exercise_daily — the exercise grain
-- ---------------------------------------------------------------------------

create table public.exercise_daily_source (
  user_id                uuid not null references auth.users (id) on delete cascade,
  exercise_definition_id uuid not null references public.exercise_definitions (id) on delete cascade,
  source_key             text not null,
  local_date             date not null,
  session_count          integer not null,
  set_count              integer not null,
  volume_sets            integer not null,
  volume_kg              numeric(18,6),
  reps                   integer,
  reps_sets              integer not null,
  top_weight_kg          numeric(18,6),
  distance_m             numeric(18,6),
  distance_sets          integer not null,
  duration_s             integer,
  duration_sets          integer not null,
  contributing_workout_ids uuid[] not null default '{}',
  computed_at            timestamptz not null default now(),
  primary key (user_id, exercise_definition_id, source_key, local_date)
);

create index exercise_daily_source_scope_idx
  on public.exercise_daily_source (user_id, local_date);

create table public.exercise_daily (
  user_id                uuid not null references auth.users (id) on delete cascade,
  exercise_definition_id uuid not null references public.exercise_definitions (id) on delete cascade,
  local_date             date not null,
  session_count          integer not null,
  set_count              integer not null,
  volume_sets            integer not null,
  volume_kg              numeric(18,6),
  reps                   integer,
  reps_sets              integer not null,
  top_weight_kg          numeric(18,6),
  distance_m             numeric(18,6),
  distance_sets          integer not null,
  duration_s             integer,
  duration_sets          integer not null,
  winning_source         text not null,
  source_count           integer not null,
  contributing_sources   jsonb not null default '[]',
  computed_at            timestamptz not null default now(),
  primary key (user_id, exercise_definition_id, local_date)
);

create index exercise_daily_scope_idx on public.exercise_daily (user_id, local_date);

comment on table public.exercise_daily is
  'The exercise grain of the analytics layer: one row per user, exercise and day. Wide rather than long because the measures are a closed set always computed together (see N-5).';

-- ---------------------------------------------------------------------------
-- 5. rollup_queue — the dirty-scope queue (ADR-19)
--
-- Never a database trigger: a bulk import would fire one per row inside the
-- insert transaction. The producers of canonical rows enqueue the days they
-- touched, and the worker drains.
--
-- The scope is a DAY, not a metric-day, because every training metric for a
-- day is recomputed from the same single scan. Enqueuing per metric would make
-- the worker scan the same day once per metric.
--
-- At most one PENDING row per scope exists, which is what makes a duplicate
-- enqueue free. A scope already being processed does NOT block a new pending
-- row: if canonical data changes while a recompute is in flight, the change
-- must be picked up by a subsequent run.
-- ---------------------------------------------------------------------------

create table public.rollup_queue (
  id           bigserial primary key,
  user_id      uuid not null references auth.users (id) on delete cascade,
  domain       text not null,
  local_date   date not null,
  state        text not null default 'pending',
  reason       text not null,
  attempts     integer not null default 0,
  enqueued_at  timestamptz not null default now(),
  claimed_at   timestamptz,
  claimed_by   text,
  processed_at timestamptz,
  last_error   text,
  constraint rollup_queue_domain_allowed check (domain in ('training')),
  constraint rollup_queue_state_allowed
    check (state in ('pending', 'processing', 'done', 'failed')),
  constraint rollup_queue_reason_allowed
    check (reason in ('import', 'retirement', 'rebuild', 'migration')),
  constraint rollup_queue_attempts_non_negative check (attempts >= 0)
);

create unique index rollup_queue_pending_uniq
  on public.rollup_queue (user_id, domain, local_date) where state = 'pending';

create index rollup_queue_claimable_idx
  on public.rollup_queue (state, enqueued_at) where state in ('pending', 'processing');

create index rollup_queue_user_idx on public.rollup_queue (user_id, state);

comment on table public.rollup_queue is
  'ADR-19. Dirty analytics scopes awaiting recomputation. One scope is one (user, domain, day). At most one pending row per scope, so duplicate enqueue is free.';

-- ---------------------------------------------------------------------------
-- 6. Row level security (I-8). Every table carries user_id and a join-free
--    policy. Derived data is readable by its owner and writable by nobody
--    through the Data API: the rollup is a privileged path, exactly as
--    normalization is (I-4, RD-3).
-- ---------------------------------------------------------------------------

alter table public.source_precedence      enable row level security;
alter table public.metric_daily_source    enable row level security;
alter table public.metric_daily           enable row level security;
alter table public.exercise_daily_source  enable row level security;
alter table public.exercise_daily         enable row level security;
alter table public.rollup_queue           enable row level security;

create policy "source_precedence_select_own" on public.source_precedence
  for select to authenticated using (user_id = (select auth.uid()));
create policy "source_precedence_insert_own" on public.source_precedence
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy "source_precedence_update_own" on public.source_precedence
  for update to authenticated using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
create policy "source_precedence_delete_own" on public.source_precedence
  for delete to authenticated using (user_id = (select auth.uid()));

create policy "metric_daily_source_select_own" on public.metric_daily_source
  for select to authenticated using (user_id = (select auth.uid()));
create policy "metric_daily_select_own" on public.metric_daily
  for select to authenticated using (user_id = (select auth.uid()));
create policy "exercise_daily_source_select_own" on public.exercise_daily_source
  for select to authenticated using (user_id = (select auth.uid()));
create policy "exercise_daily_select_own" on public.exercise_daily
  for select to authenticated using (user_id = (select auth.uid()));
create policy "rollup_queue_select_own" on public.rollup_queue
  for select to authenticated using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- 7. Privileges.
--
-- The Phase 2 lockdown revoked Supabase's default grants for future tables, so
-- these six start with nothing. They are still revoked explicitly: a migration
-- that relies on an earlier migration's ALTER DEFAULT PRIVILEGES having been
-- applied is a migration that fails silently on a database where it was not.
-- ---------------------------------------------------------------------------

revoke all on public.source_precedence     from anon, authenticated;
revoke all on public.metric_daily_source   from anon, authenticated;
revoke all on public.metric_daily          from anon, authenticated;
revoke all on public.exercise_daily_source from anon, authenticated;
revoke all on public.exercise_daily        from anon, authenticated;
revoke all on public.rollup_queue          from anon, authenticated;
revoke all on sequence public.rollup_queue_id_seq from anon, authenticated;

-- The user owns their source preference.
grant select, insert, update, delete on public.source_precedence to authenticated;

-- Derived data: read your own, write none. Analytics are produced by the
-- rollup, never by the client.
grant select on public.metric_daily_source   to authenticated;
grant select on public.metric_daily          to authenticated;
grant select on public.exercise_daily_source to authenticated;
grant select on public.exercise_daily        to authenticated;
grant select on public.rollup_queue          to authenticated;

-- ---------------------------------------------------------------------------
-- 8. Gap policy, applied by the analytics layer.
--
-- Returns the value a missing day should read as: 0 for a metric whose absence
-- genuinely means none happened, NULL for one whose absence means not
-- observed. Written so a caller can say
--   coalesce(sum(...), public.metric_gap_zero('training_workouts'))
-- and get zero-filling or gap-preserving behaviour from the registry rather
-- than from a hard-coded decision in the query.
-- ---------------------------------------------------------------------------

create or replace function public.metric_gap_zero(p_metric_key text)
returns numeric
language sql
stable
as $$
  select case when d.gap_policy = 'zero' then 0::numeric else null::numeric end
    from public.metric_definitions d
   where d.key = p_metric_key and d.user_id is null;
$$;

comment on function public.metric_gap_zero(text) is
  'v2 section 9.4. 0 when the metric''s gap_policy is zero, NULL otherwise, so gap filling is driven by the registry instead of by each query.';

grant execute on function public.metric_gap_zero(text) to authenticated;
revoke all on function public.metric_gap_zero(text) from public, anon;

-- ---------------------------------------------------------------------------
-- 9. The recomputation.
--
-- One scope is one (user, day). The function DELETES the scope and REBUILDS it
-- from canonical truth. It never adjusts a stored total by a delta, because a
-- delta can only be as correct as the caller's belief about what changed, and
-- a wrong delta is undetectable afterwards. A full scope rebuild is wrong only
-- if the canonical read is wrong.
--
-- This makes it idempotent by construction: running it twice over unchanged
-- canonical data produces byte-identical rows, and running it over a day whose
-- workouts have all been retired leaves no rows at all.
--
-- It is one statement sequence inside one function, so it is atomic: either
-- the scope is fully rebuilt or it is untouched. There is no window in which a
-- scope is half-deleted.
--
-- It reads the v_* views (I-5), so retirement is honoured by construction: a
-- retired workout is not visible to the view and therefore cannot contribute.
-- The views' retirement filter lives in the view body, not in RLS, so it
-- applies to the elevated connection the worker uses as well.
-- ---------------------------------------------------------------------------

create or replace function public.rollup_recompute_training_day(
  p_user_id    uuid,
  p_local_date date
)
returns void
language plpgsql
as $$
declare
  unresolved text;
begin
  delete from public.metric_daily_source
   where user_id = p_user_id and local_date = p_local_date;
  delete from public.metric_daily
   where user_id = p_user_id and local_date = p_local_date;
  delete from public.exercise_daily_source
   where user_id = p_user_id and local_date = p_local_date;
  delete from public.exercise_daily
   where user_id = p_user_id and local_date = p_local_date;

  -- Tier 1, user grain. Every metric is "sum over a defined set of atomic
  -- observations", which is what lets one statement produce all of them and
  -- what makes avg/min/max/first/last meaningful for each.
  insert into public.metric_daily_source
    (user_id, metric_key, source_key, local_date,
     avg, min, max, sum, first_value, last_value, count,
     contributing_workout_ids, computed_at)
  select
    p_user_id,
    o.metric_key,
    o.source_key,
    p_local_date,
    avg(o.value),
    min(o.value),
    max(o.value),
    sum(o.value),
    (array_agg(o.value order by o.ord))[1],
    (array_agg(o.value order by o.ord desc))[1],
    count(*),
    (select array_agg(distinct x) from unnest(array_agg(o.workout_id)) x),
    now()
  from (
    -- One workout is one observation of training_workouts, worth 1.
    select w.source_key, 'training_workouts'::text as metric_key,
           1::numeric as value, w.start_utc as ord, w.id as workout_id
      from public.v_strength_workouts w
     where w.user_id = p_user_id and w.local_date = p_local_date

    union all
    select w.source_key, 'training_duration_s',
           w.duration_s::numeric, w.start_utc, w.id
      from public.v_strength_workouts w
     where w.user_id = p_user_id and w.local_date = p_local_date
       and w.duration_s is not null

    union all
    select w.source_key, 'training_exercise_slots', 1::numeric, w.start_utc, w.id
      from public.v_strength_exercises e
      join public.v_strength_workouts w on w.id = e.workout_id
     where w.user_id = p_user_id and w.local_date = p_local_date

    union all
    select w.source_key, 'training_sets', 1::numeric, w.start_utc, w.id
      from public.v_strength_sets s
      join public.v_strength_exercises e on e.id = s.exercise_id
      join public.v_strength_workouts w on w.id = e.workout_id
     where w.user_id = p_user_id and w.local_date = p_local_date

    union all
    -- A loaded set: one that records BOTH a load and a rep count. This is the
    -- Phase 4 volume rule, unchanged, now enforced at write time.
    select w.source_key, 'training_volume_sets', 1::numeric, w.start_utc, w.id
      from public.v_strength_sets s
      join public.v_strength_exercises e on e.id = s.exercise_id
      join public.v_strength_workouts w on w.id = e.workout_id
     where w.user_id = p_user_id and w.local_date = p_local_date
       and s.weight_kg is not null and s.reps is not null

    union all
    select w.source_key, 'training_volume_kg', s.volume_kg, w.start_utc, w.id
      from public.v_strength_sets s
      join public.v_strength_exercises e on e.id = s.exercise_id
      join public.v_strength_workouts w on w.id = e.workout_id
     where w.user_id = p_user_id and w.local_date = p_local_date
       and s.weight_kg is not null and s.reps is not null

    union all
    select w.source_key, 'training_reps', s.reps::numeric, w.start_utc, w.id
      from public.v_strength_sets s
      join public.v_strength_exercises e on e.id = s.exercise_id
      join public.v_strength_workouts w on w.id = e.workout_id
     where w.user_id = p_user_id and w.local_date = p_local_date
       and s.reps is not null
  ) o
  group by o.metric_key, o.source_key;

  -- I-6, at the analytics boundary: a metric_key that resolves to no registry
  -- row is a free-text identifier, and the rollup refuses rather than quietly
  -- producing a series nothing can name or unit-convert.
  select string_agg(distinct mds.metric_key, ', ') into unresolved
    from public.metric_daily_source mds
   where mds.user_id = p_user_id and mds.local_date = p_local_date
     and not exists (
       select 1 from public.metric_definitions d
        where d.key = mds.metric_key and d.user_id is null and d.is_active
     );
  if unresolved is not null then
    raise exception
      'rollup: metric key(s) % resolve to no active system metric definition (I-6)', unresolved;
  end if;

  -- Tier 2, user grain. Resolve the winning source, then project the column
  -- the metric's own default_aggregation names (v2 section 9.3).
  insert into public.metric_daily
    (user_id, metric_key, local_date, value, min, max, count,
     winning_source, source_count, contributing_sources, computed_at)
  with ranked as (
    select mds.*,
           coalesce(
             (select p.priority from public.source_precedence p
               where p.user_id = mds.user_id
                 and p.metric_key = mds.metric_key
                 and p.source_key = mds.source_key),
             (select p.priority from public.source_precedence p
               where p.user_id = mds.user_id
                 and p.metric_key = '*'
                 and p.source_key = mds.source_key),
             2147483647
           ) as priority
      from public.metric_daily_source mds
     where mds.user_id = p_user_id and mds.local_date = p_local_date
  ),
  winner as (
    -- Deterministic: priority first, then source_key alphabetically, so two
    -- runs over the same data always choose the same source.
    select distinct on (r.metric_key) r.*
      from ranked r
     order by r.metric_key, r.priority, r.source_key
  )
  select
    w.user_id, w.metric_key, w.local_date,
    case d.default_aggregation
      when 'sum'   then w.sum
      when 'mean'  then w.avg
      when 'min'   then w.min
      when 'max'   then w.max
      when 'first' then w.first_value
      when 'last'  then w.last_value
      when 'count' then w.count::numeric
    end,
    w.min, w.max, w.count,
    w.source_key,
    (select count(*) from ranked r where r.metric_key = w.metric_key),
    (select jsonb_agg(jsonb_build_object('source_key', r.source_key, 'count', r.count)
                        order by r.source_key)
       from ranked r where r.metric_key = w.metric_key),
    now()
  from winner w
  join public.metric_definitions d
    on d.key = w.metric_key and d.user_id is null
  -- A projection that lands on NULL is not an observation. sum over a set of
  -- observations cannot be NULL, so this only excludes a genuinely undefined
  -- aggregation, never a real zero.
  where case d.default_aggregation
          when 'sum'   then w.sum
          when 'mean'  then w.avg
          when 'min'   then w.min
          when 'max'   then w.max
          when 'first' then w.first_value
          when 'last'  then w.last_value
          when 'count' then w.count::numeric
        end is not null;

  -- Tier 1, exercise grain.
  insert into public.exercise_daily_source
    (user_id, exercise_definition_id, source_key, local_date,
     session_count, set_count, volume_sets, volume_kg, reps, reps_sets,
     top_weight_kg, distance_m, distance_sets, duration_s, duration_sets,
     contributing_workout_ids, computed_at)
  select
    p_user_id,
    e.exercise_definition_id,
    w.source_key,
    p_local_date,
    count(distinct w.id),
    count(s.id),
    count(s.id) filter (where s.weight_kg is not null and s.reps is not null),
    sum(s.volume_kg) filter (where s.weight_kg is not null and s.reps is not null),
    sum(s.reps),
    count(s.id) filter (where s.reps is not null),
    max(s.weight_kg),
    sum(s.distance_m),
    count(s.id) filter (where s.distance_m is not null),
    sum(s.duration_s),
    count(s.id) filter (where s.duration_s is not null),
    (select array_agg(distinct x) from unnest(array_agg(w.id)) x),
    now()
  from public.v_strength_exercises e
  join public.v_strength_workouts w on w.id = e.workout_id
  left join public.v_strength_sets s on s.exercise_id = e.id
  where w.user_id = p_user_id and w.local_date = p_local_date
  group by e.exercise_definition_id, w.source_key;

  -- Tier 2, exercise grain. Same resolution rule, using the '*' precedence row
  -- because this grain is not per metric_key.
  insert into public.exercise_daily
    (user_id, exercise_definition_id, local_date,
     session_count, set_count, volume_sets, volume_kg, reps, reps_sets,
     top_weight_kg, distance_m, distance_sets, duration_s, duration_sets,
     winning_source, source_count, contributing_sources, computed_at)
  with ranked as (
    select eds.*,
           coalesce(
             (select p.priority from public.source_precedence p
               where p.user_id = eds.user_id
                 and p.metric_key = '*'
                 and p.source_key = eds.source_key),
             2147483647
           ) as priority
      from public.exercise_daily_source eds
     where eds.user_id = p_user_id and eds.local_date = p_local_date
  ),
  winner as (
    select distinct on (r.exercise_definition_id) r.*
      from ranked r
     order by r.exercise_definition_id, r.priority, r.source_key
  )
  select
    w.user_id, w.exercise_definition_id, w.local_date,
    w.session_count, w.set_count, w.volume_sets, w.volume_kg, w.reps, w.reps_sets,
    w.top_weight_kg, w.distance_m, w.distance_sets, w.duration_s, w.duration_sets,
    w.source_key,
    (select count(*) from ranked r where r.exercise_definition_id = w.exercise_definition_id),
    (select jsonb_agg(jsonb_build_object('source_key', r.source_key, 'set_count', r.set_count)
                        order by r.source_key)
       from ranked r where r.exercise_definition_id = w.exercise_definition_id),
    now()
  from winner w;
end;
$$;

comment on function public.rollup_recompute_training_day(uuid, date) is
  'Rebuilds one (user, day) analytics scope from canonical truth. Atomic, idempotent, and never an arithmetic delta. Reads the v_* views, so retired data cannot contribute.';

-- ---------------------------------------------------------------------------
-- 10. The queue API.
--
-- Enqueue is the only thing the producers of canonical rows need to know
-- about. It is deliberately cheap and deliberately duplicate-tolerant: calling
-- it twice for the same day costs one no-op insert, which is what lets the
-- import pipeline enqueue defensively without reasoning about what a previous
-- stage already did.
-- ---------------------------------------------------------------------------

create or replace function public.rollup_enqueue_training_days(
  p_user_id uuid,
  p_dates   date[],
  p_reason  text default 'import'
)
returns integer
language sql
as $$
  with inserted as (
    insert into public.rollup_queue (user_id, domain, local_date, reason)
    select distinct p_user_id, 'training', d, p_reason
      from unnest(coalesce(p_dates, '{}'::date[])) d
     where d is not null
       and not exists (
         select 1 from public.rollup_queue q
          where q.user_id = p_user_id
            and q.domain = 'training'
            and q.local_date = d
            and q.state = 'pending'
       )
    -- The not-exists above loses a race between two concurrent enqueues of the
    -- same scope. The partial unique index catches it and this makes the loser
    -- a no-op rather than an error, because the winner's row already covers it.
    on conflict do nothing
    returning 1
  )
  select count(*)::integer from inserted;
$$;

comment on function public.rollup_enqueue_training_days(uuid, date[], text) is
  'Marks analytics scopes dirty. Idempotent: a scope already pending is not enqueued twice.';

/** Enqueues every day on which the user has non-retired training. */
create or replace function public.rollup_rebuild_user(p_user_id uuid)
returns integer
language sql
as $$
  select public.rollup_enqueue_training_days(
    p_user_id,
    (select array_agg(distinct w.local_date)
       from public.v_strength_workouts w
      where w.user_id = p_user_id),
    'rebuild'
  );
$$;

comment on function public.rollup_rebuild_user(uuid) is
  'Full rebuild path. Derived data is disposable: truncating the analytics tables and calling this reproduces them from canonical truth.';

-- ---------------------------------------------------------------------------
-- 11. The worker's processing loop.
--
-- Claims one scope at a time with FOR UPDATE SKIP LOCKED, so two workers never
-- take the same scope and neither waits for the other. Each scope is
-- recomputed inside its own subtransaction: one failing scope records its
-- error and returns to the queue without rolling back the scopes already done.
--
-- A scope that fails five times is parked in 'failed' rather than spun on
-- forever. It stays visible, with its last error, which is the difference
-- between a stale metric somebody can find and a stale metric nobody knows
-- about.
-- ---------------------------------------------------------------------------

create or replace function public.rollup_process_pending(
  p_limit  integer default 100,
  p_worker text default 'worker'
)
returns jsonb
language plpgsql
as $$
declare
  scope     public.rollup_queue%rowtype;
  processed integer := 0;
  failed    integer := 0;
  errors    jsonb   := '[]'::jsonb;
  message   text;
  superseded boolean;
  -- Scopes already attempted in THIS invocation. A scope that fails goes back
  -- to 'pending' for a later run; without this it would be re-claimed
  -- immediately and one poison scope would burn the whole batch budget and all
  -- five of its attempts in a single tick.
  attempted bigint[] := '{}';
begin
  for i in 1 .. greatest(coalesce(p_limit, 0), 0) loop
    update public.rollup_queue q
       set state      = 'processing',
           claimed_at = now(),
           claimed_by = p_worker,
           attempts   = q.attempts + 1
     where q.id = (
       select inner_q.id
         from public.rollup_queue inner_q
        where inner_q.state = 'pending'
          and not (inner_q.id = any (attempted))
        order by inner_q.enqueued_at, inner_q.id
          for update skip locked
        limit 1
     )
    returning q.* into scope;

    exit when not found;
    attempted := attempted || scope.id;

    begin
      perform public.rollup_recompute_training_day(scope.user_id, scope.local_date);
      update public.rollup_queue
         set state = 'done', processed_at = now(), last_error = null
       where id = scope.id;
      processed := processed + 1;
    exception when others then
      message := sqlerrm;
      -- If a newer pending row already covers this scope, returning this one
      -- to 'pending' would collide with it and would also be pointless: the
      -- newer row recomputes exactly the same scope.
      select exists (
        select 1 from public.rollup_queue q2
         where q2.user_id = scope.user_id
           and q2.domain = scope.domain
           and q2.local_date = scope.local_date
           and q2.state = 'pending'
           and q2.id <> scope.id
      ) into superseded;

      update public.rollup_queue
         set state = case
                       when superseded or scope.attempts >= 5 then 'failed'
                       else 'pending'
                     end,
             processed_at = case
                              when superseded or scope.attempts >= 5 then now()
                            end,
             claimed_at = null,
             claimed_by = null,
             last_error = left(message, 2000)
       where id = scope.id;

      failed := failed + 1;
      errors := errors || jsonb_build_object(
        'scope_id', scope.id,
        'user_id', scope.user_id,
        'local_date', scope.local_date,
        'attempts', scope.attempts,
        'error', left(message, 500)
      );
    end;
  end loop;

  return jsonb_build_object('processed', processed, 'failed', failed, 'errors', errors);
end;
$$;

comment on function public.rollup_process_pending(integer, text) is
  'Drains pending analytics scopes. Safe to run concurrently and safe to retry: each scope is claimed exclusively and recomputed atomically from canonical truth.';

/**
 * Returns scopes abandoned by a worker that died mid-flight.
 *
 * This is the whole of the failure-recovery design. Because a scope is
 * recomputed atomically and idempotently, a crashed worker leaves no partial
 * state to repair — only a claim nobody will release. Reclaiming the claim and
 * running the scope again produces the correct answer, whether the crash
 * happened before, during or after the recompute.
 */
create or replace function public.rollup_reclaim_stale(
  p_older_than interval default interval '5 minutes'
)
returns integer
language sql
as $$
  with reclaimed as (
    update public.rollup_queue q
       set state = case
                     when exists (
                       select 1 from public.rollup_queue q2
                        where q2.user_id = q.user_id
                          and q2.domain = q.domain
                          and q2.local_date = q.local_date
                          and q2.state = 'pending'
                     ) then 'failed'
                     else 'pending'
                   end,
           claimed_at = null,
           claimed_by = null,
           last_error = coalesce(q.last_error, 'reclaimed after an abandoned claim')
     where q.state = 'processing'
       and q.claimed_at < now() - p_older_than
    returning 1
  )
  select count(*)::integer from reclaimed;
$$;

comment on function public.rollup_reclaim_stale(interval) is
  'Returns scopes whose worker died mid-claim to the queue. Recomputation is atomic and idempotent, so a reclaimed scope needs no repair, only a re-run.';

-- The rollup is a privileged path, exactly as normalization is. The client
-- roles get nothing: analytics are produced by the worker and read through the
-- read model, never written from a session.
revoke all on function public.rollup_recompute_training_day(uuid, date) from public, anon, authenticated;
revoke all on function public.rollup_enqueue_training_days(uuid, date[], text) from public, anon, authenticated;
revoke all on function public.rollup_rebuild_user(uuid) from public, anon, authenticated;
revoke all on function public.rollup_process_pending(integer, text) from public, anon, authenticated;
revoke all on function public.rollup_reclaim_stale(interval) from public, anon, authenticated;

-- ============================================================================
-- 12. Read model migration.
--
-- Selective, not wholesale. Four of the seven Phase 4 functions move onto the
-- derived series; three stay on canonical data and are listed below with why.
-- The signatures and the returned columns are unchanged, so the Phase 4 read
-- model layer and every component above it are untouched.
--
-- MOVED (they aggregated the user's whole history on every request):
--   training_overview            lifetime totals
--   training_weekly_series       the two dashboard charts
--   training_exercise_summaries  the exercise explorer
--   training_exercise_detail     one exercise's totals
--
-- STAYED CANONICAL, deliberately:
--   training_workout_summaries   per-workout figures at a grain the analytics
--                                layer does not hold, and already bounded by
--                                the page limit rather than by history length.
--   training_workout_detail      one workout's exercises and sets. This is the
--                                canonical record itself; a derived copy of it
--                                would be a second source of truth.
--   training_exercise_progression one row per session with the workout's
--                                identity and title, bounded by its own limit.
--                                Session identity is canonical, not derived.
--
-- Security is unchanged: SECURITY INVOKER, no user id parameter, and the new
-- tables carry the same join-free RLS the views do, so a caller still cannot
-- ask for another user's data.
-- ============================================================================

create or replace function public.training_overview()
returns table (
  total_workouts        bigint,
  total_exercise_slots  bigint,
  distinct_exercises    bigint,
  total_sets            bigint,
  volume_sets           bigint,
  non_volume_sets       bigint,
  total_volume_kg       numeric,
  first_workout_date    date,
  last_workout_date     date,
  workouts_last_28_days bigint
)
language sql
stable
as $$
  with md as (select * from public.metric_daily),
       last_day as (
         select max(m.local_date) as d from md m where m.metric_key = 'training_workouts'
       )
  select
    coalesce(sum(m.value) filter (where m.metric_key = 'training_workouts'), 0)::bigint,
    coalesce(sum(m.value) filter (where m.metric_key = 'training_exercise_slots'), 0)::bigint,
    (select count(distinct ed.exercise_definition_id) from public.exercise_daily ed),
    coalesce(sum(m.value) filter (where m.metric_key = 'training_sets'), 0)::bigint,
    coalesce(sum(m.value) filter (where m.metric_key = 'training_volume_sets'), 0)::bigint,
    (coalesce(sum(m.value) filter (where m.metric_key = 'training_sets'), 0)
     - coalesce(sum(m.value) filter (where m.metric_key = 'training_volume_sets'), 0))::bigint,
    -- NULL, not zero, when no loaded set has ever been recorded.
    sum(m.value) filter (where m.metric_key = 'training_volume_kg'),
    min(m.local_date) filter (where m.metric_key = 'training_workouts'),
    max(m.local_date) filter (where m.metric_key = 'training_workouts'),
    coalesce(sum(m.value) filter (
      where m.metric_key = 'training_workouts'
        and m.local_date > (select d from last_day) - 28
    ), 0)::bigint
  from md m;
$$;

comment on function public.training_overview() is
  'Phase 5 read model. Headline training totals for the signed-in user, summed from metric_daily rather than from the canonical set history. Volume counts only sets carrying both a load and a rep count; the rest are reported as non_volume_sets.';

create or replace function public.training_weekly_series(p_weeks integer default 12)
returns table (
  week_start    date,
  workout_count bigint,
  set_count     bigint,
  volume_sets   bigint,
  volume_kg     numeric,
  total_reps    bigint
)
language sql
stable
as $$
  with bounds as (
    select date_trunc('week', coalesce(max(m.local_date), current_date))::date as last_week
      from public.metric_daily m
     where m.metric_key = 'training_workouts'
  ),
  span as (
    select (select b.last_week from bounds b) - ((greatest(p_weeks, 1) - 1) * 7) as first_week,
           (select b.last_week from bounds b)                                    as last_week
  ),
  weeks as (
    select generate_series((select s.first_week from span s),
                           (select s.last_week from span s),
                           interval '7 days')::date as week_start
  ),
  -- One indexed range scan over the window, pivoted in a single pass. The
  -- window bound is what makes this independent of history length: a
  -- twelve-week chart reads twelve weeks, not twelve years.
  agg as (
    select date_trunc('week', m.local_date)::date as week_start,
           sum(m.value) filter (where m.metric_key = 'training_workouts')    as workouts,
           sum(m.value) filter (where m.metric_key = 'training_sets')        as sets,
           sum(m.value) filter (where m.metric_key = 'training_volume_sets') as volume_sets,
           sum(m.value) filter (where m.metric_key = 'training_volume_kg')   as volume_kg,
           sum(m.value) filter (where m.metric_key = 'training_reps')        as reps
      from public.metric_daily m
     where m.local_date >= (select s.first_week from span s)
       and m.local_date <  (select s.last_week from span s) + 7
       and m.metric_key in ('training_workouts', 'training_sets',
                            'training_volume_sets', 'training_volume_kg',
                            'training_reps')
     group by 1
  )
  select
    w.week_start,
    -- Gap behaviour comes from metric_definitions.gap_policy, not from a
    -- decision baked into this query: frequency zero-fills because a week
    -- without training is a real zero, volume does not because a week with no
    -- loaded set is an absence of observation.
    coalesce(a.workouts,    public.metric_gap_zero('training_workouts'))::bigint,
    coalesce(a.sets,        public.metric_gap_zero('training_sets'))::bigint,
    coalesce(a.volume_sets, public.metric_gap_zero('training_volume_sets'))::bigint,
    coalesce(a.volume_kg,   public.metric_gap_zero('training_volume_kg')),
    coalesce(a.reps,        public.metric_gap_zero('training_reps'))::bigint
  from weeks w
  left join agg a on a.week_start = w.week_start
  order by w.week_start;
$$;

comment on function public.training_weekly_series(integer) is
  'Phase 5 read model. ISO weeks over local_date, read from metric_daily in one indexed range scan. Gap filling is driven by metric_definitions.gap_policy: workout_count is an honest zero for a week without training; volume_kg is NULL when nothing loaded was recorded.';

create or replace function public.training_exercise_summaries(
  p_limit  integer default 50,
  p_offset integer default 0,
  p_search text default null
)
returns table (
  exercise_definition_id uuid,
  display_name           text,
  definition_key         text,
  session_count          bigint,
  set_count              bigint,
  volume_sets            bigint,
  total_volume_kg        numeric,
  top_weight_kg          numeric,
  total_reps             bigint,
  first_performed        date,
  last_performed         date,
  progression_kind       text,
  total_count            bigint
)
language sql
stable
as $$
  with rows_ as (
    select
      ed.exercise_definition_id,
      d.display_name,
      d.key as definition_key,
      sum(ed.session_count)::bigint as session_count,
      sum(ed.set_count)::bigint     as set_count,
      sum(ed.volume_sets)::bigint   as volume_sets,
      sum(ed.volume_kg)             as total_volume_kg,
      max(ed.top_weight_kg)         as top_weight_kg,
      sum(ed.reps)::bigint          as total_reps,
      min(ed.local_date)            as first_performed,
      max(ed.local_date)            as last_performed,
      case
        when sum(ed.volume_sets)   > 0 then 'load'
        when sum(ed.distance_sets) > 0 then 'distance'
        when sum(ed.duration_sets) > 0 then 'duration'
        when sum(ed.reps_sets)     > 0 then 'reps'
        else 'none'
      end as progression_kind
    from public.exercise_daily ed
    join public.exercise_definitions d on d.id = ed.exercise_definition_id
    where p_search is null
       or btrim(p_search) = ''
       or d.display_name ilike '%' || btrim(p_search) || '%'
    group by ed.exercise_definition_id, d.display_name, d.key
  )
  select r.*, count(*) over () as total_count
    from rows_ r
   order by r.last_performed desc nulls last, r.session_count desc, r.display_name
   limit greatest(p_limit, 0) offset greatest(p_offset, 0);
$$;

comment on function public.training_exercise_summaries(integer, integer, text) is
  'Phase 5 read model. One row per exercise the user has performed, folded from exercise_daily, with progression_kind declaring what its data supports being compared on.';

create or replace function public.training_exercise_detail(
  p_exercise_definition_id uuid
)
returns table (
  exercise_definition_id uuid,
  display_name           text,
  definition_key         text,
  session_count          bigint,
  set_count              bigint,
  volume_sets            bigint,
  total_volume_kg        numeric,
  top_weight_kg          numeric,
  total_reps             bigint,
  first_performed        date,
  last_performed         date,
  progression_kind       text
)
language sql
stable
as $$
  select
    ed.exercise_definition_id,
    d.display_name,
    d.key,
    sum(ed.session_count)::bigint,
    sum(ed.set_count)::bigint,
    sum(ed.volume_sets)::bigint,
    sum(ed.volume_kg),
    max(ed.top_weight_kg),
    sum(ed.reps)::bigint,
    min(ed.local_date),
    max(ed.local_date),
    case
      when sum(ed.volume_sets)   > 0 then 'load'
      when sum(ed.distance_sets) > 0 then 'distance'
      when sum(ed.duration_sets) > 0 then 'duration'
      when sum(ed.reps_sets)     > 0 then 'reps'
      else 'none'
    end
  from public.exercise_daily ed
  join public.exercise_definitions d on d.id = ed.exercise_definition_id
 where ed.exercise_definition_id = p_exercise_definition_id
 group by ed.exercise_definition_id, d.display_name, d.key;
$$;

comment on function public.training_exercise_detail(uuid) is
  'Phase 5 read model. One exercise, folded from exercise_daily by the same rules as a training_exercise_summaries row. Returns no row for an exercise the caller has never performed.';

-- ---------------------------------------------------------------------------
-- 13. Backfill.
--
-- Every day that already carries canonical training is marked dirty. Nothing
-- is computed here: the queue is the mechanism, and using it means the backfill
-- is exercised by the same code path everything else uses rather than by a
-- one-off script that is never run again.
--
-- Until the worker drains it, the analytics tables are empty and the dashboard
-- reads zero. That window is the eventual consistency ADR-19 accepts. After
-- deploying this migration, run the worker once (or select
-- public.rollup_process_pending()) before expecting the dashboard to be right.
-- ---------------------------------------------------------------------------

insert into public.rollup_queue (user_id, domain, local_date, reason)
select distinct w.user_id, 'training', w.local_date, 'migration'
  from public.strength_workouts w
 where w.retired_at is null;
