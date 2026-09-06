-- ============================================================================
-- 10_manual_entry.sql
-- Phase 6: manual body tracking.
--
-- The exit criterion is one sentence: a corrected measurement survives a full
-- normalize rebuild with the corrected value intact. Everything below exists
-- to make that sentence testable rather than plausible, and to check that the
-- mechanism which delivers it — precedence resolution in the upsert — does not
-- also let a stale record win by arriving last.
--
-- Canonical rows are created only through the sanctioned path: a raw record,
-- then public.import_upsert_metric. Nothing here inserts into metrics.
-- ============================================================================

\set QUIET on
\set uid_a '6a6a6a6a-6a6a-46a6-86a6-6a6a6a6a6a6a'
\set uid_b '6b6b6b6b-6b6b-46b6-86b6-6b6b6b6b6b6b'
\set claims_a '{"sub":"6a6a6a6a-6a6a-46a6-86a6-6a6a6a6a6a6a","role":"authenticated"}'
\set claims_b '{"sub":"6b6b6b6b-6b6b-46b6-86b6-6b6b6b6b6b6b","role":"authenticated"}'
\set QUIET off

insert into auth.users (id, email) values
  (:'uid_a', 'phase6-a@test.invalid'), (:'uid_b', 'phase6-b@test.invalid')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 0. The registry says what a person may type (I-6).
-- ---------------------------------------------------------------------------

do $$
declare enterable int; derived int;
begin
  select count(*) into enterable from public.metric_definitions
   where user_id is null and manual_entry and is_active;
  select count(*) into derived from public.metric_definitions
   where user_id is null and not manual_entry and key like 'training\_%';

  if enterable < 9 then
    raise exception 'FAIL [0] only % metrics are marked manually recordable', enterable;
  end if;
  if derived < 7 then
    raise exception 'FAIL [0] the derived training aggregates are not excluded from manual entry';
  end if;
  if exists (select 1 from public.metric_definitions
              where user_id is null and manual_entry and key like 'training\_%') then
    raise exception 'FAIL [0] a derived training aggregate is marked as manually recordable';
  end if;

  raise notice 'PASS [0] % metrics are manually recordable; the % derived training aggregates are not', enterable, derived;
end
$$;

-- ---------------------------------------------------------------------------
-- 1. Fixture helpers: the manual write path, and nothing else.
-- ---------------------------------------------------------------------------

create function pg_temp.manual_import(p_user uuid, p_tag text)
returns uuid language plpgsql as $$
declare imp uuid;
begin
  insert into public.data_imports
    (user_id, source_key, template, file_name, file_type, mapping_spec_snapshot,
     normalize_version, import_mode, status, imported_at, rows_total)
  values (p_user, 'manual', 'metrics', 'manual entry', 'manual',
          '{"template":"metrics","layout":"long"}'::jsonb, 1, 'append', 'completed', now(), 1)
  returning id into imp;
  return imp;
end $$;

/**
 * One manual observation, recorded exactly as the application records it: a
 * raw record at the given precedence rank, then the sanctioned upsert.
 * Returns the upsert's own verdict so a test can assert what happened.
 */
create function pg_temp.record_metric(
  p_user uuid, p_import uuid, p_natural_key text, p_metric text,
  p_value numeric, p_at timestamptz, p_precedence smallint, p_hash text,
  p_supersedes text default null
) returns public.upsert_outcome language plpgsql as $$
declare rr bigint; def record; outcome public.upsert_outcome;
begin
  insert into public.raw_records
    (user_id, import_id, source_key, payload, row_hash, precedence_rank, supersedes_natural_key)
  values (p_user, p_import, 'manual',
          jsonb_build_object('metric_key', p_metric, 'value', p_value::text,
                             'unit', 'kg', 'measured_at', p_at::text),
          p_hash, p_precedence, p_supersedes)
  returning id into rr;

  select d.id, d.key, d.canonical_unit_id into def
    from public.metric_definitions d
   where d.key = p_metric and d.user_id is null;

  outcome := public.import_upsert_metric(
    p_user, p_natural_key, def.id, def.key, null,
    p_at, 0, null, (p_at at time zone 'UTC')::date,
    p_value, def.canonical_unit_id, 'kg',
    'manual', p_value, 'kg', rr, p_import);

  return outcome;
end $$;

-- ---------------------------------------------------------------------------
-- 2. An entry, then a correction.
-- ---------------------------------------------------------------------------

do $$
declare
  u   uuid := '6a6a6a6a-6a6a-46a6-86a6-6a6a6a6a6a6a';
  imp uuid;
  nk  text := 'p6-weight-2026-08-03';
  o   public.upsert_outcome;
  v   numeric;
begin
  imp := pg_temp.manual_import(u, 'entry');
  o := pg_temp.record_metric(u, imp, nk, 'weight', 82.4,
                             timestamptz '2026-08-03 07:30:00+00', 10::smallint, 'p6-h1');
  if o <> 'added' then
    raise exception 'FAIL [1] the first entry reported %, expected added', o;
  end if;

  select value_num into v from public.v_metrics where natural_key = nk;
  if v <> 82.4 then
    raise exception 'FAIL [1] the recorded value is %, expected 82.4', v;
  end if;

  -- The correction: a NEW raw record at a higher precedence rank, naming the
  -- same observation. Nothing is edited and nothing is deleted.
  imp := pg_temp.manual_import(u, 'correction');
  o := pg_temp.record_metric(u, imp, nk, 'weight', 81.9,
                             timestamptz '2026-08-03 07:30:00+00', 20::smallint, 'p6-h2', nk);
  if o <> 'updated' then
    raise exception 'FAIL [1] the correction reported %, expected updated', o;
  end if;

  select value_num into v from public.v_metrics where natural_key = nk;
  if v <> 81.9 then
    raise exception 'FAIL [1] the corrected value is %, expected 81.9', v;
  end if;

  -- One canonical row, two raw records. The original is still there.
  if (select count(*) from public.metrics where natural_key = nk) <> 1 then
    raise exception 'FAIL [1] the correction created a second canonical row';
  end if;
  if (select count(*) from public.raw_records where user_id = u) <> 2 then
    raise exception 'FAIL [1] the original raw record did not survive the correction';
  end if;
  if (select revision from public.metrics where natural_key = nk) <> 2 then
    raise exception 'FAIL [1] the corrected row did not record a revision';
  end if;

  raise notice 'PASS [1] entry 82.4 then correction 81.9: one canonical row at revision 2, both raw records intact';
end
$$;

-- ---------------------------------------------------------------------------
-- 3. Precedence: a stale record cannot win by arriving last.
--
-- This is the mechanism the exit criterion depends on. If replaying the
-- original entry after the correction overwrote it, a rebuild would silently
-- undo every correction a person had ever made.
-- ---------------------------------------------------------------------------

do $$
declare
  u   uuid := '6a6a6a6a-6a6a-46a6-86a6-6a6a6a6a6a6a';
  imp uuid;
  nk  text := 'p6-weight-2026-08-03';
  o   public.upsert_outcome;
  v   numeric;
begin
  imp := pg_temp.manual_import(u, 'replay');
  -- The ORIGINAL value again, at entry precedence, arriving after the
  -- correction. It must lose.
  o := pg_temp.record_metric(u, imp, nk, 'weight', 82.4,
                             timestamptz '2026-08-03 07:30:00+00', 10::smallint, 'p6-h3');
  if o <> 'unchanged' then
    raise exception 'FAIL [2] a lower-precedence replay reported %, expected unchanged', o;
  end if;

  select value_num into v from public.v_metrics where natural_key = nk;
  if v <> 81.9 then
    raise exception 'FAIL [2] a lower-precedence record overwrote the correction: value is now %', v;
  end if;

  -- And an equal-precedence record that arrives later DOES win: two manual
  -- entries for the same observation are two statements of the same standing,
  -- and the later one is the person's current belief.
  imp := pg_temp.manual_import(u, 'second correction');
  o := pg_temp.record_metric(u, imp, nk, 'weight', 81.5,
                             timestamptz '2026-08-03 07:30:00+00', 20::smallint, 'p6-h4', nk);
  if o <> 'updated' then
    raise exception 'FAIL [2] a second correction reported %, expected updated', o;
  end if;
  select value_num into v from public.v_metrics where natural_key = nk;
  if v <> 81.5 then
    raise exception 'FAIL [2] the second correction did not take effect: value is %', v;
  end if;

  raise notice 'PASS [2] a replayed entry cannot overwrite a correction; a later correction can';
end
$$;

-- ---------------------------------------------------------------------------
-- 4. THE EXIT CRITERION.
--
-- Wipe the canonical rows and rebuild them from the raw layer alone, replaying
-- the raw records in every order that matters. The corrected value must come
-- back, from every order.
-- ---------------------------------------------------------------------------

do $$
declare
  u        uuid := '6a6a6a6a-6a6a-46a6-86a6-6a6a6a6a6a6a';
  nk       text := 'p6-weight-2026-08-03';
  before_v numeric;
  after_v  numeric;
  raw      record;
  def      record;
  pass     int;
begin
  select value_num into before_v from public.v_metrics where natural_key = nk;

  select d.id, d.key, d.canonical_unit_id into def
    from public.metric_definitions d where d.key = 'weight' and d.user_id is null;

  for pass in 1 .. 2 loop
    -- A full rebuild: canonical is derived data as far as this test is
    -- concerned, and the claim being tested is that the raw layer alone is
    -- enough to reconstruct it.
    delete from public.metrics where user_id = u;

    for raw in
      select r.id, r.payload, r.precedence_rank, r.supersedes_natural_key, r.import_id
        from public.raw_records r
       where r.user_id = u and r.source_key = 'manual'
       -- Pass 1 replays oldest first, pass 2 newest first. A rebuild that only
       -- works in one order is not a rebuild, it is a coincidence.
       order by case when pass = 1 then r.id end asc,
                case when pass = 2 then r.id end desc
    loop
      perform public.import_upsert_metric(
        u, nk, def.id, def.key, null,
        (raw.payload->>'measured_at')::timestamptz, 0, null,
        ((raw.payload->>'measured_at')::timestamptz at time zone 'UTC')::date,
        (raw.payload->>'value')::numeric, def.canonical_unit_id, 'kg',
        'manual', (raw.payload->>'value')::numeric, 'kg', raw.id, raw.import_id);
    end loop;

    select value_num into after_v from public.v_metrics where natural_key = nk;
    if after_v is distinct from before_v then
      raise exception
        'FAIL [EXIT] rebuild pass % produced % but the corrected value was %', pass, after_v, before_v;
    end if;
  end loop;

  if before_v <> 81.5 then
    raise exception 'FAIL [EXIT] the value under test is % rather than the corrected 81.5', before_v;
  end if;

  raise notice 'PASS [EXIT] the corrected value (%) survives a full rebuild from the raw layer, replayed in both orders', after_v;
end
$$;

-- ---------------------------------------------------------------------------
-- 5. I-1: no canonical metric exists without a raw record behind it.
-- ---------------------------------------------------------------------------

do $$
declare orphans bigint; refused boolean := false;
begin
  select count(*) into orphans
    from public.metrics m
    left join public.raw_records r on r.id = m.raw_record_id and r.user_id = m.user_id
   where r.id is null;
  if orphans <> 0 then
    raise exception 'FAIL [I-1] % metric rows have no raw record', orphans;
  end if;

  -- And the upsert refuses to invent one.
  begin
    perform public.import_upsert_metric(
      '6a6a6a6a-6a6a-46a6-86a6-6a6a6a6a6a6a', 'p6-orphan',
      (select id from public.metric_definitions where key = 'weight' and user_id is null),
      'weight', null, now(), 0, null, current_date, 70,
      (select canonical_unit_id from public.metric_definitions where key = 'weight' and user_id is null),
      'kg', 'manual', 70, 'kg', 999999999, null);
    refused := false;
  exception when others then refused := true;
  end;
  if not refused then
    raise exception 'FAIL [I-1] the upsert accepted a metric citing a raw record that does not exist';
  end if;

  raise notice 'PASS [I-1] every canonical metric traces to a raw record, and the upsert refuses one that does not';
end
$$;

-- ---------------------------------------------------------------------------
-- 6. G9: a manual record can never be retired.
--
-- Manual entry is what G9 was written to protect, and Phase 6 is the first
-- phase that actually produces one.
-- ---------------------------------------------------------------------------

do $$
declare
  u   uuid := '6a6a6a6a-6a6a-46a6-86a6-6a6a6a6a6a6a';
  imp uuid;
  refused boolean := false;
begin
  imp := pg_temp.manual_import(u, 'retire attempt');
  insert into public.reconciliation_plans
    (user_id, import_id, scope, add_count, update_count, unchanged_count, retire_count,
     existing_in_scope_count, retire_ratio, retire_natural_keys, guard_results, verdict,
     decision, decided_at)
  values (u, imp, '{}'::jsonb, 0, 0, 0, 1, 1, 1.0,
          array['p6-weight-2026-08-03'], '[]'::jsonb, 'safe', 'confirmed', now());

  begin
    update public.metrics
       set retired_at = now(), retired_by_import_id = imp
     where user_id = u and natural_key = 'p6-weight-2026-08-03';
  exception when others then refused := true;
  end;

  if not refused then
    raise exception 'FAIL [G9] a manually entered measurement was retired';
  end if;
  if (select count(*) from public.v_metrics where user_id = u) = 0 then
    raise exception 'FAIL [G9] the measurement disappeared';
  end if;

  raise notice 'PASS [G9] a manually entered measurement cannot be retired, even under a confirmed plan naming it';
end
$$;

-- ---------------------------------------------------------------------------
-- 7. Security: isolation, privileges, and no caller-supplied identity.
-- ---------------------------------------------------------------------------

do $$
declare
  u   uuid := '6b6b6b6b-6b6b-46b6-86b6-6b6b6b6b6b6b';
  imp uuid;
begin
  imp := pg_temp.manual_import(u, 'b');
  perform pg_temp.record_metric(u, imp, 'p6-b-weight', 'weight', 95.0,
                                timestamptz '2026-08-03 08:00:00+00', 10::smallint, 'p6-hb1');
  raise notice 'PASS [7] user B recorded its own measurement';
end
$$;

begin;
set local request.jwt.claims = :'claims_a';
set local role authenticated;

do $$
declare mine int; theirs int; wrote boolean := false;
begin
  select count(*) into mine from public.body_measurements(100, 0);
  select count(*) into theirs from public.v_metrics where user_id <> auth.uid();
  if theirs <> 0 then
    raise exception 'FAIL [7] user A reads % of user B''s measurements', theirs;
  end if;
  if mine = 0 then
    raise exception 'FAIL [7] user A cannot read its own measurements';
  end if;

  -- The client cannot write canonical metrics, whatever it claims to be (I-4).
  begin
    insert into public.metrics
      (user_id, metric_definition_id, metric_key, timestamp_utc, tz_offset_minutes,
       local_date, value_num, source_key, natural_key, raw_record_id, import_id)
    select auth.uid(), d.id, 'weight', now(), 0, current_date, 1, 'manual', 'p6-forged', 1,
           (select id from public.data_imports limit 1)
      from public.metric_definitions d where d.key = 'weight' and d.user_id is null;
    wrote := true;
  exception when others then null;
  end;
  -- Nor a raw record, which is the only door into canonical data.
  begin
    insert into public.raw_records (user_id, import_id, source_key, payload, row_hash)
    values (auth.uid(), (select id from public.data_imports limit 1), 'manual', '{}'::jsonb, 'forged');
    wrote := true;
  exception when others then null;
  end;
  if wrote then
    raise exception 'FAIL [7] the client wrote a canonical metric or a raw record directly';
  end if;

  raise notice 'PASS [7] user A reads its own % measurements and none of user B''s, and can write neither a metric nor a raw record', mine;
end
$$;

commit;

do $$
declare leaked text[] := '{}'; fn text;
begin
  foreach fn in array array[
    'import_upsert_metric(uuid,text,uuid,text,text,timestamptz,integer,text,date,numeric,uuid,text,text,numeric,text,bigint,uuid)',
    'normalize_rebuild_enqueue(uuid,text)'
  ] loop
    if has_function_privilege('anon', 'public.' || fn, 'execute') then
      leaked := leaked || ('anon:' || fn);
    end if;
    if has_function_privilege('authenticated', 'public.' || fn, 'execute') then
      leaked := leaked || ('authenticated:' || fn);
    end if;
  end loop;

  if not has_function_privilege('authenticated', 'public.body_measurements(integer,integer,text)', 'execute') then
    raise exception 'FAIL [7] authenticated cannot read its own measurements through the read model';
  end if;
  if has_function_privilege('anon', 'public.body_measurements(integer,integer,text)', 'execute') then
    leaked := leaked || 'anon:body_measurements';
  end if;

  if array_length(leaked, 1) is not null then
    raise exception 'FAIL [7] unexpected privileges: %', array_to_string(leaked, ', ');
  end if;

  -- The read model takes no user id: there is no parameter with which to ask
  -- for another person's measurements.
  if (select pg_get_function_arguments(p.oid)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'body_measurements') ~* 'p_user_id' then
    raise exception 'FAIL [7] body_measurements accepts a caller-supplied user id';
  end if;

  raise notice 'PASS [7] the write functions are revoked from every client role; the read model is callable by its owner only and takes no user id';
end
$$;

do $$ begin raise notice 'PASS Phase 6 manual body tracking: all assertions'; end $$;
