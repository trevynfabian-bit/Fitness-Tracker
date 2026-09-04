-- ============================================================================
-- 10_read_model.sql
-- Phase 4 exit criteria: the training read model, against real canonical rows.
--
-- Every assertion below runs as the `authenticated` Postgres role with a JWT
-- subject claim, which is the context a Supabase client request executes in.
-- The read model functions are SECURITY INVOKER over the security_invoker v_*
-- views, so this is the same code path the product uses, under the same RLS.
-- The service role is never used to validate an isolation claim.
--
-- The fixture is a canonical training history built through the same table
-- shapes the import pipeline writes: every row carries a raw_record_id and an
-- import_id, because I-1 admits no other origin. Nothing here is mock UI data.
-- ============================================================================

\set QUIET on
\set uid_a '77777777-7777-4777-8777-777777777777'
\set uid_b '88888888-8888-4888-8888-888888888888'
\set claims_a '{"sub":"77777777-7777-4777-8777-777777777777","role":"authenticated"}'
\set claims_b '{"sub":"88888888-8888-4888-8888-888888888888","role":"authenticated"}'
\set QUIET off

-- ---------------------------------------------------------------------------
-- 0. Fixture
--
-- User A: 12 workouts on a fixed calendar starting Monday 2026-06-01, with a
--   deliberate empty week (week 3), one retired workout inside that empty week
--   so the week's zero has to survive a retired row, and four exercises chosen
--   to produce one of every progression_kind:
--     Bench Press    load     (in all 12 workouts, 3 loaded sets each)
--     Plank          duration (even workouts, 2 duration-only sets)
--     Farmer Carry   distance (odd workouts, 2 distance-only sets)
--     Overhead Press load     (first 2 workouts only: below the chartable floor)
--     Mobility Flow  none     (workout 0 only, a set with no measurement)
-- User B: 2 workouts of its own, so every isolation assertion has something
--   real to fail on rather than an empty set that would pass trivially.
-- ---------------------------------------------------------------------------

insert into auth.users (id, email)
values (:'uid_a', 'phase4-a@test.invalid'), (:'uid_b', 'phase4-b@test.invalid')
on conflict (id) do nothing;

do $$
declare
  base            date := date '2026-06-01';   -- a Monday
  day_offsets     int[] := array[0,2,4,7,9,21,23,28,30,35,37,39];
  u               uuid := '77777777-7777-4777-8777-777777777777';
  imp             uuid;
  rr              bigint;
  w               uuid;
  ex              uuid;
  def_bench       uuid;
  def_plank       uuid;
  def_carry       uuid;
  def_ohp         uuid;
  def_mobility    uuid;
  i               int;
  s               int;
  d               date;
begin
  insert into public.exercise_definitions (user_id, key, display_name)
  values (u, 'bench_press', 'Bench Press')       returning id into def_bench;
  insert into public.exercise_definitions (user_id, key, display_name)
  values (u, 'plank', 'Plank')                   returning id into def_plank;
  insert into public.exercise_definitions (user_id, key, display_name)
  values (u, 'farmer_carry', 'Farmer Carry')     returning id into def_carry;
  insert into public.exercise_definitions (user_id, key, display_name)
  values (u, 'overhead_press', 'Overhead Press') returning id into def_ohp;
  insert into public.exercise_definitions (user_id, key, display_name)
  values (u, 'mobility_flow', 'Mobility Flow')   returning id into def_mobility;

  insert into public.import_profiles
    (user_id, name, template, source_key, signature_hash, header_tokens, mapping_spec)
  values (u, 'Phase 4 fixture profile', 'strength', 'fixture_source',
          'sig-phase4-a', array['a','b'], '{}'::jsonb);

  insert into public.data_imports
    (user_id, source_key, template, storage_path, file_name, file_type,
     mapping_spec_snapshot, normalize_version, import_mode, status, imported_at)
  values (u, 'fixture_source', 'strength', u::text || '/p4/a.csv', 'a.csv', 'csv',
          '{}'::jsonb, 1, 'append', 'completed', now())
  returning id into imp;

  insert into public.raw_records (user_id, import_id, source_key, payload, row_hash)
  values (u, imp, 'fixture_source', '{"fixture":"phase4-a"}'::jsonb, 'p4-hash-a')
  returning id into rr;

  for i in 1 .. array_length(day_offsets, 1) loop
    d := base + day_offsets[i];

    insert into public.strength_workouts
      (user_id, start_utc, tz_offset_minutes, local_date, duration_s, title,
       source_key, natural_key, raw_record_id, import_id)
    values (u, d + time '18:00', 0, d, 3000 + i * 60, 'Session ' || i,
            'fixture_source', 'p4-a-w-' || i, rr, imp)
    returning id into w;

    -- Bench Press: three loaded sets, load rising one kilo per session.
    insert into public.strength_exercises
      (user_id, workout_id, exercise_definition_id, exercise_name_raw, order_index,
       raw_record_id, import_id)
    values (u, w, def_bench, 'Bench Press (Barbell)', 0, rr, imp)
    returning id into ex;
    for s in 1 .. 3 loop
      insert into public.strength_sets
        (user_id, exercise_id, set_number, weight_kg, reps, rpe, natural_key, raw_record_id)
      values (u, ex, s, 60 + i, 5, 8.0, 'p4-a-s-bench-' || i || '-' || s, rr);
    end loop;

    if i % 2 = 1 then
      -- Plank: duration only. No load, no reps: contributes no volume at all.
      insert into public.strength_exercises
        (user_id, workout_id, exercise_definition_id, exercise_name_raw, order_index,
         raw_record_id, import_id)
      values (u, w, def_plank, 'Plank', 1, rr, imp)
      returning id into ex;
      for s in 1 .. 2 loop
        insert into public.strength_sets
          (user_id, exercise_id, set_number, duration_s, natural_key, raw_record_id)
        values (u, ex, s, 45 + i, 'p4-a-s-plank-' || i || '-' || s, rr);
      end loop;
    else
      -- Farmer Carry: distance only.
      insert into public.strength_exercises
        (user_id, workout_id, exercise_definition_id, exercise_name_raw, order_index,
         raw_record_id, import_id)
      values (u, w, def_carry, 'Farmer Carry', 1, rr, imp)
      returning id into ex;
      for s in 1 .. 2 loop
        insert into public.strength_sets
          (user_id, exercise_id, set_number, distance_m, natural_key, raw_record_id)
        values (u, ex, s, 40 + i, 'p4-a-s-carry-' || i || '-' || s, rr);
      end loop;
    end if;

    -- Overhead Press only in the first two sessions: two data points, which is
    -- below the progression floor the read model refuses to draw through.
    if i <= 2 then
      insert into public.strength_exercises
        (user_id, workout_id, exercise_definition_id, exercise_name_raw, order_index,
         raw_record_id, import_id)
      values (u, w, def_ohp, 'Overhead Press', 2, rr, imp)
      returning id into ex;
      insert into public.strength_sets
        (user_id, exercise_id, set_number, weight_kg, reps, natural_key, raw_record_id)
      values (u, ex, 1, 40, 8, 'p4-a-s-ohp-' || i, rr);
    end if;

    -- Mobility Flow once, with a set carrying no measurement of any kind.
    if i = 1 then
      insert into public.strength_exercises
        (user_id, workout_id, exercise_definition_id, exercise_name_raw, order_index,
         raw_record_id, import_id)
      values (u, w, def_mobility, 'Mobility Flow', 3, rr, imp)
      returning id into ex;
      insert into public.strength_sets
        (user_id, exercise_id, set_number, natural_key, raw_record_id)
      values (u, ex, 1, 'p4-a-s-mobility-1', rr);
    end if;
  end loop;

  -- A retired workout inside the otherwise empty week 3. Nothing it contains
  -- may appear in any read-model answer (I-5).
  insert into public.strength_workouts
    (user_id, start_utc, tz_offset_minutes, local_date, duration_s, title,
     source_key, natural_key, raw_record_id, import_id, retired_at, retired_by_import_id)
  values (u, (base + 16) + time '18:00', 0, base + 16, 3600, 'Retired session',
          'fixture_source', 'p4-a-w-retired', rr, imp, now(), imp)
  returning id into w;
  insert into public.strength_exercises
    (user_id, workout_id, exercise_definition_id, exercise_name_raw, order_index,
     raw_record_id, import_id)
  values (u, w, def_bench, 'Bench Press (Barbell)', 0, rr, imp)
  returning id into ex;
  insert into public.strength_sets
    (user_id, exercise_id, set_number, weight_kg, reps, natural_key, raw_record_id)
  values (u, ex, 1, 999, 99, 'p4-a-s-retired-1', rr);

  raise notice 'PASS [fixture] user A: 12 active workouts, 1 retired workout, 5 exercise definitions';
end
$$;

do $$
declare
  u    uuid := '88888888-8888-4888-8888-888888888888';
  imp  uuid;
  rr   bigint;
  w    uuid;
  ex   uuid;
  def  uuid;
  i    int;
begin
  insert into public.exercise_definitions (user_id, key, display_name)
  values (u, 'bench_press', 'Bench Press') returning id into def;

  insert into public.import_profiles
    (user_id, name, template, source_key, signature_hash, header_tokens, mapping_spec)
  values (u, 'Phase 4 fixture profile', 'strength', 'fixture_source',
          'sig-phase4-b', array['a','b'], '{}'::jsonb);

  insert into public.data_imports
    (user_id, source_key, template, storage_path, file_name, file_type,
     mapping_spec_snapshot, normalize_version, import_mode, status, imported_at)
  values (u, 'fixture_source', 'strength', u::text || '/p4/b.csv', 'b.csv', 'csv',
          '{}'::jsonb, 1, 'append', 'completed', now())
  returning id into imp;

  insert into public.raw_records (user_id, import_id, source_key, payload, row_hash)
  values (u, imp, 'fixture_source', '{"fixture":"phase4-b"}'::jsonb, 'p4-hash-b')
  returning id into rr;

  for i in 1 .. 2 loop
    insert into public.strength_workouts
      (user_id, start_utc, tz_offset_minutes, local_date, duration_s, title,
       source_key, natural_key, raw_record_id, import_id)
    values (u, (date '2026-06-01' + i) + time '07:00', 0, date '2026-06-01' + i, 1800,
            'B session ' || i, 'fixture_source', 'p4-b-w-' || i, rr, imp)
    returning id into w;

    insert into public.strength_exercises
      (user_id, workout_id, exercise_definition_id, exercise_name_raw, order_index,
       raw_record_id, import_id)
    values (u, w, def, 'Bench Press', 0, rr, imp)
    returning id into ex;

    insert into public.strength_sets
      (user_id, exercise_id, set_number, weight_kg, reps, natural_key, raw_record_id)
    values (u, ex, 1, 200, 2, 'p4-b-s-' || i, rr);
  end loop;

  raise notice 'PASS [fixture] user B: 2 workouts of its own';
end
$$;

-- ---------------------------------------------------------------------------
-- 1. Privilege: anon may not execute any read-model function.
-- ---------------------------------------------------------------------------

do $$
declare fn text; leaked text[] := '{}';
begin
  foreach fn in array array[
    'training_overview()',
    'training_workout_summaries(integer,integer,date,date,text)',
    'training_workout_detail(uuid)',
    'training_weekly_series(integer)',
    'training_exercise_summaries(integer,integer,text)',
    'training_exercise_detail(uuid)',
    'training_exercise_progression(uuid,integer)'
  ] loop
    if has_function_privilege('anon', 'public.' || fn, 'execute') then
      leaked := leaked || fn;
    end if;
    if not has_function_privilege('authenticated', 'public.' || fn, 'execute') then
      raise exception 'FAIL [1] authenticated cannot execute public.%', fn;
    end if;
  end loop;

  if array_length(leaked, 1) is not null then
    raise exception 'FAIL [1] anon can execute: %', array_to_string(leaked, ', ');
  end if;
  raise notice 'PASS [1] all 7 read-model functions: authenticated may execute, anon may not';
end
$$;

-- Structural: none of them is SECURITY DEFINER, and none takes a user id.
do $$
declare r record;
begin
  for r in select p.proname, p.prosecdef, pg_get_function_arguments(p.oid) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'training\_%'
  loop
    if r.prosecdef then
      raise exception 'FAIL [1] public.% is SECURITY DEFINER; it would bypass RLS', r.proname;
    end if;
    if r.args ~* '(^|[^a-z_])p_user_id' then
      raise exception 'FAIL [1] public.% accepts a user id parameter: %', r.proname, r.args;
    end if;
  end loop;
  raise notice 'PASS [1] every training_* function is SECURITY INVOKER and takes no user id';
end
$$;

-- ---------------------------------------------------------------------------
-- 2. Overview, as user A
-- ---------------------------------------------------------------------------

begin;
set local request.jwt.claims = :'claims_a';
set local role authenticated;

do $$
declare o record;
begin
  select * into o from public.training_overview();

  -- 12 active workouts. The retired one is excluded, which is the whole point
  -- of reading v_strength_workouts rather than the table (I-5).
  if o.total_workouts <> 12 then
    raise exception 'FAIL [2] total_workouts = %, expected 12', o.total_workouts;
  end if;

  -- 12 bench + 12 (plank|carry) + 2 ohp + 1 mobility = 27 exercise instances.
  if o.total_exercise_slots <> 27 then
    raise exception 'FAIL [2] total_exercise_slots = %, expected 27', o.total_exercise_slots;
  end if;
  if o.distinct_exercises <> 5 then
    raise exception 'FAIL [2] distinct_exercises = %, expected 5', o.distinct_exercises;
  end if;

  -- 36 bench sets + 24 plank/carry sets + 2 ohp sets + 1 mobility set = 63.
  if o.total_sets <> 63 then
    raise exception 'FAIL [2] total_sets = %, expected 63', o.total_sets;
  end if;

  -- Loaded sets: 36 bench + 2 ohp = 38. The other 25 carry no load or no reps.
  if o.volume_sets <> 38 then
    raise exception 'FAIL [2] volume_sets = %, expected 38', o.volume_sets;
  end if;
  if o.non_volume_sets <> 25 then
    raise exception 'FAIL [2] non_volume_sets = %, expected 25', o.non_volume_sets;
  end if;
  if o.volume_sets + o.non_volume_sets <> o.total_sets then
    raise exception 'FAIL [2] volume_sets + non_volume_sets <> total_sets';
  end if;

  -- sum over i of 3 * (60+i) * 5 for i in 1..12, plus 2 * (40 * 8).
  -- = 15 * (12*60 + 78) + 640 = 15 * 798 + 640 = 11970 + 640 = 12610.
  if o.total_volume_kg <> 12610 then
    raise exception 'FAIL [2] total_volume_kg = %, expected 12610', o.total_volume_kg;
  end if;

  if o.first_workout_date <> date '2026-06-01' then
    raise exception 'FAIL [2] first_workout_date = %', o.first_workout_date;
  end if;
  if o.last_workout_date <> date '2026-07-10' then
    raise exception 'FAIL [2] last_workout_date = %', o.last_workout_date;
  end if;

  raise notice 'PASS [2] overview: 12 workouts, 63 sets, 38 loaded, 12610 kg, retired row excluded';
end
$$;

-- ---------------------------------------------------------------------------
-- 3. Weekly series: frequency zeros and volume nulls are not the same thing
-- ---------------------------------------------------------------------------

do $$
declare
  weeks       int;
  empty_week  record;
  first_week  record;
  total_wk    bigint;
begin
  select count(*) into weeks from public.training_weekly_series(12);
  if weeks <> 12 then
    raise exception 'FAIL [3] training_weekly_series(12) returned % rows', weeks;
  end if;

  -- Every week in the window is present, including the ones with no training:
  -- the series is zero-filled, so a chart cannot silently compress a gap.
  select sum(workout_count) into total_wk from public.training_weekly_series(12);
  if total_wk <> 12 then
    raise exception 'FAIL [3] weekly workout_count sums to %, expected 12', total_wk;
  end if;

  -- Week 3 of the fixture (starting 2026-06-15) contains only the retired
  -- workout, so it must read as an honest zero and a NULL volume.
  select * into empty_week from public.training_weekly_series(12)
   where week_start = date '2026-06-15';
  if empty_week is null then
    raise exception 'FAIL [3] the week of 2026-06-15 is missing from the series';
  end if;
  if empty_week.workout_count <> 0 then
    raise exception 'FAIL [3] empty week workout_count = %, expected 0', empty_week.workout_count;
  end if;
  if empty_week.set_count <> 0 then
    raise exception 'FAIL [3] empty week set_count = %, expected 0', empty_week.set_count;
  end if;
  if empty_week.volume_kg is not null then
    raise exception 'FAIL [3] empty week volume_kg = %, expected NULL not 0', empty_week.volume_kg;
  end if;

  -- First week: three sessions (i = 1,2,3), so bench volume is
  -- 3*5*(61+62+63) = 15 * 186 = 2790, plus two OHP sets at 40x8 = 640.
  select * into first_week from public.training_weekly_series(12)
   where week_start = date '2026-06-01';
  if first_week.workout_count <> 3 then
    raise exception 'FAIL [3] week 1 workout_count = %, expected 3', first_week.workout_count;
  end if;
  if first_week.volume_kg <> 3430 then
    raise exception 'FAIL [3] week 1 volume_kg = %, expected 3430', first_week.volume_kg;
  end if;

  raise notice 'PASS [3] weekly series: 12 zero-filled weeks, empty week is workout_count 0 with volume NULL';
end
$$;

-- ---------------------------------------------------------------------------
-- 4. Workout summaries: ordering, pagination, total_count, filters
-- ---------------------------------------------------------------------------

do $$
declare
  page1   record;
  rows1   int;
  dates   date[];
  seen    uuid[];
  r       record;
begin
  select count(*) into rows1 from public.training_workout_summaries(5, 0);
  if rows1 <> 5 then
    raise exception 'FAIL [4] page size 5 returned % rows', rows1;
  end if;

  -- total_count rides on every row and reports the unpaged total.
  for r in select * from public.training_workout_summaries(5, 0) loop
    if r.total_count <> 12 then
      raise exception 'FAIL [4] total_count = % on a page row, expected 12', r.total_count;
    end if;
  end loop;

  -- Newest first.
  select array_agg(local_date order by ord) into dates
    from (select local_date, row_number() over () as ord
            from public.training_workout_summaries(12, 0)) q;
  for rows1 in 2 .. array_length(dates, 1) loop
    if dates[rows1] > dates[rows1 - 1] then
      raise exception 'FAIL [4] history is not newest-first at position %', rows1;
    end if;
  end loop;
  if dates[1] <> date '2026-07-10' then
    raise exception 'FAIL [4] first row is %, expected the newest workout', dates[1];
  end if;

  -- Paging covers the set exactly once: no row appears on two pages and no row
  -- is skipped between them.
  select array_agg(id) into seen from (
    select id from public.training_workout_summaries(5, 0)
    union all
    select id from public.training_workout_summaries(5, 5)
    union all
    select id from public.training_workout_summaries(5, 10)
  ) q;
  if array_length(seen, 1) <> 12 then
    raise exception 'FAIL [4] three pages of 5 returned % rows, expected 12', array_length(seen, 1);
  end if;
  if (select count(distinct x) from unnest(seen) x) <> 12 then
    raise exception 'FAIL [4] pages overlap: % rows but fewer distinct ids', array_length(seen, 1);
  end if;

  -- Past the end: no rows, and therefore no invented total.
  if (select count(*) from public.training_workout_summaries(5, 100)) <> 0 then
    raise exception 'FAIL [4] an offset past the end returned rows';
  end if;

  -- Per-workout aggregates. Session 1 (2026-06-01): bench 3x61x5 = 915, plus
  -- one OHP set 40x8 = 320, so 1235 over 4 loaded sets; 8 sets in total
  -- (3 bench + 2 plank + 1 ohp + 1 mobility ... plus nothing else) -> 7.
  select * into r from public.training_workout_summaries(50, 0)
   where local_date = date '2026-06-01';
  if r.exercise_count <> 4 then
    raise exception 'FAIL [4] session 1 exercise_count = %, expected 4', r.exercise_count;
  end if;
  if r.set_count <> 7 then
    raise exception 'FAIL [4] session 1 set_count = %, expected 7', r.set_count;
  end if;
  if r.volume_sets <> 4 then
    raise exception 'FAIL [4] session 1 volume_sets = %, expected 4', r.volume_sets;
  end if;
  if r.total_volume_kg <> 1235 then
    raise exception 'FAIL [4] session 1 total_volume_kg = %, expected 1235', r.total_volume_kg;
  end if;

  -- Date filter.
  if (select count(*) from public.training_workout_summaries(50, 0, date '2026-06-01', date '2026-06-05')) <> 3 then
    raise exception 'FAIL [4] date filter did not narrow to the 3 workouts in that range';
  end if;

  -- Title search.
  if (select count(*) from public.training_workout_summaries(50, 0, null, null, 'Session 1')) <> 4 then
    raise exception 'FAIL [4] title search for "Session 1" did not match Session 1, 10, 11, 12';
  end if;

  -- The retired workout is unreachable by any filter.
  if (select count(*) from public.training_workout_summaries(50, 0, null, null, 'Retired')) <> 0 then
    raise exception 'FAIL [4] the retired workout is reachable through search (I-5)';
  end if;

  raise notice 'PASS [4] summaries: newest-first, total_count 12, three disjoint pages, filters, retired row unreachable';
end
$$;

-- ---------------------------------------------------------------------------
-- 5. Workout detail: hierarchy, has_* flags, one round trip
-- ---------------------------------------------------------------------------

do $$
declare
  wid      uuid;
  detail   jsonb;
  bench    jsonb;
  plank    jsonb;
  mobility jsonb;
begin
  select id into wid from public.training_workout_summaries(50, 0)
   where local_date = date '2026-06-01';

  detail := public.training_workout_detail(wid);
  if detail is null then
    raise exception 'FAIL [5] training_workout_detail returned NULL for the user''s own workout';
  end if;
  if jsonb_array_length(detail->'exercises') <> 4 then
    raise exception 'FAIL [5] detail carries % exercises, expected 4',
      jsonb_array_length(detail->'exercises');
  end if;

  select x into bench from jsonb_array_elements(detail->'exercises') x
   where x->>'display_name' = 'Bench Press';
  if (bench->>'has_load')::boolean is not true
     or (bench->>'has_reps')::boolean is not true
     or (bench->>'has_rpe')::boolean is not true then
    raise exception 'FAIL [5] Bench Press flags: %', bench;
  end if;
  if (bench->>'has_distance')::boolean is not false then
    raise exception 'FAIL [5] Bench Press claims distance data it does not have';
  end if;
  if (bench->>'set_count')::int <> 3 or (bench->>'volume_kg')::numeric <> 915 then
    raise exception 'FAIL [5] Bench Press set_count/volume: %', bench;
  end if;
  if jsonb_array_length(bench->'sets') <> 3 then
    raise exception 'FAIL [5] Bench Press carries % set rows', jsonb_array_length(bench->'sets');
  end if;

  select x into plank from jsonb_array_elements(detail->'exercises') x
   where x->>'display_name' = 'Plank';
  if (plank->>'has_duration')::boolean is not true then
    raise exception 'FAIL [5] Plank does not report duration data';
  end if;
  if (plank->>'has_load')::boolean is not false or (plank->>'has_reps')::boolean is not false then
    raise exception 'FAIL [5] Plank claims load or reps it does not have';
  end if;
  -- The critical one: a duration-only exercise contributes no volume, rather
  -- than a zero produced by COALESCE inside the generated column.
  if plank->'volume_kg' <> 'null'::jsonb then
    raise exception 'FAIL [5] Plank volume_kg = %, expected NULL', plank->'volume_kg';
  end if;

  select x into mobility from jsonb_array_elements(detail->'exercises') x
   where x->>'display_name' = 'Mobility Flow';
  if (mobility->>'has_load')::boolean is not false
     or (mobility->>'has_reps')::boolean is not false
     or (mobility->>'has_distance')::boolean is not false
     or (mobility->>'has_duration')::boolean is not false then
    raise exception 'FAIL [5] Mobility Flow claims a measurement it does not have: %', mobility;
  end if;

  raise notice 'PASS [5] detail: 4 exercises in one call, has_* flags follow the data, duration-only volume is NULL';
end
$$;

-- ---------------------------------------------------------------------------
-- 6. Exercise summaries and progression kinds
-- ---------------------------------------------------------------------------

do $$
declare r record; bench_id uuid; plank_id uuid; ohp_id uuid; n int;
begin
  select count(*) into n from public.training_exercise_summaries(50, 0);
  if n <> 5 then
    raise exception 'FAIL [6] exercise summaries returned %, expected 5', n;
  end if;

  select * into r from public.training_exercise_summaries(50, 0) where display_name = 'Bench Press';
  bench_id := r.exercise_definition_id;
  if r.progression_kind <> 'load' then
    raise exception 'FAIL [6] Bench Press progression_kind = %', r.progression_kind;
  end if;
  if r.session_count <> 12 or r.set_count <> 36 then
    raise exception 'FAIL [6] Bench Press sessions/sets = %/%', r.session_count, r.set_count;
  end if;
  if r.top_weight_kg <> 72 then
    raise exception 'FAIL [6] Bench Press top_weight_kg = %, expected 72', r.top_weight_kg;
  end if;
  if r.total_volume_kg <> 11970 then
    raise exception 'FAIL [6] Bench Press total_volume_kg = %, expected 11970', r.total_volume_kg;
  end if;

  select * into r from public.training_exercise_summaries(50, 0) where display_name = 'Plank';
  plank_id := r.exercise_definition_id;
  if r.progression_kind <> 'duration' then
    raise exception 'FAIL [6] Plank progression_kind = %, expected duration', r.progression_kind;
  end if;
  if r.total_volume_kg is not null then
    raise exception 'FAIL [6] Plank total_volume_kg = %, expected NULL', r.total_volume_kg;
  end if;

  select * into r from public.training_exercise_summaries(50, 0) where display_name = 'Farmer Carry';
  if r.progression_kind <> 'distance' then
    raise exception 'FAIL [6] Farmer Carry progression_kind = %, expected distance', r.progression_kind;
  end if;

  select * into r from public.training_exercise_summaries(50, 0) where display_name = 'Mobility Flow';
  if r.progression_kind <> 'none' then
    raise exception 'FAIL [6] Mobility Flow progression_kind = %, expected none', r.progression_kind;
  end if;

  select * into r from public.training_exercise_summaries(50, 0) where display_name = 'Overhead Press';
  ohp_id := r.exercise_definition_id;
  if r.session_count <> 2 then
    raise exception 'FAIL [6] Overhead Press session_count = %, expected 2', r.session_count;
  end if;

  -- Pagination on the explorer, same contract as history.
  if (select count(*) from public.training_exercise_summaries(2, 0)) <> 2 then
    raise exception 'FAIL [6] exercise page size 2 did not return 2 rows';
  end if;
  select total_count into n from public.training_exercise_summaries(2, 0) limit 1;
  if n <> 5 then
    raise exception 'FAIL [6] exercise total_count = %, expected 5', n;
  end if;

  -- Search.
  if (select count(*) from public.training_exercise_summaries(50, 0, 'press')) <> 2 then
    raise exception 'FAIL [6] search "press" did not match Bench Press and Overhead Press';
  end if;

  -- Progression: 12 sessions, oldest first, rising load.
  if (select count(*) from public.training_exercise_progression(bench_id)) <> 12 then
    raise exception 'FAIL [6] Bench Press progression returned the wrong session count';
  end if;
  select * into r from public.training_exercise_progression(bench_id) limit 1;
  if r.local_date <> date '2026-06-01' then
    raise exception 'FAIL [6] progression is not oldest-first: first row is %', r.local_date;
  end if;
  if r.top_weight_kg <> 61 or r.best_set_weight <> 61 or r.best_set_reps <> 5 then
    raise exception 'FAIL [6] first bench session: top %, best % x %',
      r.top_weight_kg, r.best_set_weight, r.best_set_reps;
  end if;

  -- A duration-only exercise carries duration and no volume, on every session.
  if (select count(*) from public.training_exercise_progression(plank_id)
       where total_volume_kg is not null) <> 0 then
    raise exception 'FAIL [6] a Plank session reported a volume';
  end if;
  if (select count(*) from public.training_exercise_progression(plank_id)
       where total_duration_s is null) <> 0 then
    raise exception 'FAIL [6] a Plank session reported no duration';
  end if;

  -- Two sessions is below the UI's chartable floor; the read model still
  -- returns them honestly and the refusal happens in one place, not per screen.
  if (select count(*) from public.training_exercise_progression(ohp_id)) <> 2 then
    raise exception 'FAIL [6] Overhead Press progression did not return its 2 sessions';
  end if;

  -- training_exercise_detail must agree with the explorer row exactly. The
  -- exercise page and the list disagreeing about a number is the failure this
  -- prevents.
  for r in select * from public.training_exercise_summaries(50, 0) loop
    if not exists (
      select 1 from public.training_exercise_detail(r.exercise_definition_id) d
       where d.display_name     = r.display_name
         and d.session_count    = r.session_count
         and d.set_count        = r.set_count
         and d.volume_sets      = r.volume_sets
         and d.total_volume_kg  is not distinct from r.total_volume_kg
         and d.top_weight_kg    is not distinct from r.top_weight_kg
         and d.total_reps       is not distinct from r.total_reps
         and d.first_performed  = r.first_performed
         and d.last_performed   = r.last_performed
         and d.progression_kind = r.progression_kind
    ) then
      raise exception 'FAIL [6] training_exercise_detail disagrees with the explorer row for %', r.display_name;
    end if;
  end loop;

  -- An exercise definition that exists but was never performed yields no row.
  if (select count(*) from public.training_exercise_detail(
        (select id from public.exercise_definitions
          where user_id is null limit 1))) <> 0 then
    raise exception 'FAIL [6] training_exercise_detail returned a row for an unperformed exercise';
  end if;

  raise notice 'PASS [6] exercises: 5 summaries, one of every progression_kind, pagination, search, oldest-first progression, detail agrees with the list';
end
$$;

commit;

-- ---------------------------------------------------------------------------
-- 7. Isolation. Everything above, re-asked as user B.
-- ---------------------------------------------------------------------------

begin;
set local request.jwt.claims = :'claims_b';
set local role authenticated;

do $$
declare
  o        record;
  a_wid    uuid;
  a_defid  uuid;
  n        bigint;
begin
  select * into o from public.training_overview();
  if o.total_workouts <> 2 then
    raise exception 'FAIL [7] user B sees % workouts, expected its own 2', o.total_workouts;
  end if;
  if o.total_sets <> 2 then
    raise exception 'FAIL [7] user B sees % sets, expected its own 2', o.total_sets;
  end if;
  if o.total_volume_kg <> 800 then
    raise exception 'FAIL [7] user B volume = %, expected its own 800', o.total_volume_kg;
  end if;

  if (select count(*) from public.training_workout_summaries(100, 0)) <> 2 then
    raise exception 'FAIL [7] user B''s history is not limited to its own 2 workouts';
  end if;
  if (select count(*) from public.training_exercise_summaries(100, 0)) <> 1 then
    raise exception 'FAIL [7] user B sees more than its own 1 exercise';
  end if;

  -- Ask directly for a workout id that belongs to user A. The answer must be
  -- nothing, not a filtered subset and not an error that confirms it exists.
  select id into a_wid from public.strength_workouts where natural_key = 'p4-a-w-1';
  if a_wid is not null then
    raise exception 'FAIL [7] user B can even see user A''s workout row through the base table';
  end if;

  raise notice 'PASS [7] user B: sees only its own 2 workouts, 2 sets, 1 exercise, 800 kg';
end
$$;

commit;

-- User B asking for user A's records by id, with the ids supplied from outside
-- RLS. This is the cross-user read attempt in the form the product would make
-- it: a URL with somebody else's uuid in it. The ids are carried in a temp
-- table because the read itself must happen as user B.
create temporary table p4_foreign_ids as
select w.id as a_workout_id, e.exercise_definition_id as a_exercise_id
  from public.strength_workouts w
  join public.strength_exercises e on e.workout_id = w.id and e.order_index = 0
 where w.natural_key = 'p4-a-w-1';
grant select on p4_foreign_ids to authenticated;

begin;
set local request.jwt.claims = :'claims_b';
set local role authenticated;

do $$
declare detail jsonb; n bigint; wid uuid; eid uuid;
begin
  select a_workout_id, a_exercise_id into wid, eid from p4_foreign_ids;
  if wid is null or eid is null then
    raise exception 'FAIL [7] the fixture ids for user A were not captured';
  end if;

  detail := public.training_workout_detail(wid);
  if detail is not null then
    raise exception 'FAIL [7] user B read user A''s workout detail by id: %', detail;
  end if;

  select count(*) into n from public.training_exercise_progression(eid);
  if n <> 0 then
    raise exception 'FAIL [7] user B read % progression rows for user A''s exercise', n;
  end if;

  select count(*) into n from public.training_exercise_detail(eid);
  if n <> 0 then
    raise exception 'FAIL [7] user B read % detail rows for user A''s exercise', n;
  end if;

  select count(*) into n from public.training_workout_summaries(100, 0)
   where id = wid;
  if n <> 0 then
    raise exception 'FAIL [7] user A''s workout appears in user B''s summaries';
  end if;

  raise notice 'PASS [7] user B asking for user A''s workout id and exercise id by uuid gets NULL and 0 rows';
end
$$;

commit;

-- ---------------------------------------------------------------------------
-- 8. The empty user. No fabricated analytics, no division by zero.
-- ---------------------------------------------------------------------------

insert into auth.users (id, email)
values ('99999999-9999-4999-8999-999999999999', 'phase4-empty@test.invalid')
on conflict (id) do nothing;

begin;
set local request.jwt.claims = '{"sub":"99999999-9999-4999-8999-999999999999","role":"authenticated"}';
set local role authenticated;

do $$
declare o record; n int; w record;
begin
  select * into o from public.training_overview();
  if o.total_workouts <> 0 or o.total_sets <> 0 then
    raise exception 'FAIL [8] an empty account reports % workouts and % sets',
      o.total_workouts, o.total_sets;
  end if;
  if o.total_volume_kg is not null then
    raise exception 'FAIL [8] an empty account reports a volume of %', o.total_volume_kg;
  end if;
  if o.first_workout_date is not null or o.last_workout_date is not null then
    raise exception 'FAIL [8] an empty account reports a date range';
  end if;

  if (select count(*) from public.training_workout_summaries(25, 0)) <> 0 then
    raise exception 'FAIL [8] an empty account has workout summaries';
  end if;
  if (select count(*) from public.training_exercise_summaries(50, 0)) <> 0 then
    raise exception 'FAIL [8] an empty account has exercise summaries';
  end if;
  if (select count(*) from public.training_exercise_detail(
        (select id from public.exercise_definitions where user_id is null limit 1))) <> 0 then
    raise exception 'FAIL [8] an empty account has an exercise detail row';
  end if;

  -- The weekly series still returns its window, anchored on today, with every
  -- volume NULL. A zero-filled frequency for a user who has never trained is
  -- true; a zero-filled volume would be a fabricated measurement.
  select count(*) into n from public.training_weekly_series(12);
  if n <> 12 then
    raise exception 'FAIL [8] the weekly series returned % rows for an empty account', n;
  end if;
  for w in select * from public.training_weekly_series(12) loop
    if w.workout_count <> 0 then
      raise exception 'FAIL [8] an empty account reports % workouts in a week', w.workout_count;
    end if;
    if w.volume_kg is not null then
      raise exception 'FAIL [8] an empty account reports volume % in a week', w.volume_kg;
    end if;
  end loop;

  raise notice 'PASS [8] empty account: zero counts, NULL volume, NULL date range, no division by zero';
end
$$;

commit;

-- ---------------------------------------------------------------------------
-- 9. Phase 4 writes nothing. The read model has no INSERT, UPDATE or DELETE in
--    it, and the authenticated role still holds no canonical write privilege.
-- ---------------------------------------------------------------------------

do $$
declare r record; bad text[] := '{}'; t text; p text;
begin
  for r in select p.proname, pg_get_functiondef(p.oid) as def
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'training\_%'
  loop
    if r.def ~* '\y(insert into|update |delete from)\y' then
      raise exception 'FAIL [9] read-model function public.% contains a write', r.proname;
    end if;
  end loop;

  foreach t in array array['strength_workouts','strength_exercises','strength_sets','metrics','raw_records'] loop
    foreach p in array array['INSERT','UPDATE','DELETE','TRUNCATE'] loop
      if has_table_privilege('authenticated', 'public.' || t, p) then
        bad := bad || (t || ':' || p);
      end if;
    end loop;
  end loop;
  if array_length(bad, 1) is not null then
    raise exception 'FAIL [9] authenticated holds canonical write privileges: %', array_to_string(bad, ', ');
  end if;

  raise notice 'PASS [9] no read-model function writes, and authenticated holds no canonical INSERT/UPDATE/DELETE/TRUNCATE';
end
$$;

do $$ begin raise notice 'PASS Phase 4 read model: all assertions'; end $$;
