-- ============================================================================
-- 20260909090000_phase7_metrics_rollup.sql
-- Phase 7, part 1: the metrics rollup domain, and the chart read model.
--
-- WHAT THIS FIXES
--
-- Phase 6 lands body measurements in canonical `metrics`. Phase 5 built the
-- rollup infrastructure for exactly one domain — training — so those rows have
-- had nowhere to go. Four separate things stopped them:
--
--   1. rollup_queue's domain check is a closed set containing only 'training',
--      so a metrics scope could not be enqueued at all.
--   2. rollup_process_pending calls rollup_recompute_training_day
--      unconditionally. It reads scope.domain and never branches on it.
--   3. Nothing computes tier 1 from `metrics`. v2 §9.2 specifies that
--      statement; it had never been implemented.
--   4. No producer marks a metric day dirty. (That part is application code
--      and lives in src/lib/analytics/rollup.ts and src/lib/import/worker.ts.)
--
-- THE CROSS-DOMAIN DELETE, AND WHY IT HAD TO CHANGE
--
-- rollup_recompute_training_day opened with
--
--     delete from metric_daily_source where user_id = $1 and local_date = $2;
--     delete from metric_daily        where user_id = $1 and local_date = $2;
--
-- with no metric_key filter. That was correct while training was the only
-- domain writing those tables. The moment a second domain writes a row for the
-- same day, each domain's recompute silently deletes the other's — and a later
-- rebuild of the surviving domain "repairs" it until the other one runs again.
-- That is precisely the class of invisible loss I-4 exists to prevent.
--
-- v2 §9.2's own tier-1 statement is scoped per metric
-- (WHERE user_id = $1 AND metric_key = $2 AND local_date = $3). Phase 5 widened
-- it to a whole-day delete because one domain made that safe. A second domain
-- removes that safety, so the delete is narrowed back to what the architecture
-- specified. The Phase 5 migration is not edited; the function is replaced
-- here, forward-only.
--
-- WHY THE SCOPE STAYS (user_id, domain, local_date)
--
-- Unchanged from ADR-19 and the Phase 5 design. One scan of v_metrics for a
-- user-day produces every metric's tier-1 rows, exactly as one scan of the
-- v_strength_* views produces every training metric's. A metric-grain scope
-- would make the worker rescan the same day once per metric and would change
-- the queue's shape for no correctness gain. rollup_queue is untouched apart
-- from widening its domain check to the second closed value.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Which rollup domain a metric belongs to.
--
-- The delete scoping needs to know which metric keys are training aggregates
-- and which are observations. It must not know that as a list of keys written
-- into SQL: a hard-coded key list is the free-text identifier I-6 forbids, and
-- it would be wrong the moment a metric is added to the registry.
--
-- So the registry answers it, like manual_entry does. Default 'metrics',
-- because an observation is what a metric normally is; seed 0003 marks the
-- seven training aggregates. NOT NULL plus a two-value check makes the domains
-- exhaustive and disjoint, which is what lets the two recompute functions
-- partition metric_daily between them with no key left unowned.
-- ---------------------------------------------------------------------------

alter table public.metric_definitions
  add column rollup_domain text not null default 'metrics';

alter table public.metric_definitions
  add constraint metric_definitions_rollup_domain_allowed
    check (rollup_domain in ('training', 'metrics'));

comment on column public.metric_definitions.rollup_domain is
  'Which rollup domain owns this metric in metric_daily. ''training'' for aggregates computed from the strength model, ''metrics'' for observations rolled up from canonical metrics. Exhaustive and disjoint: it is what scopes each domain''s recompute so neither deletes the other''s rows.';

/**
 * The system metric keys belonging to one rollup domain.
 *
 * One definition, used by both recompute functions for both their deletes and
 * their inserts, so a scope is rebuilt over exactly the keys it deleted. That
 * equality is what makes each recompute idempotent in the presence of the
 * other.
 */
create or replace function public.rollup_domain_metric_keys(p_domain text)
returns setof text
language sql
stable
as $$
  select d.key
    from public.metric_definitions d
   where d.user_id is null
     and d.rollup_domain = p_domain;
$$;

comment on function public.rollup_domain_metric_keys(text) is
  'The system metric keys in one rollup domain. Registry-driven so no key list is ever written into engine code (I-6).';

revoke all on function public.rollup_domain_metric_keys(text) from public, anon;
grant execute on function public.rollup_domain_metric_keys(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 1. Provenance for the metrics grain.
--
-- metric_daily_source carries contributing_workout_ids so a tier-1 row can
-- answer "which canonical records produced this figure" from the row itself.
-- A metrics-domain row has no workouts; its contributing records are metrics,
-- whose ids are bigint. Without this column the metrics grain would be the one
-- part of the analytics layer with no provenance at all, which would be a
-- regression in the guarantee the table was designed around.
-- ---------------------------------------------------------------------------

alter table public.metric_daily_source
  add column contributing_metric_ids bigint[] not null default '{}';

comment on column public.metric_daily_source.contributing_metric_ids is
  'The canonical metrics rows this tier-1 figure was computed from. The metrics-grain counterpart of contributing_workout_ids; empty for training-domain rows.';

-- ---------------------------------------------------------------------------
-- 2. The scope scan index.
--
-- metrics_query leads with (user_id, metric_key, local_date), so a per-day
-- scope scan that does not name a metric can only use its first column. The
-- rollup reads a whole user-day, which is this shape. Partial on the same two
-- predicates the recompute applies, so it is the covering choice for it.
-- ---------------------------------------------------------------------------

create index metrics_rollup_scope_idx
  on public.metrics (user_id, local_date)
  where retired_at is null and is_derived = false;

-- ---------------------------------------------------------------------------
-- 3. rollup_queue: the second domain.
--
-- Still a closed set. A domain is a name the worker must be able to dispatch
-- on, so an unconstrained domain column would be a queue row nothing can
-- process, discovered only when the worker reached it.
-- ---------------------------------------------------------------------------

alter table public.rollup_queue
  drop constraint rollup_queue_domain_allowed;

alter table public.rollup_queue
  add constraint rollup_queue_domain_allowed
    check (domain in ('training', 'metrics'));

comment on constraint rollup_queue_domain_allowed on public.rollup_queue is
  'Closed set. Every value here must have a branch in rollup_process_pending; an unrecognised domain must be impossible to enqueue, not merely impossible to process.';

-- ---------------------------------------------------------------------------
-- 4. rollup_recompute_training_day — narrowed.
--
-- Identical to the Phase 5 body except for the two metric_daily deletes, which
-- now name the training domain's keys. The exercise-grain deletes are keyed by
-- exercise_definition_id and cannot collide with anything, so they are
-- unchanged.
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
  -- Scoped to this domain's keys. A body measurement's row for the same day
  -- belongs to the metrics domain and must survive this.
  delete from public.metric_daily_source
   where user_id = p_user_id and local_date = p_local_date
     and metric_key in (select public.rollup_domain_metric_keys('training'));
  delete from public.metric_daily
   where user_id = p_user_id and local_date = p_local_date
     and metric_key in (select public.rollup_domain_metric_keys('training'));
  delete from public.exercise_daily_source
   where user_id = p_user_id and local_date = p_local_date;
  delete from public.exercise_daily
   where user_id = p_user_id and local_date = p_local_date;

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

  select string_agg(distinct mds.metric_key, ', ') into unresolved
    from public.metric_daily_source mds
   where mds.user_id = p_user_id and mds.local_date = p_local_date
     and mds.metric_key in (select public.rollup_domain_metric_keys('training'))
     and not exists (
       select 1 from public.metric_definitions d
        where d.key = mds.metric_key and d.user_id is null and d.is_active
     );
  if unresolved is not null then
    raise exception
      'rollup: metric key(s) % resolve to no active system metric definition (I-6)', unresolved;
  end if;

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
       and mds.metric_key in (select public.rollup_domain_metric_keys('training'))
  ),
  winner as (
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
  where case d.default_aggregation
          when 'sum'   then w.sum
          when 'mean'  then w.avg
          when 'min'   then w.min
          when 'max'   then w.max
          when 'first' then w.first_value
          when 'last'  then w.last_value
          when 'count' then w.count::numeric
        end is not null;

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
  'Rebuilds one (user, day) training analytics scope from canonical truth. Atomic, idempotent, never an arithmetic delta. Reads the v_* views, so retired data cannot contribute. Its metric_daily deletes are scoped to the training domain''s registry keys so a metrics-domain row for the same day survives.';

-- ---------------------------------------------------------------------------
-- 5. rollup_recompute_metrics_day — the missing half of v2 §9.
--
-- Same contract as its training sibling: delete the scope, rebuild it from
-- canonical truth, atomically, in one function, never by arithmetic delta.
-- Running it twice over unchanged data produces byte-identical rows; running it
-- over a day whose observations were all retired leaves no rows.
--
-- It reads public.v_metrics (I-5), so retirement is honoured by construction.
-- It filters is_derived = false exactly as v2 §9.2 does: a derived row is a
-- formula's output, and rolling it up alongside its own inputs would double
-- count. (Nothing writes derived rows today — that is v3 Phase 7 — but the
-- filter is what the specification says, and it costs nothing to be right in
-- advance of the row existing.)
--
-- value_num is not null is not an extra rule: a metric whose value is text or
-- boolean has no numeric daily aggregate, and metric_daily.value is NUMERIC.
-- ---------------------------------------------------------------------------

create or replace function public.rollup_recompute_metrics_day(
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
   where user_id = p_user_id and local_date = p_local_date
     and metric_key in (select public.rollup_domain_metric_keys('metrics'));
  delete from public.metric_daily
   where user_id = p_user_id and local_date = p_local_date
     and metric_key in (select public.rollup_domain_metric_keys('metrics'));

  -- Tier 1 (v2 §9.2). What ONE source said about ONE metric on ONE day.
  insert into public.metric_daily_source
    (user_id, metric_key, source_key, local_date,
     avg, min, max, sum, first_value, last_value, count,
     contributing_workout_ids, contributing_metric_ids, computed_at)
  select
    p_user_id,
    m.metric_key,
    m.source_key,
    p_local_date,
    avg(m.value_num),
    min(m.value_num),
    max(m.value_num),
    sum(m.value_num),
    -- id is the tiebreak, so two observations bearing the same instant order
    -- the same way on every run. Without it "first" would be whichever row the
    -- executor happened to reach first, and the rollup would not be
    -- reproducible.
    (array_agg(m.value_num order by m.timestamp_utc, m.id))[1],
    (array_agg(m.value_num order by m.timestamp_utc desc, m.id desc))[1],
    count(*),
    '{}'::uuid[],
    array_agg(m.id order by m.id),
    now()
  from public.v_metrics m
  where m.user_id = p_user_id
    and m.local_date = p_local_date
    and m.is_derived = false
    and m.value_num is not null
    and m.metric_key in (select public.rollup_domain_metric_keys('metrics'))
  group by m.metric_key, m.source_key;

  -- I-6 at the analytics boundary, as in the training sibling. metrics.metric_key
  -- is already backed by metric_definition_id, so this is unreachable in
  -- practice; it stays because "unreachable" is a property of today's write
  -- paths, and a series nothing can name or unit-convert must fail loudly
  -- rather than appear.
  select string_agg(distinct mds.metric_key, ', ') into unresolved
    from public.metric_daily_source mds
   where mds.user_id = p_user_id and mds.local_date = p_local_date
     and mds.metric_key in (select public.rollup_domain_metric_keys('metrics'))
     and not exists (
       select 1 from public.metric_definitions d
        where d.key = mds.metric_key and d.user_id is null and d.is_active
     );
  if unresolved is not null then
    raise exception
      'rollup: metric key(s) % resolve to no active system metric definition (I-6)', unresolved;
  end if;

  -- Tier 2 (v2 §9.3). Resolve the winning source by source_precedence, then
  -- project the column the metric's own default_aggregation names. Identical
  -- resolution to the training grain, because it is the same rule: a metric is
  -- a metric regardless of which scan produced its tier-1 row.
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
       and mds.metric_key in (select public.rollup_domain_metric_keys('metrics'))
  ),
  winner as (
    -- Deterministic: priority, then source_key alphabetically.
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
  where case d.default_aggregation
          when 'sum'   then w.sum
          when 'mean'  then w.avg
          when 'min'   then w.min
          when 'max'   then w.max
          when 'first' then w.first_value
          when 'last'  then w.last_value
          when 'count' then w.count::numeric
        end is not null;
end;
$$;

comment on function public.rollup_recompute_metrics_day(uuid, date) is
  'v2 §9.2/§9.3 for the metrics grain. Rebuilds one (user, day) scope from v_metrics, excluding retired and derived rows. Atomic, idempotent, and scoped to the metrics domain''s registry keys so a training-domain row for the same day survives.';

-- ---------------------------------------------------------------------------
-- 6. The queue API, generalised over the domain.
--
-- rollup_enqueue_training_days keeps its signature and becomes a call to the
-- general form, so every existing caller is untouched and there is one
-- definition of what enqueuing means.
-- ---------------------------------------------------------------------------

create or replace function public.rollup_enqueue_days(
  p_user_id uuid,
  p_dates   date[],
  p_domain  text,
  p_reason  text default 'import'
)
returns integer
language sql
as $$
  with inserted as (
    insert into public.rollup_queue (user_id, domain, local_date, reason)
    select distinct p_user_id, p_domain, d, p_reason
      from unnest(coalesce(p_dates, '{}'::date[])) d
     where d is not null
       and not exists (
         select 1 from public.rollup_queue q
          where q.user_id = p_user_id
            and q.domain = p_domain
            and q.local_date = d
            and q.state = 'pending'
       )
    on conflict do nothing
    returning 1
  )
  select count(*)::integer from inserted;
$$;

comment on function public.rollup_enqueue_days(uuid, date[], text, text) is
  'Marks analytics scopes dirty in one domain. Idempotent: a scope already pending is not enqueued twice. An unrecognised domain is rejected by rollup_queue''s own check constraint.';

create or replace function public.rollup_enqueue_training_days(
  p_user_id uuid,
  p_dates   date[],
  p_reason  text default 'import'
)
returns integer
language sql
as $$
  select public.rollup_enqueue_days(p_user_id, p_dates, 'training', p_reason);
$$;

create or replace function public.rollup_enqueue_metric_days(
  p_user_id uuid,
  p_dates   date[],
  p_reason  text default 'import'
)
returns integer
language sql
as $$
  select public.rollup_enqueue_days(p_user_id, p_dates, 'metrics', p_reason);
$$;

comment on function public.rollup_enqueue_metric_days(uuid, date[], text) is
  'Marks metrics analytics scopes dirty. The counterpart of rollup_enqueue_training_days, called when canonical metrics rows are written or retired.';

/**
 * Enqueues every day on which the user has non-retired canonical data, in both
 * domains.
 *
 * The full rebuild path. Derived data is disposable: truncating the analytics
 * tables and calling this reproduces them from canonical truth.
 */
create or replace function public.rollup_rebuild_user(p_user_id uuid)
returns integer
language sql
as $$
  select
    public.rollup_enqueue_training_days(
      p_user_id,
      (select array_agg(distinct w.local_date)
         from public.v_strength_workouts w
        where w.user_id = p_user_id),
      'rebuild'
    )
    +
    public.rollup_enqueue_metric_days(
      p_user_id,
      (select array_agg(distinct m.local_date)
         from public.v_metrics m
        where m.user_id = p_user_id
          and m.is_derived = false
          and m.value_num is not null),
      'rebuild'
    );
$$;

comment on function public.rollup_rebuild_user(uuid) is
  'Full rebuild path across both rollup domains. Derived data is disposable: truncating the analytics tables and calling this reproduces them from canonical truth.';

-- ---------------------------------------------------------------------------
-- 7. The worker dispatches on the domain, and refuses one it does not know.
--
-- The check constraint already makes an unknown domain unenqueueable, so this
-- branch is defence in depth. It is an explicit ELSE that raises rather than a
-- fall-through, because a queue row that is claimed, marked done and never
-- computed is a stale metric nobody can find — the exact failure the parked
-- 'failed' state exists to avoid. The raise is caught by the per-scope handler
-- below and surfaces as a failed scope carrying its reason, in the queue row
-- and in this function's returned errors array.
--
-- WHY THE LOOP GAINED A USER FILTER
--
-- The cron worker drains everything, and that is right: the queue is global
-- and nobody is waiting on it. But manual entry drains inline so a person sees
-- the measurement they just typed on the chart, and that call happens inside
-- their request. Draining the whole queue there would make one typed number
-- wait on every other user's backlog — and on the same user's, from an import
-- they ran an hour ago. So the claim loop takes an optional user, and the two
-- callers get the behaviour each needs from one implementation.
--
-- p_user_id NULL means "any scope", which is what the cron worker passes.
-- ---------------------------------------------------------------------------

create or replace function public.rollup_process_scopes(
  p_limit   integer,
  p_worker  text,
  p_user_id uuid
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
          and (p_user_id is null or inner_q.user_id = p_user_id)
          and not (inner_q.id = any (attempted))
        order by inner_q.enqueued_at, inner_q.id
          for update skip locked
        limit 1
     )
    returning q.* into scope;

    exit when not found;
    attempted := attempted || scope.id;

    begin
      case scope.domain
        when 'training' then
          perform public.rollup_recompute_training_day(scope.user_id, scope.local_date);
        when 'metrics' then
          perform public.rollup_recompute_metrics_day(scope.user_id, scope.local_date);
        else
          raise exception
            'rollup: queue scope % names domain %, which has no recompute function',
            scope.id, scope.domain;
      end case;

      update public.rollup_queue
         set state = 'done', processed_at = now(), last_error = null
       where id = scope.id;
      processed := processed + 1;
    exception when others then
      message := sqlerrm;
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
        'domain', scope.domain,
        'local_date', scope.local_date,
        'attempts', scope.attempts,
        'error', left(message, 500)
      );
    end;
  end loop;

  return jsonb_build_object('processed', processed, 'failed', failed, 'errors', errors);
end;
$$;

comment on function public.rollup_process_scopes(integer, text, uuid) is
  'The claim-and-recompute loop. Drains pending analytics scopes in every domain, optionally restricted to one user. Safe to run concurrently and safe to retry: each scope is claimed exclusively and recomputed atomically. A scope naming an unknown domain fails loudly and is never marked done.';

/** Drains any pending scope. What the cron worker calls. */
create or replace function public.rollup_process_pending(
  p_limit  integer default 100,
  p_worker text default 'worker'
)
returns jsonb
language sql
as $$
  select public.rollup_process_scopes(p_limit, p_worker, null);
$$;

comment on function public.rollup_process_pending(integer, text) is
  'Drains pending analytics scopes in every domain, for every user. The cron worker''s entry point.';

/**
 * Drains one user's pending scopes.
 *
 * What manual entry calls, inline, so the measurement a person just typed is
 * on the chart when the page comes back. Scoped to that person because the
 * work happens inside their request: a typed number must not wait on anybody
 * else's backlog, and the rest of the queue is the cron worker's job.
 */
create or replace function public.rollup_process_user_pending(
  p_user_id uuid,
  p_limit   integer default 50,
  p_worker  text default 'inline'
)
returns jsonb
language sql
as $$
  select public.rollup_process_scopes(p_limit, p_worker, p_user_id);
$$;

comment on function public.rollup_process_user_pending(uuid, integer, text) is
  'Drains one user''s pending analytics scopes. Bounded and user-scoped because it runs inside that user''s own request.';

revoke all on function public.rollup_recompute_metrics_day(uuid, date) from public, anon, authenticated;
revoke all on function public.rollup_enqueue_days(uuid, date[], text, text) from public, anon, authenticated;
revoke all on function public.rollup_enqueue_metric_days(uuid, date[], text) from public, anon, authenticated;
revoke all on function public.rollup_recompute_training_day(uuid, date) from public, anon, authenticated;
revoke all on function public.rollup_enqueue_training_days(uuid, date[], text) from public, anon, authenticated;
revoke all on function public.rollup_rebuild_user(uuid) from public, anon, authenticated;
revoke all on function public.rollup_process_scopes(integer, text, uuid) from public, anon, authenticated;
revoke all on function public.rollup_process_pending(integer, text) from public, anon, authenticated;
revoke all on function public.rollup_process_user_pending(uuid, integer, text) from public, anon, authenticated;

-- ============================================================================
-- 8. The chart read model.
--
-- Charts read metric_daily and nothing else. They never touch canonical
-- metrics: that is what the analytics layer is for, and a chart that fell back
-- to canonical data would be a second definition of what a day's value is.
--
-- SECURITY INVOKER with no user id parameter, exactly as the Phase 4/5 read
-- model is. metric_daily carries a join-free RLS policy, so a caller cannot
-- ask for another user's series no matter what it passes.
--
-- Gap policy is applied HERE and only here, per v2 §9.4: "apply it in the
-- analytics layer, never in storage". metric_daily still stores only days that
-- have observations.
-- ============================================================================

/**
 * One row per requested metric per day in [p_from, p_to].
 *
 * `observed` says the day has a real measurement. `filled` says the value was
 * produced by the metric's gap policy rather than measured. A caller that
 * ignores both still cannot be misled into drawing a zero that was never
 * recorded, because a metric whose gap_policy is 'null' returns NULL and a
 * NULL is drawn as a gap.
 *
 * carry_forward looks back BEFORE the window for its seed. A 7-day chart of a
 * weekly weigh-in would otherwise be empty until the day of the weigh-in,
 * which is a worse lie than the carry: the person's weight did not cease to
 * exist between measurements, which is exactly why v2 §9.4 gives weight that
 * policy.
 */
create or replace function public.body_metric_series(
  p_metric_keys text[],
  p_from        date,
  p_to          date
)
returns table (
  metric_key text,
  local_date date,
  value      numeric,
  observed   boolean,
  filled     boolean
)
language sql
stable
as $$
  with requested as (
    select d.key, d.gap_policy
      from public.metric_definitions d
     where d.user_id is null
       and d.key = any (coalesce(p_metric_keys, '{}'::text[]))
  ),
  days as (
    select generate_series(p_from, p_to, interval '1 day')::date as d
    where p_from <= p_to
  ),
  observations as (
    select m.metric_key, m.local_date, m.value
      from public.metric_daily m
     where m.metric_key = any (coalesce(p_metric_keys, '{}'::text[]))
       and m.local_date between p_from and p_to
  ),
  -- One lookup per carry-forward metric, not one per day: the last observation
  -- strictly before the window, which seeds the days that precede the window's
  -- own first observation.
  seeds as (
    select r.key,
           (select m.value
              from public.metric_daily m
             where m.metric_key = r.key
               and m.local_date < p_from
             order by m.local_date desc
             limit 1) as value
      from requested r
     where r.gap_policy = 'carry_forward'
  ),
  grid as (
    select r.key, r.gap_policy, days.d, o.value
      from requested r
      cross join days
      left join observations o
        on o.metric_key = r.key and o.local_date = days.d
  ),
  -- The standard gaps-and-islands carry: count() over an ordered window
  -- increments only on a non-null, so every run of nulls shares the group of
  -- the observation that opened it, and first_value returns that observation.
  grouped as (
    select g.*, count(g.value) over (partition by g.key order by g.d) as island
      from grid g
  ),
  carried as (
    select gr.*,
           first_value(gr.value) over (
             partition by gr.key, gr.island order by gr.d
           ) as carried_value
      from grouped gr
  )
  select
    c.key,
    c.d,
    case
      when c.value is not null then c.value
      when c.gap_policy = 'zero' then 0::numeric
      when c.gap_policy = 'carry_forward' then coalesce(c.carried_value, s.value)
      else null::numeric
    end,
    c.value is not null,
    c.value is null
      and (c.gap_policy = 'zero'
           or (c.gap_policy = 'carry_forward'
               and coalesce(c.carried_value, s.value) is not null))
  from carried c
  left join seeds s on s.key = c.key
  order by c.key, c.d;
$$;

comment on function public.body_metric_series(text[], date, date) is
  'v2 §9.4. One row per requested metric per day in the range, read from metric_daily, with gap filling driven by metric_definitions.gap_policy and never by the query. observed distinguishes a measurement from a filled value.';

/**
 * The headline figures for a range, and whether they may be shown.
 *
 * `sufficient` is the minimum-observation gate. Below it, change_absolute and
 * change_percent are NULL rather than computed: a "change" derived from one or
 * two measurements is a number the data does not support, and returning it
 * and trusting every caller to hide it is how a misleading figure eventually
 * reaches a screen.
 *
 * p_min_observations is a parameter rather than a constant because the
 * threshold is an implementation decision, not an architectural one — no
 * authoritative document states a value. The application passes
 * MIN_CHART_OBSERVATIONS from src/lib/read-model/charts.ts so there is exactly
 * one definition of it.
 *
 * change_percent divides by the first value, so it is NULL when that value is
 * zero. A percentage change from zero is undefined, not infinite, and nullif
 * says so rather than raising or inventing a number.
 */
create or replace function public.body_metric_summary(
  p_metric_keys      text[],
  p_from             date,
  p_to               date,
  p_min_observations integer default 3
)
returns table (
  metric_key        text,
  observation_count bigint,
  first_date        date,
  first_value       numeric,
  last_date         date,
  last_value        numeric,
  min_value         numeric,
  max_value         numeric,
  mean_value        numeric,
  sufficient        boolean,
  change_absolute   numeric,
  change_percent    numeric
)
language sql
stable
as $$
  with gate as (
    select greatest(coalesce(p_min_observations, 1), 1) as n
  ),
  requested as (
    select d.key
      from public.metric_definitions d
     where d.user_id is null
       and d.key = any (coalesce(p_metric_keys, '{}'::text[]))
  ),
  observations as (
    select m.metric_key, m.local_date, m.value
      from public.metric_daily m
     where m.metric_key = any (coalesce(p_metric_keys, '{}'::text[]))
       and m.local_date between p_from and p_to
  ),
  agg as (
    select o.metric_key,
           count(*)                                            as n,
           min(o.local_date)                                   as first_date,
           max(o.local_date)                                   as last_date,
           min(o.value)                                        as min_value,
           max(o.value)                                        as max_value,
           avg(o.value)                                        as mean_value,
           (array_agg(o.value order by o.local_date))[1]       as first_value,
           (array_agg(o.value order by o.local_date desc))[1]  as last_value
      from observations o
     group by o.metric_key
  )
  select
    r.key,
    coalesce(a.n, 0),
    a.first_date,
    a.first_value,
    a.last_date,
    a.last_value,
    a.min_value,
    a.max_value,
    a.mean_value,
    coalesce(a.n, 0) >= (select n from gate),
    case when coalesce(a.n, 0) >= (select n from gate)
         then a.last_value - a.first_value end,
    case when coalesce(a.n, 0) >= (select n from gate)
         then round((a.last_value - a.first_value) / nullif(a.first_value, 0) * 100, 6) end
  from requested r
  left join agg a on a.metric_key = r.key
  order by r.key;
$$;

comment on function public.body_metric_summary(text[], date, date, integer) is
  'Range figures per metric from metric_daily, with a minimum-observation gate: below p_min_observations the change columns are NULL rather than computed. change_percent is NULL when the baseline is zero.';

/**
 * The first and last day each requested metric has any observation on.
 *
 * What an "all time" range resolves to, and how a page distinguishes a metric
 * with no history from one whose history is simply outside the current window.
 */
create or replace function public.body_metric_bounds(p_metric_keys text[])
returns table (
  metric_key        text,
  first_date        date,
  last_date         date,
  observation_count bigint
)
language sql
stable
as $$
  select r.key, min(m.local_date), max(m.local_date), count(m.local_date)
    from (
      select d.key
        from public.metric_definitions d
       where d.user_id is null
         and d.key = any (coalesce(p_metric_keys, '{}'::text[]))
    ) r
    left join public.metric_daily m on m.metric_key = r.key
   group by r.key
   order by r.key;
$$;

comment on function public.body_metric_bounds(text[]) is
  'The observed date span of each requested metric, which is what an all-time range resolves to.';

revoke all on function public.body_metric_series(text[], date, date) from public, anon;
revoke all on function public.body_metric_summary(text[], date, date, integer) from public, anon;
revoke all on function public.body_metric_bounds(text[]) from public, anon;
grant execute on function public.body_metric_series(text[], date, date) to authenticated;
grant execute on function public.body_metric_summary(text[], date, date, integer) to authenticated;
grant execute on function public.body_metric_bounds(text[]) to authenticated;
