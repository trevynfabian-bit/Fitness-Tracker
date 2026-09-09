-- ============================================================================
-- 10_analytics.sql
-- Phase 5: the analytics foundation, against real canonical rows.
--
-- The claim Phase 5 has to earn is not "a rollup ran". It is:
--
--   canonical training data can change
--     -> the affected analytics scopes are identified
--     -> derived metrics are safely rebuilt
--     -> the values equal canonical truth
--     -> repeating any of it corrupts nothing
--     -> users remain isolated
--
-- Every assertion below computes the canonical answer and the derived answer
-- and compares them. None asserts merely that a function returned.
--
-- Canonical rows are created through the sanctioned write path: the
-- import_upsert_* functions the normalization worker uses, against a real
-- raw_record and data_import. Retirement goes through the reconciliation
-- lifecycle, so the database's own I-10/G9 guard has to permit it.
-- ============================================================================

\set QUIET on
\set uid_a 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
\set uid_b 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
\set uid_empty 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
\set claims_a '{"sub":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","role":"authenticated"}'
\set claims_b '{"sub":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","role":"authenticated"}'
\set QUIET off

-- ---------------------------------------------------------------------------
-- 0. The metric registry Phase 5 depends on (I-6).
--
-- Every metric the rollup writes must resolve to an active system definition,
-- and the weekly series reads gap_policy from that definition rather than
-- hard-coding zero filling. If this drifts the read model silently changes
-- meaning, so it is asserted before anything else runs.
-- ---------------------------------------------------------------------------

do $$
declare r record; n int := 0;
begin
  for r in
    select * from (values
      ('training_workouts',       'count', 'sum', 'zero'),
      ('training_exercise_slots', 'count', 'sum', 'zero'),
      ('training_sets',           'count', 'sum', 'zero'),
      ('training_volume_sets',    'count', 'sum', 'zero'),
      ('training_volume_kg',      'kg',    'sum', 'null'),
      ('training_reps',           'count', 'sum', 'null'),
      ('training_duration_s',     's',     'sum', 'null')
    ) as v (key, unit_key, agg, gap)
  loop
    n := n + 1;
    if not exists (
      select 1
        from public.metric_definitions d
        join public.units u on u.id = d.canonical_unit_id
       where d.user_id is null and d.key = r.key and d.is_active
         and u.key = r.unit_key
         and d.default_aggregation = r.agg
         and d.gap_policy = r.gap
    ) then
      raise exception 'FAIL [0] metric definition % missing or mismatched (expected unit %, aggregation %, gap_policy %)',
        r.key, r.unit_key, r.agg, r.gap;
    end if;
  end loop;
  raise notice 'PASS [0] all % training metric definitions present with the expected unit, aggregation and gap policy', n;
end
$$;

-- ---------------------------------------------------------------------------
-- 0b. Fixture helpers: the sanctioned canonical write path, nothing else.
-- ---------------------------------------------------------------------------

create function pg_temp.add_workout(
  p_user uuid, p_rr bigint, p_import uuid, p_key text,
  p_date date, p_title text, p_duration int
) returns uuid language plpgsql as $$
declare o public.upsert_outcome; wid uuid;
begin
  select * from public.import_upsert_strength_workout(
    p_user, p_key, p_date + time '18:00', 0, p_date, p_duration, p_title,
    'hevy', p_key, p_rr, p_import
  ) into o, wid;
  return wid;
end $$;

create function pg_temp.add_exercise(
  p_user uuid, p_workout uuid, p_def uuid, p_name text, p_order int,
  p_rr bigint, p_import uuid
) returns uuid language sql as $$
  select public.import_upsert_strength_exercise(
    p_user, p_workout, p_def, p_name, p_order, p_rr, p_import);
$$;

create function pg_temp.add_set(
  p_user uuid, p_key text, p_ex uuid, p_n int, p_w numeric, p_reps int,
  p_dur int, p_dist numeric, p_rr bigint
) returns public.upsert_outcome language sql as $$
  select public.import_upsert_strength_set(
    p_user, p_key, p_ex, p_n, 'working', p_w, p_reps, null, p_dur, p_dist, p_rr);
$$;

/**
 * A stable fingerprint of everything the analytics layer holds for one user.
 * computed_at is deliberately excluded: two runs over unchanged canonical data
 * must produce the same VALUES, and they will always produce different
 * timestamps.
 */
create function pg_temp.fingerprint(p_user uuid) returns text language sql stable as $$
  select md5(coalesce(string_agg(x, '|' order by x), 'empty'))
  from (
    select 'm:' || m.metric_key || ':' || m.local_date || ':' || m.value || ':'
           || m.count || ':' || m.winning_source || ':' || m.source_count as x
      from public.metric_daily m where m.user_id = p_user
    union all
    select 's:' || s.metric_key || ':' || s.source_key || ':' || s.local_date || ':'
           || coalesce(s.sum::text, '-') || ':' || s.count || ':'
           || array_to_string(s.contributing_workout_ids, ',')
      from public.metric_daily_source s where s.user_id = p_user
    union all
    select 'e:' || e.exercise_definition_id || ':' || e.local_date || ':'
           || e.session_count || ':' || e.set_count || ':' || e.volume_sets || ':'
           || coalesce(e.volume_kg::text, '-') || ':' || coalesce(e.reps::text, '-') || ':'
           || coalesce(e.top_weight_kg::text, '-') || ':' || e.distance_sets || ':'
           || e.duration_sets || ':' || e.winning_source
      from public.exercise_daily e where e.user_id = p_user
    union all
    select 'x:' || d.exercise_definition_id || ':' || d.source_key || ':' || d.local_date
           || ':' || d.set_count || ':' || array_to_string(d.contributing_workout_ids, ',')
      from public.exercise_daily_source d where d.user_id = p_user
  ) q;
$$;

-- ---------------------------------------------------------------------------
-- 1. Fixture.
--
-- User A trains across four weeks from Monday 2026-05-04, with the awkward
-- cases deliberately present:
--   05-08  a session of planks: training happened, no loaded set exists, so
--          there must be a training_workouts row and NO training_volume_kg row
--   05-11  two sessions on one day
--   week of 05-18  no training at all
--   05-25  a loaded carry: distance and duration, no reps
-- User B trains on its own days, so every isolation assertion has real data to
-- fail against rather than an empty set that passes trivially.
-- ---------------------------------------------------------------------------

insert into auth.users (id, email) values
  (:'uid_a',     'phase5-a@test.invalid'),
  (:'uid_b',     'phase5-b@test.invalid'),
  (:'uid_empty', 'phase5-empty@test.invalid')
on conflict (id) do nothing;

do $$
declare
  u     uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  imp   uuid;
  rr    bigint;
  w     uuid;
  ex    uuid;
  bench uuid; ohp uuid; row_ uuid; plank uuid; carry uuid;
begin
  insert into public.exercise_definitions (user_id, key, display_name)
  values (u, 'bench_press', 'Bench Press') returning id into bench;
  insert into public.exercise_definitions (user_id, key, display_name)
  values (u, 'overhead_press', 'Overhead Press') returning id into ohp;
  insert into public.exercise_definitions (user_id, key, display_name)
  values (u, 'barbell_row', 'Barbell Row') returning id into row_;
  insert into public.exercise_definitions (user_id, key, display_name)
  values (u, 'plank', 'Plank') returning id into plank;
  insert into public.exercise_definitions (user_id, key, display_name)
  values (u, 'farmer_carry', 'Farmer Carry') returning id into carry;

  insert into public.import_profiles
    (user_id, name, template, source_key, signature_hash, header_tokens, mapping_spec)
  values (u, 'Phase 5 fixture', 'strength', 'hevy', 'sig-p5-a', array['a','b'], '{}'::jsonb);

  insert into public.data_imports
    (user_id, source_key, template, storage_path, file_name, file_type,
     mapping_spec_snapshot, normalize_version, import_mode, status, imported_at)
  values (u, 'hevy', 'strength', u::text || '/p5/a.csv', 'a.csv', 'csv',
          '{}'::jsonb, 1, 'append', 'completed', now())
  returning id into imp;

  insert into public.raw_records (user_id, import_id, source_key, payload, row_hash)
  values (u, imp, 'hevy', '{"fixture":"phase5-a"}'::jsonb, 'p5-hash-a')
  returning id into rr;

  -- 2026-05-04: bench 3 x 60 x 5, overhead press 1 x 40 x 8
  w  := pg_temp.add_workout(u, rr, imp, 'p5-a-w1', date '2026-05-04', 'Push', 3600);
  ex := pg_temp.add_exercise(u, w, bench, 'Bench Press', 0, rr, imp);
  perform pg_temp.add_set(u, 'p5-a-s1', ex, 1, 60, 5, null, null, rr);
  perform pg_temp.add_set(u, 'p5-a-s2', ex, 2, 60, 5, null, null, rr);
  perform pg_temp.add_set(u, 'p5-a-s3', ex, 3, 60, 5, null, null, rr);
  ex := pg_temp.add_exercise(u, w, ohp, 'Overhead Press', 1, rr, imp);
  perform pg_temp.add_set(u, 'p5-a-s4', ex, 1, 40, 8, null, null, rr);

  -- 2026-05-06: row 2 x 50 x 10
  w  := pg_temp.add_workout(u, rr, imp, 'p5-a-w2', date '2026-05-06', 'Pull', 3000);
  ex := pg_temp.add_exercise(u, w, row_, 'Barbell Row', 0, rr, imp);
  perform pg_temp.add_set(u, 'p5-a-s5', ex, 1, 50, 10, null, null, rr);
  perform pg_temp.add_set(u, 'p5-a-s6', ex, 2, 50, 10, null, null, rr);

  -- 2026-05-08: planks only. Training happened; no volume was observed.
  w  := pg_temp.add_workout(u, rr, imp, 'p5-a-w3', date '2026-05-08', 'Core', 900);
  ex := pg_temp.add_exercise(u, w, plank, 'Plank', 0, rr, imp);
  perform pg_temp.add_set(u, 'p5-a-s7', ex, 1, null, null, 60, null, rr);
  perform pg_temp.add_set(u, 'p5-a-s8', ex, 2, null, null, 45, null, rr);

  -- 2026-05-11: two sessions on one day.
  w  := pg_temp.add_workout(u, rr, imp, 'p5-a-w4', date '2026-05-11', 'Push', 3600);
  ex := pg_temp.add_exercise(u, w, bench, 'Bench Press', 0, rr, imp);
  perform pg_temp.add_set(u, 'p5-a-s9',  ex, 1, 62.5, 5, null, null, rr);
  perform pg_temp.add_set(u, 'p5-a-s10', ex, 2, 62.5, 5, null, null, rr);
  perform pg_temp.add_set(u, 'p5-a-s11', ex, 3, 62.5, 5, null, null, rr);

  w  := pg_temp.add_workout(u, rr, imp, 'p5-a-w5', date '2026-05-11', 'Evening', 600);
  ex := pg_temp.add_exercise(u, w, bench, 'Bench Press', 0, rr, imp);
  perform pg_temp.add_set(u, 'p5-a-s12', ex, 1, 65, 3, null, null, rr);

  -- week of 2026-05-18: nothing.

  -- 2026-05-25: row plus a loaded carry recording distance and duration.
  w  := pg_temp.add_workout(u, rr, imp, 'p5-a-w6', date '2026-05-25', 'Pull', 3300);
  ex := pg_temp.add_exercise(u, w, row_, 'Barbell Row', 0, rr, imp);
  perform pg_temp.add_set(u, 'p5-a-s13', ex, 1, 55, 10, null, null, rr);
  perform pg_temp.add_set(u, 'p5-a-s14', ex, 2, 55, 10, null, null, rr);
  ex := pg_temp.add_exercise(u, w, carry, 'Farmer Carry', 1, rr, imp);
  perform pg_temp.add_set(u, 'p5-a-s15', ex, 1, 32, null, 45, 40, rr);

  raise notice 'PASS [1] fixture: user A has 6 workouts across 5 training days';
end
$$;

do $$
declare
  u   uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
  imp uuid; rr bigint; w uuid; ex uuid; def uuid;
begin
  insert into public.exercise_definitions (user_id, key, display_name)
  values (u, 'bench_press', 'Bench Press') returning id into def;

  insert into public.import_profiles
    (user_id, name, template, source_key, signature_hash, header_tokens, mapping_spec)
  values (u, 'Phase 5 fixture', 'strength', 'hevy', 'sig-p5-b', array['a','b'], '{}'::jsonb);

  insert into public.data_imports
    (user_id, source_key, template, storage_path, file_name, file_type,
     mapping_spec_snapshot, normalize_version, import_mode, status, imported_at)
  values (u, 'hevy', 'strength', u::text || '/p5/b.csv', 'b.csv', 'csv',
          '{}'::jsonb, 1, 'append', 'completed', now())
  returning id into imp;

  insert into public.raw_records (user_id, import_id, source_key, payload, row_hash)
  values (u, imp, 'hevy', '{"fixture":"phase5-b"}'::jsonb, 'p5-hash-b')
  returning id into rr;

  w  := pg_temp.add_workout(u, rr, imp, 'p5-b-w1', date '2026-05-05', 'B one', 1800);
  ex := pg_temp.add_exercise(u, w, def, 'Bench Press', 0, rr, imp);
  perform pg_temp.add_set(u, 'p5-b-s1', ex, 1, 100, 2, null, null, rr);

  w  := pg_temp.add_workout(u, rr, imp, 'p5-b-w2', date '2026-05-12', 'B two', 1800);
  ex := pg_temp.add_exercise(u, w, def, 'Bench Press', 0, rr, imp);
  perform pg_temp.add_set(u, 'p5-b-s2', ex, 1, 100, 2, null, null, rr);

  raise notice 'PASS [1] fixture: user B has 2 workouts of its own';
end
$$;

-- ---------------------------------------------------------------------------
-- 2. Invalidation: the affected scopes are identified, not the whole history.
-- ---------------------------------------------------------------------------

do $$
declare enqueued int; pending int; days int;
begin
  select count(distinct local_date) into days
    from public.v_strength_workouts
   where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

  enqueued := public.rollup_rebuild_user('cccccccc-cccc-4ccc-8ccc-cccccccccccc');
  if enqueued <> days then
    raise exception 'FAIL [2] rebuild enqueued % scopes for % training days', enqueued, days;
  end if;

  -- Enqueuing the same scopes again must be free. This is what lets the import
  -- pipeline enqueue defensively at several points without double work.
  if public.rollup_enqueue_training_days(
       'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
       array[date '2026-05-04', date '2026-05-06'], 'import') <> 0 then
    raise exception 'FAIL [2] a duplicate enqueue created a second pending scope';
  end if;

  select count(*) into pending from public.rollup_queue
   where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' and state = 'pending';
  if pending <> days then
    raise exception 'FAIL [2] % pending scopes after a duplicate enqueue, expected %', pending, days;
  end if;

  perform public.rollup_rebuild_user('dddddddd-dddd-4ddd-8ddd-dddddddddddd');

  raise notice 'PASS [2] % scopes enqueued, one per training day; duplicate enqueue is a no-op', enqueued;
end
$$;

do $$
declare result jsonb;
begin
  result := public.rollup_process_pending(500, 'phase5-suite');
  if (result->>'failed')::int <> 0 then
    raise exception 'FAIL [2] rollup reported failures: %', result;
  end if;
  if (select count(*) from public.rollup_queue where state <> 'done') <> 0 then
    raise exception 'FAIL [2] scopes remain unprocessed after a full drain';
  end if;
  raise notice 'PASS [2] % scopes processed, queue drained clean', result->>'processed';
end
$$;

-- ---------------------------------------------------------------------------
-- 3. GATE A — canonical aggregation equals derived metric values.
--
-- Both sides are computed here. The derived side is read through the same
-- tables the read model reads; the canonical side is the aggregation Phase 4
-- performed at query time.
-- ---------------------------------------------------------------------------

do $$
declare mismatch record; n int;
begin
  for mismatch in
    with canon as (
      select w.local_date,
             count(distinct w.id)                                                       as workouts,
             count(distinct e.id)                                                       as slots,
             count(s.id)                                                                as sets,
             count(s.id) filter (where s.weight_kg is not null and s.reps is not null)   as volume_sets,
             sum(s.volume_kg) filter (where s.weight_kg is not null and s.reps is not null) as volume_kg,
             sum(s.reps)                                                                as reps
        from public.v_strength_workouts w
        left join public.v_strength_exercises e on e.workout_id = w.id
        left join public.v_strength_sets s on s.exercise_id = e.id
       where w.user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
       group by w.local_date
    ),
    -- The derived side is read the way the read model reads it: an absent row
    -- is not "no answer", it is whatever the metric's gap_policy says. A day of
    -- planks records no loaded set, so training_volume_sets has no row on it,
    -- and its policy of 'zero' is what turns that back into the honest 0 the
    -- canonical count produces. training_volume_kg's policy is 'null', so its
    -- absence stays an absence.
    derived as (
      select m.local_date,
             coalesce(sum(m.value) filter (where m.metric_key = 'training_workouts'),
                      public.metric_gap_zero('training_workouts'))       as workouts,
             coalesce(sum(m.value) filter (where m.metric_key = 'training_exercise_slots'),
                      public.metric_gap_zero('training_exercise_slots')) as slots,
             coalesce(sum(m.value) filter (where m.metric_key = 'training_sets'),
                      public.metric_gap_zero('training_sets'))           as sets,
             coalesce(sum(m.value) filter (where m.metric_key = 'training_volume_sets'),
                      public.metric_gap_zero('training_volume_sets'))    as volume_sets,
             coalesce(sum(m.value) filter (where m.metric_key = 'training_volume_kg'),
                      public.metric_gap_zero('training_volume_kg'))      as volume_kg,
             coalesce(sum(m.value) filter (where m.metric_key = 'training_reps'),
                      public.metric_gap_zero('training_reps'))           as reps
        from public.metric_daily m
       where m.user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
       group by m.local_date
    )
    select coalesce(c.local_date, d.local_date) as local_date,
           c.workouts as c_workouts, d.workouts as d_workouts,
           c.slots as c_slots, d.slots as d_slots,
           c.sets as c_sets, d.sets as d_sets,
           c.volume_sets as c_vsets, d.volume_sets as d_vsets,
           c.volume_kg as c_vol, d.volume_kg as d_vol,
           c.reps as c_reps, d.reps as d_reps
      from canon c
      full join derived d on d.local_date = c.local_date
     where c.workouts    is distinct from d.workouts
        or c.slots       is distinct from d.slots
        or c.sets        is distinct from d.sets
        or c.volume_sets is distinct from d.volume_sets
        or c.volume_kg   is distinct from d.volume_kg
        or c.reps        is distinct from d.reps
  loop
    raise exception 'FAIL [A] % canonical(w % s % sets % vs % vol % reps %) vs derived(w % s % sets % vs % vol % reps %)',
      mismatch.local_date,
      mismatch.c_workouts, mismatch.c_slots, mismatch.c_sets, mismatch.c_vsets, mismatch.c_vol, mismatch.c_reps,
      mismatch.d_workouts, mismatch.d_slots, mismatch.d_sets, mismatch.d_vsets, mismatch.d_vol, mismatch.d_reps;
  end loop;

  select count(distinct local_date) into n from public.metric_daily
   where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  raise notice 'PASS [A] derived daily metrics equal canonical aggregation on all % training days', n;
end
$$;

-- The plank day is the one that decides whether the layer understands the
-- difference between "did none" and "recorded none".
do $$
begin
  if not exists (select 1 from public.metric_daily
                  where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
                    and local_date = date '2026-05-08'
                    and metric_key = 'training_workouts' and value = 1) then
    raise exception 'FAIL [A] the plank day recorded no workout';
  end if;
  if exists (select 1 from public.metric_daily
              where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
                and local_date = date '2026-05-08'
                and metric_key = 'training_volume_kg') then
    raise exception 'FAIL [A] the plank day stored a volume; a day with no loaded set has no volume observation';
  end if;
  if exists (select 1 from public.metric_daily
              where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
                and local_date = date '2026-05-18') then
    raise exception 'FAIL [A] an untrained day has stored rows; metric_daily holds only days with observations';
  end if;
  raise notice 'PASS [A] a plank day has a workout row and no volume row; an untrained day has no rows at all';
end
$$;

-- Gate A through the read model itself, which is what the product calls.
-- Run as the authenticated role so both sides are scoped by RLS rather than by
-- a hand-written user filter: that is the comparison the product actually makes.
begin;
set local request.jwt.claims = :'claims_a';
set local role authenticated;

do $$
declare o record; canon_workouts bigint; canon_sets bigint; canon_vol numeric;
begin
  select count(*) into canon_workouts from public.v_strength_workouts;
  select count(*) into canon_sets
    from public.v_strength_sets s
    join public.v_strength_exercises e on e.id = s.exercise_id;
  select sum(s.volume_kg) into canon_vol
    from public.v_strength_sets s
    join public.v_strength_exercises e on e.id = s.exercise_id
   where s.weight_kg is not null and s.reps is not null;

  select * into o from public.training_overview();

  if o.total_workouts <> canon_workouts then
    raise exception 'FAIL [A] overview reports % workouts, canonical has %', o.total_workouts, canon_workouts;
  end if;
  if o.total_sets <> canon_sets then
    raise exception 'FAIL [A] overview reports % sets, canonical has %', o.total_sets, canon_sets;
  end if;
  if o.total_volume_kg <> canon_vol then
    raise exception 'FAIL [A] overview reports volume %, canonical has %', o.total_volume_kg, canon_vol;
  end if;
  raise notice 'PASS [A] training_overview(): % workouts, % sets, % kg, all equal to canonical aggregation',
    o.total_workouts, o.total_sets, o.total_volume_kg;
end
$$;

-- Weekly frequency and weekly volume, compared week by week against canonical.
do $$
declare bad record; weeks int;
begin
  for bad in
    with derived as (select * from public.training_weekly_series(4)),
    canon as (
      select date_trunc('week', w.local_date)::date as week_start,
             count(distinct w.id) as workouts,
             count(s.id) as sets,
             sum(s.volume_kg) filter (where s.weight_kg is not null and s.reps is not null) as volume_kg
        from public.v_strength_workouts w
        left join public.v_strength_exercises e on e.workout_id = w.id
        left join public.v_strength_sets s on s.exercise_id = e.id
       group by 1
    )
    select d.week_start, d.workout_count, d.set_count, d.volume_kg,
           coalesce(c.workouts, 0) as c_workouts,
           coalesce(c.sets, 0) as c_sets,
           c.volume_kg as c_volume
      from derived d
      left join canon c on c.week_start = d.week_start
     where d.workout_count is distinct from coalesce(c.workouts, 0)
        or d.set_count     is distinct from coalesce(c.sets, 0)
        or d.volume_kg     is distinct from c.volume_kg
  loop
    raise exception 'FAIL [A] week %: derived(w % sets % vol %) canonical(w % sets % vol %)',
      bad.week_start, bad.workout_count, bad.set_count, bad.volume_kg,
      bad.c_workouts, bad.c_sets, bad.c_volume;
  end loop;

  select count(*) into weeks from public.training_weekly_series(4);
  -- The empty week must be a zero for frequency and a NULL for volume.
  if not exists (select 1 from public.training_weekly_series(4)
                  where week_start = date '2026-05-18' and workout_count = 0 and volume_kg is null) then
    raise exception 'FAIL [A] the untrained week is not frequency 0 with volume NULL';
  end if;
  raise notice 'PASS [A] weekly frequency and volume equal canonical aggregation across % weeks, gaps preserved', weeks;
end
$$;

commit;

-- The exercise grain.
do $$
declare bad record; n int;
begin
  for bad in
    with canon as (
      select e.exercise_definition_id,
             count(distinct e.workout_id) as sessions,
             count(s.id) as sets,
             sum(s.volume_kg) filter (where s.weight_kg is not null and s.reps is not null) as volume,
             max(s.weight_kg) as top,
             sum(s.reps) as reps
        from public.v_strength_exercises e
        join public.v_strength_workouts w on w.id = e.workout_id
        left join public.v_strength_sets s on s.exercise_id = e.id
       where w.user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
       group by e.exercise_definition_id
    ),
    derived as (
      select ed.exercise_definition_id,
             sum(ed.session_count) as sessions,
             sum(ed.set_count) as sets,
             sum(ed.volume_kg) as volume,
             max(ed.top_weight_kg) as top,
             sum(ed.reps) as reps
        from public.exercise_daily ed
       where ed.user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
       group by ed.exercise_definition_id
    )
    select coalesce(c.exercise_definition_id, d.exercise_definition_id) as id,
           c.sessions as c_sessions, d.sessions as d_sessions,
           c.sets as c_sets, d.sets as d_sets,
           c.volume as c_volume, d.volume as d_volume,
           c.top as c_top, d.top as d_top,
           c.reps as c_reps, d.reps as d_reps
      from canon c full join derived d on d.exercise_definition_id = c.exercise_definition_id
     where c.sessions is distinct from d.sessions
        or c.sets     is distinct from d.sets
        or c.volume   is distinct from d.volume
        or c.top      is distinct from d.top
        or c.reps     is distinct from d.reps
  loop
    raise exception 'FAIL [A] exercise %: canonical(% % % % %) derived(% % % % %)',
      bad.id, bad.c_sessions, bad.c_sets, bad.c_volume, bad.c_top, bad.c_reps,
      bad.d_sessions, bad.d_sets, bad.d_volume, bad.d_top, bad.d_reps;
  end loop;

  select count(distinct exercise_definition_id) into n from public.exercise_daily
   where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  raise notice 'PASS [A] exercise-grain metrics equal canonical aggregation for all % exercises', n;
end
$$;

-- ---------------------------------------------------------------------------
-- 4. Provenance: a derived figure names the canonical records behind it.
-- ---------------------------------------------------------------------------

do $$
declare bad record; n int;
begin
  for bad in
    select mds.metric_key, mds.local_date, mds.contributing_workout_ids
      from public.metric_daily_source mds
     where mds.user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
       and (
         cardinality(mds.contributing_workout_ids) = 0
         or exists (
           select 1 from unnest(mds.contributing_workout_ids) wid
            where not exists (
              select 1 from public.v_strength_workouts w
               where w.id = wid
                 and w.user_id = mds.user_id
                 and w.local_date = mds.local_date
            )
         )
       )
  loop
    raise exception 'FAIL [provenance] %/% names workouts that are not live on that day: %',
      bad.metric_key, bad.local_date, bad.contributing_workout_ids;
  end loop;

  -- The two-session day must name both sessions.
  if (select cardinality(contributing_workout_ids) from public.metric_daily_source
       where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
         and local_date = date '2026-05-11' and metric_key = 'training_workouts') <> 2 then
    raise exception 'FAIL [provenance] the two-session day does not name both sessions';
  end if;

  select count(*) into n from public.metric_daily_source
   where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  raise notice 'PASS [provenance] all % tier-1 rows name live canonical workouts on their own day', n;
end
$$;

-- ---------------------------------------------------------------------------
-- 5. GATE C — idempotency.
-- ---------------------------------------------------------------------------

do $$
declare before_fp text; after_fp text; rows_before bigint; rows_after bigint; i int;
begin
  before_fp := pg_temp.fingerprint('cccccccc-cccc-4ccc-8ccc-cccccccccccc');
  select count(*) into rows_before from public.metric_daily
   where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

  -- Reprocess every scope three more times, directly, with no canonical change.
  for i in 1 .. 3 loop
    perform public.rollup_recompute_training_day(
              'cccccccc-cccc-4ccc-8ccc-cccccccccccc', d)
      from (select distinct local_date as d from public.v_strength_workouts
             where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc') days;
  end loop;

  after_fp := pg_temp.fingerprint('cccccccc-cccc-4ccc-8ccc-cccccccccccc');
  select count(*) into rows_after from public.metric_daily
   where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

  if before_fp is distinct from after_fp then
    raise exception 'FAIL [C] recomputing an unchanged scope four times changed the values';
  end if;
  if rows_before <> rows_after then
    raise exception 'FAIL [C] row count went from % to % across repeated recomputation', rows_before, rows_after;
  end if;
  raise notice 'PASS [C] four recomputations of every unchanged scope: identical values, % rows throughout', rows_after;
end
$$;

-- Re-import consistency: the sanctioned upsert path, run again with the same
-- values, reports every row unchanged and leaves the metrics identical.
do $$
declare
  u  uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  rr bigint;
  ex uuid;
  o  public.upsert_outcome;
  fp text;
begin
  fp := pg_temp.fingerprint(u);
  select id into rr from public.raw_records where user_id = u limit 1;
  select s.exercise_id into ex from public.strength_sets s where s.natural_key = 'p5-a-s1';

  o := pg_temp.add_set(u, 'p5-a-s1', ex, 1, 60, 5, null, null, rr);
  if o <> 'unchanged' then
    raise exception 'FAIL [C] re-importing an identical set reported %, expected unchanged', o;
  end if;

  perform public.rollup_enqueue_training_days(u, array[date '2026-05-04'], 'import');
  perform public.rollup_process_pending(50, 'phase5-suite');

  if pg_temp.fingerprint(u) is distinct from fp then
    raise exception 'FAIL [C] re-importing unchanged data changed the derived metrics';
  end if;
  raise notice 'PASS [C] re-importing unchanged data adds nothing and leaves every metric identical';
end
$$;

-- ---------------------------------------------------------------------------
-- 6. Correction consistency: a superseding canonical value rebuilds the scope.
-- ---------------------------------------------------------------------------

do $$
declare
  u   uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  rr  bigint; ex uuid; o public.upsert_outcome;
  before_vol numeric; after_vol numeric; other_before text; other_after text;
begin
  select value into before_vol from public.metric_daily
   where user_id = u and local_date = date '2026-05-04' and metric_key = 'training_volume_kg';
  select md5(string_agg(m.metric_key || m.value::text, '|' order by m.metric_key)) into other_before
    from public.metric_daily m where m.user_id = u and m.local_date = date '2026-05-06';

  select id into rr from public.raw_records where user_id = u limit 1;
  select s.exercise_id into ex from public.strength_sets s where s.natural_key = 'p5-a-s1';

  -- 60 x 5 becomes 70 x 5: the day's volume must rise by exactly 50 kg.
  o := pg_temp.add_set(u, 'p5-a-s1', ex, 1, 70, 5, null, null, rr);
  if o <> 'updated' then
    raise exception 'FAIL [correction] the corrected set reported %, expected updated', o;
  end if;

  perform public.rollup_enqueue_training_days(u, array[date '2026-05-04'], 'import');
  perform public.rollup_process_pending(50, 'phase5-suite');

  select value into after_vol from public.metric_daily
   where user_id = u and local_date = date '2026-05-04' and metric_key = 'training_volume_kg';
  if after_vol <> before_vol + 50 then
    raise exception 'FAIL [correction] volume went % -> %, expected +50', before_vol, after_vol;
  end if;

  select md5(string_agg(m.metric_key || m.value::text, '|' order by m.metric_key)) into other_after
    from public.metric_daily m where m.user_id = u and m.local_date = date '2026-05-06';
  if other_before is distinct from other_after then
    raise exception 'FAIL [correction] an unrelated day changed when one day was corrected';
  end if;

  -- Put it back, so the rest of the suite reasons about the original fixture.
  perform pg_temp.add_set(u, 'p5-a-s1', ex, 1, 60, 5, null, null, rr);
  perform public.rollup_enqueue_training_days(u, array[date '2026-05-04'], 'import');
  perform public.rollup_process_pending(50, 'phase5-suite');

  raise notice 'PASS [correction] a corrected set rebuilds only its own scope, by exactly the right amount';
end
$$;

-- ---------------------------------------------------------------------------
-- 7. GATE B — retirement.
--
-- The retirement goes through the sanctioned lifecycle: a persisted plan,
-- confirmed and not blocked, naming the exact natural key. The database's own
-- I-10/G9 guard refuses anything else, so this is the same path the product
-- uses and not a back door dressed up as one.
-- ---------------------------------------------------------------------------

do $$
declare
  u          uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  imp        uuid;
  rr         bigint;
  retired    int;
  before_vol numeric;
  after_vol  numeric;
  other_before text;
  other_after  text;
  evening_vol numeric := 65 * 3;
begin
  select md5(string_agg(m.metric_key || ':' || m.value::text, '|' order by m.metric_key)) into other_before
    from public.metric_daily m
   where m.user_id = u and m.local_date <> date '2026-05-11';

  select value into strict before_vol from public.metric_daily
   where user_id = u and local_date = date '2026-05-11' and metric_key = 'training_volume_kg';

  -- A second import carries the plan, exactly as a snapshot re-import would.
  select id into rr from public.raw_records where user_id = u limit 1;
  insert into public.data_imports
    (user_id, source_key, template, storage_path, file_name, file_type,
     mapping_spec_snapshot, normalize_version, import_mode, status, imported_at)
  values (u, 'hevy', 'strength', u::text || '/p5/a2.csv', 'a2.csv', 'csv',
          '{}'::jsonb, 1, 'full_snapshot', 'completed', now())
  returning id into imp;

  insert into public.reconciliation_plans
    (user_id, import_id, scope, add_count, update_count, unchanged_count, retire_count,
     existing_in_scope_count, retire_ratio, retire_natural_keys, guard_results, verdict,
     decision, decided_at)
  values (u, imp, '{"template":"strength"}'::jsonb, 0, 0, 5, 1, 6, 0.1667,
          array['p5-a-w5'], '[]'::jsonb, 'safe', 'confirmed', now());

  update public.strength_workouts
     set retired_at = now(), retired_by_import_id = imp
   where user_id = u and natural_key = 'p5-a-w5' and retired_at is null;
  get diagnostics retired = row_count;
  if retired <> 1 then
    raise exception 'FAIL [B] the sanctioned retirement affected % rows', retired;
  end if;

  -- Nothing has been recomputed yet, so the stale figure is still there. That
  -- is the eventual consistency ADR-19 accepts, and asserting it here makes
  -- the next step a real test rather than a coincidence.
  select value into strict after_vol from public.metric_daily
   where user_id = u and local_date = date '2026-05-11' and metric_key = 'training_volume_kg';
  if after_vol <> before_vol then
    raise exception 'FAIL [B] the metric changed before any recomputation ran';
  end if;

  perform public.rollup_enqueue_training_days(u, array[date '2026-05-11'], 'retirement');
  perform public.rollup_process_pending(50, 'phase5-suite');

  select value into strict after_vol from public.metric_daily
   where user_id = u and local_date = date '2026-05-11' and metric_key = 'training_volume_kg';

  if after_vol <> before_vol - evening_vol then
    raise exception 'FAIL [B] volume went % -> % after retiring a % kg session',
      before_vol, after_vol, evening_vol;
  end if;

  if (select value from public.metric_daily
       where user_id = u and local_date = date '2026-05-11'
         and metric_key = 'training_workouts') <> 1 then
    raise exception 'FAIL [B] the retired session is still counted in training_workouts';
  end if;

  -- The retired workout must not appear in provenance any more.
  if exists (
    select 1 from public.metric_daily_source mds
      join public.strength_workouts w on w.natural_key = 'p5-a-w5'
     where mds.user_id = u and mds.contributing_workout_ids @> array[w.id]
  ) then
    raise exception 'FAIL [B] a retired workout is still named in derived provenance';
  end if;

  select md5(string_agg(m.metric_key || ':' || m.value::text, '|' order by m.metric_key)) into other_after
    from public.metric_daily m
   where m.user_id = u and m.local_date <> date '2026-05-11';
  if other_before is distinct from other_after then
    raise exception 'FAIL [B] retiring one workout changed metrics on unrelated days';
  end if;

  raise notice 'PASS [B] a retired session stops contributing (% -> % kg), leaves no stale provenance, and changes no other day',
    before_vol, after_vol;
end
$$;

-- Retiring every workout on a day must remove the day, not leave a zero.
do $$
declare
  u   uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  imp uuid;
begin
  insert into public.data_imports
    (user_id, source_key, template, storage_path, file_name, file_type,
     mapping_spec_snapshot, normalize_version, import_mode, status, imported_at)
  values (u, 'hevy', 'strength', u::text || '/p5/a3.csv', 'a3.csv', 'csv',
          '{}'::jsonb, 1, 'full_snapshot', 'completed', now())
  returning id into imp;

  insert into public.reconciliation_plans
    (user_id, import_id, scope, add_count, update_count, unchanged_count, retire_count,
     existing_in_scope_count, retire_ratio, retire_natural_keys, guard_results, verdict,
     decision, decided_at)
  values (u, imp, '{"template":"strength"}'::jsonb, 0, 0, 4, 1, 5, 0.2,
          array['p5-a-w3'], '[]'::jsonb, 'safe', 'confirmed', now());

  update public.strength_workouts
     set retired_at = now(), retired_by_import_id = imp
   where user_id = u and natural_key = 'p5-a-w3' and retired_at is null;

  perform public.rollup_enqueue_training_days(u, array[date '2026-05-08'], 'retirement');
  perform public.rollup_process_pending(50, 'phase5-suite');

  if exists (select 1 from public.metric_daily where user_id = u and local_date = date '2026-05-08') then
    raise exception 'FAIL [B] a fully retired day still has derived rows';
  end if;
  if exists (select 1 from public.metric_daily_source where user_id = u and local_date = date '2026-05-08')
     or exists (select 1 from public.exercise_daily where user_id = u and local_date = date '2026-05-08')
     or exists (select 1 from public.exercise_daily_source where user_id = u and local_date = date '2026-05-08') then
    raise exception 'FAIL [B] a fully retired day left rows in a tier-1 or exercise-grain table';
  end if;
  raise notice 'PASS [B] retiring every workout on a day removes the day rather than storing a zero';
end
$$;

-- After the retirements, canonical and derived must agree again, everywhere.
do $$
declare bad record;
begin
  for bad in
    with canon as (
      select w.local_date,
             count(distinct w.id) as workouts,
             count(s.id) as sets,
             sum(s.volume_kg) filter (where s.weight_kg is not null and s.reps is not null) as volume
        from public.v_strength_workouts w
        left join public.v_strength_exercises e on e.workout_id = w.id
        left join public.v_strength_sets s on s.exercise_id = e.id
       where w.user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
       group by w.local_date
    ),
    derived as (
      select m.local_date,
             coalesce(sum(m.value) filter (where m.metric_key = 'training_workouts'),
                      public.metric_gap_zero('training_workouts')) as workouts,
             coalesce(sum(m.value) filter (where m.metric_key = 'training_sets'),
                      public.metric_gap_zero('training_sets')) as sets,
             coalesce(sum(m.value) filter (where m.metric_key = 'training_volume_kg'),
                      public.metric_gap_zero('training_volume_kg')) as volume
        from public.metric_daily m
       where m.user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
       group by m.local_date
    )
    select coalesce(c.local_date, d.local_date) as local_date
      from canon c full join derived d on d.local_date = c.local_date
     where c.workouts is distinct from d.workouts
        or c.sets     is distinct from d.sets
        or c.volume   is distinct from d.volume
  loop
    raise exception 'FAIL [B] canonical and derived disagree on % after retirement', bad.local_date;
  end loop;
  raise notice 'PASS [B] canonical and derived agree on every day after retirement';
end
$$;

-- ---------------------------------------------------------------------------
-- 8. GATE F — failure and recovery.
-- ---------------------------------------------------------------------------

-- F1: a worker that dies holding a claim. The scope is stranded, reclaimed,
-- and re-run; the recompute is atomic, so there is no partial state to repair.
do $$
declare
  u   uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  fp  text;
  sid bigint;
  reclaimed int;
begin
  fp := pg_temp.fingerprint(u);

  perform public.rollup_enqueue_training_days(u, array[date '2026-05-04'], 'rebuild');
  select id into sid from public.rollup_queue
   where user_id = u and local_date = date '2026-05-04' and state = 'pending';

  -- Simulate the crash: the scope is claimed and the worker never returns.
  update public.rollup_queue
     set state = 'processing', claimed_at = now() - interval '30 minutes',
         claimed_by = 'crashed-worker', attempts = attempts + 1
   where id = sid;

  if (select public.rollup_process_pending(50, 'phase5-suite')->>'processed')::int <> 0 then
    raise exception 'FAIL [F] a claimed scope was picked up by a second worker';
  end if;

  reclaimed := public.rollup_reclaim_stale(interval '5 minutes');
  if reclaimed < 1 then
    raise exception 'FAIL [F] the abandoned claim was not reclaimed';
  end if;
  if (select state from public.rollup_queue where id = sid) <> 'pending' then
    raise exception 'FAIL [F] the reclaimed scope is not pending again';
  end if;

  perform public.rollup_process_pending(50, 'phase5-suite');
  if (select state from public.rollup_queue where id = sid) <> 'done' then
    raise exception 'FAIL [F] the retried scope did not complete';
  end if;
  if pg_temp.fingerprint(u) is distinct from fp then
    raise exception 'FAIL [F] retrying a crashed scope changed the metrics';
  end if;

  raise notice 'PASS [F] a crashed claim is reclaimed and re-run, and the final values are unchanged';
end
$$;

-- F2: a recompute that raises part-way. The scope must return to the queue
-- with its error recorded, and must leave no half-written state behind.
do $$
declare
  u        uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  fp       text;
  sid      bigint;
  result   jsonb;
  row_state text;
  err      text;
begin
  fp := pg_temp.fingerprint(u);

  -- Break the registry so the rollup's I-6 check fires mid-recompute, after
  -- tier 1 has been written and before tier 2 exists.
  update public.metric_definitions set is_active = false
   where user_id is null and key = 'training_volume_kg';

  perform public.rollup_enqueue_training_days(u, array[date '2026-05-04'], 'rebuild');
  select id into sid from public.rollup_queue
   where user_id = u and local_date = date '2026-05-04' and state = 'pending';

  result := public.rollup_process_pending(50, 'phase5-suite');
  if (result->>'failed')::int <> 1 then
    raise exception 'FAIL [F] a failing recompute was not reported as failed: %', result;
  end if;

  select state, last_error into row_state, err from public.rollup_queue where id = sid;
  if row_state <> 'pending' then
    raise exception 'FAIL [F] a retryable failure left the scope in state %', row_state;
  end if;
  if err is null or err not like '%I-6%' then
    raise exception 'FAIL [F] the failure recorded no usable error: %', err;
  end if;

  -- Atomicity: the failed transaction wrote nothing. The metrics are exactly
  -- what they were before the attempt.
  if pg_temp.fingerprint(u) is distinct from fp then
    raise exception 'FAIL [F] a failed recompute left partial state behind';
  end if;

  update public.metric_definitions set is_active = true
   where user_id is null and key = 'training_volume_kg';

  perform public.rollup_process_pending(50, 'phase5-suite');
  if (select state from public.rollup_queue where id = sid) <> 'done' then
    raise exception 'FAIL [F] the scope did not succeed once the cause was fixed';
  end if;
  if pg_temp.fingerprint(u) is distinct from fp then
    raise exception 'FAIL [F] recovery produced different values from canonical truth';
  end if;

  raise notice 'PASS [F] a failing recompute is atomic, records its error, returns to the queue, and recovers to the correct values';
end
$$;

-- F3: a scope that keeps failing is parked rather than spun on forever.
do $$
declare
  u   uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  sid bigint;
  i   int;
begin
  update public.metric_definitions set is_active = false
   where user_id is null and key = 'training_volume_kg';

  perform public.rollup_enqueue_training_days(u, array[date '2026-05-04'], 'rebuild');
  select id into sid from public.rollup_queue
   where user_id = u and local_date = date '2026-05-04' and state = 'pending';

  for i in 1 .. 6 loop
    perform public.rollup_process_pending(10, 'phase5-suite');
  end loop;

  if (select state from public.rollup_queue where id = sid) <> 'failed' then
    raise exception 'FAIL [F] a scope failing repeatedly was not parked (state %, attempts %)',
      (select state from public.rollup_queue where id = sid),
      (select attempts from public.rollup_queue where id = sid);
  end if;

  update public.metric_definitions set is_active = true
   where user_id is null and key = 'training_volume_kg';
  perform public.rollup_rebuild_user(u);
  perform public.rollup_process_pending(100, 'phase5-suite');

  raise notice 'PASS [F] a scope that fails five times is parked in ''failed'' with its error, not retried forever';
end
$$;

-- ---------------------------------------------------------------------------
-- 9. Concurrency: a canonical change during processing is not lost.
-- ---------------------------------------------------------------------------

do $$
declare
  u   uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  sid bigint;
  n   int;
begin
  perform public.rollup_enqueue_training_days(u, array[date '2026-05-06'], 'import');
  select id into sid from public.rollup_queue
   where user_id = u and local_date = date '2026-05-06' and state = 'pending';

  -- The worker claims it and is still working.
  update public.rollup_queue set state = 'processing', claimed_at = now(), claimed_by = 'w1'
   where id = sid;

  -- Canonical data changes now. The in-flight recompute may or may not see it,
  -- so a NEW pending scope must be created rather than the enqueue being
  -- swallowed as a duplicate.
  if public.rollup_enqueue_training_days(u, array[date '2026-05-06'], 'import') <> 1 then
    raise exception 'FAIL [concurrency] a change during processing did not create a new pending scope';
  end if;

  select count(*) into n from public.rollup_queue
   where user_id = u and local_date = date '2026-05-06' and state = 'pending';
  if n <> 1 then
    raise exception 'FAIL [concurrency] % pending scopes for one day, expected exactly 1', n;
  end if;

  update public.rollup_queue set state = 'done', processed_at = now() where id = sid;
  perform public.rollup_process_pending(50, 'phase5-suite');

  raise notice 'PASS [concurrency] a change while a scope is in flight queues a fresh scope; only one is ever pending';
end
$$;

-- ---------------------------------------------------------------------------
-- 10. GATE D — user isolation and security.
-- ---------------------------------------------------------------------------

-- Structural: I-8 on every new table, join-free policies, and no write
-- privilege for the client on any derived table.
do $$
declare t text; n int := 0; bad text[] := '{}'; p text;
begin
  foreach t in array array['source_precedence', 'metric_daily_source', 'metric_daily',
                           'exercise_daily_source', 'exercise_daily', 'rollup_queue']
  loop
    n := n + 1;
    if not (select c.relrowsecurity from pg_class c
             join pg_namespace ns on ns.oid = c.relnamespace
            where ns.nspname = 'public' and c.relname = t) then
      raise exception 'FAIL [D] RLS is not enabled on public.%', t;
    end if;
    if not exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name = t and column_name = 'user_id') then
      raise exception 'FAIL [D] public.% has no user_id column (I-8)', t;
    end if;
    if (select count(*) from pg_policies where schemaname = 'public' and tablename = t) < 1 then
      raise exception 'FAIL [D] public.% has no RLS policy (I-8)', t;
    end if;
    if exists (select 1 from pg_policies
                where schemaname = 'public' and tablename = t
                  and (coalesce(qual, '') || ' ' || coalesce(with_check, '')) ~* '\yfrom\y') then
      raise exception 'FAIL [D] a policy on public.% references another relation (I-8 forbids a join)', t;
    end if;
    -- anon holds nothing anywhere.
    foreach p in array array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] loop
      if has_table_privilege('anon', 'public.' || t, p) then
        bad := bad || (t || ':anon:' || p);
      end if;
    end loop;
  end loop;

  -- Derived data is written by the rollup and by nothing else.
  foreach t in array array['metric_daily_source', 'metric_daily',
                           'exercise_daily_source', 'exercise_daily', 'rollup_queue']
  loop
    foreach p in array array['INSERT','UPDATE','DELETE','TRUNCATE'] loop
      if has_table_privilege('authenticated', 'public.' || t, p) then
        bad := bad || (t || ':authenticated:' || p);
      end if;
    end loop;
    if not has_table_privilege('authenticated', 'public.' || t, 'SELECT') then
      raise exception 'FAIL [D] authenticated cannot read its own public.%', t;
    end if;
  end loop;

  if array_length(bad, 1) is not null then
    raise exception 'FAIL [D] unexpected privileges: %', array_to_string(bad, ', ');
  end if;
  raise notice 'PASS [D] all % analytics tables: RLS on, user_id present, join-free policy, anon holds nothing, client cannot write derived data', n;
end
$$;

-- The rollup functions are a privileged path. No client role may call them.
-- EXECUTE defaults to PUBLIC, so this is asserted rather than assumed.
do $$
declare fn text; leaked text[] := '{}';
begin
  foreach fn in array array[
    'rollup_recompute_training_day(uuid,date)',
    'rollup_enqueue_training_days(uuid,date[],text)',
    'rollup_rebuild_user(uuid)',
    'rollup_process_pending(integer,text)',
    'rollup_reclaim_stale(interval)'
  ] loop
    if has_function_privilege('anon', 'public.' || fn, 'execute') then
      leaked := leaked || ('anon:' || fn);
    end if;
    if has_function_privilege('authenticated', 'public.' || fn, 'execute') then
      leaked := leaked || ('authenticated:' || fn);
    end if;
  end loop;

  -- The one analytics function the client legitimately calls.
  if not has_function_privilege('authenticated', 'public.metric_gap_zero(text)', 'execute') then
    raise exception 'FAIL [D] authenticated cannot execute metric_gap_zero, which the read model needs';
  end if;
  if has_function_privilege('anon', 'public.metric_gap_zero(text)', 'execute') then
    leaked := leaked || 'anon:metric_gap_zero(text)';
  end if;

  if array_length(leaked, 1) is not null then
    raise exception 'FAIL [D] rollup functions are callable by a client role: %', array_to_string(leaked, ', ');
  end if;
  raise notice 'PASS [D] every rollup function is revoked from anon and authenticated; only metric_gap_zero is callable';
end
$$;

-- No rollup function is SECURITY DEFINER, and none takes a caller-supplied
-- user id it would trust. The two that take one are privileged and unreachable
-- from a session, which is asserted immediately above.
do $$
declare r record; n int := 0;
begin
  for r in select p.proname, p.prosecdef
             from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
            where ns.nspname = 'public' and p.proname like 'rollup\_%'
  loop
    n := n + 1;
    if r.prosecdef then
      raise exception 'FAIL [D] public.% is SECURITY DEFINER; it would run with the owner''s rights', r.proname;
    end if;
  end loop;
  raise notice 'PASS [D] all % rollup functions are SECURITY INVOKER', n;
end
$$;

-- Behavioural: two authenticated users, real data on both sides.
begin;
set local request.jwt.claims = :'claims_a';
set local role authenticated;

do $$
declare mine bigint; theirs bigint;
begin
  select count(*) into mine from public.metric_daily;
  select count(*) into theirs from public.metric_daily where user_id <> auth.uid();
  if theirs <> 0 then
    raise exception 'FAIL [D] user A reads % of user B''s metric_daily rows', theirs;
  end if;
  if mine = 0 then
    raise exception 'FAIL [D] user A reads none of its own metric_daily rows';
  end if;

  if (select count(*) from public.metric_daily_source where user_id <> auth.uid()) <> 0
     or (select count(*) from public.exercise_daily where user_id <> auth.uid()) <> 0
     or (select count(*) from public.exercise_daily_source where user_id <> auth.uid()) <> 0
     or (select count(*) from public.rollup_queue where user_id <> auth.uid()) <> 0 then
    raise exception 'FAIL [D] an analytics table leaked another user''s rows to user A';
  end if;

  raise notice 'PASS [D] user A reads its own % metric_daily rows and none of user B''s, across all four analytics tables', mine;
end
$$;

commit;

begin;
set local request.jwt.claims = :'claims_b';
set local role authenticated;

do $$
declare o record; canon_workouts bigint; canon_vol numeric;
begin
  select count(*) into canon_workouts from public.v_strength_workouts;
  select sum(s.volume_kg) into canon_vol
    from public.v_strength_sets s
    join public.v_strength_exercises e on e.id = s.exercise_id
   where s.weight_kg is not null and s.reps is not null;

  select * into o from public.training_overview();
  if o.total_workouts <> canon_workouts or canon_workouts <> 2 then
    raise exception 'FAIL [D] user B''s overview reports % workouts, its canonical model has %',
      o.total_workouts, canon_workouts;
  end if;
  if o.total_volume_kg <> canon_vol then
    raise exception 'FAIL [D] user B''s derived volume % does not equal its canonical volume %',
      o.total_volume_kg, canon_vol;
  end if;

  -- The read model takes no user id, so there is no way to ask for user A's
  -- figures. Asking through the tables directly returns nothing.
  if (select count(*) from public.metric_daily
       where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc') <> 0 then
    raise exception 'FAIL [D] user B read user A''s metric_daily rows by naming the id';
  end if;

  raise notice 'PASS [D] user B''s derived metrics equal ITS OWN canonical truth (% workouts, % kg) and contain nothing of user A''s',
    o.total_workouts, o.total_volume_kg;
end
$$;

commit;

-- An account with no training reads zeros and NULLs, never another user's data
-- and never a fabricated figure.
begin;
set local request.jwt.claims = '{"sub":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","role":"authenticated"}';
set local role authenticated;

do $$
declare o record; w record; n int;
begin
  select * into o from public.training_overview();
  if o.total_workouts <> 0 or o.total_sets <> 0 then
    raise exception 'FAIL [D] an empty account reports % workouts and % sets', o.total_workouts, o.total_sets;
  end if;
  if o.total_volume_kg is not null then
    raise exception 'FAIL [D] an empty account reports a volume of %', o.total_volume_kg;
  end if;
  if (select count(*) from public.metric_daily) <> 0 then
    raise exception 'FAIL [D] an empty account can see derived rows';
  end if;

  select count(*) into n from public.training_weekly_series(12);
  if n <> 12 then
    raise exception 'FAIL [D] the weekly series returned % rows for an empty account', n;
  end if;
  for w in select * from public.training_weekly_series(12) loop
    if w.workout_count <> 0 then
      raise exception 'FAIL [D] an empty account reports % workouts in a week', w.workout_count;
    end if;
    if w.volume_kg is not null then
      raise exception 'FAIL [D] an empty account reports volume % in a week', w.volume_kg;
    end if;
  end loop;

  raise notice 'PASS [D] an empty account: zero counts, NULL volume, 12 zero-filled weeks, no rows from anybody else';
end
$$;

commit;

-- ---------------------------------------------------------------------------
-- 11. Derived data is disposable (v2 section 1.4).
--
-- The strongest statement Phase 5 can make about correctness: throw all of it
-- away, rebuild from canonical truth, and get the same answer back.
-- ---------------------------------------------------------------------------

do $$
declare u uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'; before_fp text; after_fp text;
begin
  before_fp := pg_temp.fingerprint(u);

  truncate public.metric_daily, public.metric_daily_source,
           public.exercise_daily, public.exercise_daily_source;

  if pg_temp.fingerprint(u) <> md5('empty') then
    raise exception 'FAIL [rebuild] the analytics tables are not empty after truncate';
  end if;

  perform public.rollup_rebuild_user(u);
  perform public.rollup_rebuild_user('dddddddd-dddd-4ddd-8ddd-dddddddddddd');
  perform public.rollup_process_pending(500, 'phase5-suite');

  after_fp := pg_temp.fingerprint(u);
  if after_fp is distinct from before_fp then
    raise exception 'FAIL [rebuild] a full rebuild from canonical truth produced different values';
  end if;
  raise notice 'PASS [rebuild] truncating every analytics table and rebuilding reproduces identical values';
end
$$;

do $$ begin raise notice 'PASS Phase 5 analytics foundation: all assertions'; end $$;
