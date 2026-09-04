-- ============================================================================
-- 20260904090300_phase2_views_and_rls.sql
-- Phase 2 - Data foundation: canonical views, RLS and grants.
--
--   I-5   Application code queries views, not canonical tables. The views
--         apply retired_at IS NULL so a retired record cannot reappear in a
--         trend line.
--   R3    strength_workouts is the retirement root. v_strength_exercises and
--         v_strength_sets exclude descendants of a retired workout, so a
--         retired workout never leaves visible orphan exercises or sets.
--   I-8   Every table carries user_id and a join-free RLS policy.
--   I-4   Application code never updates a canonical table. Enforced here by
--         privilege: authenticated is granted SELECT only on metrics,
--         strength_workouts, strength_exercises and strength_sets, so the
--         statement cannot be issued at all (RD-3).
--
-- Views are declared security_invoker so they evaluate the caller's RLS.
-- Without it a view runs as its owner and silently bypasses row level
-- security, which would defeat the whole isolation model.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Canonical views (I-5, R3)
-- ---------------------------------------------------------------------------

create view public.v_metrics with (security_invoker = true) as
  select *
    from public.metrics
   where retired_at is null;

create view public.v_strength_workouts with (security_invoker = true) as
  select *
    from public.strength_workouts
   where retired_at is null;

-- R3: an exercise is visible only while its workout is.
create view public.v_strength_exercises with (security_invoker = true) as
  select e.*
    from public.strength_exercises e
    join public.strength_workouts w on w.id = e.workout_id
   where w.retired_at is null;

-- R3: a set is visible only while its own retired_at is null AND its workout
-- is not retired. The exercise join carries the hierarchy; exercises have no
-- retirement state of their own by design.
create view public.v_strength_sets with (security_invoker = true) as
  select s.*
    from public.strength_sets s
    join public.strength_exercises e on e.id = s.exercise_id
    join public.strength_workouts w on w.id = e.workout_id
   where s.retired_at is null
     and w.retired_at is null;

comment on view public.v_metrics is
  'I-5. Query this, never public.metrics.';
comment on view public.v_strength_workouts is
  'I-5. Query this, never public.strength_workouts.';
comment on view public.v_strength_exercises is
  'I-5, R3. Excludes exercises whose workout has been retired.';
comment on view public.v_strength_sets is
  'I-5, R3. Excludes sets that are retired themselves and sets whose workout has been retired.';

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.import_profiles  enable row level security;
alter table public.data_imports     enable row level security;
alter table public.import_jobs      enable row level security;
alter table public.raw_records      enable row level security;
alter table public.import_coverage  enable row level security;
alter table public.metrics          enable row level security;
alter table public.strength_workouts   enable row level security;
alter table public.strength_exercises  enable row level security;
alter table public.strength_sets       enable row level security;

-- ---------------------------------------------------------------------------
-- import_profiles
--   Same ownership model as the Phase 1 registries (R6): system profiles are
--   shared and read-only, user profiles are private and writable.
-- ---------------------------------------------------------------------------

grant select, insert, update, delete on public.import_profiles to authenticated;

create policy "import_profiles_select_own_or_system"
  on public.import_profiles for select to authenticated
  using (user_id is null or user_id = (select auth.uid()));

create policy "import_profiles_insert_own"
  on public.import_profiles for insert to authenticated
  with check (user_id = (select auth.uid()));

create policy "import_profiles_update_own"
  on public.import_profiles for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "import_profiles_delete_own"
  on public.import_profiles for delete to authenticated
  using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- data_imports
--   The client starts an import; the worker advances it. Grant INSERT so an
--   import can be created, but no UPDATE or DELETE: status transitions,
--   counters and rollback are the worker's, on an elevated connection.
-- ---------------------------------------------------------------------------

grant select, insert on public.data_imports to authenticated;

create policy "data_imports_select_own"
  on public.data_imports for select to authenticated
  using (user_id = (select auth.uid()));

create policy "data_imports_insert_own"
  on public.data_imports for insert to authenticated
  with check (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- import_jobs, raw_records, import_coverage
--   Read-only to the client. Jobs are polled for progress, raw records are
--   read for provenance, coverage is read for addressability. All three are
--   written only by the worker.
--
--   raw_records additionally carries the append-only trigger (I-2), which
--   applies to every role including the worker's.
-- ---------------------------------------------------------------------------

grant select on public.import_jobs to authenticated;

create policy "import_jobs_select_own"
  on public.import_jobs for select to authenticated
  using (user_id = (select auth.uid()));

grant select on public.raw_records to authenticated;

create policy "raw_records_select_own"
  on public.raw_records for select to authenticated
  using (user_id = (select auth.uid()));

grant select on public.import_coverage to authenticated;

create policy "import_coverage_select_own"
  on public.import_coverage for select to authenticated
  using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Canonical tables
--   SELECT only, for every canonical table. This is how I-4 is enforced
--   (RD-3): an UPDATE against metrics from application code is not a policy
--   violation to be caught in review, it is a privilege the role does not
--   hold. Normalization writes on an elevated connection.
--
--   Application code should read the v_* views rather than these tables; the
--   SELECT grant exists so the views resolve and so provenance queries work.
-- ---------------------------------------------------------------------------

grant select on public.metrics to authenticated;

create policy "metrics_select_own"
  on public.metrics for select to authenticated
  using (user_id = (select auth.uid()));

grant select on public.strength_workouts to authenticated;

create policy "strength_workouts_select_own"
  on public.strength_workouts for select to authenticated
  using (user_id = (select auth.uid()));

grant select on public.strength_exercises to authenticated;

create policy "strength_exercises_select_own"
  on public.strength_exercises for select to authenticated
  using (user_id = (select auth.uid()));

grant select on public.strength_sets to authenticated;

create policy "strength_sets_select_own"
  on public.strength_sets for select to authenticated
  using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Views inherit RLS from their base tables through security_invoker, but the
-- caller still needs the privilege on the view itself.
-- ---------------------------------------------------------------------------

grant select on public.v_metrics             to authenticated;
grant select on public.v_strength_workouts   to authenticated;
grant select on public.v_strength_exercises  to authenticated;
grant select on public.v_strength_sets       to authenticated;

-- The anon role is granted nothing on any Phase 2 object.
revoke all on public.import_profiles, public.data_imports, public.import_jobs,
              public.raw_records, public.import_coverage, public.metrics,
              public.strength_workouts, public.strength_exercises, public.strength_sets
  from anon;
revoke all on public.v_metrics, public.v_strength_workouts,
              public.v_strength_exercises, public.v_strength_sets
  from anon;
