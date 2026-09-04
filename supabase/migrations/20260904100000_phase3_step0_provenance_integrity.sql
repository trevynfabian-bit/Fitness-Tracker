-- ============================================================================
-- 20260904100000_phase3_step0_provenance_integrity.sql
-- Phase 3 Step 0, item 1: close the remaining ownership integrity gaps.
-- Additive and forward-only. No column is dropped, renamed or retyped.
--
-- WHAT WAS ALREADY IN PLACE BEFORE THIS MIGRATION
--
-- The provenance rule the ruling asks for is already structural, from
-- 20260904090200:
--
--     raw_records                       UNIQUE (id, user_id)
--     metrics            FOREIGN KEY (raw_record_id, user_id) -> raw_records (id, user_id)
--     strength_workouts  FOREIGN KEY (raw_record_id, user_id) -> raw_records (id, user_id)
--     strength_exercises FOREIGN KEY (raw_record_id, user_id) -> raw_records (id, user_id)
--     strength_sets      FOREIGN KEY (raw_record_id, user_id) -> raw_records (id, user_id)
--
-- so canonical.user_id = raw_record.user_id is enforced by the database for
-- every canonical row that references a raw record. This migration does not
-- change that; it closes the four references that were NOT covered.
--
-- GAP 1 - retired_by_import_id had no foreign key at all
--
-- v3 section 4.4 adds this column to make retirement undo a single indexed
-- update. It was created as a bare uuid, so a retirement could cite an import
-- that does not exist, or one belonging to another user. Closed with a
-- composite foreign key. The column stays nullable; MATCH SIMPLE skips the
-- check while it is null, which is the unretired state.
--
-- GAPS 2 to 4 - references to a registry whose owner may be NULL
--
-- data_imports.profile_id, metrics.metric_definition_id and metrics.unit_id
-- point at tables where user_id IS NULL means "shared system row" (ruling R6).
-- A composite foreign key CANNOT express the rule there: a child row with
-- user_id = X would have to match a parent tuple (id, NULL), which no
-- equality can satisfy, so every system row would become unreferenceable.
-- This is the documented case where the foreign key approach is technically
-- impossible, so the existing registry ownership trigger is used instead. It
-- is the same guard already applied to metric_aliases, exercise_aliases,
-- metric_definitions.canonical_unit_id, unit_conversions and
-- strength_exercises.exercise_definition_id.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Gap 1: retirement provenance
-- ---------------------------------------------------------------------------

alter table public.metrics
  add constraint metrics_retired_by_import_fk
    foreign key (retired_by_import_id, user_id)
    references public.data_imports (id, user_id) on delete restrict;

alter table public.strength_workouts
  add constraint strength_workouts_retired_by_import_fk
    foreign key (retired_by_import_id, user_id)
    references public.data_imports (id, user_id) on delete restrict;

alter table public.strength_sets
  add constraint strength_sets_retired_by_import_fk
    foreign key (retired_by_import_id, user_id)
    references public.data_imports (id, user_id) on delete restrict;

create index metrics_retired_by_import_idx
  on public.metrics (retired_by_import_id) where retired_by_import_id is not null;
create index strength_workouts_retired_by_import_idx
  on public.strength_workouts (retired_by_import_id) where retired_by_import_id is not null;
create index strength_sets_retired_by_import_idx
  on public.strength_sets (retired_by_import_id) where retired_by_import_id is not null;

-- ---------------------------------------------------------------------------
-- Gaps 2 to 4: nullable-owner registry references
-- ---------------------------------------------------------------------------

create trigger data_imports_profile_ownership
  before insert or update on public.data_imports
  for each row execute function public.registry_assert_parent_ownership('import_profiles', 'profile_id');

-- metrics takes bulk inserts, so these two triggers cost one indexed primary
-- key lookup per row each. At the volumes v3 section 2.5 projects (15,000 to
-- 40,000 raw records per year) that is not worth trading correctness for.
create trigger metrics_definition_ownership
  before insert or update on public.metrics
  for each row execute function public.registry_assert_parent_ownership('metric_definitions', 'metric_definition_id');

create trigger metrics_unit_ownership
  before insert or update on public.metrics
  for each row execute function public.registry_assert_parent_ownership('units', 'unit_id');

comment on constraint metrics_retired_by_import_fk on public.metrics is
  'A retirement may only cite an import belonging to the same user as the row being retired.';
