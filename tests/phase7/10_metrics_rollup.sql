-- ============================================================================
-- 10_metrics_rollup.sql
-- Phase 7, part 1: the metrics rollup domain.
--
-- The claim Phase 7 has to earn is the whole path, not the last step of it:
--
--   a body measurement reaches canonical metrics
--     -> the day it landed on is identified as dirty
--     -> the metrics domain scope is enqueued
--     -> the worker dispatches on the domain and recomputes
--     -> metric_daily_source and metric_daily equal canonical truth
--     -> retired observations contribute nothing
--     -> precedence picks one source per metric per day
--     -> repeating any of it changes nothing
--     -> and NEITHER domain deletes the other's rows
--
-- Every assertion computes the canonical answer and the derived answer and
-- compares them. Canonical rows are created only through the sanctioned write
-- path: a real data_import, a real raw_record, then import_upsert_metric.
-- Nothing here inserts into metrics or into metric_daily directly.
-- ============================================================================

\set QUIET on
\set uid_a '77777777-7777-4777-8777-777777777777'
\set uid_b '78787878-7878-4787-8787-787878787878'
\set claims_a '{"sub":"77777777-7777-4777-8777-777777777777","role":"authenticated"}'
\set claims_b '{"sub":"78787878-7878-4787-8787-787878787878","role":"authenticated"}'
\set QUIET off

insert into auth.users (id, email) values
  (:'uid_a', 'phase7-a@test.invalid'), (:'uid_b', 'phase7-b@test.invalid')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 0. The registry partitions metric_daily between the two domains.
--
-- This is what makes the cross-domain deletes safe, so it is asserted before
-- anything runs. Exhaustive (no key is unowned) and disjoint (no key is owned
-- twice) are both properties of the column, not of a list written here.
-- ---------------------------------------------------------------------------

do $$
declare total int; training int; metrics_n int;
begin
  select count(*) into total from public.metric_definitions where user_id is null;
  select count(*) into training from public.rollup_domain_metric_keys('training');
  select count(*) into metrics_n from public.rollup_domain_metric_keys('metrics');

  if training + metrics_n <> total then
    raise exception 'FAIL [0] the two rollup domains cover % of % system metrics; the partition is not exhaustive',
      training + metrics_n, total;
  end if;
  if exists (
    select public.rollup_domain_metric_keys('training')
    intersect
    select public.rollup_domain_metric_keys('metrics')
  ) then
    raise exception 'FAIL [0] a metric key belongs to both rollup domains';
  end if;

  -- The six metrics Phase 7 charts must be in the metrics domain, or the
  -- metrics recompute will not produce them.
  if exists (
    select 1 from unnest(array['weight','body_fat_percentage','waist_circumference',
                               'resting_heart_rate','heart_rate_variability','sleep_duration']) k
     where k not in (select public.rollup_domain_metric_keys('metrics'))
  ) then
    raise exception 'FAIL [0] a Phase 7 chart metric is not in the metrics rollup domain';
  end if;

  -- And every training aggregate must be in the training domain, or the
  -- training recompute will stop deleting rows it is about to rewrite.
  if exists (
    select 1 from public.metric_definitions
     where user_id is null and key like 'training\_%' and rollup_domain <> 'training'
  ) then
    raise exception 'FAIL [0] a training aggregate is not in the training rollup domain';
  end if;

  raise notice 'PASS [0] % system metrics partition into % training and % metrics, exhaustively and disjointly',
    total, training, metrics_n;
end
$$;

-- ---------------------------------------------------------------------------
-- 0b. Fixture helpers: the sanctioned canonical write paths, nothing else.
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

create function pg_temp.file_import(p_user uuid, p_source text, p_tag text)
returns uuid language plpgsql as $$
declare imp uuid;
begin
  insert into public.data_imports
    (user_id, source_key, template, storage_path, file_name, file_type,
     mapping_spec_snapshot, normalize_version, import_mode, status, imported_at)
  values (p_user, p_source, 'metrics', p_user::text || '/p7/' || p_tag, p_tag, 'csv',
          '{}'::jsonb, 1, 'append', 'completed', now())
  returning id into imp;
  return imp;
end $$;

/**
 * One observation, recorded the way the application records one: a raw record
 * at the given precedence rank, then the sanctioned upsert. Returns the
 * upsert's verdict so a test can assert what actually happened rather than
 * assuming.
 */
create function pg_temp.observe(
  p_user uuid, p_import uuid, p_natural_key text, p_metric text,
  p_value numeric, p_at timestamptz, p_source text default 'manual',
  p_precedence smallint default 10::smallint, p_supersedes text default null
) returns public.upsert_outcome language plpgsql as $$
declare rr bigint; def record; outcome public.upsert_outcome;
begin
  insert into public.raw_records
    (user_id, import_id, source_key, payload, row_hash, precedence_rank, supersedes_natural_key)
  values (p_user, p_import, p_source,
          jsonb_build_object('metric_key', p_metric, 'value', p_value::text,
                             'measured_at', p_at::text),
          md5(p_natural_key || p_value::text || p_source), p_precedence, p_supersedes)
  returning id into rr;

  select d.id, d.key, d.canonical_unit_id into def
    from public.metric_definitions d
   where d.key = p_metric and d.user_id is null;

  outcome := public.import_upsert_metric(
    p_user, p_natural_key, def.id, def.key, null,
    p_at, 0, null, (p_at at time zone 'UTC')::date,
    p_value, def.canonical_unit_id, null,
    p_source, p_value, null, rr, p_import);

  return outcome;
end $$;

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

/** A stable fingerprint of the metrics grain for one user. */
create function pg_temp.metrics_fingerprint(p_user uuid) returns text
language sql stable as $$
  select md5(coalesce(string_agg(x, '|' order by x), 'empty'))
  from (
    select 'm:' || m.metric_key || ':' || m.local_date || ':' || m.value || ':'
           || m.count || ':' || m.winning_source || ':' || m.source_count as x
      from public.metric_daily m
     where m.user_id = p_user
       and m.metric_key in (select public.rollup_domain_metric_keys('metrics'))
    union all
    select 's:' || s.metric_key || ':' || s.source_key || ':' || s.local_date || ':'
           || coalesce(s.avg::text, '-') || ':' || coalesce(s.sum::text, '-') || ':'
           || s.count || ':' || array_to_string(s.contributing_metric_ids, ',')
      from public.metric_daily_source s
     where s.user_id = p_user
       and s.metric_key in (select public.rollup_domain_metric_keys('metrics'))
  ) q;
$$;

/** The whole training grain for one user, so cross-domain damage is visible. */
create function pg_temp.training_fingerprint(p_user uuid) returns text
language sql stable as $$
  select md5(coalesce(string_agg(x, '|' order by x), 'empty'))
  from (
    select 'm:' || m.metric_key || ':' || m.local_date || ':' || m.value || ':'
           || m.count || ':' || m.winning_source as x
      from public.metric_daily m
     where m.user_id = p_user
       and m.metric_key in (select public.rollup_domain_metric_keys('training'))
    union all
    select 'e:' || e.exercise_definition_id || ':' || e.local_date || ':'
           || e.session_count || ':' || e.set_count
      from public.exercise_daily e where e.user_id = p_user
  ) q;
$$;

-- ---------------------------------------------------------------------------
-- 1. Fixture.
--
--   User A records weight on four days, twice on one of them, plus body fat,
--   HRV and sleep. 2026-06-03 carries two weight readings from two sources so
--   precedence has something real to resolve. User A also TRAINS on
--   2026-06-01, which is also a weight day: that overlap is what makes the
--   cross-domain isolation test meaningful rather than vacuous.
--
--   User B records its own weight so every isolation assertion has real data
--   to fail against rather than an empty set that passes trivially.
-- ---------------------------------------------------------------------------

do $$
declare
  u        uuid := '77777777-7777-4777-8777-777777777777';
  manual   uuid;
  scale    uuid;
  timp     uuid;
  rr       bigint;
  squat    uuid;
  w        uuid;
begin
  manual := pg_temp.manual_import(u, 'p7-a-manual');
  scale  := pg_temp.file_import(u, 'withings', 'p7-a-scale.csv');

  -- Weight, one reading a day, except 06-03 which has two sources.
  perform pg_temp.observe(u, manual, 'p7-a-w-0601', 'weight', 82.4, timestamptz '2026-06-01 07:00:00+00');
  perform pg_temp.observe(u, manual, 'p7-a-w-0603', 'weight', 82.0, timestamptz '2026-06-03 07:00:00+00');
  perform pg_temp.observe(u, scale,  'p7-a-w-0603-scale', 'weight', 83.9,
                          timestamptz '2026-06-03 06:30:00+00', 'withings', 0::smallint);
  perform pg_temp.observe(u, manual, 'p7-a-w-0607', 'weight', 81.6, timestamptz '2026-06-07 07:00:00+00');

  -- 06-05 is observed by the scale and by nothing else. Retiring it later must
  -- remove the day entirely rather than leave a zero, and it can be retired
  -- because it came from a file: G9 makes manual records permanently
  -- unretirable and has no override.
  perform pg_temp.observe(u, scale, 'p7-a-w-0605-scale', 'weight', 82.2,
                          timestamptz '2026-06-05 06:30:00+00', 'withings', 0::smallint);
  perform pg_temp.observe(u, manual, 'p7-a-w-0610', 'weight', 81.2, timestamptz '2026-06-10 07:00:00+00');

  -- Two weight readings on one day from ONE source: the mean is what
  -- default_aggregation names, and it must not be the sum.
  perform pg_temp.observe(u, manual, 'p7-a-w-0610-pm', 'weight', 81.8,
                          timestamptz '2026-06-10 19:00:00+00');

  -- Body fat: three readings, enough to clear the observation gate.
  perform pg_temp.observe(u, manual, 'p7-a-bf-0601', 'body_fat_percentage', 18.5,
                          timestamptz '2026-06-01 07:00:00+00');
  perform pg_temp.observe(u, manual, 'p7-a-bf-0607', 'body_fat_percentage', 18.1,
                          timestamptz '2026-06-07 07:00:00+00');
  perform pg_temp.observe(u, manual, 'p7-a-bf-0610', 'body_fat_percentage', 17.9,
                          timestamptz '2026-06-10 07:00:00+00');

  -- HRV: two readings only. Deliberately below the gate.
  perform pg_temp.observe(u, manual, 'p7-a-hrv-0601', 'heart_rate_variability', 62,
                          timestamptz '2026-06-01 07:00:00+00');
  perform pg_temp.observe(u, manual, 'p7-a-hrv-0603', 'heart_rate_variability', 58,
                          timestamptz '2026-06-03 07:00:00+00');

  -- Sleep: default_aggregation is 'sum', so two segments on one night must add.
  perform pg_temp.observe(u, manual, 'p7-a-sl-0601a', 'sleep_duration', 380,
                          timestamptz '2026-06-01 06:00:00+00');
  perform pg_temp.observe(u, manual, 'p7-a-sl-0601b', 'sleep_duration', 45,
                          timestamptz '2026-06-01 14:00:00+00');

  -- Training on 2026-06-01, the same day as a weight reading.
  insert into public.exercise_definitions (user_id, key, display_name)
  values (u, 'back_squat', 'Back Squat') returning id into squat;

  timp := pg_temp.file_import(u, 'hevy', 'p7-a-hevy.csv');
  update public.data_imports set template = 'strength' where id = timp;
  insert into public.raw_records (user_id, import_id, source_key, payload, row_hash)
  values (u, timp, 'hevy', '{"fixture":"p7-a-training"}'::jsonb, 'p7-training-a')
  returning id into rr;

  w := pg_temp.add_workout(u, rr, timp, 'p7-a-w1', date '2026-06-01', 'Legs', 3600);
  perform public.import_upsert_strength_set(
    u, 'p7-a-s1',
    public.import_upsert_strength_exercise(u, w, squat, 'Back Squat', 0, rr, timp),
    1, 'working', 100, 5, null, null, null, rr);
end
$$;

do $$
declare
  u      uuid := '78787878-7878-4787-8787-787878787878';
  manual uuid;
begin
  manual := pg_temp.manual_import(u, 'p7-b-manual');
  perform pg_temp.observe(u, manual, 'p7-b-w-0601', 'weight', 71.0, timestamptz '2026-06-01 07:00:00+00');
  perform pg_temp.observe(u, manual, 'p7-b-w-0603', 'weight', 70.8, timestamptz '2026-06-03 07:00:00+00');
  perform pg_temp.observe(u, manual, 'p7-b-w-0607', 'weight', 70.5, timestamptz '2026-06-07 07:00:00+00');
end
$$;

-- ---------------------------------------------------------------------------
-- 2. A new observation invalidates exactly the day it landed on.
--
-- The enqueue is asserted for the days that changed AND against the days that
-- did not: "everything is dirty" would pass a test that only checked the first.
-- ---------------------------------------------------------------------------

do $$
declare
  u uuid := '77777777-7777-4777-8777-777777777777';
  n int;
  queued int;
begin
  queued := public.rollup_enqueue_metric_days(
    u,
    (select array_agg(distinct m.local_date) from public.v_metrics m where m.user_id = u),
    'import');

  select count(*) into n from public.rollup_queue q
   where q.user_id = u and q.domain = 'metrics' and q.state = 'pending';
  if n <> 5 then
    raise exception 'FAIL [2] % metrics scopes pending, expected the 5 days observations landed on', n;
  end if;

  if exists (
    select 1 from public.rollup_queue q
     where q.user_id = u and q.domain = 'metrics'
       and q.local_date not in (date '2026-06-01', date '2026-06-03', date '2026-06-05',
                                date '2026-06-07', date '2026-06-10')
  ) then
    raise exception 'FAIL [2] a day with no observation was enqueued';
  end if;

  -- Idempotent: enqueuing the same scopes again adds nothing.
  if public.rollup_enqueue_metric_days(u, array[date '2026-06-01', date '2026-06-03'], 'import') <> 0 then
    raise exception 'FAIL [2] re-enqueuing a pending scope created a duplicate';
  end if;

  raise notice 'PASS [2] % metric days enqueued, exactly the days observations landed on, and re-enqueuing is free', queued;
end
$$;

-- ---------------------------------------------------------------------------
-- 3. The worker dispatches on the domain and the values equal canonical truth.
-- ---------------------------------------------------------------------------

do $$
declare
  u        uuid := '77777777-7777-4777-8777-777777777777';
  result   jsonb;
  v        numeric;
  expected numeric;
  n        int;
begin
  -- Both domains are queued so the dispatch is exercised in one drain.
  perform public.rollup_enqueue_training_days(u, array[date '2026-06-01'], 'import');

  result := public.rollup_process_pending(50, 'phase7');
  if (result ->> 'failed')::int <> 0 then
    raise exception 'FAIL [3] the drain reported failures: %', result ->> 'errors';
  end if;
  if (result ->> 'processed')::int <> 6 then
    raise exception 'FAIL [3] the drain processed % scopes, expected 6 (5 metrics + 1 training)',
      result ->> 'processed';
  end if;

  -- default_aggregation 'mean': two readings on 06-10 must average, not sum.
  select value into strict v from public.metric_daily
   where user_id = u and metric_key = 'weight' and local_date = date '2026-06-10';
  select avg(m.value_num) into expected from public.v_metrics m
   where m.user_id = u and m.metric_key = 'weight' and m.local_date = date '2026-06-10'
     and m.source_key = 'manual';
  if v is distinct from expected then
    raise exception 'FAIL [3] weight on 2026-06-10 is % but canonical mean is %', v, expected;
  end if;
  if v > 82 then
    raise exception 'FAIL [3] weight on 2026-06-10 is %, which is a sum and not a mean', v;
  end if;

  -- default_aggregation 'sum': two sleep segments must add.
  select value into strict v from public.metric_daily
   where user_id = u and metric_key = 'sleep_duration' and local_date = date '2026-06-01';
  if v <> 425 then
    raise exception 'FAIL [3] sleep_duration on 2026-06-01 is %, expected 425 (380 + 45)', v;
  end if;

  -- Every metric_daily row equals the canonical aggregate of its winning source.
  for v in
    select md.value
      from public.metric_daily md
      join public.metric_definitions d on d.key = md.metric_key and d.user_id is null
     where md.user_id = u and d.rollup_domain = 'metrics'
       and md.value is distinct from (
         select case d.default_aggregation
                  when 'mean' then avg(m.value_num)
                  when 'sum'  then sum(m.value_num)
                  when 'min'  then min(m.value_num)
                  when 'max'  then max(m.value_num)
                end
           from public.v_metrics m
          where m.user_id = md.user_id and m.metric_key = md.metric_key
            and m.local_date = md.local_date and m.source_key = md.winning_source
            and m.is_derived = false and m.value_num is not null)
  loop
    raise exception 'FAIL [3] a metric_daily value (%) does not equal its canonical aggregate', v;
  end loop;

  -- Provenance: every tier-1 row names the canonical rows behind it.
  select count(*) into n from public.metric_daily_source s
   where s.user_id = u
     and s.metric_key in (select public.rollup_domain_metric_keys('metrics'))
     and (s.contributing_metric_ids = '{}' or s.count <> array_length(s.contributing_metric_ids, 1));
  if n > 0 then
    raise exception 'FAIL [3] % tier-1 metrics rows carry no or mismatched provenance', n;
  end if;

  raise notice 'PASS [3] the drain dispatched both domains; every metrics value equals its canonical aggregate and carries provenance';
end
$$;

-- ---------------------------------------------------------------------------
-- 4. CROSS-DOMAIN ISOLATION — the regression test for the bug Phase 7 fixed.
--
-- 2026-06-01 carries BOTH a training session and body measurements. Before
-- this migration, rollup_recompute_training_day deleted every metric_daily row
-- for the day regardless of which domain owned it. Recomputing either domain
-- must now leave the other's rows byte-identical.
-- ---------------------------------------------------------------------------

do $$
declare
  u            uuid := '77777777-7777-4777-8777-777777777777';
  metrics_before  text;
  metrics_after   text;
  training_before text;
  training_after  text;
  body_rows    int;
  train_rows   int;
begin
  select count(*) into body_rows from public.metric_daily
   where user_id = u and local_date = date '2026-06-01'
     and metric_key in (select public.rollup_domain_metric_keys('metrics'));
  select count(*) into train_rows from public.metric_daily
   where user_id = u and local_date = date '2026-06-01'
     and metric_key in (select public.rollup_domain_metric_keys('training'));

  -- The test is only meaningful if the day really does carry both.
  if body_rows = 0 or train_rows = 0 then
    raise exception 'FAIL [4] 2026-06-01 carries % body and % training rows; the isolation test would be vacuous',
      body_rows, train_rows;
  end if;

  -- A training recompute must not touch the metrics domain.
  metrics_before := pg_temp.metrics_fingerprint(u);
  perform public.rollup_recompute_training_day(u, date '2026-06-01');
  metrics_after := pg_temp.metrics_fingerprint(u);
  if metrics_before <> metrics_after then
    raise exception 'FAIL [4] a training recompute changed the metrics grain (% -> %)',
      metrics_before, metrics_after;
  end if;
  if (select count(*) from public.metric_daily
       where user_id = u and local_date = date '2026-06-01'
         and metric_key in (select public.rollup_domain_metric_keys('metrics'))) <> body_rows then
    raise exception 'FAIL [4] a training recompute deleted body measurements from a shared day';
  end if;

  -- And a metrics recompute must not touch the training domain.
  training_before := pg_temp.training_fingerprint(u);
  perform public.rollup_recompute_metrics_day(u, date '2026-06-01');
  training_after := pg_temp.training_fingerprint(u);
  if training_before <> training_after then
    raise exception 'FAIL [4] a metrics recompute changed the training grain (% -> %)',
      training_before, training_after;
  end if;
  if (select count(*) from public.metric_daily
       where user_id = u and local_date = date '2026-06-01'
         and metric_key in (select public.rollup_domain_metric_keys('training'))) <> train_rows then
    raise exception 'FAIL [4] a metrics recompute deleted training aggregates from a shared day';
  end if;

  raise notice 'PASS [4] 2026-06-01 carries % body and % training rows; neither domain''s recompute disturbs the other',
    body_rows, train_rows;
end
$$;

-- ---------------------------------------------------------------------------
-- 5. Source precedence resolves, and changing it changes the winner.
--
-- 2026-06-03 has manual 82.0 and withings 83.9. With no preference recorded
-- the tiebreak is alphabetical, so 'manual' wins. Recording a preference for
-- withings must move the value on the next recompute and only then.
-- ---------------------------------------------------------------------------

do $$
declare
  u uuid := '77777777-7777-4777-8777-777777777777';
  v numeric; src text; sources int;
begin
  select value, winning_source, source_count into strict v, src, sources
    from public.metric_daily
   where user_id = u and metric_key = 'weight' and local_date = date '2026-06-03';

  if sources <> 2 then
    raise exception 'FAIL [5] 2026-06-03 resolved % sources, expected 2', sources;
  end if;
  if src <> 'manual' or v <> 82.0 then
    raise exception 'FAIL [5] with no preference recorded the winner is % at %, expected manual at 82.0', src, v;
  end if;

  insert into public.source_precedence (user_id, metric_key, source_key, priority)
  values (u, 'weight', 'withings', 1), (u, 'weight', 'manual', 2);

  -- Stored data must not move until the scope is recomputed: a preference is a
  -- setting, and derived rows change when the rollup runs, not when a row in
  -- another table does.
  select value into strict v from public.metric_daily
   where user_id = u and metric_key = 'weight' and local_date = date '2026-06-03';
  if v <> 82.0 then
    raise exception 'FAIL [5] the stored value moved before any recompute ran';
  end if;

  perform public.rollup_recompute_metrics_day(u, date '2026-06-03');

  select value, winning_source into strict v, src from public.metric_daily
   where user_id = u and metric_key = 'weight' and local_date = date '2026-06-03';
  if src <> 'withings' or v <> 83.9 then
    raise exception 'FAIL [5] after the preference the winner is % at %, expected withings at 83.9', src, v;
  end if;

  -- Put it back so later assertions read the original series.
  delete from public.source_precedence where user_id = u and metric_key = 'weight';
  perform public.rollup_recompute_metrics_day(u, date '2026-06-03');
  select winning_source into strict src from public.metric_daily
   where user_id = u and metric_key = 'weight' and local_date = date '2026-06-03';
  if src <> 'manual' then
    raise exception 'FAIL [5] removing the preference did not restore the alphabetical winner';
  end if;

  raise notice 'PASS [5] two sources coexist in tier 1; precedence picks one in tier 2, and only a recompute moves it';
end
$$;

-- ---------------------------------------------------------------------------
-- 6. A correction moves the value, and invalidates its own day.
--
-- The correction is a superseding raw record at a higher precedence rank, per
-- Phase 6. What Phase 7 has to add is that the analytics layer follows it.
-- ---------------------------------------------------------------------------

do $$
declare
  u   uuid := '77777777-7777-4777-8777-777777777777';
  imp uuid;
  o   public.upsert_outcome;
  v   numeric;
  n   int;
begin
  imp := pg_temp.manual_import(u, 'p7-a-correction');

  o := pg_temp.observe(u, imp, 'p7-a-w-0607', 'weight', 80.9,
                       timestamptz '2026-06-07 07:00:00+00', 'manual',
                       20::smallint, 'p7-a-w-0607');
  if o <> 'updated' then
    raise exception 'FAIL [6] the correction reported %, expected updated', o;
  end if;

  n := public.rollup_enqueue_metric_days(
         u,
         (select array_agg(distinct m.local_date) from public.v_metrics m
           where m.user_id = u and m.natural_key = 'p7-a-w-0607'),
         'import');
  if n <> 1 then
    raise exception 'FAIL [6] the correction enqueued % scopes, expected 1', n;
  end if;
  if not exists (
    select 1 from public.rollup_queue
     where user_id = u and domain = 'metrics'
       and local_date = date '2026-06-07' and state = 'pending'
  ) then
    raise exception 'FAIL [6] the correction did not mark 2026-06-07 dirty';
  end if;

  -- And no OTHER day was marked dirty by it.
  if (select count(*) from public.rollup_queue
       where user_id = u and domain = 'metrics' and state = 'pending') <> 1 then
    raise exception 'FAIL [6] the correction marked days other than its own dirty';
  end if;

  perform public.rollup_process_pending(50, 'phase7');

  select value into strict v from public.metric_daily
   where user_id = u and metric_key = 'weight' and local_date = date '2026-06-07';
  if v <> 80.9 then
    raise exception 'FAIL [6] after the correction the daily value is %, expected 80.9', v;
  end if;

  raise notice 'PASS [6] a correction invalidates only its own day, and the daily value follows it to 80.9';
end
$$;

-- ---------------------------------------------------------------------------
-- 7. Retired observations contribute nothing.
--
-- Retirement goes through the real lifecycle: a persisted, confirmed
-- reconciliation plan, then the column. The database's own I-10 guard has to
-- permit it, and G9 refuses outright for a manual record — which is why the
-- rows retired here are the ones that came from a file. That guard is not
-- worked around; it is the reason this fixture has a second source at all.
--
-- The recompute reads v_metrics, so the derived value moves without the
-- recompute knowing anything about retirement.
-- ---------------------------------------------------------------------------

do $$
declare
  u      uuid := '77777777-7777-4777-8777-777777777777';
  imp    uuid;
  before numeric;
  after_ numeric;
  n      int;
  src    text;
  retired int;
begin
  select id into strict imp from public.data_imports
   where user_id = u and file_name = 'p7-a-scale.csv';

  select value, source_count into strict before, n from public.metric_daily
   where user_id = u and metric_key = 'weight' and local_date = date '2026-06-03';
  if n <> 2 then
    raise exception 'FAIL [7] 2026-06-03 has % sources before retirement, expected 2', n;
  end if;

  insert into public.reconciliation_plans
    (user_id, import_id, scope, add_count, update_count, unchanged_count, retire_count,
     existing_in_scope_count, retire_ratio, retire_natural_keys, guard_results, verdict,
     decision, decided_at)
  values (u, imp, '{"template":"metrics"}'::jsonb, 0, 0, 1, 2, 3, 0.6667,
          array['p7-a-w-0603-scale', 'p7-a-w-0605-scale'], '[]'::jsonb, 'safe',
          'confirmed', now());

  update public.metrics
     set retired_at = now(), retired_by_import_id = imp
   where user_id = u and natural_key in ('p7-a-w-0603-scale', 'p7-a-w-0605-scale')
     and retired_at is null;
  get diagnostics retired = row_count;
  if retired <> 2 then
    raise exception 'FAIL [7] the sanctioned retirement affected % rows, expected 2', retired;
  end if;

  -- Nothing has been recomputed, so the stale figures are still there. ADR-19
  -- accepts that eventual consistency, and asserting it makes the next step a
  -- real test rather than a coincidence.
  select source_count into strict n from public.metric_daily
   where user_id = u and metric_key = 'weight' and local_date = date '2026-06-03';
  if n <> 2 then
    raise exception 'FAIL [7] the derived row changed before any recomputation ran';
  end if;

  perform public.rollup_enqueue_metric_days(
    u, array[date '2026-06-03', date '2026-06-05'], 'retirement');
  perform public.rollup_process_pending(50, 'phase7');

  -- 06-03 keeps its manual reading and loses the retired source.
  select value, source_count, winning_source into strict after_, n, src
    from public.metric_daily
   where user_id = u and metric_key = 'weight' and local_date = date '2026-06-03';
  if n <> 1 or src <> 'manual' or after_ <> 82.0 then
    raise exception 'FAIL [7] after retirement 2026-06-03 resolved % source(s) to % at %, expected 1 manual at 82.0',
      n, src, after_;
  end if;
  if exists (
    select 1 from public.metric_daily_source
     where user_id = u and metric_key = 'weight'
       and local_date = date '2026-06-03' and source_key = 'withings'
  ) then
    raise exception 'FAIL [7] a retired source still holds a tier-1 row';
  end if;

  -- 06-05 was observed by that source and nothing else, so the day goes away.
  -- metric_daily stores only days that have observations; it must not become a
  -- stored zero.
  if exists (
    select 1 from public.metric_daily
     where user_id = u and metric_key = 'weight' and local_date = date '2026-06-05'
  ) then
    raise exception 'FAIL [7] a fully retired metric-day still has a stored row';
  end if;

  -- And no retired canonical row is named in provenance any more.
  if exists (
    select 1 from public.metric_daily_source s
      join public.metrics m on m.id = any (s.contributing_metric_ids)
     where s.user_id = u and m.retired_at is not null
  ) then
    raise exception 'FAIL [7] a retired observation is still named in derived provenance';
  end if;

  raise notice 'PASS [7] retired observations stop contributing, a fully retired day stores no row, and no retired row remains in provenance';
end
$$;

-- G9 is absolute: a manual observation cannot be retired even with a confirmed
-- plan naming it. Asserted here because the analytics layer's correctness
-- depends on it — a manual correction that could be retired would be a
-- canonical value with no way back.
do $$
declare
  u   uuid := '77777777-7777-4777-8777-777777777777';
  imp uuid;
begin
  select id into strict imp from public.data_imports
   where user_id = u and file_name = 'p7-a-manual' limit 1;

  insert into public.reconciliation_plans
    (user_id, import_id, scope, add_count, update_count, unchanged_count, retire_count,
     existing_in_scope_count, retire_ratio, retire_natural_keys, guard_results, verdict,
     decision, decided_at)
  values (u, imp, '{"template":"metrics"}'::jsonb, 0, 0, 0, 1, 1, 1.0,
          array['p7-a-w-0601'], '[]'::jsonb, 'safe', 'confirmed', now());

  begin
    update public.metrics
       set retired_at = now(), retired_by_import_id = imp
     where user_id = u and natural_key = 'p7-a-w-0601';
    raise exception 'FAIL [7b] a manual observation was retired; G9 has no override';
  -- G9 raises with SQLSTATE 42501, pinned so a refusal for some other reason
  -- would not read as a pass.
  exception when insufficient_privilege then
    if sqlerrm not like '%G9%' then
      raise exception 'FAIL [7b] the retirement was refused for the wrong reason: %', sqlerrm;
    end if;
  end;

  raise notice 'PASS [7b] G9 refuses to retire a manual observation even under a confirmed plan naming it';
end
$$;

-- ---------------------------------------------------------------------------
-- 8. Idempotence and disposability.
--
-- Recomputing every scope repeatedly must not change a single value, and
-- truncating the derived tables and rebuilding must reproduce them exactly.
-- ---------------------------------------------------------------------------

do $$
declare
  u      uuid := '77777777-7777-4777-8777-777777777777';
  before text;
  after_ text;
  d      date;
begin
  before := pg_temp.metrics_fingerprint(u);

  for d in select distinct local_date from public.v_metrics where user_id = u loop
    perform public.rollup_recompute_metrics_day(u, d);
    perform public.rollup_recompute_metrics_day(u, d);
  end loop;

  after_ := pg_temp.metrics_fingerprint(u);
  if before <> after_ then
    raise exception 'FAIL [8] recomputing every scope twice changed the values (% -> %)', before, after_;
  end if;

  -- Disposable: destroy the derived layer entirely and rebuild it from
  -- canonical truth through the ordinary queue.
  delete from public.metric_daily where user_id = u;
  delete from public.metric_daily_source where user_id = u;
  delete from public.exercise_daily where user_id = u;
  delete from public.exercise_daily_source where user_id = u;
  delete from public.rollup_queue where user_id = u;

  perform public.rollup_rebuild_user(u);
  perform public.rollup_process_pending(200, 'phase7-rebuild');

  after_ := pg_temp.metrics_fingerprint(u);
  if before <> after_ then
    raise exception 'FAIL [8] a full rebuild did not reproduce the derived layer (% -> %)', before, after_;
  end if;

  raise notice 'PASS [8] recomputation is idempotent and the derived layer is reproducible from canonical truth';
end
$$;

-- ---------------------------------------------------------------------------
-- 9. rollup_rebuild_user covers BOTH domains.
--
-- The rebuild above deleted the training grain too. If rebuild_user only
-- enqueued training days, or only metric days, one grain would have come back
-- empty and section 8 would still have passed on the metrics fingerprint alone.
-- ---------------------------------------------------------------------------

do $$
declare
  u uuid := '77777777-7777-4777-8777-777777777777';
  t int; m int;
begin
  select count(*) into t from public.metric_daily
   where user_id = u and metric_key in (select public.rollup_domain_metric_keys('training'));
  select count(*) into m from public.metric_daily
   where user_id = u and metric_key in (select public.rollup_domain_metric_keys('metrics'));

  if t = 0 then
    raise exception 'FAIL [9] the rebuild restored no training rows; rollup_rebuild_user misses a domain';
  end if;
  if m = 0 then
    raise exception 'FAIL [9] the rebuild restored no metrics rows; rollup_rebuild_user misses a domain';
  end if;
  if (select count(*) from public.exercise_daily where user_id = u) = 0 then
    raise exception 'FAIL [9] the rebuild restored no exercise grain';
  end if;

  raise notice 'PASS [9] one rebuild call restored both domains: % training and % metrics rows', t, m;
end
$$;

-- ---------------------------------------------------------------------------
-- 10. An unknown domain fails loudly and is never marked done.
--
-- The check constraint makes an unknown domain unenqueueable, which is the
-- first line of defence. This proves the second: if a row ever reached the
-- queue anyway, the worker refuses it rather than claiming it, marking it done
-- and computing nothing. The constraint is dropped inside a transaction that
-- rolls back, so nothing here outlives the test.
-- ---------------------------------------------------------------------------

begin;

do $$
declare
  u      uuid := '77777777-7777-4777-8777-777777777777';
  id_    bigint;
  result jsonb;
  state_ text;
  err    text;
begin
  -- First: the constraint really does refuse an unknown domain.
  begin
    insert into public.rollup_queue (user_id, domain, local_date, reason)
    values (u, 'sleep_sessions', date '2026-06-01', 'import');
    raise exception 'FAIL [10] rollup_queue accepted an unrecognised domain';
  exception when check_violation then
    null;
  end;

  -- Then: with the constraint out of the way, the worker still refuses it.
  alter table public.rollup_queue drop constraint rollup_queue_domain_allowed;
  insert into public.rollup_queue (user_id, domain, local_date, reason)
  values (u, 'sleep_sessions', date '2026-06-01', 'import')
  returning id into id_;

  result := public.rollup_process_pending(10, 'phase7-unknown');

  select state, last_error into strict state_, err
    from public.rollup_queue where id = id_;

  if state_ = 'done' then
    raise exception 'FAIL [10] a scope naming an unknown domain was marked done without being computed';
  end if;
  if err is null or err not like '%has no recompute function%' then
    raise exception 'FAIL [10] the unknown domain did not record its own reason; last_error was %', err;
  end if;
  if (result ->> 'failed')::int < 1 then
    raise exception 'FAIL [10] the drain did not report the unknown domain as a failure';
  end if;
  if not (result -> 'errors')::text like '%sleep_sessions%' then
    raise exception 'FAIL [10] the returned errors do not name the offending domain';
  end if;

  raise notice 'PASS [10] an unknown domain is rejected by the constraint, and refused loudly by the worker if it ever got past it';
end
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 10b. The inline drain takes one user's scopes and nobody else's.
--
-- Manual entry drains inline so a typed measurement is on the chart when the
-- page comes back, and that runs inside the person's own request. The queue is
-- global, so an unscoped drain there would make one typed number wait on every
-- other user's import backlog. This asserts the scoping, not the speed: after
-- a user-scoped drain, the other user's scopes are still exactly where they
-- were.
-- ---------------------------------------------------------------------------

do $$
declare
  ua     uuid := '77777777-7777-4777-8777-777777777777';
  ub     uuid := '78787878-7878-4787-8787-787878787878';
  result jsonb;
  b_pending_before int;
  b_pending_after  int;
  a_pending_after  int;
begin
  -- Both users have dirty scopes waiting.
  perform public.rollup_enqueue_metric_days(
    ua, (select array_agg(distinct m.local_date) from public.v_metrics m where m.user_id = ua), 'rebuild');
  perform public.rollup_enqueue_metric_days(
    ub, (select array_agg(distinct m.local_date) from public.v_metrics m where m.user_id = ub), 'rebuild');

  select count(*) into b_pending_before from public.rollup_queue
   where user_id = ub and state = 'pending';
  if b_pending_before = 0 then
    raise exception 'FAIL [10b] user B has no pending scopes; the scoping test would be vacuous';
  end if;

  result := public.rollup_process_user_pending(ua, 200, 'phase7-inline');

  select count(*) into a_pending_after from public.rollup_queue
   where user_id = ua and state = 'pending';
  select count(*) into b_pending_after from public.rollup_queue
   where user_id = ub and state = 'pending';

  if a_pending_after <> 0 then
    raise exception 'FAIL [10b] a user-scoped drain left % of its own scopes pending', a_pending_after;
  end if;
  if b_pending_after <> b_pending_before then
    raise exception 'FAIL [10b] a drain scoped to user A consumed % of user B''s scopes',
      b_pending_before - b_pending_after;
  end if;
  if (result ->> 'failed')::int <> 0 then
    raise exception 'FAIL [10b] the inline drain reported failures: %', result ->> 'errors';
  end if;

  -- And the unscoped drain still takes everything, which is what the cron
  -- worker relies on.
  result := public.rollup_process_pending(200, 'phase7-cron');
  if (select count(*) from public.rollup_queue where state = 'pending') <> 0 then
    raise exception 'FAIL [10b] the unscoped drain left scopes pending';
  end if;

  raise notice 'PASS [10b] a user-scoped drain takes only that user''s % scopes; the unscoped drain still takes every one',
    b_pending_before;
end
$$;

-- ---------------------------------------------------------------------------
-- 11. Isolation: one user's observations never reach another's series.
--
-- Asserted at the database, through a real authenticated session rather than
-- the elevated connection, because that is the boundary that matters.
-- ---------------------------------------------------------------------------

do $$
declare a int; b int;
begin
  -- User B's own scopes, through the ordinary queue. Until now only A has been
  -- rolled up, and an isolation test against an empty table passes trivially.
  perform public.rollup_rebuild_user('78787878-7878-4787-8787-787878787878');
  perform public.rollup_process_pending(200, 'phase7-b');

  select count(*) into a from public.metric_daily
   where user_id = '77777777-7777-4777-8777-777777777777' and metric_key = 'weight';
  select count(*) into b from public.metric_daily
   where user_id = '78787878-7878-4787-8787-787878787878' and metric_key = 'weight';
  if a = 0 or b = 0 then
    raise exception 'FAIL [11] both users must have weight rows for isolation to be testable (a=%, b=%)', a, b;
  end if;
  raise notice 'PASS [11] both users hold weight rows (% and %); the session assertions below have something to fail against', a, b;
end
$$;

begin;
set local request.jwt.claims = :'claims_a';
set local role authenticated;

do $$
declare n int;
begin
  select count(*) into n from public.metric_daily;
  if n = 0 then
    raise exception 'FAIL [11] user A cannot see its own derived rows';
  end if;
  if exists (select 1 from public.metric_daily
              where user_id <> '77777777-7777-4777-8777-777777777777') then
    raise exception 'FAIL [11] user A can read another user''s metric_daily rows';
  end if;
  if exists (select 1 from public.metric_daily_source
              where user_id <> '77777777-7777-4777-8777-777777777777') then
    raise exception 'FAIL [11] user A can read another user''s metric_daily_source rows';
  end if;
  raise notice 'PASS [11] an authenticated session reads its own % derived rows and no others', n;
end
$$;

commit;

-- ---------------------------------------------------------------------------
-- 12. The security surface of the new functions.
--
-- EXECUTE defaults to PUBLIC, so a revoke from anon alone leaves a function
-- callable by the anon key. Every write-side function must be closed to both
-- client roles; the read model must be open to authenticated and closed to
-- anon.
-- ---------------------------------------------------------------------------

do $$
declare r record; bad text[] := '{}';
begin
  for r in
    select * from (values
      ('rollup_recompute_metrics_day(uuid, date)',            false, false),
      ('rollup_recompute_training_day(uuid, date)',           false, false),
      ('rollup_enqueue_days(uuid, date[], text, text)',       false, false),
      ('rollup_enqueue_metric_days(uuid, date[], text)',      false, false),
      ('rollup_enqueue_training_days(uuid, date[], text)',    false, false),
      ('rollup_rebuild_user(uuid)',                           false, false),
      ('rollup_process_scopes(integer, text, uuid)',           false, false),
      ('rollup_process_pending(integer, text)',                false, false),
      ('rollup_process_user_pending(uuid, integer, text)',     false, false),
      ('body_metric_series(text[], date, date)',              true,  false),
      ('body_metric_summary(text[], date, date, integer)',    true,  false),
      ('body_metric_bounds(text[])',                          true,  false),
      ('rollup_domain_metric_keys(text)',                     true,  false)
    ) as v (sig, want_authenticated, want_anon)
  loop
    if has_function_privilege('authenticated', r.sig, 'execute') <> r.want_authenticated then
      bad := bad || (r.sig || ' authenticated');
    end if;
    if has_function_privilege('anon', r.sig, 'execute') <> r.want_anon then
      bad := bad || (r.sig || ' anon');
    end if;
  end loop;

  if array_length(bad, 1) > 0 then
    raise exception 'FAIL [12] function privileges are wrong for: %', array_to_string(bad, ', ');
  end if;
  raise notice 'PASS [12] the rollup write path is closed to both client roles; the chart read model is open to authenticated only';
end
$$;

-- ---------------------------------------------------------------------------
-- 13. The chart layer never reads canonical metrics.
--
-- Asserted from the catalogue rather than by reading the code, so it stays
-- true when the function bodies change.
-- ---------------------------------------------------------------------------

do $$
declare r record;
begin
  for r in
    select p.proname, pg_get_functiondef(p.oid) as body
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname like 'body_metric%'
  loop
    if r.body ~* '\mpublic\.(v_)?metrics\M' then
      raise exception 'FAIL [13] % reads canonical metrics; charts must read metric_daily only', r.proname;
    end if;
    if r.body !~* '\mpublic\.metric_daily\M' then
      raise exception 'FAIL [13] % does not read metric_daily', r.proname;
    end if;
  end loop;
  raise notice 'PASS [13] every chart read-model function reads metric_daily and none reads canonical metrics';
end
$$;
