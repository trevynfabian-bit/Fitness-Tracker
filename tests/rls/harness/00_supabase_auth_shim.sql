-- ============================================================================
-- 00_supabase_auth_shim.sql
-- TEST HARNESS ONLY. Never applied to a Supabase project.
--
-- Supabase provides the auth schema, the auth.users table, the auth.uid()
-- helper and the anon / authenticated / service_role roles. A bare PostgreSQL
-- instance does not. This file recreates the minimum surface the Phase 1
-- migrations depend on so the migrations and the RLS policies can be executed
-- and verified against a real Postgres server.
--
-- auth.uid() below is the same expression Supabase ships.
-- ============================================================================

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end
$$;

create schema if not exists auth;

create table if not exists auth.users (
  id                  uuid primary key default gen_random_uuid(),
  email               text unique,
  encrypted_password  text,
  created_at          timestamptz not null default now()
);

create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

create or replace function auth.role()
returns text
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$$;

-- Supabase grants ALL on every newly created public table to the Data API
-- roles by default (the `auto_expose_new_tables` cloud default). A migration
-- that creates a table and only ADDS grants therefore leaves the defaults in
-- place. Replicating that here is what makes this harness able to catch such a
-- migration; without it the harness reports privileges the real database does
-- not have.
alter default privileges in schema public
  grant all on tables to anon, authenticated, service_role;

grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
grant execute on function auth.role() to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;
