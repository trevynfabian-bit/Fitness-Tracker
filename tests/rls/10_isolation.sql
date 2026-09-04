-- ============================================================================
-- 10_isolation.sql
-- Phase 1 exit-criterion verification: RLS user isolation.
--
-- Every statement that reads or writes registry data below runs as the
-- `authenticated` Postgres role with a JWT claim set, i.e. exactly the context
-- a Supabase client request runs in. The service role is NOT used anywhere in
-- this file. Only the auth.users fixture rows are created with the privileged
-- connection, because signup is the auth server's job, not the client's.
--
-- Run with: psql -v ON_ERROR_STOP=1 -f tests/rls/10_isolation.sql
-- Any FAIL raises an exception and aborts with a non-zero exit code.
-- ============================================================================

\set QUIET on
\set user_a '11111111-1111-4111-8111-111111111111'
\set user_b '22222222-2222-4222-8222-222222222222'
\set claims_a '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}'
\set claims_b '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}'
\set QUIET off

-- ---------------------------------------------------------------------------
-- 0. Structural checks — I-8
-- ---------------------------------------------------------------------------

do $$
declare
  expected text[] := array[
    'sources','units','unit_conversions','metric_definitions','metric_aliases',
    'exercise_definitions','exercise_aliases','activity_types','event_definitions'
  ];
  t text;
  has_user_id boolean;
  rls_on boolean;
  policy_count int;
begin
  foreach t in array expected loop
    select c.relrowsecurity into rls_on
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = t;

    if rls_on is null then
      raise exception 'FAIL [0] table public.% does not exist', t;
    end if;
    if not rls_on then
      raise exception 'FAIL [0] RLS is not enabled on public.%', t;
    end if;

    select exists (
      select 1 from information_schema.columns
       where table_schema = 'public' and table_name = t and column_name = 'user_id'
    ) into has_user_id;
    if not has_user_id then
      raise exception 'FAIL [0] public.% has no user_id column (I-8)', t;
    end if;

    select count(*) into policy_count
      from pg_policies where schemaname = 'public' and tablename = t;
    if policy_count < 4 then
      raise exception 'FAIL [0] public.% has only % policies, expected select/insert/update/delete', t, policy_count;
    end if;
  end loop;

  raise notice 'PASS [0] all 9 registry tables: RLS enabled, user_id present, 4 policies each';
end
$$;

do $$
declare bad record;
begin
  -- I-8: no policy may require a join. A join would show up as a subquery over
  -- another relation inside the policy expression.
  for bad in
    select tablename, policyname, coalesce(qual, '') || ' ' || coalesce(with_check, '') as expr
      from pg_policies where schemaname = 'public'
  loop
    if bad.expr ~* '\yfrom\y' then
      raise exception 'FAIL [0] policy %.% appears to reference another relation: %',
        bad.tablename, bad.policyname, bad.expr;
    end if;
  end loop;
  raise notice 'PASS [0] no RLS policy references another relation (join-free, I-8)';
end
$$;

-- ---------------------------------------------------------------------------
-- 1. Fixture: two auth users (privileged connection — this is the auth server)
-- ---------------------------------------------------------------------------

insert into auth.users (id, email)
values
  (:'user_a', 'user-a@rls-test.invalid'),
  (:'user_b', 'user-b@rls-test.invalid')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 2. User A creates its own registry rows, as an authenticated client
-- ---------------------------------------------------------------------------

begin;
set local request.jwt.claims = :'claims_a';
set local role authenticated;

do $$
begin
  if auth.uid() is null then
    raise exception 'FAIL [2] auth.uid() is null; the JWT claim shim is not working';
  end if;
  if current_user <> 'authenticated' then
    raise exception 'FAIL [2] running as %, expected authenticated', current_user;
  end if;
end
$$;

insert into public.sources (user_id, source_key, display_name, precedence_rank)
values (auth.uid(), 'private_scale', 'Private Scale', 10);

insert into public.units (user_id, key, display_name, symbol, dimension)
values (auth.uid(), 'stone', 'Stone', 'st', 'mass');

insert into public.unit_conversions (user_id, from_unit_id, to_unit_id, factor)
select auth.uid(), s.id, k.id, 6.350293180000000
from public.units s, public.units k
where s.key = 'stone' and s.user_id = auth.uid()
  and k.key = 'kg' and k.user_id is null;

insert into public.metric_definitions (user_id, key, display_name, canonical_unit_id, default_aggregation)
select auth.uid(), 'private_metric', 'Private Metric', u.id, 'mean'
from public.units u where u.key = 'kg' and u.user_id is null;

insert into public.metric_aliases (user_id, metric_definition_id, alias_normalized)
select auth.uid(), d.id, 'my private column'
from public.metric_definitions d where d.key = 'private_metric' and d.user_id = auth.uid();

insert into public.exercise_definitions (user_id, key, display_name)
values (auth.uid(), 'private_lift', 'Private Lift');

insert into public.exercise_aliases (user_id, exercise_definition_id, alias_normalized)
select auth.uid(), e.id, 'my private lift'
from public.exercise_definitions e where e.key = 'private_lift' and e.user_id = auth.uid();

insert into public.activity_types (user_id, key, display_name)
values (auth.uid(), 'private_activity', 'Private Activity');

insert into public.event_definitions (user_id, key, display_name)
values (auth.uid(), 'private_event', 'Private Event');

commit;

-- ---------------------------------------------------------------------------
-- 3. User B creates structurally identical rows (same keys, different owner)
-- ---------------------------------------------------------------------------

begin;
set local request.jwt.claims = :'claims_b';
set local role authenticated;

insert into public.sources (user_id, source_key, display_name, precedence_rank)
values (auth.uid(), 'private_scale', 'Private Scale', 10);

insert into public.units (user_id, key, display_name, symbol, dimension)
values (auth.uid(), 'stone', 'Stone', 'st', 'mass');

insert into public.unit_conversions (user_id, from_unit_id, to_unit_id, factor)
select auth.uid(), s.id, k.id, 6.350293180000000
from public.units s, public.units k
where s.key = 'stone' and s.user_id = auth.uid()
  and k.key = 'kg' and k.user_id is null;

insert into public.metric_definitions (user_id, key, display_name, canonical_unit_id, default_aggregation)
select auth.uid(), 'private_metric', 'Private Metric', u.id, 'mean'
from public.units u where u.key = 'kg' and u.user_id is null;

insert into public.metric_aliases (user_id, metric_definition_id, alias_normalized)
select auth.uid(), d.id, 'my private column'
from public.metric_definitions d where d.key = 'private_metric' and d.user_id = auth.uid();

insert into public.exercise_definitions (user_id, key, display_name)
values (auth.uid(), 'private_lift', 'Private Lift');

insert into public.exercise_aliases (user_id, exercise_definition_id, alias_normalized)
select auth.uid(), e.id, 'my private lift'
from public.exercise_definitions e where e.key = 'private_lift' and e.user_id = auth.uid();

insert into public.activity_types (user_id, key, display_name)
values (auth.uid(), 'private_activity', 'Private Activity');

insert into public.event_definitions (user_id, key, display_name)
values (auth.uid(), 'private_event', 'Private Event');

commit;

-- Capture user B's private definition id with the privileged connection so the
-- cross-user reference test below can attempt to use a primary key that RLS
-- would never have revealed to user A.
\o /dev/null
select set_config(
  'rls_test.user_b_definition_id',
  (select id::text from public.metric_definitions
    where user_id = '22222222-2222-4222-8222-222222222222'),
  false
);
\o

do $$
declare total bigint;
begin
  select (select count(*) from public.sources where user_id is not null)
       + (select count(*) from public.units where user_id is not null)
       + (select count(*) from public.unit_conversions where user_id is not null)
       + (select count(*) from public.metric_definitions where user_id is not null)
       + (select count(*) from public.metric_aliases where user_id is not null)
       + (select count(*) from public.exercise_definitions where user_id is not null)
       + (select count(*) from public.exercise_aliases where user_id is not null)
       + (select count(*) from public.activity_types where user_id is not null)
       + (select count(*) from public.event_definitions where user_id is not null)
    into total;
  if total <> 18 then
    raise exception 'FAIL [1] fixture: expected 18 user-owned rows in total (9 per user), found %', total;
  end if;
  raise notice 'PASS [1] fixture: 18 user-owned registry rows created by the two authenticated users';
end
$$;

-- ---------------------------------------------------------------------------
-- 4. CRITERION 1 — User A can read its own rows
-- ---------------------------------------------------------------------------

begin;
set local request.jwt.claims = :'claims_a';
set local role authenticated;

do $$
declare own bigint; sys bigint;
begin
  select (select count(*) from public.sources              where user_id = auth.uid())
       + (select count(*) from public.units                where user_id = auth.uid())
       + (select count(*) from public.unit_conversions     where user_id = auth.uid())
       + (select count(*) from public.metric_definitions   where user_id = auth.uid())
       + (select count(*) from public.metric_aliases       where user_id = auth.uid())
       + (select count(*) from public.exercise_definitions where user_id = auth.uid())
       + (select count(*) from public.exercise_aliases     where user_id = auth.uid())
       + (select count(*) from public.activity_types       where user_id = auth.uid())
       + (select count(*) from public.event_definitions    where user_id = auth.uid())
    into own;
  if own <> 9 then
    raise exception 'FAIL [C1] user A can read % of its own 9 rows', own;
  end if;

  select count(*) into sys from public.metric_definitions where user_id is null;
  if sys <> 9 then
    raise exception 'FAIL [C1] user A sees % system metric definitions, expected 9', sys;
  end if;

  raise notice 'PASS [C1] user A reads all 9 of its own registry rows and all 9 system metric definitions';
end
$$;

commit;

-- ---------------------------------------------------------------------------
-- 5. CRITERION 2 — User B can read its own rows
-- ---------------------------------------------------------------------------

begin;
set local request.jwt.claims = :'claims_b';
set local role authenticated;

do $$
declare own bigint; sys bigint;
begin
  select (select count(*) from public.sources              where user_id = auth.uid())
       + (select count(*) from public.units                where user_id = auth.uid())
       + (select count(*) from public.unit_conversions     where user_id = auth.uid())
       + (select count(*) from public.metric_definitions   where user_id = auth.uid())
       + (select count(*) from public.metric_aliases       where user_id = auth.uid())
       + (select count(*) from public.exercise_definitions where user_id = auth.uid())
       + (select count(*) from public.exercise_aliases     where user_id = auth.uid())
       + (select count(*) from public.activity_types       where user_id = auth.uid())
       + (select count(*) from public.event_definitions    where user_id = auth.uid())
    into own;
  if own <> 9 then
    raise exception 'FAIL [C2] user B can read % of its own 9 rows', own;
  end if;

  select count(*) into sys from public.metric_definitions where user_id is null;
  if sys <> 9 then
    raise exception 'FAIL [C2] user B sees % system metric definitions, expected 9', sys;
  end if;

  raise notice 'PASS [C2] user B reads all 9 of its own registry rows and all 9 system metric definitions';
end
$$;

commit;

-- ---------------------------------------------------------------------------
-- 6. CRITERION 3 — User A cannot read User B's rows
-- ---------------------------------------------------------------------------

begin;
set local request.jwt.claims = :'claims_a';
set local role authenticated;

do $$
declare
  other_uid uuid := '22222222-2222-4222-8222-222222222222';
  leaked bigint;
  foreign_rows bigint;
begin
  select (select count(*) from public.sources              where user_id = other_uid)
       + (select count(*) from public.units                where user_id = other_uid)
       + (select count(*) from public.unit_conversions     where user_id = other_uid)
       + (select count(*) from public.metric_definitions   where user_id = other_uid)
       + (select count(*) from public.metric_aliases       where user_id = other_uid)
       + (select count(*) from public.exercise_definitions where user_id = other_uid)
       + (select count(*) from public.exercise_aliases     where user_id = other_uid)
       + (select count(*) from public.activity_types       where user_id = other_uid)
       + (select count(*) from public.event_definitions    where user_id = other_uid)
    into leaked;
  if leaked <> 0 then
    raise exception 'FAIL [C3] user A can read % rows belonging to user B', leaked;
  end if;

  -- Unfiltered reads must also contain nothing owned by anyone else.
  select (select count(*) from public.sources              where user_id is not null and user_id <> auth.uid())
       + (select count(*) from public.units                where user_id is not null and user_id <> auth.uid())
       + (select count(*) from public.unit_conversions     where user_id is not null and user_id <> auth.uid())
       + (select count(*) from public.metric_definitions   where user_id is not null and user_id <> auth.uid())
       + (select count(*) from public.metric_aliases       where user_id is not null and user_id <> auth.uid())
       + (select count(*) from public.exercise_definitions where user_id is not null and user_id <> auth.uid())
       + (select count(*) from public.exercise_aliases     where user_id is not null and user_id <> auth.uid())
       + (select count(*) from public.activity_types       where user_id is not null and user_id <> auth.uid())
       + (select count(*) from public.event_definitions    where user_id is not null and user_id <> auth.uid())
    into foreign_rows;
  if foreign_rows <> 0 then
    raise exception 'FAIL [C3] an unfiltered read by user A returned % foreign rows', foreign_rows;
  end if;

  raise notice 'PASS [C3] user A reads 0 of user B''s rows, filtered and unfiltered, across all 9 tables';
end
$$;

commit;

-- ---------------------------------------------------------------------------
-- 7. CRITERION 4 — User B cannot read User A's rows
-- ---------------------------------------------------------------------------

begin;
set local request.jwt.claims = :'claims_b';
set local role authenticated;

do $$
declare
  other_uid uuid := '11111111-1111-4111-8111-111111111111';
  leaked bigint;
  foreign_rows bigint;
begin
  select (select count(*) from public.sources              where user_id = other_uid)
       + (select count(*) from public.units                where user_id = other_uid)
       + (select count(*) from public.unit_conversions     where user_id = other_uid)
       + (select count(*) from public.metric_definitions   where user_id = other_uid)
       + (select count(*) from public.metric_aliases       where user_id = other_uid)
       + (select count(*) from public.exercise_definitions where user_id = other_uid)
       + (select count(*) from public.exercise_aliases     where user_id = other_uid)
       + (select count(*) from public.activity_types       where user_id = other_uid)
       + (select count(*) from public.event_definitions    where user_id = other_uid)
    into leaked;
  if leaked <> 0 then
    raise exception 'FAIL [C4] user B can read % rows belonging to user A', leaked;
  end if;

  select (select count(*) from public.sources              where user_id is not null and user_id <> auth.uid())
       + (select count(*) from public.units                where user_id is not null and user_id <> auth.uid())
       + (select count(*) from public.unit_conversions     where user_id is not null and user_id <> auth.uid())
       + (select count(*) from public.metric_definitions   where user_id is not null and user_id <> auth.uid())
       + (select count(*) from public.metric_aliases       where user_id is not null and user_id <> auth.uid())
       + (select count(*) from public.exercise_definitions where user_id is not null and user_id <> auth.uid())
       + (select count(*) from public.exercise_aliases     where user_id is not null and user_id <> auth.uid())
       + (select count(*) from public.activity_types       where user_id is not null and user_id <> auth.uid())
       + (select count(*) from public.event_definitions    where user_id is not null and user_id <> auth.uid())
    into foreign_rows;
  if foreign_rows <> 0 then
    raise exception 'FAIL [C4] an unfiltered read by user B returned % foreign rows', foreign_rows;
  end if;

  raise notice 'PASS [C4] user B reads 0 of user A''s rows, filtered and unfiltered, across all 9 tables';
end
$$;

commit;

-- ---------------------------------------------------------------------------
-- 8. Write isolation — A cannot forge, mutate or delete anything it does not own
-- ---------------------------------------------------------------------------

begin;
set local request.jwt.claims = :'claims_a';
set local role authenticated;

do $$
begin
  begin
    insert into public.activity_types (user_id, key, display_name)
    values ('22222222-2222-4222-8222-222222222222', 'forged_activity', 'Forged');
    raise exception 'FAIL [W1] user A inserted a row owned by user B';
  exception when insufficient_privilege then
    raise notice 'PASS [W1] insert with another user''s user_id rejected (42501)';
  end;
end
$$;

do $$
begin
  begin
    insert into public.activity_types (key, display_name)
    values ('orphan_activity', 'Orphan');
    raise exception 'FAIL [W2] user A inserted a system row (user_id NULL)';
  exception when insufficient_privilege then
    raise notice 'PASS [W2] insert of a system row (user_id NULL) rejected (42501)';
  end;
end
$$;

do $$
declare affected int;
begin
  update public.activity_types set display_name = 'Hijacked'
   where user_id = '22222222-2222-4222-8222-222222222222';
  get diagnostics affected = row_count;
  if affected <> 0 then
    raise exception 'FAIL [W3] user A updated % of user B''s rows', affected;
  end if;
  raise notice 'PASS [W3] user A updated 0 of user B''s rows';
end
$$;

do $$
declare affected int;
begin
  delete from public.activity_types where user_id = '22222222-2222-4222-8222-222222222222';
  get diagnostics affected = row_count;
  if affected <> 0 then
    raise exception 'FAIL [W4] user A deleted % of user B''s rows', affected;
  end if;

  delete from public.metric_definitions where user_id is null;
  get diagnostics affected = row_count;
  if affected <> 0 then
    raise exception 'FAIL [W4] user A deleted % system registry rows', affected;
  end if;

  update public.metric_definitions set display_name = 'Tampered' where user_id is null;
  get diagnostics affected = row_count;
  if affected <> 0 then
    raise exception 'FAIL [W4] user A updated % system registry rows', affected;
  end if;

  raise notice 'PASS [W4] user A deleted 0 of user B''s rows and cannot mutate or delete system registry rows';
end
$$;

do $$
declare b_definition uuid;
begin
  -- Ownership trigger: A must not be able to attach an alias to B's private
  -- definition, even knowing its primary key.
  select id into b_definition
    from public.metric_definitions
   where user_id = '22222222-2222-4222-8222-222222222222';

  if b_definition is not null then
    raise exception 'FAIL [W5] user A could read user B''s definition id through RLS';
  end if;

  select current_setting('rls_test.user_b_definition_id', true)::uuid into b_definition;
  if b_definition is null then
    raise exception 'FAIL [W5] fixture: user B definition id was not captured';
  end if;

  begin
    insert into public.metric_aliases (user_id, metric_definition_id, alias_normalized)
    values (auth.uid(), b_definition, 'stolen alias');
    raise exception 'FAIL [W5] user A attached an alias to user B''s private definition';
  exception when insufficient_privilege then
    raise notice 'PASS [W5] cross-user parent reference rejected by ownership trigger (42501)';
  end;
end
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 9. Unauthenticated database contexts
-- ---------------------------------------------------------------------------

begin;
set local role anon;

do $$
declare n bigint;
begin
  begin
    select count(*) into n from public.metric_definitions;
    raise exception 'FAIL [A1] the anon role could read metric_definitions (% rows)', n;
  exception when insufficient_privilege then
    raise notice 'PASS [A1] anon role denied on public.metric_definitions (42501)';
  end;
end
$$;

rollback;

begin;
-- authenticated role, but no JWT claims: auth.uid() is NULL.
set local request.jwt.claims = '';
set local role authenticated;

do $$
declare user_rows bigint;
begin
  if auth.uid() is not null then
    raise exception 'FAIL [A2] auth.uid() is not null without claims';
  end if;

  select (select count(*) from public.sources              where user_id is not null)
       + (select count(*) from public.units                where user_id is not null)
       + (select count(*) from public.metric_definitions   where user_id is not null)
       + (select count(*) from public.metric_aliases       where user_id is not null)
       + (select count(*) from public.exercise_definitions where user_id is not null)
       + (select count(*) from public.activity_types       where user_id is not null)
       + (select count(*) from public.event_definitions    where user_id is not null)
    into user_rows;
  if user_rows <> 0 then
    raise exception 'FAIL [A2] a claimless session read % user-owned rows', user_rows;
  end if;
  raise notice 'PASS [A2] a session with no JWT subject reads 0 user-owned rows';
end
$$;

rollback;

\echo ''
\echo '================================================================'
\echo ' RLS ISOLATION SUITE: all assertions passed'
\echo '================================================================'
