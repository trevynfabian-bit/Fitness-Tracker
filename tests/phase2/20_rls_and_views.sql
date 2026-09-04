-- ============================================================================
-- 20_rls_and_views.sql
-- Phase 2 row level security and canonical view isolation.
--
-- Every read below runs as the `authenticated` Postgres role with a JWT
-- subject claim, which is the context a Supabase client request executes in.
-- The service role is never used to validate a policy. Fixture rows are
-- created on the privileged connection because that is the normalization
-- worker's context and because I-4 denies the client any canonical write.
-- ============================================================================

\set QUIET on
\set uid_a '55555555-5555-4555-8555-555555555555'
\set uid_b '66666666-6666-4666-8666-666666666666'
\set claims_a '{"sub":"55555555-5555-4555-8555-555555555555","role":"authenticated"}'
\set claims_b '{"sub":"66666666-6666-4666-8666-666666666666","role":"authenticated"}'
\set QUIET off

-- ---------------------------------------------------------------------------
-- 0. Structural: I-8 across every table in the schema, Phase 1 and Phase 2
-- ---------------------------------------------------------------------------

do $$
declare r record; n int; policy_count int;
begin
  n := 0;
  for r in select c.relname, c.relrowsecurity
             from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
            where ns.nspname = 'public' and c.relkind = 'r'
  loop
    n := n + 1;
    if not r.relrowsecurity then
      raise exception 'FAIL [0] RLS is not enabled on public.%', r.relname;
    end if;
    if not exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name = r.relname
                      and column_name = 'user_id') then
      raise exception 'FAIL [0] public.% has no user_id column (I-8)', r.relname;
    end if;
    select count(*) into policy_count
      from pg_policies where schemaname = 'public' and tablename = r.relname;
    if policy_count < 1 then
      raise exception 'FAIL [0] public.% has no RLS policy (I-8)', r.relname;
    end if;
  end loop;

  if n < 18 then
    raise exception 'FAIL [0] only % tables inspected; expected the 9 registry plus 9 Phase 2 tables', n;
  end if;
  raise notice 'PASS [0] all % public tables: RLS enabled, user_id present, at least one policy (I-8)', n;
end
$$;

do $$
declare bad record;
begin
  for bad in select tablename, policyname,
                    coalesce(qual, '') || ' ' || coalesce(with_check, '') as expr
               from pg_policies where schemaname = 'public'
  loop
    if bad.expr ~* '\yfrom\y' then
      raise exception 'FAIL [0] policy %.% references another relation: %',
        bad.tablename, bad.policyname, bad.expr;
    end if;
  end loop;
  raise notice 'PASS [0] no RLS policy references another relation (join-free, I-8)';
end
$$;

-- ---------------------------------------------------------------------------
-- 1. Fixture: two users, each with a full import graph
-- ---------------------------------------------------------------------------

insert into auth.users (id, email)
values (:'uid_a', 'phase2-rls-a@test.invalid'), (:'uid_b', 'phase2-rls-b@test.invalid')
on conflict (id) do nothing;

do $$
declare
  u uuid;
  imp uuid;
  rr bigint;
  w uuid;
  ex uuid;
  def uuid;
begin
  foreach u in array array[
    '55555555-5555-4555-8555-555555555555'::uuid,
    '66666666-6666-4666-8666-666666666666'::uuid
  ] loop
    insert into public.exercise_definitions (user_id, key, display_name)
    values (u, 'private_lift', 'Private Lift') returning id into def;

    insert into public.import_profiles
      (user_id, name, template, source_key, signature_hash, header_tokens, mapping_spec)
    values (u, 'Private profile', 'strength', 'sample_source',
            'sig-' || u::text, array['a','b'], '{}'::jsonb);

    insert into public.data_imports
      (user_id, source_key, template, storage_path, file_name, file_type,
       mapping_spec_snapshot, normalize_version, import_mode, status, imported_at)
    values (u, 'sample_source', 'strength', u::text || '/x/f.csv', 'f.csv', 'csv',
            '{}'::jsonb, 1, 'append', 'completed', now())
    returning id into imp;

    insert into public.import_jobs (user_id, import_id, stage, state)
    values (u, imp, 'ingest', 'done');

    insert into public.raw_records (user_id, import_id, source_key, payload, row_hash)
    values (u, imp, 'sample_source', '{"row":"1"}'::jsonb, 'hash-' || u::text)
    returning id into rr;

    insert into public.import_coverage
      (user_id, import_id, template, granularity, date_from, date_to,
       source_row_count, canonical_row_count)
    values (u, imp, 'strength', 'event', current_date, current_date, 1, 3);

    insert into public.strength_workouts
      (user_id, start_utc, tz_offset_minutes, local_date, source_key,
       natural_key, raw_record_id, import_id)
    values (u, now(), 0, current_date, 'sample_source', 'wk-' || u::text, rr, imp)
    returning id into w;

    insert into public.strength_exercises
      (user_id, workout_id, exercise_definition_id, exercise_name_raw,
       order_index, raw_record_id, import_id)
    values (u, w, def, 'Private Lift', 0, rr, imp)
    returning id into ex;

    insert into public.strength_sets
      (user_id, exercise_id, set_number, weight_kg, reps, natural_key, raw_record_id)
    values (u, ex, 1, 100.000000, 5, 'st-' || u::text, rr);
  end loop;
  raise notice 'PASS [1] fixture: a complete import graph created for each of two users';
end
$$;

-- ---------------------------------------------------------------------------
-- 2. Each user reads their own rows and none of the other's
-- ---------------------------------------------------------------------------

begin;
set local request.jwt.claims = :'claims_a';
set local role authenticated;

do $$
declare own bigint; foreign_rows bigint;
begin
  select (select count(*) from public.import_profiles   where user_id = auth.uid())
       + (select count(*) from public.data_imports      where user_id = auth.uid())
       + (select count(*) from public.import_jobs       where user_id = auth.uid())
       + (select count(*) from public.raw_records       where user_id = auth.uid())
       + (select count(*) from public.import_coverage   where user_id = auth.uid())
       + (select count(*) from public.strength_workouts where user_id = auth.uid())
       + (select count(*) from public.strength_exercises where user_id = auth.uid())
       + (select count(*) from public.strength_sets     where user_id = auth.uid())
    into own;
  if own <> 8 then
    raise exception 'FAIL [C1] user A reads % of its own 8 Phase 2 rows', own;
  end if;

  select (select count(*) from public.import_profiles   where user_id is not null and user_id <> auth.uid())
       + (select count(*) from public.data_imports      where user_id <> auth.uid())
       + (select count(*) from public.import_jobs       where user_id <> auth.uid())
       + (select count(*) from public.raw_records       where user_id <> auth.uid())
       + (select count(*) from public.import_coverage   where user_id <> auth.uid())
       + (select count(*) from public.metrics           where user_id <> auth.uid())
       + (select count(*) from public.strength_workouts where user_id <> auth.uid())
       + (select count(*) from public.strength_exercises where user_id <> auth.uid())
       + (select count(*) from public.strength_sets     where user_id <> auth.uid())
    into foreign_rows;
  if foreign_rows <> 0 then
    raise exception 'FAIL [C3] user A reads % rows belonging to another user', foreign_rows;
  end if;

  -- The views must isolate too, which requires security_invoker.
  if (select count(*) from public.v_strength_workouts where user_id <> auth.uid()) <> 0
     or (select count(*) from public.v_strength_exercises where user_id <> auth.uid()) <> 0
     or (select count(*) from public.v_strength_sets where user_id <> auth.uid()) <> 0
     or (select count(*) from public.v_metrics where user_id <> auth.uid()) <> 0 then
    raise exception 'FAIL [C3] a canonical view leaked another user''s rows';
  end if;

  if (select count(*) from public.v_strength_sets) <> 1 then
    raise exception 'FAIL [C1] user A cannot read its own set through v_strength_sets';
  end if;

  raise notice 'PASS [C1/C3] user A reads its own 8 Phase 2 rows and 0 foreign rows, tables and views alike';
end
$$;

commit;

begin;
set local request.jwt.claims = :'claims_b';
set local role authenticated;

do $$
declare own bigint; foreign_rows bigint;
begin
  select (select count(*) from public.import_profiles   where user_id = auth.uid())
       + (select count(*) from public.data_imports      where user_id = auth.uid())
       + (select count(*) from public.import_jobs       where user_id = auth.uid())
       + (select count(*) from public.raw_records       where user_id = auth.uid())
       + (select count(*) from public.import_coverage   where user_id = auth.uid())
       + (select count(*) from public.strength_workouts where user_id = auth.uid())
       + (select count(*) from public.strength_exercises where user_id = auth.uid())
       + (select count(*) from public.strength_sets     where user_id = auth.uid())
    into own;
  if own <> 8 then
    raise exception 'FAIL [C2] user B reads % of its own 8 Phase 2 rows', own;
  end if;

  select (select count(*) from public.data_imports      where user_id <> auth.uid())
       + (select count(*) from public.raw_records       where user_id <> auth.uid())
       + (select count(*) from public.strength_workouts where user_id <> auth.uid())
       + (select count(*) from public.strength_sets     where user_id <> auth.uid())
    into foreign_rows;
  if foreign_rows <> 0 then
    raise exception 'FAIL [C4] user B reads % rows belonging to user A', foreign_rows;
  end if;

  if (select count(*) from public.v_strength_sets where user_id <> auth.uid()) <> 0 then
    raise exception 'FAIL [C4] v_strength_sets leaked user A''s rows to user B';
  end if;

  raise notice 'PASS [C2/C4] user B reads its own 8 Phase 2 rows and 0 of user A''s';
end
$$;

commit;

-- ---------------------------------------------------------------------------
-- 3. Write isolation at the client role
-- ---------------------------------------------------------------------------

begin;
set local request.jwt.claims = :'claims_a';
set local role authenticated;

do $$
begin
  begin
    insert into public.strength_workouts
      (user_id, start_utc, tz_offset_minutes, local_date, source_key, natural_key, raw_record_id, import_id)
    select auth.uid(), now(), 0, current_date, 'sample_source', 'client-write', r.id, r.import_id
      from public.raw_records r where r.user_id = auth.uid() limit 1;
    raise exception 'FAIL [W1] the client role inserted directly into a canonical table (I-4)';
  exception when insufficient_privilege then
    raise notice 'PASS [W1] client insert into a canonical table denied by privilege (I-4, RD-3)';
  end;
end
$$;

do $$
begin
  begin
    update public.strength_sets set reps = 999;
    raise exception 'FAIL [W2] the client role updated a canonical table (I-4)';
  exception when insufficient_privilege then
    raise notice 'PASS [W2] client update of a canonical table denied by privilege (I-4, RD-3)';
  end;
end
$$;

do $$
begin
  begin
    update public.raw_records set payload = '{"x":1}'::jsonb;
    raise exception 'FAIL [W3] the client role updated raw_records';
  exception when insufficient_privilege then
    raise notice 'PASS [W3] client update of raw_records denied by privilege (I-2)';
  end;
end
$$;

do $$
begin
  begin
    insert into public.import_profiles
      (user_id, name, template, source_key, signature_hash, header_tokens, mapping_spec)
    values ('66666666-6666-4666-8666-666666666666', 'Forged', 'strength', 'sample_source',
            'sig-forged', array['a'], '{}'::jsonb);
    raise exception 'FAIL [W4] user A created an import profile owned by user B';
  exception when insufficient_privilege then
    raise notice 'PASS [W4] import profile insert with another user''s user_id rejected (42501)';
  end;
end
$$;

do $$
declare affected int;
begin
  update public.import_profiles set name = 'Hijacked'
   where user_id = '66666666-6666-4666-8666-666666666666';
  get diagnostics affected = row_count;
  if affected <> 0 then
    raise exception 'FAIL [W5] user A updated % of user B''s import profiles', affected;
  end if;
  raise notice 'PASS [W5] user A updated 0 of user B''s import profiles';
end
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 4. The anon role holds nothing on any Phase 2 object
-- ---------------------------------------------------------------------------

do $$
declare o text;
begin
  foreach o in array array[
    'import_profiles','data_imports','import_jobs','raw_records','import_coverage',
    'metrics','strength_workouts','strength_exercises','strength_sets',
    'v_metrics','v_strength_workouts','v_strength_exercises','v_strength_sets'
  ] loop
    if has_table_privilege('anon', 'public.' || o, 'SELECT') then
      raise exception 'FAIL [A1] the anon role can read public.%', o;
    end if;
  end loop;
  raise notice 'PASS [A1] anon holds no privilege on any of the 9 Phase 2 tables or 4 views';
end
$$;

-- ---------------------------------------------------------------------------
-- 5. The complete privilege matrix, asserted explicitly.
--
-- Supabase's default privileges grant ALL on every new public table to the
-- Data API roles, so a migration that only adds grants silently leaves write
-- access in place. That happened once already; this assertion is what stops it
-- happening again, and the harness replicates the Supabase default so it can
-- actually fire.
-- ---------------------------------------------------------------------------

do $$
declare
  expected constant text[][] := array[
    -- registries and import profiles: full CRUD on own rows
    array['sources','SELECT,INSERT,UPDATE,DELETE'],
    array['units','SELECT,INSERT,UPDATE,DELETE'],
    array['unit_conversions','SELECT,INSERT,UPDATE,DELETE'],
    array['metric_definitions','SELECT,INSERT,UPDATE,DELETE'],
    array['metric_aliases','SELECT,INSERT,UPDATE,DELETE'],
    array['exercise_definitions','SELECT,INSERT,UPDATE,DELETE'],
    array['exercise_aliases','SELECT,INSERT,UPDATE,DELETE'],
    array['activity_types','SELECT,INSERT,UPDATE,DELETE'],
    array['event_definitions','SELECT,INSERT,UPDATE,DELETE'],
    array['import_profiles','SELECT,INSERT,UPDATE,DELETE'],
    -- the client starts an import, the worker advances it
    array['data_imports','SELECT,INSERT'],
    -- read-only to the client
    array['import_jobs','SELECT'],
    array['raw_records','SELECT'],
    array['import_coverage','SELECT'],
    -- canonical tables: SELECT only (I-4 / RD-3)
    array['metrics','SELECT'],
    array['strength_workouts','SELECT'],
    array['strength_exercises','SELECT'],
    array['strength_sets','SELECT'],
    -- canonical views
    array['v_metrics','SELECT'],
    array['v_strength_workouts','SELECT'],
    array['v_strength_exercises','SELECT'],
    array['v_strength_sets','SELECT']
  ];
  row_i int;
  obj text;
  want text[];
  priv text;
  all_privs constant text[] := array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'];
  held boolean;
  should boolean;
begin
  for row_i in 1 .. array_length(expected, 1) loop
    obj  := expected[row_i][1];
    want := string_to_array(expected[row_i][2], ',');

    foreach priv in array all_privs loop
      held   := has_table_privilege('authenticated', 'public.' || obj, priv);
      should := priv = any (want);
      if held <> should then
        raise exception 'FAIL [PRIV] authenticated % on public.%: has=%, expected=%',
          priv, obj, held, should;
      end if;
      if has_table_privilege('anon', 'public.' || obj, priv) then
        raise exception 'FAIL [PRIV] anon holds % on public.%', priv, obj;
      end if;
    end loop;
  end loop;

  raise notice 'PASS [PRIV] the privilege matrix matches exactly for all % objects, and anon holds nothing', array_length(expected, 1);
end
$$;

-- No object may be left ungranted-but-writable, and none may be missed.
do $$
declare missing text;
begin
  select string_agg(c.relname, ', ')
    into missing
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind in ('r', 'v')
     and c.relname not in (
       'sources','units','unit_conversions','metric_definitions','metric_aliases',
       'exercise_definitions','exercise_aliases','activity_types','event_definitions',
       'import_profiles','data_imports','import_jobs','raw_records','import_coverage',
       'metrics','strength_workouts','strength_exercises','strength_sets',
       'v_metrics','v_strength_workouts','v_strength_exercises','v_strength_sets'
     );
  if missing is not null then
    raise exception 'FAIL [PRIV] objects exist that the privilege matrix does not cover: %', missing;
  end if;
  raise notice 'PASS [PRIV] every table and view in the schema is covered by the matrix above';
end
$$;

\echo ''
\echo '================================================================'
\echo ' PHASE 2 RLS AND VIEW SUITE: all assertions passed'
\echo '================================================================'
