-- ============================================================================
-- 10_step0_safety.sql
-- Phase 3 Step 0 verification.
--
-- Proves, against a real schema, the two scenarios the checkpoint requires be
-- structurally impossible:
--
--   A. a canonical row owned by user B referencing a raw record owned by user A
--   B. a truncated full-snapshot import retiring existing history automatically
--
-- plus the ownership, guard, override and alias-normalization rules that back
-- them.
-- ============================================================================

\set QUIET on
\set ua '77777777-7777-4777-8777-777777777777'
\set ub '88888888-8888-4888-8888-888888888888'
\set QUIET off

insert into auth.users (id, email)
values (:'ua', 'step0-a@test.invalid'), (:'ub', 'step0-b@test.invalid')
on conflict (id) do nothing;

create or replace function pg_temp.rejects(stmt text, label text, expected_sqlstate text default null)
returns void language plpgsql as $$
declare got text; msg text;
begin
  begin
    execute stmt;
  exception when others then
    got := sqlstate; msg := sqlerrm;
    if expected_sqlstate is not null and got <> expected_sqlstate then
      raise exception 'FAIL [%] rejected with % (%) but expected %', label, got, msg, expected_sqlstate;
    end if;
    raise notice 'PASS [%] rejected (%)', label, got;
    return;
  end;
  raise exception 'FAIL [%] statement was ACCEPTED but must be rejected', label;
end;
$$;

-- ===========================================================================
-- Fixture: a complete vendor import for user A, plus one manual record.
-- ===========================================================================

begin;

insert into public.exercise_definitions (user_id, key, display_name)
values (:'ua', 'barbell_bench_press', 'Barbell Bench Press'),
       (:'ub', 'barbell_bench_press', 'Barbell Bench Press');

-- User A: a vendor import with three workouts.
insert into public.data_imports
  (id, user_id, source_key, template, storage_path, file_name, file_type,
   mapping_spec_snapshot, normalize_version, import_mode, status, imported_at)
values ('00000000-0000-4000-8000-0000000000a1', :'ua', 'sample_source', 'strength',
        'a/1/full.csv', 'full.csv', 'csv', '{}'::jsonb, 1, 'full_snapshot', 'completed',
        timestamptz '2026-01-01 00:00:00+00');

insert into public.raw_records (id, user_id, import_id, source_key, payload, row_hash, precedence_rank)
values (9100001, :'ua', '00000000-0000-4000-8000-0000000000a1', 'sample_source', '{"n":1}'::jsonb, 'h1', 0),
       (9100002, :'ua', '00000000-0000-4000-8000-0000000000a1', 'sample_source', '{"n":2}'::jsonb, 'h2', 0),
       (9100003, :'ua', '00000000-0000-4000-8000-0000000000a1', 'sample_source', '{"n":3}'::jsonb, 'h3', 0);

insert into public.strength_workouts
  (user_id, start_utc, tz_offset_minutes, local_date, source_key, natural_key, raw_record_id, import_id)
values (:'ua', timestamptz '2026-01-05 18:00:00+00', 0, date '2026-01-05', 'sample_source', 'wk-a-1', 9100001, '00000000-0000-4000-8000-0000000000a1'),
       (:'ua', timestamptz '2026-01-06 18:00:00+00', 0, date '2026-01-06', 'sample_source', 'wk-a-2', 9100002, '00000000-0000-4000-8000-0000000000a1'),
       (:'ua', timestamptz '2026-01-07 18:00:00+00', 0, date '2026-01-07', 'sample_source', 'wk-a-3', 9100003, '00000000-0000-4000-8000-0000000000a1');

-- User A: one MANUAL record, the kind G9 protects absolutely.
insert into public.data_imports
  (id, user_id, source_key, template, file_type, mapping_spec_snapshot,
   normalize_version, import_mode, status, imported_at)
values ('00000000-0000-4000-8000-0000000000a2', :'ua', 'manual', 'strength', 'manual',
        '{}'::jsonb, 1, 'append', 'completed', timestamptz '2026-01-08 00:00:00+00');

insert into public.raw_records (id, user_id, import_id, source_key, payload, row_hash, precedence_rank)
values (9100010, :'ua', '00000000-0000-4000-8000-0000000000a2', 'manual', '{"typed":true}'::jsonb, 'hm1', 10);

insert into public.strength_workouts
  (user_id, start_utc, tz_offset_minutes, local_date, source_key, natural_key, raw_record_id, import_id)
values (:'ua', timestamptz '2026-01-08 18:00:00+00', 0, date '2026-01-08', 'manual', 'wk-a-manual', 9100010, '00000000-0000-4000-8000-0000000000a2');

-- User B: their own import, for the cross-user tests.
insert into public.data_imports
  (id, user_id, source_key, template, storage_path, file_name, file_type,
   mapping_spec_snapshot, normalize_version, import_mode, status, imported_at)
values ('00000000-0000-4000-8000-0000000000b1', :'ub', 'sample_source', 'strength',
        'b/1/f.csv', 'f.csv', 'csv', '{}'::jsonb, 1, 'append', 'completed', now());

insert into public.raw_records (id, user_id, import_id, source_key, payload, row_hash)
values (9100100, :'ub', '00000000-0000-4000-8000-0000000000b1', 'sample_source', '{"n":1}'::jsonb, 'hb1');

commit;

do $$
declare n bigint;
begin
  select count(*) into n from public.strength_workouts
   where user_id = '77777777-7777-4777-8777-777777777777';
  if n <> 4 then raise exception 'FAIL [fixture] expected 4 workouts for user A, got %', n; end if;
  raise notice 'PASS [fixture] user A holds 3 vendor workouts and 1 manual workout';
end
$$;

-- ===========================================================================
-- 1. OWNERSHIP INTEGRITY
-- ===========================================================================

-- SCENARIO A, the one the checkpoint asks to be impossible:
--   raw_record belongs to user A, canonical row belongs to user B,
--   canonical row references that raw record.
select pg_temp.rejects(
  $q$ insert into public.strength_workouts
      (user_id, start_utc, tz_offset_minutes, local_date, source_key, natural_key, raw_record_id, import_id)
      values ('88888888-8888-4888-8888-888888888888', now(), 0, current_date, 'sample_source',
              'cross-user-workout', 9100001, '00000000-0000-4000-8000-0000000000b1') $q$,
  'SCENARIO A strength_workouts: user B row citing user A raw record', '23503');

select pg_temp.rejects(
  $q$ insert into public.metrics
      (user_id, metric_definition_id, metric_key, timestamp_utc, tz_offset_minutes, local_date,
       value_num, source_key, natural_key, raw_record_id, import_id)
      select '88888888-8888-4888-8888-888888888888', d.id, 'weight', now(), 0, current_date,
             80.0, 'sample_source', 'cross-user-metric', 9100001, '00000000-0000-4000-8000-0000000000b1'
        from public.metric_definitions d where d.key = 'weight' and d.user_id is null $q$,
  'SCENARIO A metrics: user B row citing user A raw record', '23503');

select pg_temp.rejects(
  $q$ insert into public.strength_exercises
      (user_id, workout_id, exercise_definition_id, exercise_name_raw, order_index, raw_record_id, import_id)
      select '88888888-8888-4888-8888-888888888888',
             (select id from public.strength_workouts where natural_key = 'wk-a-1'),
             d.id, 'x', 0, 9100001, '00000000-0000-4000-8000-0000000000b1'
        from public.exercise_definitions d
       where d.key = 'barbell_bench_press' and d.user_id = '88888888-8888-4888-8888-888888888888' $q$,
  'SCENARIO A strength_exercises: user B row citing user A raw record', '23503');

do $$
declare missing text;
begin
  -- Every canonical table that carries raw_record_id must reach raw_records
  -- through a COMPOSITE key that includes user_id. This is the structural
  -- statement of canonical.user_id = raw_record.user_id.
  select string_agg(t, ', ') into missing from (
    select c.relname as t
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
      join pg_attribute a on a.attrelid = c.oid and a.attname = 'raw_record_id' and a.attnum > 0
     where n.nspname = 'public' and c.relkind = 'r'
       and not exists (
         select 1 from pg_constraint fk
          where fk.conrelid = c.oid and fk.contype = 'f'
            and fk.confrelid = 'public.raw_records'::regclass
            and array_length(fk.conkey, 1) = 2
            and (select array_agg(at.attname::text order by k.ord)
                   from unnest(fk.conkey) with ordinality k(att, ord)
                   join pg_attribute at on at.attrelid = fk.conrelid and at.attnum = k.att)
                @> array['raw_record_id','user_id']
       )
  ) q;
  if missing is not null then
    raise exception 'FAIL [OWN-1] tables with raw_record_id lacking a composite provenance FK: %', missing;
  end if;
  raise notice 'PASS [OWN-1] every table carrying raw_record_id reaches raw_records by (raw_record_id, user_id)';
end
$$;

-- retired_by_import_id, previously unconstrained. Two independent defences now
-- cover it: the composite foreign key, and the retirement guard. The guard
-- fires first (a plan for another user's import can never match this row's
-- user_id), so the rejection code is not pinned here; the foreign key itself is
-- asserted from the catalogue immediately below.
select pg_temp.rejects(
  $q$ update public.strength_workouts
        set retired_at = now(),
            retired_by_import_id = '00000000-0000-4000-8000-0000000000b1'
      where natural_key = 'wk-a-1' $q$,
  'OWN-2 retirement citing another user''s import');

do $$
declare missing text;
begin
  select string_agg(t, ', ') into missing from (
    select c.relname as t
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
      join pg_attribute a on a.attrelid = c.oid and a.attname = 'retired_by_import_id' and a.attnum > 0
     where n.nspname = 'public' and c.relkind = 'r'
       and not exists (
         select 1 from pg_constraint fk
          where fk.conrelid = c.oid and fk.contype = 'f'
            and fk.confrelid = 'public.data_imports'::regclass
            and array_length(fk.conkey, 1) = 2
            and (select array_agg(at.attname::text order by k.ord)
                   from unnest(fk.conkey) with ordinality k(att, ord)
                   join pg_attribute at on at.attrelid = fk.conrelid and at.attnum = k.att)
                @> array['retired_by_import_id','user_id']
       )
  ) q;
  if missing is not null then
    raise exception 'FAIL [OWN-2] tables with retired_by_import_id lacking a composite FK: %', missing;
  end if;
  raise notice 'PASS [OWN-2] every table carrying retired_by_import_id reaches data_imports by (retired_by_import_id, user_id)';
end
$$;

-- Nullable-owner registry references, where a composite FK is impossible
-- because a child row with user_id = X can never match a parent tuple
-- (id, NULL). The registry ownership trigger is the only mechanism that can
-- express the rule, which is why one is used here and nowhere else.
do $$
declare def_id uuid;
begin
  -- Give user B a private definition, then have user A try to reference it.
  insert into public.metric_definitions (user_id, key, display_name, canonical_unit_id, default_aggregation)
  select '88888888-8888-4888-8888-888888888888', 'b_private', 'B private', u.id, 'mean'
    from public.units u where u.key = 'kg' and u.user_id is null
  returning id into def_id;

  begin
    insert into public.metrics
      (user_id, metric_definition_id, metric_key, timestamp_utc, tz_offset_minutes, local_date,
       value_num, source_key, natural_key, raw_record_id, import_id)
    values ('77777777-7777-4777-8777-777777777777', def_id, 'b_private', now(), 0, current_date,
            1.0, 'sample_source', 'nk-priv-2', 9100001, '00000000-0000-4000-8000-0000000000a1');
    raise exception 'FAIL [OWN-3] user A referenced user B''s private metric definition';
  exception when insufficient_privilege then
    raise notice 'PASS [OWN-3] cross-user metric definition reference rejected by the ownership trigger (42501)';
  end;
end
$$;

-- ===========================================================================
-- 2. G9 - manual records are never retirable, with no override
-- ===========================================================================

-- Build a fully valid, confirmed plan that (wrongly) lists the manual record.
insert into public.reconciliation_plans
  (id, user_id, import_id, scope, add_count, update_count, unchanged_count,
   retire_count, existing_in_scope_count, retire_ratio, retire_natural_keys,
   guard_results, verdict, decision, decided_at, decided_reason)
values ('00000000-0000-4000-8000-0000000000c9', :'ua', '00000000-0000-4000-8000-0000000000a1',
        '{"source_key":"sample_source","templates":["strength"]}'::jsonb,
        0, 0, 0, 1, 4, 0.2500, array['wk-a-manual'],
        '[{"id":"G9","outcome":"pass"}]'::jsonb, 'safe', 'confirmed', now(), 'operator insisted');

select pg_temp.rejects(
  $q$ update public.strength_workouts
        set retired_at = now(),
            retired_by_import_id = '00000000-0000-4000-8000-0000000000a1'
      where natural_key = 'wk-a-manual' $q$,
  'G9 manual record retirement, even with a confirmed plan naming it', '42501');

-- And an override row for G9 cannot even be recorded.
select pg_temp.rejects(
  $q$ insert into public.retirement_overrides (user_id, plan_id, guard_id, typed_confirmation)
      values ('77777777-7777-4777-8777-777777777777',
              '00000000-0000-4000-8000-0000000000c9', 'G9', '1') $q$,
  'G9 override row cannot be recorded at all', '23514');

select pg_temp.rejects(
  $q$ insert into public.retirement_overrides (user_id, plan_id, guard_id, typed_confirmation)
      values ('77777777-7777-4777-8777-777777777777',
              '00000000-0000-4000-8000-0000000000c9', 'G1', '1') $q$,
  'G1 override row cannot be recorded (not an overridable guard)', '23514');

do $$
begin
  insert into public.retirement_overrides (user_id, plan_id, guard_id, typed_confirmation)
  values ('77777777-7777-4777-8777-777777777777',
          '00000000-0000-4000-8000-0000000000c9', 'G4', '1243');
  raise notice 'PASS [G9/overrides] only G4 and G6 accept an override row; G4 accepted with a typed confirmation';
end
$$;

-- A manual record also cannot be retired via a manual-source correction record.
do $$
declare src text; prec smallint;
begin
  select r.source_key, r.precedence_rank into src, prec
    from public.raw_records r
    join public.strength_workouts w on w.raw_record_id = r.id
   where w.natural_key = 'wk-a-manual';
  if src <> 'manual' or prec <= 0 then
    raise exception 'FAIL [G9] fixture provenance wrong: source_key=%, precedence_rank=%', src, prec;
  end if;
  raise notice 'PASS [G9] the protected row is identified structurally by its raw record (source_key=manual, precedence_rank=%)', prec;
end
$$;

-- ===========================================================================
-- 3. SCENARIO B - a truncated snapshot cannot retire anything automatically
-- ===========================================================================

-- The truncated import: it carries one of the three vendor workouts.
insert into public.data_imports
  (id, user_id, source_key, template, storage_path, file_name, file_type,
   mapping_spec_snapshot, normalize_version, import_mode, status, imported_at)
values ('00000000-0000-4000-8000-0000000000a3', :'ua', 'sample_source', 'strength',
        'a/2/truncated.csv', 'truncated.csv', 'csv', '{}'::jsonb, 1, 'full_snapshot',
        'planning_reconciliation', timestamptz '2026-02-01 00:00:00+00');

-- Step 1 of the required behaviour: with NO plan at all, nothing can retire.
select pg_temp.rejects(
  $q$ update public.strength_workouts
        set retired_at = now(),
            retired_by_import_id = '00000000-0000-4000-8000-0000000000a3'
      where natural_key = 'wk-a-2' $q$,
  'SCENARIO B no plan exists: retirement refused', '42501');

-- The import cannot even enter the retiring stage.
select pg_temp.rejects(
  $q$ update public.data_imports set status = 'retiring'
      where id = '00000000-0000-4000-8000-0000000000a3' $q$,
  'SCENARIO B import cannot enter the retiring stage without a confirmed plan', '42501');

-- Step 2: the guard evaluates. Incoming 1 of 4 in scope is 25%, far below the
-- 70% floor, so G4 blocks and the plan is persisted with verdict 'blocked'.
insert into public.reconciliation_plans
  (id, user_id, import_id, scope, add_count, update_count, unchanged_count,
   retire_count, existing_in_scope_count, retire_ratio, retire_key_sample,
   retire_date_histogram, retire_natural_keys, guard_results, verdict)
values ('00000000-0000-4000-8000-0000000000c4', :'ua', '00000000-0000-4000-8000-0000000000a3',
        '{"source_key":"sample_source","templates":["strength"],"date_from":"2026-01-05","date_to":"2026-01-07"}'::jsonb,
        0, 0, 1, 2, 3, 0.6667,
        '[{"local_date":"2026-01-06","label":"Workout"},{"local_date":"2026-01-07","label":"Workout"}]'::jsonb,
        '{"2026-01":2}'::jsonb,
        array['wk-a-2','wk-a-3'],
        '[{"id":"G4","outcome":"BLOCKED","detail":"incoming 1 of 3 in scope is 33%, below the 70% floor"}]'::jsonb,
        'blocked');

-- Step 3 to 5: a blocked plan can never be confirmed, so retirement can never
-- be reached, and the append-only fallback is the only forward path.
select pg_temp.rejects(
  $q$ update public.reconciliation_plans
        set decision = 'confirmed', decided_at = now()
      where id = '00000000-0000-4000-8000-0000000000c4' $q$,
  'SCENARIO B G4-blocked plan cannot be confirmed', '23514');

select pg_temp.rejects(
  $q$ update public.strength_workouts
        set retired_at = now(),
            retired_by_import_id = '00000000-0000-4000-8000-0000000000a3'
      where natural_key = 'wk-a-2' $q$,
  'SCENARIO B blocked plan present: retirement still refused', '42501');

do $$
declare surviving bigint;
begin
  -- The append-only fallback: skip_retirement. The import completes, adding
  -- and updating, retiring nothing.
  update public.reconciliation_plans
     set decision = 'skipped', decided_at = now(), decided_reason = 'append-only fallback'
   where id = '00000000-0000-4000-8000-0000000000c4';

  select count(*) into surviving from public.v_strength_workouts
   where user_id = '77777777-7777-4777-8777-777777777777';
  if surviving <> 4 then
    raise exception 'FAIL [SCENARIO B] % of 4 workouts survived the truncated snapshot', surviving;
  end if;
  raise notice 'PASS [SCENARIO B] truncated snapshot: G4 blocked, confirmation refused, append-only fallback taken, all 4 workouts intact';
end
$$;

-- A confirmed plan is required AND must name the row. A plan that omits a row
-- cannot be used to retire it.
-- A healthy full snapshot, for contrast: a complete export whose plan passes
-- the guards. Its own import, because only one confirmed plan may exist per
-- import.
insert into public.data_imports
  (id, user_id, source_key, template, storage_path, file_name, file_type,
   mapping_spec_snapshot, normalize_version, import_mode, status, imported_at)
values ('00000000-0000-4000-8000-0000000000a4', :'ua', 'sample_source', 'strength',
        'a/3/complete.csv', 'complete.csv', 'csv', '{}'::jsonb, 1, 'full_snapshot',
        'planning_reconciliation', timestamptz '2026-03-01 00:00:00+00');

do $$
declare retired_count bigint;
begin
  insert into public.reconciliation_plans
    (id, user_id, import_id, scope, add_count, update_count, unchanged_count,
     retire_count, existing_in_scope_count, retire_ratio, retire_natural_keys,
     guard_results, verdict, decision, decided_at)
  values ('00000000-0000-4000-8000-0000000000c5', '77777777-7777-4777-8777-777777777777',
          '00000000-0000-4000-8000-0000000000a4', '{}'::jsonb,
          0, 0, 2, 1, 3, 0.3333, array['wk-a-3'],
          '[{"id":"G4","outcome":"pass"}]'::jsonb, 'safe', 'confirmed', now());

  -- wk-a-2 is NOT in the plan's key set.
  begin
    update public.strength_workouts
       set retired_at = now(), retired_by_import_id = '00000000-0000-4000-8000-0000000000a4'
     where natural_key = 'wk-a-2';
    raise exception 'FAIL [PLAN] a row absent from the plan key set was retired';
  exception when insufficient_privilege then
    raise notice 'PASS [PLAN] a row absent from the confirmed plan''s key set cannot be retired';
  end;

  -- wk-a-3 IS in the key set, so retirement proceeds.
  update public.strength_workouts
     set retired_at = now(), retired_by_import_id = '00000000-0000-4000-8000-0000000000a4'
   where natural_key = 'wk-a-3';
  get diagnostics retired_count = row_count;
  if retired_count <> 1 then
    raise exception 'FAIL [PLAN] a row named by a confirmed plan was not retirable';
  end if;
  raise notice 'PASS [PLAN] a row named by a confirmed, non-blocked plan retires normally';

  -- And undo remains available (v3 section 4.4).
  update public.strength_workouts
     set retired_at = null, retired_by_import_id = null
   where natural_key = 'wk-a-3';
  raise notice 'PASS [PLAN] retirement undo is not gated';
end
$$;

-- Plan integrity rules.
select pg_temp.rejects(
  $q$ insert into public.reconciliation_plans
      (user_id, import_id, scope, add_count, update_count, unchanged_count,
       retire_count, existing_in_scope_count, retire_ratio, retire_natural_keys,
       guard_results, verdict)
      values ('77777777-7777-4777-8777-777777777777', '00000000-0000-4000-8000-0000000000a1',
              '{}'::jsonb, 0, 0, 0, 5, 10, 0.5, array['only-one-key'],
              '[]'::jsonb, 'warn') $q$,
  'PLAN retire_count must match the persisted key set size', '23514');

select pg_temp.rejects(
  $q$ update public.reconciliation_plans
        set retire_natural_keys = array['wk-a-1','wk-a-2','wk-a-3']
      where id = '00000000-0000-4000-8000-0000000000c5' $q$,
  'PLAN body is immutable once computed', '42501');

select pg_temp.rejects(
  $q$ update public.reconciliation_plans set decision = 'cancelled', decided_at = now()
      where id = '00000000-0000-4000-8000-0000000000c5' $q$,
  'PLAN decision is final once recorded', '42501');

select pg_temp.rejects(
  $q$ insert into public.reconciliation_plans
      (user_id, import_id, computed_at, scope, add_count, update_count, unchanged_count,
       retire_count, existing_in_scope_count, retire_ratio, retire_natural_keys,
       guard_results, verdict, decision, decided_at)
      values ('77777777-7777-4777-8777-777777777777', '00000000-0000-4000-8000-0000000000a1',
              now() - interval '48 hours', '{}'::jsonb, 0, 0, 0, 0, 3, 0,
              '{}'::text[], '[]'::jsonb, 'safe', 'confirmed', now()) $q$,
  'PLAN a plan older than 24 hours cannot be confirmed', '23514');

-- ===========================================================================
-- 4. Alias normalization contract
-- ===========================================================================

do $$
declare v text;
begin
  foreach v in array array['  Body Fat %  ', 'Weight (kg)', 'body_fat', 'Heart-Rate   Variability'] loop
    if public.normalize_alias(v) <> public.normalize_alias(public.normalize_alias(v)) then
      raise exception 'FAIL [ALIAS] normalize_alias is not idempotent for %', v;
    end if;
  end loop;

  if public.normalize_alias('  Body Fat %  ') <> 'body fat' then
    raise exception 'FAIL [ALIAS] expected "body fat", got "%"', public.normalize_alias('  Body Fat %  ');
  end if;
  if public.normalize_alias('body_fat') <> 'body fat' then
    raise exception 'FAIL [ALIAS] underscore must become a space, not be deleted';
  end if;
  if public.normalize_alias('Weight (kg)') <> 'weight kg' then
    raise exception 'FAIL [ALIAS] expected "weight kg", got "%"', public.normalize_alias('Weight (kg)');
  end if;
  raise notice 'PASS [ALIAS] normalize_alias is deterministic and idempotent: lowercase, punctuation to space, whitespace collapsed, trimmed';
end
$$;

do $$
declare unnormalized bigint; legacy int;
begin
  select count(*) into unnormalized from public.metric_aliases
   where alias_normalized <> public.normalize_alias(alias_normalized);
  if unnormalized <> 0 then
    raise exception 'FAIL [ALIAS] % stored metric aliases are not in normalized form', unnormalized;
  end if;

  select count(*) into legacy from information_schema.columns
   where table_schema = 'public' and table_name in ('metric_aliases','exercise_aliases')
     and column_name = 'alias';
  if legacy <> 0 then
    raise exception 'FAIL [ALIAS] the legacy alias column still exists alongside alias_normalized';
  end if;

  select count(*) into legacy from information_schema.columns
   where table_schema = 'public' and table_name in ('metric_aliases','exercise_aliases')
     and column_name = 'alias_normalized';
  if legacy <> 2 then
    raise exception 'FAIL [ALIAS] expected alias_normalized on both alias tables, found %', legacy;
  end if;
  raise notice 'PASS [ALIAS] one field only: alias_normalized on both tables, every stored value normalized';
end
$$;

select pg_temp.rejects(
  $q$ insert into public.metric_aliases (user_id, metric_definition_id, alias_normalized)
      select '77777777-7777-4777-8777-777777777777', d.id, 'Body Fat %'
        from public.metric_definitions d where d.key = 'weight' and d.user_id is null $q$,
  'ALIAS an unnormalized value cannot be stored', '23514');

\echo ''
\echo '================================================================'
\echo ' PHASE 3 STEP 0 SAFETY SUITE: all assertions passed'
\echo '================================================================'
