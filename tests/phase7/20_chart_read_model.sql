-- ============================================================================
-- 20_chart_read_model.sql
-- Phase 7, part 2: the chart read layer.
--
-- The rollup suite proves metric_daily is correct. This one proves the layer
-- above it does not then make it misleading:
--
--   * every range resolves to exactly the days it names
--   * each gap policy does what the registry says, and nothing invents one
--   * a day with no measurement is never silently a zero
--   * carry_forward carries only where it is configured, and looks back before
--     the window rather than starting a chart blank
--   * a percentage change from a zero baseline is undefined, not infinite
--   * below the observation gate no change is computed at all
--
-- All three gap policies are exercised against metrics that genuinely carry
-- them. No registry value is invented to make a branch reachable: weight is
-- carry_forward and body_fat_percentage is null per seed 0002 (from v2 §9.4),
-- and training_workouts is zero per seed 0003. The chart functions are generic
-- over metric_key, so the zero branch is the same code path either way.
-- ============================================================================

\set QUIET on
\set uid_c '79797979-7979-4797-8797-797979797979'
\set uid_d '7a7a7a7a-7a7a-47a7-87a7-7a7a7a7a7a7a'
\set claims_c '{"sub":"79797979-7979-4797-8797-797979797979","role":"authenticated"}'
\set claims_d '{"sub":"7a7a7a7a-7a7a-47a7-87a7-7a7a7a7a7a7a","role":"authenticated"}'
\set QUIET off

insert into auth.users (id, email) values
  (:'uid_c', 'phase7-c@test.invalid'), (:'uid_d', 'phase7-d@test.invalid')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 0. The gap policies this suite relies on come from the registry.
--
-- If a seed changes one of these the assertions below silently start testing
-- something else, so the premise is pinned before anything runs.
-- ---------------------------------------------------------------------------

do $$
declare r record;
begin
  for r in
    select * from (values
      ('weight',              'carry_forward'),
      ('body_fat_percentage', 'null'),
      ('training_workouts',   'zero')
    ) as v (key, gap)
  loop
    if not exists (
      select 1 from public.metric_definitions
       where user_id is null and key = r.key and gap_policy = r.gap and is_active
    ) then
      raise exception 'FAIL [0] % does not carry gap_policy %; this suite would test the wrong branch',
        r.key, r.gap;
    end if;
  end loop;
  raise notice 'PASS [0] all three gap policies are present on real registry metrics';
end
$$;

-- ---------------------------------------------------------------------------
-- 1. Fixture.
--
-- User C measures weight and body fat on 2026-03-02, 2026-03-05 and
-- 2026-03-09, and trains on 2026-03-02 only. The gaps are deliberate: 03-03,
-- 03-04, 03-06, 03-07 and 03-08 have no measurement of anything, and each gap
-- policy must treat them differently.
--
-- Waist circumference is measured ONCE, on 2026-03-05, so the observation gate
-- has a real case to refuse. Resting heart rate is measured twice.
-- ---------------------------------------------------------------------------

create function pg_temp.manual_import(p_user uuid, p_tag text)
returns uuid language plpgsql as $$
declare imp uuid;
begin
  insert into public.data_imports
    (user_id, source_key, template, file_name, file_type, mapping_spec_snapshot,
     normalize_version, import_mode, status, imported_at, rows_total)
  values (p_user, 'manual', 'metrics', p_tag, 'manual',
          '{"template":"metrics","layout":"long"}'::jsonb, 1, 'append', 'completed', now(), 1)
  returning id into imp;
  return imp;
end $$;

create function pg_temp.observe(
  p_user uuid, p_import uuid, p_natural_key text, p_metric text,
  p_value numeric, p_at timestamptz
) returns public.upsert_outcome language plpgsql as $$
declare rr bigint; def record;
begin
  insert into public.raw_records
    (user_id, import_id, source_key, payload, row_hash, precedence_rank)
  values (p_user, p_import, 'manual',
          jsonb_build_object('metric_key', p_metric, 'value', p_value::text),
          md5(p_natural_key || p_value::text), 10::smallint)
  returning id into rr;

  select d.id, d.key, d.canonical_unit_id into def
    from public.metric_definitions d
   where d.key = p_metric and d.user_id is null;

  return public.import_upsert_metric(
    p_user, p_natural_key, def.id, def.key, null,
    p_at, 0, null, (p_at at time zone 'UTC')::date,
    p_value, def.canonical_unit_id, null,
    'manual', p_value, null, rr, p_import);
end $$;

do $$
declare
  u   uuid := '79797979-7979-4797-8797-797979797979';
  imp uuid;
  timp uuid;
  rr  bigint;
  sq  uuid;
  w   uuid;
  o   public.upsert_outcome;
begin
  imp := pg_temp.manual_import(u, 'p7c-manual');

  perform pg_temp.observe(u, imp, 'p7c-w-0302', 'weight', 80.0, timestamptz '2026-03-02 07:00:00+00');
  perform pg_temp.observe(u, imp, 'p7c-w-0305', 'weight', 79.0, timestamptz '2026-03-05 07:00:00+00');
  perform pg_temp.observe(u, imp, 'p7c-w-0309', 'weight', 78.4, timestamptz '2026-03-09 07:00:00+00');

  perform pg_temp.observe(u, imp, 'p7c-bf-0302', 'body_fat_percentage', 20.0, timestamptz '2026-03-02 07:00:00+00');
  perform pg_temp.observe(u, imp, 'p7c-bf-0305', 'body_fat_percentage', 19.6, timestamptz '2026-03-05 07:00:00+00');
  perform pg_temp.observe(u, imp, 'p7c-bf-0309', 'body_fat_percentage', 19.2, timestamptz '2026-03-09 07:00:00+00');

  -- One measurement only: below the gate.
  perform pg_temp.observe(u, imp, 'p7c-wa-0305', 'waist_circumference', 84.0, timestamptz '2026-03-05 07:00:00+00');

  -- Two measurements: still below the gate of three.
  perform pg_temp.observe(u, imp, 'p7c-rhr-0302', 'resting_heart_rate', 54, timestamptz '2026-03-02 07:00:00+00');
  perform pg_temp.observe(u, imp, 'p7c-rhr-0309', 'resting_heart_rate', 52, timestamptz '2026-03-09 07:00:00+00');

  -- A training day inside the same window, so the zero gap policy has a real
  -- series to be tested against.
  insert into public.exercise_definitions (user_id, key, display_name)
  values (u, 'deadlift', 'Deadlift') returning id into sq;

  insert into public.data_imports
    (user_id, source_key, template, storage_path, file_name, file_type,
     mapping_spec_snapshot, normalize_version, import_mode, status, imported_at)
  values (u, 'hevy', 'strength', u::text || '/p7c/h.csv', 'p7c-hevy.csv', 'csv',
          '{}'::jsonb, 1, 'append', 'completed', now())
  returning id into timp;

  insert into public.raw_records (user_id, import_id, source_key, payload, row_hash)
  values (u, timp, 'hevy', '{"fixture":"p7c"}'::jsonb, 'p7c-training')
  returning id into rr;

  select * from public.import_upsert_strength_workout(
    u, 'p7c-w1', timestamptz '2026-03-02 18:00:00+00', 0, date '2026-03-02',
    3600, 'Pull', 'hevy', 'p7c-w1', rr, timp) into o, w;
  perform public.import_upsert_strength_set(
    u, 'p7c-s1',
    public.import_upsert_strength_exercise(u, w, sq, 'Deadlift', 0, rr, timp),
    1, 'working', 120, 5, null, null, null, rr);

  perform public.rollup_rebuild_user(u);
  perform public.rollup_process_pending(200, 'phase7-charts');
end
$$;

-- User D exists so every isolation assertion has real data to fail against.
do $$
declare u uuid := '7a7a7a7a-7a7a-47a7-87a7-7a7a7a7a7a7a'; imp uuid;
begin
  imp := pg_temp.manual_import(u, 'p7d-manual');
  perform pg_temp.observe(u, imp, 'p7d-w-0302', 'weight', 95.0, timestamptz '2026-03-02 07:00:00+00');
  perform pg_temp.observe(u, imp, 'p7d-w-0305', 'weight', 94.5, timestamptz '2026-03-05 07:00:00+00');
  perform pg_temp.observe(u, imp, 'p7d-w-0309', 'weight', 94.0, timestamptz '2026-03-09 07:00:00+00');
  perform public.rollup_rebuild_user(u);
  perform public.rollup_process_pending(200, 'phase7-charts-d');
end
$$;

-- ---------------------------------------------------------------------------
-- Everything below runs as an authenticated session, because the chart read
-- model takes no user id and is scoped entirely by row level security. Testing
-- it on the elevated connection would test a different function.
-- ---------------------------------------------------------------------------

begin;
set local request.jwt.claims = :'claims_c';
set local role authenticated;

-- ---------------------------------------------------------------------------
-- 2. Ranges resolve to exactly the days they name.
--
-- The series returns one row per day in [from, to] inclusive, so a 7-day
-- window is 7 rows and a 365-day window is 365 — whether or not anything was
-- measured in them. That is what makes a range chart honest: the empty days
-- are shown as empty rather than omitted, which is a different picture.
-- ---------------------------------------------------------------------------

do $$
declare r record; n int;
begin
  for r in
    select * from (values (7), (30), (90), (365)) as v (days)
  loop
    select count(*) into n
      from public.body_metric_series(
        array['weight'], date '2026-03-09' - (r.days - 1), date '2026-03-09');
    if n <> r.days then
      raise exception 'FAIL [2] a %-day range returned % rows', r.days, n;
    end if;
  end loop;

  -- All time: from the first observation to the last, inclusive.
  select count(*) into n
    from public.body_metric_series(array['weight'], date '2026-03-02', date '2026-03-09');
  if n <> 8 then
    raise exception 'FAIL [2] an all-time range over 2026-03-02..09 returned % rows, expected 8', n;
  end if;

  -- Several metrics at once return their own days each, never interleaved
  -- or collapsed.
  select count(*) into n
    from public.body_metric_series(
      array['weight', 'body_fat_percentage'], date '2026-03-02', date '2026-03-09');
  if n <> 16 then
    raise exception 'FAIL [2] two metrics over 8 days returned % rows, expected 16', n;
  end if;

  raise notice 'PASS [2] 7D, 30D, 90D, 1Y and all-time each resolve to exactly the days they name';
end
$$;

-- ---------------------------------------------------------------------------
-- 3. gap_policy = 'null'. An unmeasured day is NULL and is never a zero.
-- ---------------------------------------------------------------------------

do $$
declare n_observed int; n_null int; n_zero int; n_filled int;
begin
  select count(*) filter (where s.observed),
         count(*) filter (where s.value is null),
         count(*) filter (where s.value = 0),
         count(*) filter (where s.filled)
    into n_observed, n_null, n_zero, n_filled
    from public.body_metric_series(
      array['body_fat_percentage'], date '2026-03-02', date '2026-03-09') s;

  if n_observed <> 3 then
    raise exception 'FAIL [3] % observed days, expected 3', n_observed;
  end if;
  if n_null <> 5 then
    raise exception 'FAIL [3] % NULL days, expected the 5 unmeasured ones', n_null;
  end if;
  if n_zero <> 0 then
    raise exception 'FAIL [3] % unmeasured days were reported as zero', n_zero;
  end if;
  if n_filled <> 0 then
    raise exception 'FAIL [3] a null-policy metric filled % days', n_filled;
  end if;

  raise notice 'PASS [3] a null-policy metric returns NULL on every unmeasured day and fills none';
end
$$;

-- ---------------------------------------------------------------------------
-- 4. gap_policy = 'zero'. An unmeasured day is a real zero, and says so.
-- ---------------------------------------------------------------------------

do $$
declare n_observed int; n_zero int; n_null int; n_filled int;
begin
  select count(*) filter (where s.observed),
         count(*) filter (where s.value = 0),
         count(*) filter (where s.value is null),
         count(*) filter (where s.filled)
    into n_observed, n_zero, n_null, n_filled
    from public.body_metric_series(
      array['training_workouts'], date '2026-03-02', date '2026-03-09') s;

  if n_observed <> 1 then
    raise exception 'FAIL [4] % observed training days, expected 1', n_observed;
  end if;
  if n_zero <> 7 then
    raise exception 'FAIL [4] % zero-filled days, expected the 7 untrained ones', n_zero;
  end if;
  if n_null <> 0 then
    raise exception 'FAIL [4] a zero-policy metric returned % NULLs', n_null;
  end if;
  if n_filled <> 7 then
    raise exception 'FAIL [4] % days were flagged as filled, expected 7', n_filled;
  end if;

  raise notice 'PASS [4] a zero-policy metric zero-fills every unmeasured day and flags each as filled, not measured';
end
$$;

-- ---------------------------------------------------------------------------
-- 5. gap_policy = 'carry_forward'. Carried where configured, and nowhere else.
-- ---------------------------------------------------------------------------

do $$
declare r record; n_observed int; n_filled int; n_null int;
begin
  select count(*) filter (where s.observed),
         count(*) filter (where s.filled),
         count(*) filter (where s.value is null)
    into n_observed, n_filled, n_null
    from public.body_metric_series(array['weight'], date '2026-03-02', date '2026-03-09') s;

  if n_observed <> 3 then
    raise exception 'FAIL [5] % observed weight days, expected 3', n_observed;
  end if;
  if n_filled <> 5 then
    raise exception 'FAIL [5] % carried days, expected 5', n_filled;
  end if;
  if n_null <> 0 then
    raise exception 'FAIL [5] carry_forward left % days NULL inside the measured span', n_null;
  end if;

  -- The carried value is the LAST measurement before that day, not the next
  -- one and not the mean of the two.
  for r in
    select * from (values
      (date '2026-03-03', 80.0), (date '2026-03-04', 80.0),
      (date '2026-03-06', 79.0), (date '2026-03-07', 79.0), (date '2026-03-08', 79.0)
    ) as v (d, expected)
  loop
    if (select value from public.body_metric_series(array['weight'], r.d, r.d)) <> r.expected then
      raise exception 'FAIL [5] % carried %, expected %',
        r.d, (select value from public.body_metric_series(array['weight'], r.d, r.d)), r.expected;
    end if;
  end loop;

  -- The seed comes from BEFORE the window. A one-day window on an unmeasured
  -- day still carries, which is the whole reason a weekly weigh-in produces a
  -- usable 7-day chart.
  if (select value from public.body_metric_series(
        array['weight'], date '2026-03-08', date '2026-03-08')) <> 79.0 then
    raise exception 'FAIL [5] a window containing no measurement did not carry one in from before it';
  end if;

  -- And a day BEFORE the first measurement ever is not carried backwards.
  if (select value from public.body_metric_series(
        array['weight'], date '2026-03-01', date '2026-03-01')) is not null then
    raise exception 'FAIL [5] a day before the first measurement was given a value';
  end if;

  raise notice 'PASS [5] carry_forward carries the previous measurement, seeds from before the window, and never carries backwards';
end
$$;

-- ---------------------------------------------------------------------------
-- 6. The minimum-observation gate.
--
-- Below the threshold the change columns are NULL rather than computed. The
-- threshold is a parameter, so the boundary is tested at it and either side of
-- it rather than at one hard-coded number.
-- ---------------------------------------------------------------------------

do $$
declare s record;
begin
  -- waist_circumference: one measurement.
  select * into strict s from public.body_metric_summary(
    array['waist_circumference'], date '2026-03-02', date '2026-03-09', 3);
  if s.observation_count <> 1 then
    raise exception 'FAIL [6] waist has % observations, expected 1', s.observation_count;
  end if;
  if s.sufficient then
    raise exception 'FAIL [6] one measurement was reported as sufficient';
  end if;
  if s.change_absolute is not null or s.change_percent is not null then
    raise exception 'FAIL [6] a change was computed from one measurement (% / %)',
      s.change_absolute, s.change_percent;
  end if;
  -- The facts themselves are still returned: the gate withholds the trend, not
  -- the measurement.
  if s.last_value <> 84.0 then
    raise exception 'FAIL [6] the gate also withheld the measured value';
  end if;

  -- resting_heart_rate: two measurements, still below three.
  select * into strict s from public.body_metric_summary(
    array['resting_heart_rate'], date '2026-03-02', date '2026-03-09', 3);
  if s.sufficient or s.change_absolute is not null then
    raise exception 'FAIL [6] two measurements passed a gate of three';
  end if;

  -- Same data, a gate of two: now it is sufficient, and the change is real.
  select * into strict s from public.body_metric_summary(
    array['resting_heart_rate'], date '2026-03-02', date '2026-03-09', 2);
  if not s.sufficient then
    raise exception 'FAIL [6] two measurements failed a gate of two';
  end if;
  if s.change_absolute <> -2 then
    raise exception 'FAIL [6] the change is %, expected -2 (54 -> 52)', s.change_absolute;
  end if;

  -- weight: three measurements, at the gate.
  select * into strict s from public.body_metric_summary(
    array['weight'], date '2026-03-02', date '2026-03-09', 3);
  if not s.sufficient then
    raise exception 'FAIL [6] three measurements failed a gate of three';
  end if;
  if s.change_absolute <> -1.6 then
    raise exception 'FAIL [6] the weight change is %, expected -1.6 (80.0 -> 78.4)', s.change_absolute;
  end if;
  if round(s.change_percent, 3) <> -2.000 then
    raise exception 'FAIL [6] the weight change percent is %, expected -2.000', round(s.change_percent, 3);
  end if;
  if s.min_value <> 78.4 or s.max_value <> 80.0 then
    raise exception 'FAIL [6] the range is % to %, expected 78.4 to 80.0', s.min_value, s.max_value;
  end if;

  -- A metric with no observations at all is reported as zero, not as absent:
  -- the caller asked about it and is entitled to be told there is nothing.
  select * into strict s from public.body_metric_summary(
    array['heart_rate_variability'], date '2026-03-02', date '2026-03-09', 3);
  if s.observation_count <> 0 or s.sufficient then
    raise exception 'FAIL [6] an unmeasured metric reported % observations, sufficient=%',
      s.observation_count, s.sufficient;
  end if;

  raise notice 'PASS [6] the observation gate withholds trends below the threshold, returns them at it, and withholds no measured fact';
end
$$;

-- ---------------------------------------------------------------------------
-- 7. Division by zero.
--
-- training_workouts on a day with no training is a genuine zero, so a window
-- starting on one has a zero baseline. A percentage change from zero is
-- undefined; it must be NULL, and it must not raise, and the absolute change
-- must still be reported.
-- ---------------------------------------------------------------------------

commit;

-- A zero baseline, constructed honestly.
--
-- metric_daily stores only days that were observed, so a gap can never be the
-- baseline: the first row in a window always carries a measured value. The
-- only way the baseline is zero is if somebody measured zero, so that is what
-- the fixture does. A sleep_duration of zero is a real thing a device reports
-- for a night it did not detect sleep, and dividing by it must not raise, must
-- not return an infinity, and must not suppress the absolute change alongside
-- it.
do $$
declare
  u   uuid := '79797979-7979-4797-8797-797979797979';
  imp uuid;
begin
  imp := pg_temp.manual_import(u, 'p7c-zero-baseline');
  perform pg_temp.observe(u, imp, 'p7c-sl-0302', 'sleep_duration', 0, timestamptz '2026-03-02 06:00:00+00');
  perform pg_temp.observe(u, imp, 'p7c-sl-0305', 'sleep_duration', 400, timestamptz '2026-03-05 06:00:00+00');
  perform pg_temp.observe(u, imp, 'p7c-sl-0309', 'sleep_duration', 420, timestamptz '2026-03-09 06:00:00+00');
  perform public.rollup_enqueue_metric_days(
    u, array[date '2026-03-02', date '2026-03-05', date '2026-03-09'], 'import');
  perform public.rollup_process_pending(50, 'phase7-zero');
end
$$;

begin;
set local request.jwt.claims = :'claims_c';
set local role authenticated;

do $$
declare s record;
begin
  select * into strict s from public.body_metric_summary(
    array['sleep_duration'], date '2026-03-02', date '2026-03-09', 3);

  if s.first_value <> 0 then
    raise exception 'FAIL [7] the zero-baseline fixture did not produce a zero first value (got %)', s.first_value;
  end if;
  if s.change_absolute <> 420 then
    raise exception 'FAIL [7] the absolute change is %, expected 420', s.change_absolute;
  end if;
  if s.change_percent is not null then
    raise exception 'FAIL [7] a percentage change of % was computed from a zero baseline', s.change_percent;
  end if;

  raise notice 'PASS [7] a zero baseline yields a real absolute change and a NULL percentage, never an error and never an infinity';
end
$$;

-- ---------------------------------------------------------------------------
-- 8. Bounds, and the all-time range they resolve.
-- ---------------------------------------------------------------------------

do $$
declare b record;
begin
  select * into strict b from public.body_metric_bounds(array['weight']);
  if b.first_date <> date '2026-03-02' or b.last_date <> date '2026-03-09' then
    raise exception 'FAIL [8] weight bounds are % to %, expected 2026-03-02 to 2026-03-09',
      b.first_date, b.last_date;
  end if;
  if b.observation_count <> 3 then
    raise exception 'FAIL [8] weight has % observed days, expected 3', b.observation_count;
  end if;

  -- A metric with no history returns a row with NULL bounds, not no row: the
  -- page needs to know the metric exists and is empty.
  select * into strict b from public.body_metric_bounds(array['heart_rate_variability']);
  if b.first_date is not null or b.observation_count <> 0 then
    raise exception 'FAIL [8] an unmeasured metric reported bounds % / %', b.first_date, b.observation_count;
  end if;

  raise notice 'PASS [8] bounds report the real span, and an unmeasured metric returns a row saying so';
end
$$;

-- ---------------------------------------------------------------------------
-- 9. Isolation. The chart layer takes no user id; RLS is the only scope.
-- ---------------------------------------------------------------------------

do $$
declare v numeric; n bigint;
begin
  -- User D's weight on 2026-03-02 is 95.0. User C must see 80.0 and never 95.0.
  select value into strict v
    from public.body_metric_series(array['weight'], date '2026-03-02', date '2026-03-02');
  if v <> 80.0 then
    raise exception 'FAIL [9] user C sees % on 2026-03-02, expected its own 80.0', v;
  end if;

  select observation_count into strict n
    from public.body_metric_summary(array['weight'], date '2026-03-02', date '2026-03-09', 3);
  if n <> 3 then
    raise exception 'FAIL [9] user C counts % weight observations, expected its own 3', n;
  end if;

  raise notice 'PASS [9] the chart read model returns the caller''s own series and never another user''s';
end
$$;

commit;

-- The same functions, as the other user, on the same days: the values must be
-- the other user's, which proves the isolation above is RLS and not an empty set.
begin;
set local request.jwt.claims = :'claims_d';
set local role authenticated;

do $$
declare v numeric;
begin
  select value into strict v
    from public.body_metric_series(array['weight'], date '2026-03-02', date '2026-03-02');
  if v <> 95.0 then
    raise exception 'FAIL [9b] user D sees % on 2026-03-02, expected its own 95.0', v;
  end if;
  raise notice 'PASS [9b] the same call as a different user returns that user''s own series';
end
$$;

commit;

-- ---------------------------------------------------------------------------
-- 10. An anonymous caller reaches none of it.
-- ---------------------------------------------------------------------------

begin;
set local role anon;

do $$
begin
  begin
    perform * from public.body_metric_series(array['weight'], date '2026-03-02', date '2026-03-09');
    raise exception 'FAIL [10] the anon role could call body_metric_series';
  exception when insufficient_privilege then
    null;
  end;

  begin
    perform * from public.body_metric_summary(array['weight'], date '2026-03-02', date '2026-03-09', 3);
    raise exception 'FAIL [10] the anon role could call body_metric_summary';
  exception when insufficient_privilege then
    null;
  end;

  begin
    perform * from public.body_metric_bounds(array['weight']);
    raise exception 'FAIL [10] the anon role could call body_metric_bounds';
  exception when insufficient_privilege then
    null;
  end;

  raise notice 'PASS [10] an anonymous caller cannot reach the chart read model at all';
end
$$;

commit;
