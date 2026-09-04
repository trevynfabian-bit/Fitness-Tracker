-- ============================================================================
-- 10_pipeline_constraints.sql
-- Phase 2 exit criterion: "the schema supports a complete Hevy import pipeline
-- with no further schema changes required for the Hevy vertical slice.
-- Demonstrate by writing the pipeline's inserts as raw SQL against a sample
-- row and showing every constraint holds."
--
-- Part 1 walks one source row through the entire chain as raw SQL:
--   import_profiles -> data_imports -> import_jobs -> raw_records
--                   -> strength_workouts -> strength_exercises -> strength_sets
--
-- Part 2 attacks every constraint and invariant in turn and asserts each one
-- rejects what it is supposed to reject.
--
-- The sample row is a synthetic schema fixture used only by this test. It is
-- never seeded, never reaches the application, and is not health data. The
-- real anonymized export fixture arrives with the profile in Phase 3
-- (CLAUDE.md section 5).
--
-- These inserts run on a privileged connection because that is the context
-- normalization runs in. Client-role isolation is tested separately in
-- 20_rls_and_views.sql.
--
-- Run with: psql -v ON_ERROR_STOP=1 -f tests/phase2/10_pipeline_constraints.sql
-- ============================================================================

\set QUIET on
\set uid  '33333333-3333-4333-8333-333333333333'
\set uid2 '44444444-4444-4444-8444-444444444444'
\set QUIET off

insert into auth.users (id, email)
values (:'uid', 'phase2-a@pipeline-test.invalid'),
       (:'uid2', 'phase2-b@pipeline-test.invalid')
on conflict (id) do nothing;

-- ===========================================================================
-- PART 1 - the pipeline, as raw SQL
-- ===========================================================================

begin;

-- --- registry prerequisite: the exercise this row resolves to (I-6) --------
insert into public.exercise_definitions (user_id, key, display_name)
values (:'uid', 'barbell_bench_press', 'Barbell Bench Press');

insert into public.exercise_aliases (user_id, exercise_definition_id, alias, source_key)
select :'uid', id, 'Bench Press (Barbell)', 'sample_source'
  from public.exercise_definitions
 where user_id = :'uid' and key = 'barbell_bench_press';

-- User B's own registry row, so the cross-user tests below can isolate which
-- mechanism does the rejecting.
insert into public.exercise_definitions (user_id, key, display_name)
values (:'uid2', 'barbell_bench_press', 'Barbell Bench Press');

-- --- 1. import_profiles ----------------------------------------------------
-- A strength profile in full_snapshot mode, which is what makes the Phase 3
-- truncated-export gate meaningful. snapshot_scope is mandatory here.
insert into public.import_profiles
  (id, user_id, name, template, source_key, signature_hash, header_tokens,
   mapping_spec, import_mode, snapshot_scope)
values (
  '00000000-0000-4000-8000-000000000001'::uuid,
  :'uid',
  'Sample strength export',
  'strength',
  'sample_source',
  encode(sha256(convert_to('title|start_time|exercise_title|set_index|weight_kg|reps|rpe', 'UTF8')), 'hex'),
  array['title','start time','exercise title','set index','weight','reps','rpe'],
  '{"template":"strength","layout":"wide","timestamp":{"columns":["start_time"],"format":"yyyy-MM-dd HH:mm:ss","timezone":{"mode":"fixed","tz_name":"UTC"}},"constants":{"source_key":"sample_source"}}'::jsonb,
  'full_snapshot',
  '{"source_key":"sample_source","templates":["strength"],"date_range":"derive_from_file","metric_keys":null}'::jsonb
);

-- --- 2. data_imports -------------------------------------------------------
insert into public.data_imports
  (id, user_id, source_key, template, profile_id, storage_path, file_name,
   file_type, file_bytes, file_sha256, mapping_spec_snapshot, normalize_version,
   import_mode, status, raw_granularity, file_required, rows_total, imported_at)
select
  '00000000-0000-4000-8000-000000000002'::uuid,
  :'uid', 'sample_source', 'strength',
  p.id,
  :'uid' || '/00000000-0000-4000-8000-000000000002/sample.csv',
  'sample.csv', 'csv', 4096,
  encode(sha256(convert_to('sample-file-bytes', 'UTF8')), 'hex'),
  p.mapping_spec,          -- frozen copy, v2 section 3
  1,
  'full_snapshot', 'ingesting', 'row', false, 1,
  timestamptz '2026-02-14 19:00:00+00'
from public.import_profiles p
where p.id = '00000000-0000-4000-8000-000000000001'::uuid;

-- --- 3. import_jobs --------------------------------------------------------
insert into public.import_jobs (user_id, import_id, stage, state, cursor, heartbeat_at)
values (:'uid', '00000000-0000-4000-8000-000000000002'::uuid,
        'ingest', 'running', '{"last_row": 1}'::jsonb, now());

-- --- 4. raw_records: the sample source row, verbatim ----------------------
insert into public.raw_records
  (id, user_id, import_id, source_key, row_number, external_id, payload,
   row_hash, precedence_rank, granularity, normalize_status)
values (
  9000001,
  :'uid',
  '00000000-0000-4000-8000-000000000002'::uuid,
  'sample_source',
  1,
  'sample-workout-1',
  '{"title":"Evening Session","start_time":"2026-02-14 18:03:00","exercise_title":"Bench Press (Barbell)","set_index":"1","weight_kg":"60","reps":"8","rpe":"8"}'::jsonb,
  encode(sha256(convert_to('row-1-canonical-payload', 'UTF8')), 'hex'),
  0,
  'row',
  'pending'
);

-- --- 5. strength_workouts (natural key per v2 section 7.1 strategy A) ------
insert into public.strength_workouts
  (id, user_id, start_utc, tz_offset_minutes, local_date, duration_s, title,
   source_key, external_id, natural_key, raw_record_id, import_id)
values (
  '00000000-0000-4000-8000-000000000003'::uuid,
  :'uid',
  timestamptz '2026-02-14 18:03:00+00',
  0,
  date '2026-02-14',
  3600,
  'Evening Session',
  'sample_source',
  'sample-workout-1',
  encode(sha256(convert_to(
    concat_ws('|', :'uid', 'sample_source', 'strength', 'workout', 'sample-workout-1'), 'UTF8')), 'hex'),
  9000001,
  '00000000-0000-4000-8000-000000000002'::uuid
);

-- --- 6. strength_exercises (resolved to the registry, I-6) -----------------
insert into public.strength_exercises
  (id, user_id, workout_id, exercise_definition_id, exercise_name_raw,
   order_index, raw_record_id, import_id)
select
  '00000000-0000-4000-8000-000000000004'::uuid,
  :'uid',
  '00000000-0000-4000-8000-000000000003'::uuid,
  d.id,
  'Bench Press (Barbell)',
  0,
  9000001,
  '00000000-0000-4000-8000-000000000002'::uuid
from public.exercise_definitions d
where d.user_id = :'uid' and d.key = 'barbell_bench_press';

-- --- 7. strength_sets ------------------------------------------------------
insert into public.strength_sets
  (user_id, exercise_id, set_number, set_type, weight_kg, reps, rpe, natural_key, raw_record_id)
values (
  :'uid',
  '00000000-0000-4000-8000-000000000004'::uuid,
  1, 'working', 60.000000, 8, 8.00,
  encode(sha256(convert_to(
    concat_ws('|', :'uid', 'sample_source', 'strength', 'set', 'sample-workout-1', '0', '1'), 'UTF8')), 'hex'),
  9000001
);

-- --- 8. normalization write-back (the only permitted raw_records update) ---
update public.raw_records
   set processed_at      = now(),
       normalize_version = 1,
       normalize_status  = 'ok',
       normalized_keys   = array[
         (select natural_key from public.strength_workouts where id = '00000000-0000-4000-8000-000000000003'::uuid),
         (select natural_key from public.strength_sets where exercise_id = '00000000-0000-4000-8000-000000000004'::uuid)
       ]
 where id = 9000001;

-- --- 9. import_coverage ----------------------------------------------------
insert into public.import_coverage
  (user_id, import_id, template, metric_key, granularity, date_from, date_to,
   source_row_count, canonical_row_count)
values (:'uid', '00000000-0000-4000-8000-000000000002'::uuid, 'strength', null,
        'event', date '2026-02-14', date '2026-02-14', 1, 3);

commit;

do $$
declare
  w bigint; e bigint; s bigint; vol numeric; keys text[];
begin
  select count(*) into w from public.strength_workouts where user_id = '33333333-3333-4333-8333-333333333333';
  select count(*) into e from public.strength_exercises where user_id = '33333333-3333-4333-8333-333333333333';
  select count(*) into s from public.strength_sets where user_id = '33333333-3333-4333-8333-333333333333';
  if (w, e, s) is distinct from (1::bigint, 1::bigint, 1::bigint) then
    raise exception 'FAIL [P1] pipeline produced % workouts, % exercises, % sets; expected 1/1/1', w, e, s;
  end if;

  select volume_kg into vol from public.strength_sets where user_id = '33333333-3333-4333-8333-333333333333';
  if vol <> 480.000000 then
    raise exception 'FAIL [P1] generated volume_kg is %, expected 480.000000 (60 x 8)', vol;
  end if;

  select normalized_keys into keys from public.raw_records where id = 9000001;
  if array_length(keys, 1) <> 2 then
    raise exception 'FAIL [P1] normalized_keys holds % entries, expected 2', array_length(keys, 1);
  end if;

  raise notice 'PASS [P1] one source row traversed profile -> import -> job -> raw_record -> workout -> exercise -> set';
end
$$;

-- Provenance chain (PRD section 4.4, section 19): every canonical row reaches
-- its raw record, its import, and the original file path.
do $$
declare unreachable bigint;
begin
  select count(*) into unreachable
    from (
      select w.id from public.strength_workouts w
        join public.raw_records r on r.id = w.raw_record_id and r.user_id = w.user_id
        join public.data_imports i on i.id = r.import_id and i.user_id = r.user_id
       where i.storage_path is null
      union all
      select e.id from public.strength_exercises e
        join public.raw_records r on r.id = e.raw_record_id
        join public.data_imports i on i.id = r.import_id
       where i.storage_path is null
      union all
      select s.id::text::uuid from public.strength_sets s
        join public.raw_records r on r.id = s.raw_record_id
        join public.data_imports i on i.id = r.import_id
       where i.storage_path is null
    ) q;
  if unreachable <> 0 then
    raise exception 'FAIL [P2] % canonical rows do not reach an original file', unreachable;
  end if;
  raise notice 'PASS [P2] every canonical row traces to its raw record, import and original file';
end
$$;

-- ===========================================================================
-- PART 2 - every constraint holds
-- ===========================================================================

create or replace function pg_temp.rejects(stmt text, label text, expected_sqlstate text default null)
returns void
language plpgsql
as $$
declare
  got text;
begin
  begin
    execute stmt;
  exception when others then
    got := sqlstate;
    if expected_sqlstate is not null and got <> expected_sqlstate then
      raise exception 'FAIL [%] rejected with % but expected %', label, got, expected_sqlstate;
    end if;
    raise notice 'PASS [%] rejected (%)', label, got;
    return;
  end;
  raise exception 'FAIL [%] statement was ACCEPTED but must be rejected', label;
end;
$$;

-- --- I-2 append-only -------------------------------------------------------
select pg_temp.rejects(
  $q$ update public.raw_records set payload = '{"tampered":true}'::jsonb where id = 9000001 $q$,
  'I-2 payload update', '42501');

select pg_temp.rejects(
  $q$ update public.raw_records set precedence_rank = 20 where id = 9000001 $q$,
  'I-2 precedence_rank update', '42501');

select pg_temp.rejects(
  $q$ delete from public.raw_records where id = 9000001 $q$,
  'I-2 unannounced delete', '42501');

do $$
begin
  -- The write-back columns remain updatable.
  update public.raw_records set normalize_status = 'ok', normalize_error = null where id = 9000001;
  raise notice 'PASS [I-2 write-back] the five normalization columns remain updatable';
end
$$;

-- --- I-1 no canonical row without a raw record -----------------------------
select pg_temp.rejects(
  $q$ insert into public.strength_workouts
      (user_id, start_utc, tz_offset_minutes, local_date, source_key, natural_key, raw_record_id, import_id)
      values ('33333333-3333-4333-8333-333333333333', now(), 0, current_date, 'sample_source',
              'orphan-key-1', null, '00000000-0000-4000-8000-000000000002') $q$,
  'I-1 workout without raw_record_id', '23502');

select pg_temp.rejects(
  $q$ insert into public.strength_sets
      (user_id, exercise_id, set_number, natural_key, raw_record_id)
      values ('33333333-3333-4333-8333-333333333333',
              '00000000-0000-4000-8000-000000000004', 9, 'orphan-key-2', null) $q$,
  'I-1 set without raw_record_id', '23502');

-- --- I-6 no free-text identifiers ------------------------------------------
select pg_temp.rejects(
  $q$ insert into public.strength_exercises
      (user_id, workout_id, exercise_definition_id, exercise_name_raw, order_index, raw_record_id, import_id)
      values ('33333333-3333-4333-8333-333333333333',
              '00000000-0000-4000-8000-000000000003', null, 'Some Unregistered Lift', 5,
              9000001, '00000000-0000-4000-8000-000000000002') $q$,
  'I-6 exercise without a registry row', '23502');

-- --- cross-user integrity, enforced by composite foreign keys --------------
-- Composite foreign key: user B, holding its own registry row, still cannot
-- attach an exercise to user A's workout.
select pg_temp.rejects(
  $q$ insert into public.strength_exercises
      (user_id, workout_id, exercise_definition_id, exercise_name_raw, order_index, raw_record_id, import_id)
      select '44444444-4444-4444-8444-444444444444',
             '00000000-0000-4000-8000-000000000003', d.id, 'Bench Press (Barbell)', 7,
             9000001, '00000000-0000-4000-8000-000000000002'
        from public.exercise_definitions d
       where d.key = 'barbell_bench_press'
         and d.user_id = '44444444-4444-4444-8444-444444444444' $q$,
  'composite FK: exercise under another user''s workout', '23503');

-- Ownership trigger: user A's own workout, but a registry row owned by user B.
select pg_temp.rejects(
  $q$ insert into public.strength_exercises
      (user_id, workout_id, exercise_definition_id, exercise_name_raw, order_index, raw_record_id, import_id)
      select '33333333-3333-4333-8333-333333333333',
             '00000000-0000-4000-8000-000000000003', d.id, 'Bench Press (Barbell)', 8,
             9000001, '00000000-0000-4000-8000-000000000002'
        from public.exercise_definitions d
       where d.key = 'barbell_bench_press'
         and d.user_id = '44444444-4444-4444-8444-444444444444' $q$,
  'ownership trigger: exercise resolved to another user''s registry row', '42501');

select pg_temp.rejects(
  $q$ insert into public.raw_records (user_id, import_id, source_key, payload, row_hash)
      values ('44444444-4444-4444-8444-444444444444',
              '00000000-0000-4000-8000-000000000002', 'sample_source', '{}'::jsonb, 'x-hash-1') $q$,
  'cross-user raw record under another user''s import', '23503');

-- --- deduplication ---------------------------------------------------------
select pg_temp.rejects(
  $q$ insert into public.raw_records (user_id, import_id, source_key, payload, row_hash)
      select user_id, import_id, source_key, '{"different":"payload"}'::jsonb, row_hash
        from public.raw_records where id = 9000001 $q$,
  'intra-file duplicate (import_id, row_hash)', '23505');

select pg_temp.rejects(
  $q$ insert into public.strength_sets (user_id, exercise_id, set_number, natural_key, raw_record_id)
      select user_id, exercise_id, 2, natural_key, raw_record_id
        from public.strength_sets limit 1 $q$,
  'duplicate set natural_key', '23505');

select pg_temp.rejects(
  $q$ insert into public.strength_sets (user_id, exercise_id, set_number, natural_key, raw_record_id)
      select user_id, exercise_id, set_number, 'a-different-natural-key', raw_record_id
        from public.strength_sets limit 1 $q$,
  'duplicate (exercise_id, set_number)', '23505');

-- --- domain constraints ----------------------------------------------------
select pg_temp.rejects(
  $q$ update public.strength_sets set rpe = 11.00 $q$,
  'R5 rpe above the 0-10 domain', '23514');

select pg_temp.rejects(
  $q$ update public.strength_sets set set_type = 'superset' $q$,
  'set_type outside the allowed vocabulary', '23514');

select pg_temp.rejects(
  $q$ update public.strength_sets set reps = -1 $q$,
  'negative reps', '23514');

select pg_temp.rejects(
  $q$ update public.data_imports set status = 'nearly_done' $q$,
  'status outside the v3 section 4.1 lifecycle', '23514');

select pg_temp.rejects(
  $q$ update public.raw_records set normalize_status = 'maybe' where id = 9000001 $q$,
  'normalize_status outside the allowed vocabulary', '23514');

select pg_temp.rejects(
  $q$ insert into public.raw_records (user_id, import_id, source_key, payload, row_hash, precedence_rank)
      values ('33333333-3333-4333-8333-333333333333',
              '00000000-0000-4000-8000-000000000002', 'sample_source', '{}'::jsonb, 'h-prec', 5) $q$,
  'precedence_rank outside 0/10/20', '23514');

select pg_temp.rejects(
  $q$ insert into public.import_profiles
      (user_id, name, template, source_key, signature_hash, header_tokens, mapping_spec, import_mode)
      values ('33333333-3333-4333-8333-333333333333', 'No scope', 'strength', 'sample_source',
              'sig-2', array['a'], '{}'::jsonb, 'full_snapshot') $q$,
  'full_snapshot profile without snapshot_scope', '23514');

select pg_temp.rejects(
  $q$ insert into public.raw_records
      (user_id, import_id, source_key, payload, row_hash, granularity)
      values ('33333333-3333-4333-8333-333333333333',
              '00000000-0000-4000-8000-000000000002', 'sample_source', '{}'::jsonb, 'h-red', 'reduced') $q$,
  'reduced raw record without its bucket columns', '23514');

select pg_temp.rejects(
  $q$ update public.strength_workouts set retired_at = now() $q$,
  'retired_at without retired_by_import_id', '23514');

select pg_temp.rejects(
  $q$ update public.metric_definitions
        set plausibility_min = 500, plausibility_max = 10
      where user_id is null and key = 'weight' $q$,
  'R4 plausibility_min above plausibility_max', '23514');

-- --- I-4 enforced by privilege (RD-3) --------------------------------------
do $$
declare t text;
begin
  foreach t in array array['metrics','strength_workouts','strength_exercises','strength_sets'] loop
    if has_table_privilege('authenticated', 'public.' || t, 'UPDATE')
       or has_table_privilege('authenticated', 'public.' || t, 'DELETE')
       or has_table_privilege('authenticated', 'public.' || t, 'INSERT') then
      raise exception 'FAIL [I-4] the authenticated role can write public.%', t;
    end if;
    if not has_table_privilege('authenticated', 'public.' || t, 'SELECT') then
      raise exception 'FAIL [I-4] the authenticated role cannot read public.%', t;
    end if;
  end loop;
  raise notice 'PASS [I-4] authenticated holds SELECT and no write privilege on any canonical table';
end
$$;

-- --- I-7 / R5 / R7 storage precision ---------------------------------------
do $$
declare bad text;
begin
  select string_agg(table_name || '.' || column_name || ' ' || numeric_precision || ',' || numeric_scale, ', ')
    into bad
    from information_schema.columns c
   where table_schema = 'public'
     and data_type = 'numeric'
     -- Base tables only. Views inherit their columns' types.
     and exists (select 1 from information_schema.tables t
                  where t.table_schema = c.table_schema
                    and t.table_name = c.table_name
                    and t.table_type = 'BASE TABLE')
     and not (
       (numeric_precision, numeric_scale) = (18, 6)                                   -- I-7 measured values
       or (table_name = 'unit_conversions' and (numeric_precision, numeric_scale) = (30, 15))  -- R7 coefficients
       or (table_name = 'strength_sets' and column_name = 'rpe'
           and (numeric_precision, numeric_scale) = (4, 2))                            -- R5 domain exception
     );
  if bad is not null then
    raise exception 'FAIL [I-7] numeric columns outside the approved precision classes: %', bad;
  end if;

  if exists (select 1 from information_schema.columns c
              where table_schema = 'public' and data_type in ('real', 'double precision')
                and exists (select 1 from information_schema.tables t
                             where t.table_schema = c.table_schema
                               and t.table_name = c.table_name
                               and t.table_type = 'BASE TABLE')) then
    raise exception 'FAIL [I-7] a float column exists in the public schema';
  end if;

  raise notice 'PASS [I-7/R5/R7] every numeric column is 18,6 except unit_conversions 30,15 and strength_sets.rpe 4,2; no floats';
end
$$;

-- --- R3 retirement propagates through the views ----------------------------
do $$
declare vw bigint; ve bigint; vs bigint; te bigint; ts bigint;
begin
  update public.strength_workouts
     set retired_at = now(),
         retired_by_import_id = '00000000-0000-4000-8000-000000000002'::uuid
   where id = '00000000-0000-4000-8000-000000000003'::uuid;

  select count(*) into vw from public.v_strength_workouts;
  select count(*) into ve from public.v_strength_exercises;
  select count(*) into vs from public.v_strength_sets;
  select count(*) into te from public.strength_exercises;
  select count(*) into ts from public.strength_sets;

  if (vw, ve, vs) is distinct from (0::bigint, 0::bigint, 0::bigint) then
    raise exception 'FAIL [R3] after retiring the workout the views still show %/%/% workouts/exercises/sets', vw, ve, vs;
  end if;
  if (te, ts) is distinct from (1::bigint, 1::bigint) then
    raise exception 'FAIL [R3] retirement was not soft: base tables hold %/% exercises/sets', te, ts;
  end if;

  raise notice 'PASS [R3] retiring the workout hides its exercises and sets in the views, leaving no orphans; base rows survive';

  update public.strength_workouts
     set retired_at = null, retired_by_import_id = null
   where id = '00000000-0000-4000-8000-000000000003'::uuid;

  select count(*) into vs from public.v_strength_sets;
  if vs <> 1 then
    raise exception 'FAIL [R3] undo did not restore the set to v_strength_sets';
  end if;
  raise notice 'PASS [R3] undoing retirement restores the whole hierarchy (ADR-11)';
end
$$;

-- --- I-5 the views filter, the tables do not -------------------------------
do $$
declare t text; def text;
begin
  foreach t in array array['v_metrics','v_strength_workouts','v_strength_exercises','v_strength_sets'] loop
    select pg_get_viewdef(('public.' || t)::regclass) into def;
    if def !~* 'retired_at IS NULL' then
      raise exception 'FAIL [I-5] view public.% does not filter retired_at', t;
    end if;
    if not (select c.reloptions::text[] @> array['security_invoker=true']
              from pg_class c where c.oid = ('public.' || t)::regclass) then
      raise exception 'FAIL [I-5] view public.% is not security_invoker; it would bypass RLS', t;
    end if;
  end loop;
  raise notice 'PASS [I-5] all four canonical views filter retired_at and run security_invoker';
end
$$;

-- --- the two sanctioned deletion paths (I-2, v2 section 5.3) ---------------
do $$
declare remaining bigint;
begin
  -- Rollback deletes the import's raw records; canonical rows go with them
  -- through their restricting foreign keys, so they must be removed first.
  delete from public.strength_sets where raw_record_id = 9000001;
  delete from public.strength_exercises where raw_record_id = 9000001;
  delete from public.strength_workouts where raw_record_id = 9000001;

  perform set_config('app.raw_records_deletion_reason', 'import_rollback', true);
  delete from public.raw_records where id = 9000001;
  perform set_config('app.raw_records_deletion_reason', '', true);

  select count(*) into remaining from public.raw_records where id = 9000001;
  if remaining <> 0 then
    raise exception 'FAIL [I-2 rollback] the sanctioned deletion path did not delete';
  end if;
  raise notice 'PASS [I-2 rollback] an announced import_rollback may delete raw records';
end
$$;

\echo ''
\echo '================================================================'
\echo ' PHASE 2 PIPELINE AND CONSTRAINT SUITE: all assertions passed'
\echo '================================================================'
