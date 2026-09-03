-- ============================================================================
-- 20260903120100_registry_rls.sql
-- Phase 1 — Foundation: row level security for every registry table.
--
-- I-8: Every table carries user_id and an RLS policy, including child tables.
--      No policy may require a join. Every predicate below reads only the
--      row's own user_id column.
--
-- Read rule : user_id IS NULL (system registry) OR user_id = auth.uid()
-- Write rule: user_id = auth.uid()
--      -> a user can never insert, update or delete a system registry row
--         through the client API, and can never see or touch another user's
--         rows. Seeding system rows is done with a privileged connection
--         (service role / migration role), which bypasses RLS.
--
-- auth.uid() is wrapped in a scalar subquery so Postgres evaluates it once per
-- statement (InitPlan) rather than once per row.
--
-- The anon role is granted nothing on these tables. An unauthenticated client
-- gets "permission denied", not an empty result set.
-- ============================================================================

revoke all on all tables in schema public from anon;
revoke all on all tables in schema public from authenticated;

grant usage on schema public to authenticated;

-- ---------------------------------------------------------------------------
-- sources
-- ---------------------------------------------------------------------------

alter table public.sources enable row level security;

grant select, insert, update, delete on public.sources to authenticated;

create policy "sources_select_own_or_system"
  on public.sources
  for select
  to authenticated
  using (user_id is null or user_id = (select auth.uid()));

create policy "sources_insert_own"
  on public.sources
  for insert
  to authenticated
  with check (user_id = (select auth.uid()));

create policy "sources_update_own"
  on public.sources
  for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "sources_delete_own"
  on public.sources
  for delete
  to authenticated
  using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- units
-- ---------------------------------------------------------------------------

alter table public.units enable row level security;

grant select, insert, update, delete on public.units to authenticated;

create policy "units_select_own_or_system"
  on public.units
  for select
  to authenticated
  using (user_id is null or user_id = (select auth.uid()));

create policy "units_insert_own"
  on public.units
  for insert
  to authenticated
  with check (user_id = (select auth.uid()));

create policy "units_update_own"
  on public.units
  for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "units_delete_own"
  on public.units
  for delete
  to authenticated
  using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- unit_conversions
-- ---------------------------------------------------------------------------

alter table public.unit_conversions enable row level security;

grant select, insert, update, delete on public.unit_conversions to authenticated;

create policy "unit_conversions_select_own_or_system"
  on public.unit_conversions
  for select
  to authenticated
  using (user_id is null or user_id = (select auth.uid()));

create policy "unit_conversions_insert_own"
  on public.unit_conversions
  for insert
  to authenticated
  with check (user_id = (select auth.uid()));

create policy "unit_conversions_update_own"
  on public.unit_conversions
  for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "unit_conversions_delete_own"
  on public.unit_conversions
  for delete
  to authenticated
  using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- metric_definitions
-- ---------------------------------------------------------------------------

alter table public.metric_definitions enable row level security;

grant select, insert, update, delete on public.metric_definitions to authenticated;

create policy "metric_definitions_select_own_or_system"
  on public.metric_definitions
  for select
  to authenticated
  using (user_id is null or user_id = (select auth.uid()));

create policy "metric_definitions_insert_own"
  on public.metric_definitions
  for insert
  to authenticated
  with check (user_id = (select auth.uid()));

create policy "metric_definitions_update_own"
  on public.metric_definitions
  for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "metric_definitions_delete_own"
  on public.metric_definitions
  for delete
  to authenticated
  using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- metric_aliases
-- ---------------------------------------------------------------------------

alter table public.metric_aliases enable row level security;

grant select, insert, update, delete on public.metric_aliases to authenticated;

create policy "metric_aliases_select_own_or_system"
  on public.metric_aliases
  for select
  to authenticated
  using (user_id is null or user_id = (select auth.uid()));

create policy "metric_aliases_insert_own"
  on public.metric_aliases
  for insert
  to authenticated
  with check (user_id = (select auth.uid()));

create policy "metric_aliases_update_own"
  on public.metric_aliases
  for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "metric_aliases_delete_own"
  on public.metric_aliases
  for delete
  to authenticated
  using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- exercise_definitions
-- ---------------------------------------------------------------------------

alter table public.exercise_definitions enable row level security;

grant select, insert, update, delete on public.exercise_definitions to authenticated;

create policy "exercise_definitions_select_own_or_system"
  on public.exercise_definitions
  for select
  to authenticated
  using (user_id is null or user_id = (select auth.uid()));

create policy "exercise_definitions_insert_own"
  on public.exercise_definitions
  for insert
  to authenticated
  with check (user_id = (select auth.uid()));

create policy "exercise_definitions_update_own"
  on public.exercise_definitions
  for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "exercise_definitions_delete_own"
  on public.exercise_definitions
  for delete
  to authenticated
  using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- exercise_aliases
-- ---------------------------------------------------------------------------

alter table public.exercise_aliases enable row level security;

grant select, insert, update, delete on public.exercise_aliases to authenticated;

create policy "exercise_aliases_select_own_or_system"
  on public.exercise_aliases
  for select
  to authenticated
  using (user_id is null or user_id = (select auth.uid()));

create policy "exercise_aliases_insert_own"
  on public.exercise_aliases
  for insert
  to authenticated
  with check (user_id = (select auth.uid()));

create policy "exercise_aliases_update_own"
  on public.exercise_aliases
  for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "exercise_aliases_delete_own"
  on public.exercise_aliases
  for delete
  to authenticated
  using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- activity_types
-- ---------------------------------------------------------------------------

alter table public.activity_types enable row level security;

grant select, insert, update, delete on public.activity_types to authenticated;

create policy "activity_types_select_own_or_system"
  on public.activity_types
  for select
  to authenticated
  using (user_id is null or user_id = (select auth.uid()));

create policy "activity_types_insert_own"
  on public.activity_types
  for insert
  to authenticated
  with check (user_id = (select auth.uid()));

create policy "activity_types_update_own"
  on public.activity_types
  for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "activity_types_delete_own"
  on public.activity_types
  for delete
  to authenticated
  using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- event_definitions
-- ---------------------------------------------------------------------------

alter table public.event_definitions enable row level security;

grant select, insert, update, delete on public.event_definitions to authenticated;

create policy "event_definitions_select_own_or_system"
  on public.event_definitions
  for select
  to authenticated
  using (user_id is null or user_id = (select auth.uid()));

create policy "event_definitions_insert_own"
  on public.event_definitions
  for insert
  to authenticated
  with check (user_id = (select auth.uid()));

create policy "event_definitions_update_own"
  on public.event_definitions
  for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "event_definitions_delete_own"
  on public.event_definitions
  for delete
  to authenticated
  using (user_id = (select auth.uid()));
