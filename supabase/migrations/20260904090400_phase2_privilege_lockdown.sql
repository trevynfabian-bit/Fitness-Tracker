-- ============================================================================
-- 20260904090400_phase2_privilege_lockdown.sql
-- Phase 2 - corrective, forward-only.
--
-- THE BUG THIS FIXES
--
-- Supabase grants ALL privileges on every newly created table in the public
-- schema to anon, authenticated and service_role, through default privileges
-- (the auto_expose_new_tables cloud default). A migration that creates a table
-- and then only ADDS grants leaves those defaults in place.
--
-- 20260904090100 and 20260904090200 created the nine Phase 2 tables.
-- 20260904090300 granted SELECT on the canonical ones and relied on there
-- being nothing else to take away. There was: on a real Supabase database the
-- authenticated role held INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES and
-- TRIGGER on metrics, raw_records, strength_workouts, strength_exercises and
-- strength_sets.
--
-- Row level security limited the damage, because those tables carry only
-- SELECT policies, so an UPDATE or DELETE matched zero rows. TRUNCATE is the
-- exception: it is not filtered by row level security at all. The privilege
-- had to go regardless, because RD-3 states that I-4 is enforced by privilege
-- and that statement was not true.
--
-- 20260903120100 avoided this for the Phase 1 registries only because it
-- opened with an explicit REVOKE. This migration makes that structural rather
-- than a thing each migration must remember.
--
-- Found by querying a real Supabase database. The plain-Postgres test harness
-- had no such default privileges and reported a clean privilege matrix; the
-- harness now replicates the Supabase default so it can catch this class of
-- mistake.
-- ============================================================================

-- 1. Take everything back, including whatever the defaults granted. This
--    covers views as well as tables.
revoke all on all tables in schema public from anon;
revoke all on all tables in schema public from authenticated;
revoke all on all sequences in schema public from anon;
revoke all on all sequences in schema public from authenticated;

-- 2. Stop the defaults from re-creating the problem on every future table.
--    From here on a table is reachable by the Data API only if a migration
--    grants it explicitly.
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on tables from authenticated;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke all on sequences from authenticated;

-- 3. Re-grant the intended matrix in full, for every object in the schema, so
--    this migration is the single authoritative statement of who may do what.
--    anon appears nowhere: it holds no privilege on any object.

grant usage on schema public to authenticated;

-- Registries (Phase 1): read system rows and own rows, write own rows.
grant select, insert, update, delete on public.sources              to authenticated;
grant select, insert, update, delete on public.units                to authenticated;
grant select, insert, update, delete on public.unit_conversions     to authenticated;
grant select, insert, update, delete on public.metric_definitions   to authenticated;
grant select, insert, update, delete on public.metric_aliases       to authenticated;
grant select, insert, update, delete on public.exercise_definitions to authenticated;
grant select, insert, update, delete on public.exercise_aliases     to authenticated;
grant select, insert, update, delete on public.activity_types       to authenticated;
grant select, insert, update, delete on public.event_definitions    to authenticated;

-- Import profiles: same ownership model as the registries.
grant select, insert, update, delete on public.import_profiles to authenticated;

-- The client starts an import; the worker advances it.
grant select, insert on public.data_imports to authenticated;

-- Read-only to the client: progress, provenance, addressability.
grant select on public.import_jobs     to authenticated;
grant select on public.raw_records     to authenticated;
grant select on public.import_coverage to authenticated;

-- Canonical tables: SELECT and nothing else. This is I-4 (RD-3): an UPDATE
-- against metrics from application code is a privilege the role does not
-- hold, not a convention to be enforced in review.
grant select on public.metrics            to authenticated;
grant select on public.strength_workouts  to authenticated;
grant select on public.strength_exercises to authenticated;
grant select on public.strength_sets      to authenticated;

-- Canonical views (I-5): what application code should actually read.
grant select on public.v_metrics            to authenticated;
grant select on public.v_strength_workouts  to authenticated;
grant select on public.v_strength_exercises to authenticated;
grant select on public.v_strength_sets      to authenticated;

-- Sequences backing the BIGSERIAL keys are the worker's business only. No
-- grant is issued: the authenticated role cannot insert into those tables.
