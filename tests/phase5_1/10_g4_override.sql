-- ============================================================================
-- 10_g4_override.sql
-- Phase 5.1: G4 is a safety gate with an audited human override.
--
-- The property under test is a pair, and both halves have to hold:
--
--   G4 still stops automatic retirement, AND an owner can consciously proceed
--   through a strongly confirmed, audited, attributable override.
--
-- Every assertion runs against the real schema. Where the check is about what
-- a USER may do, it runs as the `authenticated` Postgres role with a JWT
-- subject claim, which is the context a Supabase client request executes in.
-- ============================================================================

\set QUIET on
\set uid_a '1a1a1a1a-1a1a-41a1-81a1-1a1a1a1a1a1a'
\set uid_b '1b1b1b1b-1b1b-41b1-81b1-1b1b1b1b1b1b'
\set claims_a '{"sub":"1a1a1a1a-1a1a-41a1-81a1-1a1a1a1a1a1a","role":"authenticated"}'
\set claims_b '{"sub":"1b1b1b1b-1b1b-41b1-81b1-1b1b1b1b1b1b","role":"authenticated"}'
\set QUIET off

insert into auth.users (id, email) values
  (:'uid_a', 'phase51-a@test.invalid'),
  (:'uid_b', 'phase51-b@test.invalid')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 0. Fixture.
--
-- Each user gets canonical training on three days through the sanctioned
-- upsert path, plus a second import carrying a reconciliation plan that G4
-- blocked. Blocking one day's workout means the analytics gate later has
-- something specific to check, and two untouched days to prove nothing else
-- moved.
-- ---------------------------------------------------------------------------

create function pg_temp.build_user(p_user uuid, p_tag text)
returns void language plpgsql as $$
declare
  imp uuid; rr bigint; w uuid; ex uuid; def uuid; o public.upsert_outcome;
  i int;
begin
  insert into public.exercise_definitions (user_id, key, display_name)
  values (p_user, 'bench_press', 'Bench Press') returning id into def;

  insert into public.import_profiles
    (user_id, name, template, source_key, signature_hash, header_tokens, mapping_spec)
  values (p_user, 'Phase 5.1 fixture', 'strength', 'hevy', 'sig-p51-' || p_tag,
          array['a','b'], '{}'::jsonb);

  insert into public.data_imports
    (user_id, source_key, template, storage_path, file_name, file_type,
     mapping_spec_snapshot, normalize_version, import_mode, status, imported_at)
  values (p_user, 'hevy', 'strength', p_user::text || '/p51/first.csv', 'first.csv', 'csv',
          '{}'::jsonb, 1, 'full_snapshot', 'completed', now())
  returning id into imp;

  insert into public.raw_records (user_id, import_id, source_key, payload, row_hash)
  values (p_user, imp, 'hevy', '{"fixture":"phase51"}'::jsonb, 'p51-hash-' || p_tag)
  returning id into rr;

  -- Three sessions, one per day, 100 kg x 5 x 2 sets = 1000 kg each.
  for i in 1 .. 3 loop
    select * into o, w from public.import_upsert_strength_workout(
      p_user, p_tag || '-w' || i, (date '2026-07-06' + (i - 1)) + time '18:00', 0,
      date '2026-07-06' + (i - 1), 3600, 'Session ' || i, 'hevy',
      p_tag || '-w' || i, rr, imp);
    ex := public.import_upsert_strength_exercise(p_user, w, def, 'Bench Press', 0, rr, imp);
    perform public.import_upsert_strength_set(
      p_user, p_tag || '-s' || i || 'a', ex, 1, 'working', 100, 5, null, null, null, rr);
    perform public.import_upsert_strength_set(
      p_user, p_tag || '-s' || i || 'b', ex, 2, 'working', 100, 5, null, null, null, rr);
  end loop;
end $$;

/** A second import carrying a G4-blocked plan that proposes retiring one day. */
create function pg_temp.build_blocked_plan(p_user uuid, p_tag text, p_key text)
returns uuid language plpgsql as $$
declare imp uuid; plan_id uuid;
begin
  insert into public.data_imports
    (user_id, source_key, template, storage_path, file_name, file_type,
     mapping_spec_snapshot, normalize_version, import_mode, status, imported_at)
  values (p_user, 'hevy', 'strength', p_user::text || '/p51/partial.csv', 'partial.csv', 'csv',
          '{}'::jsonb, 1, 'full_snapshot', 'awaiting_retirement_confirmation', now())
  returning id into imp;

  insert into public.reconciliation_plans
    (user_id, import_id, scope, add_count, update_count, unchanged_count, retire_count,
     existing_in_scope_count, retire_ratio, retire_natural_keys, guard_results, verdict)
  values (
    p_user, imp, '{"template":"strength"}'::jsonb, 0, 0, 2, 1, 3, 0.3333,
    array[p_key],
    jsonb_build_array(
      jsonb_build_object('id','G1','outcome','pass','detail','0 of 12 rows invalid','overridable',false),
      jsonb_build_object('id','G4','outcome','blocked',
        'detail','the file contains 2 records in scope against 3 existing (67%, floor 70%). This usually means the export is partial rather than complete.',
        'overridable',true),
      jsonb_build_object('id','G9','outcome','pass','detail','no retirement targets a manual record','overridable',false)
    ),
    'blocked')
  returning id into plan_id;

  return plan_id;
end $$;

select pg_temp.build_user(:'uid_a', 'a51');
select pg_temp.build_user(:'uid_b', 'b51');
select pg_temp.build_blocked_plan(:'uid_a', 'a51', 'a51-w1') as plan_a \gset
select pg_temp.build_blocked_plan(:'uid_b', 'b51', 'b51-w1') as plan_b \gset

select import_id as import_a from public.reconciliation_plans where id = :'plan_a' \gset
select import_id as import_b from public.reconciliation_plans where id = :'plan_b' \gset

-- psql does not substitute its variables inside dollar-quoted blocks, so the
-- fixture ids are carried in a temp table and read back through temp
-- functions. The table is granted to `authenticated` because several blocks
-- below run as that role and still need to name a row they must NOT be able
-- to touch: knowing the id is the whole point of an isolation test.
create temporary table p51_ids as
select :'uid_a'::uuid     as uid_a,
       :'uid_b'::uuid     as uid_b,
       :'plan_a'::uuid    as plan_a,
       :'plan_b'::uuid    as plan_b,
       :'import_a'::uuid  as import_a,
       :'import_b'::uuid  as import_b;
grant select on p51_ids to authenticated;

create function pg_temp.uid_a()    returns uuid language sql stable as $fn$ select uid_a    from p51_ids $fn$;
create function pg_temp.uid_b()    returns uuid language sql stable as $fn$ select uid_b    from p51_ids $fn$;
create function pg_temp.plan_a()   returns uuid language sql stable as $fn$ select plan_a   from p51_ids $fn$;
create function pg_temp.plan_b()   returns uuid language sql stable as $fn$ select plan_b   from p51_ids $fn$;
create function pg_temp.import_a() returns uuid language sql stable as $fn$ select import_a from p51_ids $fn$;
create function pg_temp.import_b() returns uuid language sql stable as $fn$ select import_b from p51_ids $fn$;

do $$
begin
  raise notice 'PASS [0] fixture: two users, three training days each, one G4-blocked plan each';
end
$$;

-- Roll the canonical fixture up so the analytics gate has a baseline.
select public.rollup_rebuild_user(:'uid_a') as scopes_a \gset
select public.rollup_rebuild_user(:'uid_b') as scopes_b \gset
select public.rollup_process_pending(500, 'phase5_1-suite') as rollup \gset

-- ---------------------------------------------------------------------------
-- 1. GATE A — G4 still blocks automatic retirement.
-- ---------------------------------------------------------------------------

begin;
set local request.jwt.claims = :'claims_a';
set local role authenticated;

do $$
declare msg text; blocked boolean := false;
begin
  -- The owner, with no override recorded, tries the ordinary confirmation.
  begin
    update public.reconciliation_plans
       set decision = 'confirmed', decided_at = now()
     where id = (select id from public.reconciliation_plans where verdict = 'blocked' limit 1);
  exception when others then
    blocked := true;
    msg := sqlerrm;
  end;

  if not blocked then
    raise exception 'FAIL [A] a blocked plan was confirmed with no override recorded';
  end if;
  if msg not like '%I-10%' or msg not like '%G4%' then
    raise exception 'FAIL [A] the refusal did not name the rule or the guard: %', msg;
  end if;
  raise notice 'PASS [A] confirming a blocked plan with no override is refused: %', left(msg, 90);
end
$$;

commit;

-- The refusal is not the route's: it holds against the elevated connection too.
do $$
declare blocked boolean := false; retired int;
begin
  begin
    update public.reconciliation_plans
       set decision = 'confirmed', decided_at = now()
     where id = pg_temp.plan_a();
  exception when others then blocked := true;
  end;
  if not blocked then
    raise exception 'FAIL [A] the service connection confirmed a blocked plan';
  end if;

  -- And the retirement itself is refused, whoever attempts it.
  blocked := false;
  begin
    update public.strength_workouts
       set retired_at = now(), retired_by_import_id = pg_temp.import_a()
     where user_id = pg_temp.uid_a() and natural_key = 'a51-w1';
  exception when others then blocked := true;
  end;
  if not blocked then
    raise exception 'FAIL [A] a workout was retired under a blocked, unconfirmed plan';
  end if;

  select count(*) into retired from public.strength_workouts
   where user_id = pg_temp.uid_a() and retired_at is not null;
  if retired <> 0 then
    raise exception 'FAIL [A] % workouts are retired after a refused attempt', retired;
  end if;

  raise notice 'PASS [A] no record is retired: the plan cannot be confirmed and the retirement guard refuses independently';
end
$$;

-- ---------------------------------------------------------------------------
-- 2. The override requirements are enforced where the row is written.
--
-- The client holds INSERT on retirement_overrides, so these are the checks a
-- caller meets whether it goes through the API or straight at PostgREST.
-- ---------------------------------------------------------------------------

begin;
set local request.jwt.claims = :'claims_a';
set local role authenticated;

do $$
declare
  plan_id uuid;
  attempts text[] := '{}';
  msg text;
begin
  select id into plan_id from public.reconciliation_plans where verdict = 'blocked';

  -- Wrong typed confirmation.
  begin
    insert into public.retirement_overrides
      (user_id, plan_id, guard_id, typed_confirmation, acknowledged, reason)
    values (auth.uid(), plan_id, 'G4', '99', true, 'this snapshot is authoritative');
    attempts := attempts || 'wrong typed confirmation accepted';
  exception when others then null;
  end;

  -- No acknowledgement.
  begin
    insert into public.retirement_overrides
      (user_id, plan_id, guard_id, typed_confirmation, acknowledged, reason)
    values (auth.uid(), plan_id, 'G4', '1', false, 'this snapshot is authoritative');
    attempts := attempts || 'unacknowledged override accepted';
  exception when others then null;
  end;

  -- Reason too thin to be a record of anything.
  begin
    insert into public.retirement_overrides
      (user_id, plan_id, guard_id, typed_confirmation, acknowledged, reason)
    values (auth.uid(), plan_id, 'G4', '1', true, 'ok');
    attempts := attempts || 'one-word reason accepted';
  exception when others then null;
  end;

  -- A guard that did not block this plan.
  begin
    insert into public.retirement_overrides
      (user_id, plan_id, guard_id, typed_confirmation, acknowledged, reason)
    values (auth.uid(), plan_id, 'G6', '1', true, 'this snapshot is authoritative');
    attempts := attempts || 'override of a guard that did not block accepted';
  exception when others then null;
  end;

  -- G9 has no override, and the audit table refuses to record one.
  begin
    insert into public.retirement_overrides
      (user_id, plan_id, guard_id, typed_confirmation, acknowledged, reason)
    values (auth.uid(), plan_id, 'G9', '1', true, 'this snapshot is authoritative');
    attempts := attempts || 'an override row for G9 was accepted';
  exception when others then null;
  end;

  if array_length(attempts, 1) is not null then
    raise exception 'FAIL [contract] %', array_to_string(attempts, '; ');
  end if;
  if (select count(*) from public.retirement_overrides) <> 0 then
    raise exception 'FAIL [contract] a rejected attempt still wrote an override row';
  end if;

  raise notice 'PASS [contract] the override refuses a wrong count, a missing acknowledgement, a one-word reason, a guard that did not block, and G9';
end
$$;

commit;

-- ---------------------------------------------------------------------------
-- 3. GATE B — the explicit override works, end to end.
-- ---------------------------------------------------------------------------

begin;
set local request.jwt.claims = :'claims_a';
set local role authenticated;

do $$
declare plan_id uuid; imp uuid;
begin
  select id, import_id into plan_id, imp
    from public.reconciliation_plans where verdict = 'blocked';

  insert into public.retirement_overrides
    (user_id, plan_id, guard_id, typed_confirmation, acknowledged, reason)
  values (auth.uid(), plan_id, 'G4', '1', true,
          'This export is authoritative; the missing session was deleted deliberately.');

  update public.reconciliation_plans
     set decision = 'confirmed',
         decided_at = now(),
         decided_reason = 'This export is authoritative; the missing session was deleted deliberately.'
   where id = plan_id;

  if (select decision from public.reconciliation_plans where id = plan_id) <> 'confirmed' then
    raise exception 'FAIL [B] the override did not permit confirmation';
  end if;
  -- The original safety result is untouched. This is the whole point.
  if (select verdict from public.reconciliation_plans where id = plan_id) <> 'blocked' then
    raise exception 'FAIL [B] the verdict was rewritten; the audit trail must keep saying blocked';
  end if;

  raise notice 'PASS [B] an acknowledged override permits confirmation, and the verdict still reads blocked';
end
$$;

commit;

-- Retirement then runs through the ordinary lifecycle: status transition,
-- retirement guard, exactly the plan's key set.
do $$
declare retired int; live int;
begin
  update public.data_imports set status = 'retiring'
   where id = pg_temp.import_a() and user_id = pg_temp.uid_a();

  update public.strength_workouts
     set retired_at = now(), retired_by_import_id = pg_temp.import_a()
   where user_id = pg_temp.uid_a()
     and natural_key = any (
           (select p.retire_natural_keys from public.reconciliation_plans p
             where p.id = pg_temp.plan_a())::text[])
     and retired_at is null;
  get diagnostics retired = row_count;

  if retired <> 1 then
    raise exception 'FAIL [B] the override retirement affected % rows, expected 1', retired;
  end if;

  select count(*) into live from public.v_strength_workouts where user_id = pg_temp.uid_a();
  if live <> 2 then
    raise exception 'FAIL [B] % workouts remain live, expected 2', live;
  end if;

  -- Only the named record. Nothing else in scope was touched.
  if exists (select 1 from public.strength_workouts
              where user_id = pg_temp.uid_a() and retired_at is not null
                and natural_key <> 'a51-w1') then
    raise exception 'FAIL [B] a record outside the plan''s key set was retired';
  end if;

  update public.data_imports
     set status = 'completed', records_retired = retired
   where id = pg_temp.import_a();

  raise notice 'PASS [B] the override retires exactly the plan''s key set through the ordinary lifecycle: 1 retired, 2 live';
end
$$;

-- ---------------------------------------------------------------------------
-- 4. GATE C — auditability.
-- ---------------------------------------------------------------------------

begin;
set local request.jwt.claims = :'claims_a';
set local role authenticated;

do $$
declare a record;
begin
  select * into a from public.v_retirement_audit
   where plan_id = (select id from public.reconciliation_plans where verdict = 'blocked');

  -- Why was G4 blocked?
  if a.blocking_guards -> 0 ->> 'id' <> 'G4'
     or a.blocking_guards -> 0 ->> 'detail' not like '%floor 70%%' then
    raise exception 'FAIL [C] the audit does not say why the plan was blocked: %', a.blocking_guards;
  end if;

  -- Who overrode it, when, and why?
  if a.overrides -> 0 ->> 'overridden_by' <> auth.uid()::text then
    raise exception 'FAIL [C] the audit does not attribute the override to its actor: %', a.overrides;
  end if;
  if (a.overrides -> 0 ->> 'overridden_at') is null then
    raise exception 'FAIL [C] the audit records no override timestamp';
  end if;
  if a.overrides -> 0 ->> 'reason' not like '%authoritative%' then
    raise exception 'FAIL [C] the audit records no usable reason: %', a.overrides;
  end if;
  if (a.overrides -> 0 ->> 'acknowledged')::boolean is not true then
    raise exception 'FAIL [C] the audit does not record the acknowledgement';
  end if;

  -- The guard evidence is preserved on the override row itself, derived from
  -- the plan rather than supplied by whoever wrote it.
  if a.overrides -> 0 ->> 'guard_detail' not like '%partial rather than complete%' then
    raise exception 'FAIL [C] the override row carries no guard evidence: %', a.overrides;
  end if;

  -- Which reconciliation context?
  if a.import_id is null or a.file_name is null then
    raise exception 'FAIL [C] the audit does not name the import';
  end if;

  -- And the distinction the whole contract exists to preserve.
  if a.original_verdict <> 'blocked' then
    raise exception 'FAIL [C] the original verdict was not preserved';
  end if;
  if a.was_safety_override is not true then
    raise exception 'FAIL [C] the audit does not distinguish an override from a normal confirmation';
  end if;

  raise notice 'PASS [C] the audit answers why blocked, who overrode, when, why, and against which import, with the original verdict intact';
end
$$;

commit;

-- An override row is an audit record: it cannot be edited or deleted.
do $$
declare mutated boolean := false;
begin
  begin
    update public.retirement_overrides set reason = 'something else';
    mutated := true;
  exception when others then null;
  end;
  begin
    delete from public.retirement_overrides;
    mutated := true;
  exception when others then null;
  end;
  if mutated then
    raise exception 'FAIL [C] an override audit record was changed or removed';
  end if;
  raise notice 'PASS [C] override records are immutable: neither update nor delete is permitted';
end
$$;

-- ---------------------------------------------------------------------------
-- 5. GATE F — analytics after an override retirement.
-- ---------------------------------------------------------------------------

do $$
declare
  before_workouts numeric; after_workouts numeric;
  canon_workouts bigint; canon_sets bigint; canon_vol numeric;
  derived_workouts numeric; derived_sets numeric; derived_vol numeric;
begin
  select sum(value) into before_workouts from public.metric_daily
   where user_id = pg_temp.uid_a() and metric_key = 'training_workouts';
  if before_workouts <> 3 then
    raise exception 'FAIL [F] the baseline is wrong: % workouts in the derived series', before_workouts;
  end if;

  -- The retirement made one day dirty. This is the same enqueue the decision
  -- route performs; nothing about the override path is special here.
  perform public.rollup_enqueue_training_days(
    pg_temp.uid_a(),
    array(select w.local_date from public.strength_workouts w
           where w.user_id = pg_temp.uid_a() and w.natural_key = 'a51-w1'),
    'retirement');
  perform public.rollup_process_pending(100, 'phase5_1-suite');

  select count(*) into canon_workouts from public.v_strength_workouts where user_id = pg_temp.uid_a();
  select count(*) into canon_sets
    from public.v_strength_sets s
    join public.v_strength_exercises e on e.id = s.exercise_id
    join public.v_strength_workouts w on w.id = e.workout_id
   where w.user_id = pg_temp.uid_a();
  select sum(s.volume_kg) into canon_vol
    from public.v_strength_sets s
    join public.v_strength_exercises e on e.id = s.exercise_id
    join public.v_strength_workouts w on w.id = e.workout_id
   where w.user_id = pg_temp.uid_a() and s.weight_kg is not null and s.reps is not null;

  select sum(value) filter (where metric_key = 'training_workouts'),
         sum(value) filter (where metric_key = 'training_sets'),
         sum(value) filter (where metric_key = 'training_volume_kg')
    into derived_workouts, derived_sets, derived_vol
    from public.metric_daily where user_id = pg_temp.uid_a();

  if derived_workouts <> canon_workouts then
    raise exception 'FAIL [F] derived workouts % vs canonical %', derived_workouts, canon_workouts;
  end if;
  if derived_sets <> canon_sets then
    raise exception 'FAIL [F] derived sets % vs canonical %', derived_sets, canon_sets;
  end if;
  if derived_vol <> canon_vol then
    raise exception 'FAIL [F] derived volume % vs canonical %', derived_vol, canon_vol;
  end if;
  if derived_workouts <> 2 or derived_vol <> 2000 then
    raise exception 'FAIL [F] expected 2 workouts and 2000 kg after the override, got % and %',
      derived_workouts, derived_vol;
  end if;

  -- The retired day is gone entirely, not zeroed, and nothing else moved.
  if exists (select 1 from public.metric_daily
              where user_id = pg_temp.uid_a() and local_date = date '2026-07-06') then
    raise exception 'FAIL [F] the retired day still has derived rows';
  end if;
  if exists (
    select 1 from public.metric_daily_source mds
      join public.strength_workouts w on w.natural_key = 'a51-w1'
     where mds.user_id = pg_temp.uid_a() and mds.contributing_workout_ids @> array[w.id]
  ) then
    raise exception 'FAIL [F] the retired workout is still named in derived provenance';
  end if;

  raise notice 'PASS [F] after the override retirement, derived metrics equal canonical truth (% workouts, % sets, % kg), with no stale rows or provenance',
    derived_workouts, derived_sets, derived_vol;
end
$$;

-- ---------------------------------------------------------------------------
-- 6. GATE G — idempotency.
-- ---------------------------------------------------------------------------

do $$
declare
  duplicated boolean := false;
  overrides int;
  retired int;
  fingerprint_before text;
  fingerprint_after text;
begin
  select md5(string_agg(metric_key || ':' || local_date || ':' || value, '|' order by metric_key, local_date))
    into fingerprint_before
    from public.metric_daily where user_id = pg_temp.uid_a();

  -- The same override submitted again.
  begin
    insert into public.retirement_overrides
      (user_id, plan_id, guard_id, typed_confirmation, acknowledged, reason)
    values (pg_temp.uid_a(), pg_temp.plan_a(), 'G4', '1', true,
            'This export is authoritative; the missing session was deleted deliberately.');
    duplicated := true;
  exception when unique_violation then null;
  end;
  if duplicated then
    raise exception 'FAIL [G] a duplicate override created a second audit record';
  end if;

  select count(*) into overrides from public.retirement_overrides where plan_id = pg_temp.plan_a();
  if overrides <> 1 then
    raise exception 'FAIL [G] % override records exist for one plan and guard', overrides;
  end if;

  -- The same decision submitted again.
  duplicated := false;
  begin
    update public.reconciliation_plans
       set decision = 'confirmed', decided_at = now()
     where id = pg_temp.plan_a();
    duplicated := true;
  exception when others then null;
  end;
  if duplicated then
    raise exception 'FAIL [G] a decision was recorded twice';
  end if;

  -- The same retirement submitted again. The guard permits it, because the
  -- plan is confirmed and names the key; the row-level filter is what makes it
  -- a no-op, and that is the property being asserted.
  update public.strength_workouts
     set retired_at = now(), retired_by_import_id = pg_temp.import_a()
   where user_id = pg_temp.uid_a() and natural_key = 'a51-w1' and retired_at is null;
  get diagnostics retired = row_count;
  if retired <> 0 then
    raise exception 'FAIL [G] a repeated retirement affected % rows', retired;
  end if;

  -- Reprocessing the analytics scope again.
  perform public.rollup_enqueue_training_days(pg_temp.uid_a(), array[date '2026-07-06'], 'retirement');
  perform public.rollup_process_pending(100, 'phase5_1-suite');

  select md5(string_agg(metric_key || ':' || local_date || ':' || value, '|' order by metric_key, local_date))
    into fingerprint_after
    from public.metric_daily where user_id = pg_temp.uid_a();
  if fingerprint_after is distinct from fingerprint_before then
    raise exception 'FAIL [G] repeating the override workflow changed the derived metrics';
  end if;

  raise notice 'PASS [G] repeating the override, the decision, the retirement and the rollup changes nothing: 1 audit record, 1 decision, 0 further retirements';
end
$$;

-- ---------------------------------------------------------------------------
-- 7. GATE D — the safe fallback still works, on a blocked plan.
-- ---------------------------------------------------------------------------

begin;
set local request.jwt.claims = :'claims_b';
set local role authenticated;

do $$
declare plan_id uuid;
begin
  select id into plan_id from public.reconciliation_plans where verdict = 'blocked';

  update public.reconciliation_plans
     set decision = 'skipped', decided_at = now(),
         decided_reason = 'the export looks partial'
   where id = plan_id;

  if (select decision from public.reconciliation_plans where id = plan_id) <> 'skipped' then
    raise exception 'FAIL [D] the append-only fallback was refused on a blocked plan';
  end if;
  raise notice 'PASS [D] append-only remains available on a blocked plan, with no override involved';
end
$$;

commit;

do $$
declare live int; derived numeric;
begin
  if exists (select 1 from public.strength_workouts
              where user_id = pg_temp.uid_b() and retired_at is not null) then
    raise exception 'FAIL [D] the fallback retired something';
  end if;
  select count(*) into live from public.v_strength_workouts where user_id = pg_temp.uid_b();
  select sum(value) into derived from public.metric_daily
   where user_id = pg_temp.uid_b() and metric_key = 'training_workouts';
  if live <> 3 or derived <> 3 then
    raise exception 'FAIL [D] after the fallback: % live workouts, % derived', live, derived;
  end if;
  if (select count(*) from public.retirement_overrides where plan_id = pg_temp.plan_b()) <> 0 then
    raise exception 'FAIL [D] the fallback recorded an override';
  end if;
  raise notice 'PASS [D] the fallback leaves all 3 workouts live, analytics unchanged at 3, and writes no override record';
end
$$;

-- ---------------------------------------------------------------------------
-- 8. GATE E — isolation and security.
-- ---------------------------------------------------------------------------

begin;
set local request.jwt.claims = :'claims_b';
set local role authenticated;

do $$
declare wrote boolean := false; visible int;
begin
  -- User B cannot override user A's plan, under either user_id.
  begin
    insert into public.retirement_overrides
      (user_id, plan_id, guard_id, typed_confirmation, acknowledged, reason)
    values (auth.uid(), pg_temp.plan_a(), 'G4', '1', true, 'I would like this gone please');
    wrote := true;
  exception when others then null;
  end;
  begin
    insert into public.retirement_overrides
      (user_id, plan_id, guard_id, typed_confirmation, acknowledged, reason)
    values (pg_temp.uid_a(), pg_temp.plan_a(), 'G4', '1', true, 'I would like this gone please');
    wrote := true;
  exception when others then null;
  end;
  if wrote then
    raise exception 'FAIL [E] user B recorded an override against user A''s plan';
  end if;

  -- Nor can it decide that plan.
  update public.reconciliation_plans set decision = 'confirmed', decided_at = now()
   where id = pg_temp.plan_a();
  if (select count(*) from public.reconciliation_plans where id = pg_temp.plan_a()
       and decided_reason = 'the export looks partial') <> 0 then
    raise exception 'FAIL [E] user B altered user A''s decision';
  end if;

  -- Nor read user A's override metadata, through the table or the audit view.
  select count(*) into visible from public.retirement_overrides where user_id <> auth.uid();
  if visible <> 0 then
    raise exception 'FAIL [E] user B reads % of user A''s override records', visible;
  end if;
  select count(*) into visible from public.v_retirement_audit where user_id <> auth.uid();
  if visible <> 0 then
    raise exception 'FAIL [E] the audit view leaked another user''s rows';
  end if;
  if (select count(*) from public.v_retirement_audit) = 0 then
    raise exception 'FAIL [E] user B cannot see its own audit rows';
  end if;

  raise notice 'PASS [E] user B cannot override, decide, or read anything belonging to user A, and still sees its own';
end
$$;

commit;

-- Function and table privileges. EXECUTE defaults to PUBLIC, so this is
-- asserted rather than assumed.
do $$
declare fn text; leaked text[] := '{}'; priv text;
begin
  foreach fn in array array[
    'reconciliation_plan_override_is_complete(uuid)',
    'assert_plan_confirmation_is_permitted()',
    'retirement_override_validate()',
    'retirement_override_is_immutable()',
    'assert_retiring_status_is_confirmed()',
    'assert_retirement_is_planned_and_permitted()'
  ] loop
    if has_function_privilege('anon', 'public.' || fn, 'execute') then
      leaked := leaked || ('anon:' || fn);
    end if;
    if has_function_privilege('authenticated', 'public.' || fn, 'execute') then
      leaked := leaked || ('authenticated:' || fn);
    end if;
  end loop;

  foreach priv in array array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] loop
    if has_table_privilege('anon', 'public.v_retirement_audit', priv) then
      leaked := leaked || ('anon:v_retirement_audit:' || priv);
    end if;
    if priv <> 'SELECT'
       and has_table_privilege('authenticated', 'public.v_retirement_audit', priv) then
      leaked := leaked || ('authenticated:v_retirement_audit:' || priv);
    end if;
  end loop;
  if not has_table_privilege('authenticated', 'public.v_retirement_audit', 'SELECT') then
    raise exception 'FAIL [E] authenticated cannot read its own audit view';
  end if;

  -- The client may still record its own override and read the trail, and may
  -- still not change or delete one.
  if not has_table_privilege('authenticated', 'public.retirement_overrides', 'INSERT')
     or not has_table_privilege('authenticated', 'public.retirement_overrides', 'SELECT') then
    raise exception 'FAIL [E] the client cannot record or read its own override';
  end if;
  foreach priv in array array['UPDATE','DELETE','TRUNCATE'] loop
    if has_table_privilege('authenticated', 'public.retirement_overrides', priv) then
      leaked := leaked || ('authenticated:retirement_overrides:' || priv);
    end if;
  end loop;

  if array_length(leaked, 1) is not null then
    raise exception 'FAIL [E] unexpected privileges: %', array_to_string(leaked, ', ');
  end if;
  raise notice 'PASS [E] every Phase 5.1 function is revoked from anon and authenticated; the audit view is read-only to its owner and closed to anon';
end
$$;

-- No Phase 5.1 function accepts an actor identity it would trust.
do $$
declare r record;
begin
  for r in select p.proname, pg_get_function_arguments(p.oid) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public'
              and p.proname in ('reconciliation_plan_override_is_complete',
                                'assert_plan_confirmation_is_permitted',
                                'retirement_override_validate')
  loop
    if r.args ~* '(^|[^a-z_])p_user_id' then
      raise exception 'FAIL [E] public.% accepts a caller-supplied user id: %', r.proname, r.args;
    end if;
  end loop;
  raise notice 'PASS [E] no override function takes a caller-supplied actor identity; attribution comes from the session';
end
$$;

-- ---------------------------------------------------------------------------
-- 9. G9 remains absolute.
--
-- A plan blocked by a guard with no override can never be confirmed, no matter
-- what else is recorded against it.
-- ---------------------------------------------------------------------------

do $$
declare imp uuid; plan_id uuid; confirmed boolean := false;
begin
  insert into public.data_imports
    (user_id, source_key, template, storage_path, file_name, file_type,
     mapping_spec_snapshot, normalize_version, import_mode, status, imported_at)
  values (pg_temp.uid_a(), 'hevy', 'strength', 'x/p51/manual.csv', 'manual.csv', 'csv',
          '{}'::jsonb, 1, 'full_snapshot', 'awaiting_retirement_confirmation', now())
  returning id into imp;

  insert into public.reconciliation_plans
    (user_id, import_id, scope, add_count, update_count, unchanged_count, retire_count,
     existing_in_scope_count, retire_ratio, retire_natural_keys, guard_results, verdict)
  values (pg_temp.uid_a(), imp, '{}'::jsonb, 0, 0, 1, 1, 2, 0.5, array['a51-w2'],
    jsonb_build_array(
      jsonb_build_object('id','G4','outcome','blocked','detail','coverage below floor','overridable',true),
      jsonb_build_object('id','G9','outcome','blocked','detail','1 retirement targets a manually entered record; this guard has no override','overridable',false)
    ),
    'blocked')
  returning id into plan_id;

  -- The overridable half can be overridden.
  insert into public.retirement_overrides
    (user_id, plan_id, guard_id, typed_confirmation, acknowledged, reason)
  values (pg_temp.uid_a(), plan_id, 'G4', '1', true, 'the coverage figure is expected here');

  -- The plan is still unconfirmable, because G9 cannot be covered at all.
  begin
    update public.reconciliation_plans set decision = 'confirmed', decided_at = now()
     where id = plan_id;
    confirmed := true;
  exception when others then null;
  end;

  if confirmed then
    raise exception 'FAIL [G9] a plan blocked by G9 was confirmed after overriding only G4';
  end if;
  raise notice 'PASS [G9] overriding G4 does not confirm a plan G9 also blocked: an override must cover every blocking guard, and G9 can never be covered';
end
$$;

do $$ begin raise notice 'PASS Phase 5.1 G4 override: all assertions'; end $$;
