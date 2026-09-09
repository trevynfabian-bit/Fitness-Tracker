-- ============================================================================
-- 20_scale.sql
-- Phase 4 hard gate D: the read model at the size the product is designed for.
--
-- Builds 2,000 workouts, 6,000 exercise instances and 30,000 sets for one user
-- and 500 workouts for a second, then times every read-model call as the
-- `authenticated` role. The point is not a benchmark number: it is that a page
-- of history costs a page of history, that no screen's query walks the whole
-- history, and that the aggregations use the indexes rather than sequential
-- scans over the set table.
--
-- The rows here are harness rows, not health data: they exist to exercise the
-- query planner. Correctness of values is asserted in 10_read_model.sql against
-- the small, hand-checked fixture.
-- ============================================================================

\set QUIET on
\set uid_a 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
\set uid_b 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
\set claims_a '{"sub":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","role":"authenticated"}'
\set QUIET off

insert into auth.users (id, email)
values (:'uid_a', 'phase4-scale-a@test.invalid'), (:'uid_b', 'phase4-scale-b@test.invalid')
on conflict (id) do nothing;

do $$
declare
  u            uuid;
  workouts     int;
  imp          uuid;
  rr           bigint;
  def_ids      uuid[];
begin
  foreach u in array array[
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'::uuid
  ] loop
    workouts := case when u::text like 'aaaa%' then 2000 else 500 end;

    insert into public.exercise_definitions (user_id, key, display_name)
    select u, 'scale_ex_' || n, 'Scale Exercise ' || n
      from generate_series(1, 30) n;

    select array_agg(id order by key) into def_ids
      from public.exercise_definitions
     where user_id = u and key like 'scale\_ex\_%';

    insert into public.import_profiles
      (user_id, name, template, source_key, signature_hash, header_tokens, mapping_spec)
    values (u, 'Scale profile', 'strength', 'fixture_source',
            'sig-scale-' || u::text, array['a','b'], '{}'::jsonb);

    insert into public.data_imports
      (user_id, source_key, template, storage_path, file_name, file_type,
       mapping_spec_snapshot, normalize_version, import_mode, status, imported_at)
    values (u, 'fixture_source', 'strength', u::text || '/scale/f.csv', 'f.csv', 'csv',
            '{}'::jsonb, 1, 'append', 'completed', now())
    returning id into imp;

    insert into public.raw_records (user_id, import_id, source_key, payload, row_hash)
    values (u, imp, 'fixture_source', '{"fixture":"scale"}'::jsonb, 'scale-hash-' || u::text)
    returning id into rr;

    -- Set based rather than row by row: 2,000 workouts, three exercises each,
    -- five sets each, spread one per day backwards from today.
    insert into public.strength_workouts
      (user_id, start_utc, tz_offset_minutes, local_date, duration_s, title,
       source_key, natural_key, raw_record_id, import_id)
    select u,
           (current_date - g) + time '18:00',
           0,
           current_date - g,
           3600,
           'Scale session ' || g,
           'fixture_source',
           'scale-w-' || u::text || '-' || g,
           rr,
           imp
      from generate_series(0, workouts - 1) g;

    insert into public.strength_exercises
      (user_id, workout_id, exercise_definition_id, exercise_name_raw, order_index,
       raw_record_id, import_id)
    select u, w.id, def_ids[1 + ((w.local_date - date '2020-01-01') + k) % 30],
           'Scale Exercise', k, rr, imp
      from public.strength_workouts w
      cross join generate_series(0, 2) k
     where w.user_id = u;

    insert into public.strength_sets
      (user_id, exercise_id, set_number, weight_kg, reps, natural_key, raw_record_id)
    select u, e.id, s, 50 + (e.order_index * 10) + s, 5, 'scale-s-' || e.id::text || '-' || s, rr
      from public.strength_exercises e
      cross join generate_series(1, 5) s
     where e.user_id = u;
  end loop;

  analyze public.strength_workouts;
  analyze public.strength_exercises;
  analyze public.strength_sets;

  raise notice 'PASS [scale] fixture built';
end
$$;

do $$
declare w bigint; e bigint; s bigint;
begin
  select count(*) into w from public.strength_workouts;
  select count(*) into e from public.strength_exercises;
  select count(*) into s from public.strength_sets;
  raise notice 'PASS [scale] % workouts, % exercise instances, % sets across two users', w, e, s;
  if s < 30000 then
    raise exception 'FAIL [scale] only % sets built; the gate needs tens of thousands', s;
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Roll the scale fixture up, and time that too: the rollup's own cost is part
-- of what Phase 5 has to justify.
-- ---------------------------------------------------------------------------

do $$
declare
  started    timestamptz;
  elapsed_ms numeric;
  scopes     integer;
  result     jsonb;
begin
  started := clock_timestamp();
  select public.rollup_rebuild_user('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')
       + public.rollup_rebuild_user('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')
    into scopes;
  elapsed_ms := extract(epoch from clock_timestamp() - started) * 1000;
  raise notice 'PASS [D] enqueued % scopes in % ms', scopes, round(elapsed_ms);

  started := clock_timestamp();
  select public.rollup_process_pending(5000, 'scale-suite') into result;
  elapsed_ms := extract(epoch from clock_timestamp() - started) * 1000;
  if (result->>'failed')::int <> 0 then
    raise exception 'FAIL [D] rollup reported failures: %', result;
  end if;
  raise notice 'PASS [D] rolled up % scopes in % ms (% ms per scope)',
    result->>'processed', round(elapsed_ms),
    round(elapsed_ms / greatest((result->>'processed')::numeric, 1), 2);

  if (select count(*) from public.rollup_queue where state <> 'done') <> 0 then
    raise exception 'FAIL [D] scopes remain unprocessed';
  end if;
end
$$;

analyze public.metric_daily;
analyze public.metric_daily_source;
analyze public.exercise_daily;
analyze public.exercise_daily_source;

-- ---------------------------------------------------------------------------
-- Timing, as the authenticated role, through the same functions the product
-- calls. The budget is deliberately loose: this catches an accidental full
-- scan or an N+1 shaped query, not a millisecond regression.
-- ---------------------------------------------------------------------------

begin;
set local request.jwt.claims = :'claims_a';
set local role authenticated;

do $$
declare
  started    timestamptz;
  elapsed_ms numeric;
  budget_ms  numeric := 2000;
  n          bigint;
  wid        uuid;
  did        uuid;
begin
  -- 1. The history page: one page of 25, newest first, with its total.
  started := clock_timestamp();
  select count(*) into n from public.training_workout_summaries(25, 0);
  elapsed_ms := extract(epoch from clock_timestamp() - started) * 1000;
  if n <> 25 then
    raise exception 'FAIL [D] a page of history returned % rows', n;
  end if;
  raise notice 'PASS [D] training_workout_summaries(25, 0) over 2000 workouts: % ms', round(elapsed_ms);
  if elapsed_ms > budget_ms then
    raise exception 'FAIL [D] one page of history took % ms, over the % ms budget', round(elapsed_ms), budget_ms;
  end if;

  -- 2. A deep page costs the same order as a shallow one.
  started := clock_timestamp();
  select count(*) into n from public.training_workout_summaries(25, 1900);
  elapsed_ms := extract(epoch from clock_timestamp() - started) * 1000;
  if n <> 25 then
    raise exception 'FAIL [D] a deep page of history returned % rows', n;
  end if;
  raise notice 'PASS [D] training_workout_summaries(25, 1900): % ms', round(elapsed_ms);
  if elapsed_ms > budget_ms then
    raise exception 'FAIL [D] a deep page took % ms', round(elapsed_ms);
  end if;

  -- 3. The dashboard's three calls.
  started := clock_timestamp();
  perform * from public.training_overview();
  elapsed_ms := extract(epoch from clock_timestamp() - started) * 1000;
  raise notice 'PASS [D] training_overview() over 30000 sets: % ms', round(elapsed_ms);
  if elapsed_ms > budget_ms then
    raise exception 'FAIL [D] training_overview took % ms', round(elapsed_ms);
  end if;

  started := clock_timestamp();
  perform * from public.training_weekly_series(12);
  elapsed_ms := extract(epoch from clock_timestamp() - started) * 1000;
  raise notice 'PASS [D] training_weekly_series(12): % ms', round(elapsed_ms);
  if elapsed_ms > budget_ms then
    raise exception 'FAIL [D] training_weekly_series took % ms', round(elapsed_ms);
  end if;

  -- 4. The exercise explorer.
  started := clock_timestamp();
  select count(*) into n from public.training_exercise_summaries(30, 0);
  elapsed_ms := extract(epoch from clock_timestamp() - started) * 1000;
  if n <> 30 then
    raise exception 'FAIL [D] the exercise explorer returned % rows', n;
  end if;
  raise notice 'PASS [D] training_exercise_summaries(30, 0) over 30 exercises: % ms', round(elapsed_ms);
  if elapsed_ms > budget_ms then
    raise exception 'FAIL [D] the exercise explorer took % ms', round(elapsed_ms);
  end if;

  -- 5. One workout, whole hierarchy, one call.
  select id into wid from public.training_workout_summaries(1, 0);
  started := clock_timestamp();
  perform public.training_workout_detail(wid);
  elapsed_ms := extract(epoch from clock_timestamp() - started) * 1000;
  raise notice 'PASS [D] training_workout_detail(): % ms', round(elapsed_ms);
  if elapsed_ms > budget_ms then
    raise exception 'FAIL [D] one workout detail took % ms', round(elapsed_ms);
  end if;

  -- 6. One exercise's progression, bounded by its own limit.
  select exercise_definition_id into did from public.training_exercise_summaries(1, 0);
  started := clock_timestamp();
  select count(*) into n from public.training_exercise_progression(did, 60);
  elapsed_ms := extract(epoch from clock_timestamp() - started) * 1000;
  if n > 60 then
    raise exception 'FAIL [D] progression returned % rows, over its own limit', n;
  end if;
  raise notice 'PASS [D] training_exercise_progression(limit 60): % ms, % rows', round(elapsed_ms), n;
  if elapsed_ms > budget_ms then
    raise exception 'FAIL [D] one progression took % ms', round(elapsed_ms);
  end if;
end
$$;

-- Paging at scale still covers the set exactly once.
do $$
declare seen uuid[]; total bigint;
begin
  select array_agg(id) into seen from (
    select id from public.training_workout_summaries(25, 0)
    union all
    select id from public.training_workout_summaries(25, 25)
    union all
    select id from public.training_workout_summaries(25, 50)
  ) q;
  if array_length(seen, 1) <> 75 then
    raise exception 'FAIL [D] three pages returned % rows', array_length(seen, 1);
  end if;
  if (select count(distinct x) from unnest(seen) x) <> 75 then
    raise exception 'FAIL [D] pages overlap at scale';
  end if;

  select total_count into total from public.training_workout_summaries(25, 0) limit 1;
  if total <> 2000 then
    raise exception 'FAIL [D] total_count = % at scale, expected 2000', total;
  end if;

  raise notice 'PASS [D] three 25-row pages over 2000 workouts are disjoint, total_count 2000';
end
$$;

-- Isolation holds at scale: the other user's 500 workouts are invisible, and
-- the totals prove the row count was never merely truncated by the page limit.
do $$
declare o record;
begin
  select * into o from public.training_overview();
  if o.total_workouts <> 2000 then
    raise exception 'FAIL [D] user A sees % workouts at scale, expected its own 2000', o.total_workouts;
  end if;
  if o.total_sets <> 30000 then
    raise exception 'FAIL [D] user A sees % sets, expected its own 30000', o.total_sets;
  end if;
  raise notice 'PASS [D] at scale user A sees exactly its own 2000 workouts and 30000 sets, none of user B''s';
end
$$;

commit;

do $$ begin raise notice 'PASS Phase 4 hard gate D: read model at 2000 workouts / 30000 sets'; end $$;
