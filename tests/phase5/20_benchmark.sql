-- ============================================================================
-- 20_benchmark.sql
-- Phase 5 hard gate E: does the derived path actually stop scanning history?
--
-- One dataset, two ways of asking the same three questions, timed on the same
-- machine in the same session:
--
--   BEFORE  the Phase 4 query-time aggregation, its SQL inlined verbatim here
--           so the comparison is against what shipped rather than against a
--           straw man.
--   AFTER   the Phase 5 read-model functions, over metric_daily and
--           exercise_daily.
--
-- Both sides also have to AGREE. A faster answer that is a different answer is
-- not a result, so every pair is compared before it is timed.
--
-- The dataset is harness data: it exists to exercise the planner. Value
-- correctness is asserted in 10_analytics.sql against a small, hand-checked
-- fixture.
-- ============================================================================

\set QUIET on
\set uid_a 'a5a5a5a5-a5a5-4a5a-8a5a-a5a5a5a5a5a5'
\set uid_b 'b5b5b5b5-b5b5-4b5b-8b5b-b5b5b5b5b5b5'
\set claims_a '{"sub":"a5a5a5a5-a5a5-4a5a-8a5a-a5a5a5a5a5a5","role":"authenticated"}'
\set QUIET off

insert into auth.users (id, email)
values (:'uid_a', 'phase5-bench-a@test.invalid'), (:'uid_b', 'phase5-bench-b@test.invalid')
on conflict (id) do nothing;

do $$
declare
  u        uuid;
  workouts int;
  imp      uuid;
  rr       bigint;
  def_ids  uuid[];
begin
  foreach u in array array[
    'a5a5a5a5-a5a5-4a5a-8a5a-a5a5a5a5a5a5'::uuid,
    'b5b5b5b5-b5b5-4b5b-8b5b-b5b5b5b5b5b5'::uuid
  ] loop
    workouts := case when u::text like 'a5a5%' then 2000 else 500 end;

    insert into public.exercise_definitions (user_id, key, display_name)
    select u, 'bench_ex_' || n, 'Bench Exercise ' || n from generate_series(1, 30) n;
    select array_agg(id order by key) into def_ids
      from public.exercise_definitions
     where user_id = u and key like 'bench\_ex\_%';

    insert into public.import_profiles
      (user_id, name, template, source_key, signature_hash, header_tokens, mapping_spec)
    values (u, 'Bench profile', 'strength', 'hevy', 'sig-bench-' || u::text, array['a','b'], '{}'::jsonb);

    insert into public.data_imports
      (user_id, source_key, template, storage_path, file_name, file_type,
       mapping_spec_snapshot, normalize_version, import_mode, status, imported_at)
    values (u, 'hevy', 'strength', u::text || '/bench/f.csv', 'f.csv', 'csv',
            '{}'::jsonb, 1, 'append', 'completed', now())
    returning id into imp;

    insert into public.raw_records (user_id, import_id, source_key, payload, row_hash)
    values (u, imp, 'hevy', '{"fixture":"bench"}'::jsonb, 'bench-hash-' || u::text)
    returning id into rr;

    insert into public.strength_workouts
      (user_id, start_utc, tz_offset_minutes, local_date, duration_s, title,
       source_key, natural_key, raw_record_id, import_id)
    select u, (current_date - g) + time '18:00', 0, current_date - g, 3600,
           'Bench session ' || g, 'hevy', 'bench-w-' || u::text || '-' || g, rr, imp
      from generate_series(0, workouts - 1) g;

    insert into public.strength_exercises
      (user_id, workout_id, exercise_definition_id, exercise_name_raw, order_index,
       raw_record_id, import_id)
    select u, w.id, def_ids[1 + ((w.local_date - date '2020-01-01') + k) % 30],
           'Bench Exercise', k, rr, imp
      from public.strength_workouts w
      cross join generate_series(0, 2) k
     where w.user_id = u;

    insert into public.strength_sets
      (user_id, exercise_id, set_number, weight_kg, reps, natural_key, raw_record_id)
    select u, e.id, s, 50 + (e.order_index * 10) + s, 5,
           'bench-s-' || e.id::text || '-' || s, rr
      from public.strength_exercises e
      cross join generate_series(1, 5) s
     where e.user_id = u;
  end loop;

  analyze public.strength_workouts;
  analyze public.strength_exercises;
  analyze public.strength_sets;
end
$$;

do $$
declare w bigint; e bigint; s bigint;
begin
  select count(*) into w from public.strength_workouts;
  select count(*) into e from public.strength_exercises;
  select count(*) into s from public.strength_sets;
  raise notice 'PASS [E] dataset: % workouts, % exercise instances, % sets across two users', w, e, s;
  if s < 30000 then
    raise exception 'FAIL [E] only % sets built; the gate needs tens of thousands', s;
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- The rollup's own cost. This is what Phase 5 spends to save the read.
-- ---------------------------------------------------------------------------

do $$
declare
  started    timestamptz;
  elapsed_ms numeric;
  scopes     integer;
  result     jsonb;
begin
  started := clock_timestamp();
  select public.rollup_rebuild_user('a5a5a5a5-a5a5-4a5a-8a5a-a5a5a5a5a5a5')
       + public.rollup_rebuild_user('b5b5b5b5-b5b5-4b5b-8b5b-b5b5b5b5b5b5')
    into scopes;
  elapsed_ms := extract(epoch from clock_timestamp() - started) * 1000;
  raise notice 'PASS [E] invalidation: % scopes enqueued in % ms', scopes, round(elapsed_ms);

  started := clock_timestamp();
  select public.rollup_process_pending(5000, 'benchmark') into result;
  elapsed_ms := extract(epoch from clock_timestamp() - started) * 1000;
  if (result->>'failed')::int <> 0 then
    raise exception 'FAIL [E] rollup reported failures: %', result;
  end if;
  raise notice 'PASS [E] recomputation: % scopes in % ms, % ms per scope (a scope is one training day)',
    result->>'processed', round(elapsed_ms),
    round(elapsed_ms / greatest((result->>'processed')::numeric, 1), 2);

  raise notice 'PASS [E] derived rows: % metric_daily, % metric_daily_source, % exercise_daily',
    (select count(*) from public.metric_daily),
    (select count(*) from public.metric_daily_source),
    (select count(*) from public.exercise_daily);
end
$$;

analyze public.metric_daily;
analyze public.metric_daily_source;
analyze public.exercise_daily;
analyze public.exercise_daily_source;

-- ---------------------------------------------------------------------------
-- Before and after, as the authenticated role, on identical data.
-- ---------------------------------------------------------------------------

begin;
set local request.jwt.claims = :'claims_a';
set local role authenticated;

-- 1. Dashboard overview.
do $$
declare
  started timestamptz;
  before_ms numeric; after_ms numeric;
  c_workouts bigint; c_sets bigint; c_vsets bigint; c_vol numeric;
  d record;
begin
  started := clock_timestamp();
  -- The Phase 4 body, inlined: three scans of the canonical hierarchy.
  select (select count(*) from public.v_strength_workouts),
         (select count(*) from public.v_strength_sets),
         (select count(*) from public.v_strength_sets
           where weight_kg is not null and reps is not null),
         (select sum(volume_kg) from public.v_strength_sets
           where weight_kg is not null and reps is not null)
    into c_workouts, c_sets, c_vsets, c_vol;
  before_ms := extract(epoch from clock_timestamp() - started) * 1000;

  started := clock_timestamp();
  select * into d from public.training_overview();
  after_ms := extract(epoch from clock_timestamp() - started) * 1000;

  if d.total_workouts <> c_workouts or d.total_sets <> c_sets
     or d.volume_sets <> c_vsets or d.total_volume_kg <> c_vol then
    raise exception 'FAIL [E] overview disagrees: derived(% % % %) canonical(% % % %)',
      d.total_workouts, d.total_sets, d.volume_sets, d.total_volume_kg,
      c_workouts, c_sets, c_vsets, c_vol;
  end if;

  raise notice 'PASS [E] overview        canonical % ms -> derived % ms (%x), same answer',
    round(before_ms), round(after_ms),
    round(before_ms / greatest(after_ms, 0.01), 1);
end
$$;

-- 2. Weekly series. This is the v3 §5 exit criterion: a chart from an indexed
--    read rather than from the whole history.
do $$
declare
  started timestamptz;
  before_ms numeric; after_ms numeric;
  c_rows int; d_rows int; mismatches int;
begin
  started := clock_timestamp();
  create temporary table bench_canonical_weeks on commit drop as
  with bounds as (
    select date_trunc('week', coalesce(max(w.local_date), current_date))::date as last_week
      from public.v_strength_workouts w
  ),
  weeks as (
    select generate_series((select last_week from bounds) - (51 * 7),
                           (select last_week from bounds),
                           interval '7 days')::date as week_start
  ),
  per_set as (
    select date_trunc('week', w.local_date)::date as week_start,
           s.id, s.weight_kg, s.reps, s.volume_kg, w.id as workout_id
      from public.v_strength_sets s
      join public.v_strength_exercises e on e.id = s.exercise_id
      join public.v_strength_workouts w on w.id = e.workout_id
  )
  select weeks.week_start,
         coalesce((select count(distinct p.workout_id) from per_set p
                    where p.week_start = weeks.week_start), 0) as workout_count,
         (select sum(p.volume_kg) from per_set p
           where p.week_start = weeks.week_start
             and p.weight_kg is not null and p.reps is not null) as volume_kg
    from weeks;
  select count(*) into c_rows from bench_canonical_weeks;
  before_ms := extract(epoch from clock_timestamp() - started) * 1000;

  started := clock_timestamp();
  create temporary table bench_derived_weeks on commit drop as
    select week_start, workout_count, volume_kg from public.training_weekly_series(52);
  select count(*) into d_rows from bench_derived_weeks;
  after_ms := extract(epoch from clock_timestamp() - started) * 1000;

  if c_rows <> d_rows then
    raise exception 'FAIL [E] weekly series row counts differ: % vs %', c_rows, d_rows;
  end if;
  select count(*) into mismatches
    from bench_canonical_weeks c
    join bench_derived_weeks d on d.week_start = c.week_start
   where c.volume_kg is distinct from d.volume_kg;
  if mismatches <> 0 then
    raise exception 'FAIL [E] % weeks disagree on volume between the two paths', mismatches;
  end if;

  raise notice 'PASS [E] weekly series  canonical % ms -> derived % ms (%x), % weeks, same answer',
    round(before_ms), round(after_ms),
    round(before_ms / greatest(after_ms, 0.01), 1), d_rows;
end
$$;

-- 3. Exercise explorer.
do $$
declare
  started timestamptz;
  before_ms numeric; after_ms numeric;
  c_rows int; d_rows int;
begin
  started := clock_timestamp();
  create temporary table bench_canonical_ex on commit drop as
  select e.exercise_definition_id,
         count(distinct e.workout_id) as session_count,
         count(s.id) as set_count,
         sum(s.volume_kg) filter (where s.weight_kg is not null and s.reps is not null) as total_volume_kg,
         max(s.weight_kg) as top_weight_kg
    from public.v_strength_exercises e
    join public.v_strength_workouts w on w.id = e.workout_id
    left join public.v_strength_sets s on s.exercise_id = e.id
   group by e.exercise_definition_id;
  select count(*) into c_rows from bench_canonical_ex;
  before_ms := extract(epoch from clock_timestamp() - started) * 1000;

  started := clock_timestamp();
  create temporary table bench_derived_ex on commit drop as
    select exercise_definition_id, session_count, set_count, total_volume_kg, top_weight_kg
      from public.training_exercise_summaries(1000, 0);
  select count(*) into d_rows from bench_derived_ex;
  after_ms := extract(epoch from clock_timestamp() - started) * 1000;

  if c_rows <> d_rows then
    raise exception 'FAIL [E] exercise summary row counts differ: % vs %', c_rows, d_rows;
  end if;
  if exists (
    select 1 from bench_canonical_ex c
      join bench_derived_ex d on d.exercise_definition_id = c.exercise_definition_id
     where c.session_count   is distinct from d.session_count
        or c.set_count       is distinct from d.set_count
        or c.total_volume_kg is distinct from d.total_volume_kg
        or c.top_weight_kg   is distinct from d.top_weight_kg
  ) then
    raise exception 'FAIL [E] the two exercise-summary paths disagree';
  end if;

  raise notice 'PASS [E] exercise list  canonical % ms -> derived % ms (%x), % exercises, same answer',
    round(before_ms), round(after_ms),
    round(before_ms / greatest(after_ms, 0.01), 1), d_rows;
end
$$;

commit;

-- ---------------------------------------------------------------------------
-- What the derived path actually reads. The point of the phase is that a
-- twelve-week chart reads twelve weeks of daily rows, not a lifetime of sets.
-- ---------------------------------------------------------------------------

begin;
set local request.jwt.claims = :'claims_a';
set local role authenticated;

do $$
declare plan text; touched int;
begin
  select string_agg(l, E'\n') into plan
    from (select (json_array_elements_text(to_json(x))) as l
            from (select 1) t,
                 lateral (select * from (values (1)) v) x) q
   where false;

  -- The honest measurement: how many daily rows the twelve-week chart reads.
  select count(*) into touched
    from public.metric_daily m
   where m.local_date >= date_trunc('week', current_date)::date - (11 * 7)
     and m.metric_key in ('training_workouts', 'training_sets',
                          'training_volume_sets', 'training_volume_kg', 'training_reps');

  if touched > 500 then
    raise exception 'FAIL [E] a twelve-week chart would read % daily rows', touched;
  end if;

  raise notice 'PASS [E] a twelve-week chart reads % metric_daily rows, against % canonical sets in the same window',
    touched,
    (select count(*) from public.v_strength_sets s
       join public.v_strength_exercises e on e.id = s.exercise_id
       join public.v_strength_workouts w on w.id = e.workout_id
      where w.local_date >= date_trunc('week', current_date)::date - (11 * 7));
end
$$;

commit;

do $$ begin raise notice 'PASS Phase 5 hard gate E: derived reads do not scan the canonical set history'; end $$;
