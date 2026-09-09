-- ============================================================================
-- 20260904100100_phase3_step0_reconciliation.sql
-- Phase 3 Step 0, item 2: the schema the Hevy hard gate needs.
--
-- Specification: v3 section 4.1 (lifecycle), 4.2 (the plan), 4.3 (guards and
-- overrides), 4.4 (soft retirement and undo); PRD section 11; I-10.
--
-- This migration adds no engine logic. It adds the two tables and the
-- structural rules that make the required behaviour impossible to skip:
--
--   * retirement cannot happen without a persisted, confirmed, non-blocked
--     plan that names the row being retired (I-10, G4 step 3 to 5);
--   * a manual record can never be retired, by anyone, with no override
--     (G9);
--   * an override row cannot even be recorded for a non-overridable guard,
--     G9 included (v3 section 4.3);
--   * the plan body is immutable once computed, so confirmation cannot
--     quietly enlarge the retirement it was shown for.
--
-- DOCUMENTED GAP CLOSURE
--
-- v3 section 4.2's prose requires that "retirement executes against the
-- persisted plan's key set, not against a freshly recomputed one", which is
-- what closes the time-of-check-to-time-of-use window. Its DDL stores only
-- retire_key_sample, "up to 50 examples ... for the UI", which cannot serve
-- that purpose. retire_natural_keys is added to hold the actual key set the
-- plan was computed over. This is the minimum needed to implement v3's own
-- stated behaviour, and is recorded here rather than decided silently.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- reconciliation_plans (v3 section 4.2)
-- ---------------------------------------------------------------------------

create table public.reconciliation_plans (
  id                       uuid primary key default gen_random_uuid(),
  user_id                  uuid not null references auth.users (id) on delete cascade,
  import_id                uuid not null,
  computed_at              timestamptz not null default now(),
  scope                    jsonb not null,
  add_count                integer not null,
  update_count             integer not null,
  unchanged_count          integer not null,
  retire_count             integer not null,
  existing_in_scope_count  integer not null,
  retire_ratio             numeric(6,4) not null,
  retire_key_sample        jsonb not null default '[]'::jsonb,
  retire_date_histogram    jsonb not null default '{}'::jsonb,
  retire_natural_keys      text[] not null default '{}'::text[],
  guard_results            jsonb not null default '[]'::jsonb,
  verdict                  text not null,
  decision                 text,
  decided_at               timestamptz,
  decided_reason           text,
  created_at               timestamptz not null default now(),

  constraint reconciliation_plans_verdict_allowed
    check (verdict in ('safe', 'warn', 'blocked')),
  constraint reconciliation_plans_decision_allowed
    check (decision is null or decision in ('confirmed', 'skipped', 'cancelled')),
  constraint reconciliation_plans_decision_timestamped
    check ((decision is null) = (decided_at is null)),
  constraint reconciliation_plans_counts_non_negative
    check (add_count >= 0 and update_count >= 0 and unchanged_count >= 0
           and retire_count >= 0 and existing_in_scope_count >= 0),
  constraint reconciliation_plans_ratio_range
    check (retire_ratio >= 0 and retire_ratio <= 1),

  -- The persisted key set must be complete, not a sample. Retirement executes
  -- against it, so a partial set would silently under-retire or, worse, invite
  -- a recompute at execution time (v3 section 4.2).
  constraint reconciliation_plans_key_set_complete
    check (coalesce(array_length(retire_natural_keys, 1), 0) = retire_count),

  -- A blocked plan can never be confirmed. This is the database-level half of
  -- G1, G2, G3, G4, G7, G8 and G9: whatever the engine decides, a plan whose
  -- verdict is blocked cannot reach the state that permits retirement.
  constraint reconciliation_plans_blocked_is_never_confirmed
    check (verdict <> 'blocked' or decision is distinct from 'confirmed'),

  -- v3 section 4.2: a plan older than 24 hours at confirmation time is
  -- invalidated and must be recomputed.
  constraint reconciliation_plans_confirmation_not_stale
    check (decision is distinct from 'confirmed'
           or decided_at <= computed_at + interval '24 hours'),

  constraint reconciliation_plans_import_fk
    foreign key (import_id, user_id)
    references public.data_imports (id, user_id) on delete cascade,

  constraint reconciliation_plans_id_user_uq unique (id, user_id)
);

-- At most one confirmed plan per import: retirement happens once, against one
-- agreed key set.
create unique index reconciliation_plans_one_confirmed_per_import
  on public.reconciliation_plans (import_id) where decision = 'confirmed';
create index reconciliation_plans_user_id_idx on public.reconciliation_plans (user_id);
create index reconciliation_plans_import_idx on public.reconciliation_plans (import_id);
create index reconciliation_plans_pending_idx
  on public.reconciliation_plans (user_id, computed_at desc) where decision is null;
-- Membership lookups from the retirement guard below.
create index reconciliation_plans_retire_keys_gin
  on public.reconciliation_plans using gin (retire_natural_keys);

comment on table public.reconciliation_plans is
  'v3 section 4.2. Computed by the planning stage, persisted, then halted on for human confirmation. Retirement executes against retire_natural_keys, never against a freshly recomputed set.';
comment on column public.reconciliation_plans.retire_natural_keys is
  'The complete set of natural keys this plan proposes to retire. v3 section 4.2 requires retirement to execute against the persisted key set; retire_key_sample holds only the UI examples and cannot serve that purpose.';
comment on column public.reconciliation_plans.guard_results is
  'v3 section 4.3. One entry per guard evaluated, in order, with its outcome. The most severe outcome determines verdict.';

-- The plan body is what the user was shown. Only the decision may change
-- afterwards, so a confirmation cannot silently apply to a larger retirement
-- than the one presented.
create or replace function public.reconciliation_plans_decision_only_update()
returns trigger
language plpgsql
as $$
declare
  decision_columns text[] := array['decision', 'decided_at', 'decided_reason'];
begin
  if to_jsonb(old) - decision_columns is distinct from to_jsonb(new) - decision_columns then
    raise exception
      'reconciliation_plans is immutable once computed: only decision, decided_at and decided_reason may be updated (v3 section 4.2)'
      using errcode = '42501';
  end if;

  if old.decision is not null and new.decision is distinct from old.decision then
    raise exception 'reconciliation_plans.decision is final once recorded (was %, attempted %)',
      old.decision, new.decision
      using errcode = '42501';
  end if;

  return new;
end;
$$;

create trigger reconciliation_plans_decision_only_update
  before update on public.reconciliation_plans
  for each row execute function public.reconciliation_plans_decision_only_update();

-- ---------------------------------------------------------------------------
-- retirement_overrides (v3 section 4.3)
-- ---------------------------------------------------------------------------

create table public.retirement_overrides (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references auth.users (id) on delete cascade,
  plan_id             uuid not null,
  guard_id            text not null,
  overridden_at       timestamptz not null default now(),
  typed_confirmation  text not null,

  -- v3 section 4.3 gives an override to exactly two guards. G1, G2, G3, G7 and
  -- G8 are structural blocks, and G9 is explicitly "BLOCKED, always, with no
  -- override". Constraining the column means an override row for G9 cannot be
  -- written at all, so no code path can produce one to wave through.
  constraint retirement_overrides_guard_overridable
    check (guard_id in ('G4', 'G6')),
  constraint retirement_overrides_typed_confirmation_not_blank
    check (length(btrim(typed_confirmation)) > 0),
  constraint retirement_overrides_plan_fk
    foreign key (plan_id, user_id)
    references public.reconciliation_plans (id, user_id) on delete cascade
);

create index retirement_overrides_plan_idx on public.retirement_overrides (plan_id);
create index retirement_overrides_user_id_idx on public.retirement_overrides (user_id);

comment on table public.retirement_overrides is
  'v3 section 4.3. Audit record of a user typing the retire count to proceed past an overridable guard. Only G4 and G6 are overridable; G9 has no override and the check constraint above makes one unrecordable.';

-- ---------------------------------------------------------------------------
-- The retirement guard (I-10, G4, G9)
--
-- Fires on the transition retired_at NULL -> NOT NULL, on every canonical
-- table that can be retired. Undo (NOT NULL -> NULL) is deliberately not
-- gated: v3 section 4.4 keeps undo available for the life of the import.
--
-- This is a trigger and not a constraint because the rules are relational:
-- they depend on the row's originating raw record and on a plan in another
-- table. No CHECK or foreign key can express either.
-- ---------------------------------------------------------------------------

create or replace function public.assert_retirement_is_planned_and_permitted()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  origin_source_key   text;
  origin_precedence   smallint;
  plan_permits        boolean;
begin
  -- G9, evaluated first and with no override path. A manual entry or a manual
  -- correction is the only data in the system that cannot be re-obtained from
  -- anywhere, so no vendor snapshot may retire it. 'manual' is the synthetic
  -- import source key the architecture defines (v2 section 0.2, ADR-06); it is
  -- not a vendor name, so I-9 is not in play. precedence_rank is checked as
  -- well because v2 section 4.3 fixes 0 = imported, 10 = manual entry,
  -- 20 = manual correction, which makes it a structural provenance rule that
  -- does not depend on the literal string.
  select r.source_key, r.precedence_rank
    into origin_source_key, origin_precedence
    from public.raw_records r
   where r.id = new.raw_record_id;

  if origin_source_key is null then
    raise exception 'G9: cannot evaluate retirement of %.% because its raw record is missing',
      tg_table_name, new.natural_key
      using errcode = '42501';
  end if;

  if origin_source_key = 'manual' or coalesce(origin_precedence, 0) > 0 then
    raise exception
      'G9: %.% originates from a manual record (source_key=%, precedence_rank=%) and can never be retired. This guard has no override.',
      tg_table_name, new.natural_key, origin_source_key, origin_precedence
      using errcode = '42501';
  end if;

  -- I-10 and G4 steps 3 to 5: a persisted plan, confirmed by a human, not
  -- blocked, and naming this exact row. Retirement therefore executes against
  -- the plan's key set rather than against anything recomputed later.
  select exists (
    select 1
      from public.reconciliation_plans p
     where p.import_id = new.retired_by_import_id
       and p.user_id   = new.user_id
       and p.decision  = 'confirmed'
       and p.verdict  <> 'blocked'
       and p.retire_natural_keys @> array[new.natural_key]
  ) into plan_permits;

  if not plan_permits then
    raise exception
      'I-10: retiring %.% requires a persisted reconciliation_plan for import % that is confirmed, not blocked, and lists this natural key',
      tg_table_name, new.natural_key, new.retired_by_import_id
      using errcode = '42501';
  end if;

  return new;
end;
$$;

comment on function public.assert_retirement_is_planned_and_permitted() is
  'I-10, G4, G9. No canonical row may be retired without a confirmed, non-blocked, non-stale plan that names it, and no manual-origin row may ever be retired.';

create trigger metrics_retirement_guard
  before update on public.metrics
  for each row when (old.retired_at is null and new.retired_at is not null)
  execute function public.assert_retirement_is_planned_and_permitted();

create trigger strength_workouts_retirement_guard
  before update on public.strength_workouts
  for each row when (old.retired_at is null and new.retired_at is not null)
  execute function public.assert_retirement_is_planned_and_permitted();

create trigger strength_sets_retirement_guard
  before update on public.strength_sets
  for each row when (old.retired_at is null and new.retired_at is not null)
  execute function public.assert_retirement_is_planned_and_permitted();

-- ---------------------------------------------------------------------------
-- An import may not enter the retiring stage without a confirmed plan
-- (v3 section 4.1). Retirement is never reached by an unattended job.
-- ---------------------------------------------------------------------------

create or replace function public.assert_retiring_status_is_confirmed()
returns trigger
language plpgsql
as $$
begin
  if not exists (
    select 1 from public.reconciliation_plans p
     where p.import_id = new.id
       and p.user_id   = new.user_id
       and p.decision  = 'confirmed'
       and p.verdict  <> 'blocked'
  ) then
    raise exception
      'v3 section 4.1: import % cannot enter the retiring stage without a confirmed, non-blocked reconciliation plan',
      new.id
      using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger data_imports_retiring_requires_confirmation
  before update on public.data_imports
  for each row when (old.status is distinct from 'retiring' and new.status = 'retiring')
  execute function public.assert_retiring_status_is_confirmed();

-- ---------------------------------------------------------------------------
-- RLS and grants
-- ---------------------------------------------------------------------------

alter table public.reconciliation_plans enable row level security;
alter table public.retirement_overrides enable row level security;

-- The plan is computed by the worker and read by the user. The user records a
-- decision on it, and nothing else: the column-level grant means the impact
-- figures and the key set are not writable from the client at all.
grant select on public.reconciliation_plans to authenticated;
grant update (decision, decided_at, decided_reason) on public.reconciliation_plans to authenticated;

create policy "reconciliation_plans_select_own"
  on public.reconciliation_plans for select to authenticated
  using (user_id = (select auth.uid()));

create policy "reconciliation_plans_decide_own"
  on public.reconciliation_plans for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- The override is the user's typed confirmation, so the client writes it.
-- It is an audit record: insert and read, never change or remove.
grant select, insert on public.retirement_overrides to authenticated;

create policy "retirement_overrides_select_own"
  on public.retirement_overrides for select to authenticated
  using (user_id = (select auth.uid()));

create policy "retirement_overrides_insert_own"
  on public.retirement_overrides for insert to authenticated
  with check (user_id = (select auth.uid()));

revoke all on public.reconciliation_plans from anon;
revoke all on public.retirement_overrides from anon;
