-- ============================================================================
-- 20260907090000_phase51_g4_override.sql
-- Phase 5.1: resolve the G4 override contradiction.
--
-- THE CONTRADICTION
--
-- v3 section 4.3 makes G4 and G6 overridable, and Phase 3 built three of the
-- four pieces that implies:
--
--   * the engine reports them as overridable (availableDecisions);
--   * the UI offers "Override G4 and retire" with a typed confirmation;
--   * retirement_overrides exists to record the audit trail, constrained so
--     that an override row for a non-overridable guard cannot be written.
--
-- The fourth piece contradicted the other three. Persistence treated "blocked"
-- as absolute, in three places:
--
--   1. CHECK reconciliation_plans_blocked_is_never_confirmed
--   2. assert_retiring_status_is_confirmed   (requires verdict <> 'blocked')
--   3. assert_retirement_is_planned_and_permitted (same)
--
-- plus the decision route, which returned 409 for any confirmation of a
-- blocked plan before it ever looked at the override fields. The result was
-- dead functionality: an action the product offered and the system could not
-- perform.
--
-- THE RESOLUTION
--
-- G4 becomes what v3 section 4.3 always described: a safety gate, not a
-- prohibition. A blocked plan still cannot be confirmed by any automatic path.
-- It can be confirmed by a human who explicitly overrides every guard that
-- blocked it, under requirements this migration enforces in the database.
--
-- WHAT IS NOT WEAKENED
--
--   * G9 remains absolute. An override row can only exist for G4 or G6
--     (retirement_overrides_guard_overridable), so a plan blocked by G9 can
--     never satisfy "every blocking guard has an override" and can never be
--     confirmed. G9 is also enforced independently, on provenance, inside the
--     retirement guard itself.
--   * The original verdict is never rewritten. A plan blocked by G4 and then
--     overridden still reads verdict = 'blocked' forever. The distinction
--     between "G4 passed, then retirement" and "G4 blocked, then a human
--     overrode it, then retirement" is preserved as a fact, not erased to
--     satisfy a constraint.
--   * Nothing else about reconciliation changes. The override buys exactly one
--     thing: permission to proceed past a blocked verdict. Every other rule —
--     the persisted key set, plan immutability, one confirmed plan per import,
--     the 24-hour staleness window, G9 — still applies.
--
-- WHERE THE RULES LIVE
--
-- In the database, not in the route. The client holds INSERT on
-- retirement_overrides (it is the user's own typed confirmation), so the
-- requirements are enforced by a BEFORE INSERT trigger that also derives the
-- guard evidence from the plan rather than accepting it from the caller. The
-- API is convenience; this file is the enforcement.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. retirement_overrides gains the audit fields the contract requires.
--
-- Expand only. The columns are added with defaults that are honest about a
-- legacy row: the override path never completed, so a row written before this
-- migration recorded no reason and no acknowledgement, and says so rather than
-- being back-dated into looking compliant.
-- ---------------------------------------------------------------------------

alter table public.retirement_overrides
  add column reason        text        not null default 'no reason captured: recorded before Phase 5.1',
  add column acknowledged  boolean     not null default false,
  -- Derived from the plan by the trigger below, never supplied by the caller.
  add column guard_outcome text,
  add column guard_detail  text;

comment on column public.retirement_overrides.reason is
  'Why the user chose to override. Free text, required, and validated for substance at insert time. Not a controlled vocabulary: the useful reasons are situational.';
comment on column public.retirement_overrides.acknowledged is
  'The user ticked the acknowledgement that proceeding may retire historical records. Required at insert time; false only on a row predating Phase 5.1.';
comment on column public.retirement_overrides.guard_detail is
  'The guard''s own explanation of why it blocked, copied from the plan by the database at insert time. Evidence, not input: it cannot be forged by the caller.';

-- One override per guard per plan. This is the idempotency key: a double
-- submission records the decision once, not twice, and the audit trail cannot
-- accumulate contradictory rows for the same guard.
create unique index retirement_overrides_plan_guard_uq
  on public.retirement_overrides (plan_id, guard_id);

-- ---------------------------------------------------------------------------
-- 2. The override requirements, enforced where the row is written.
--
-- SECURITY DEFINER because it reads the plan to derive evidence and to check
-- the typed confirmation, and the caller is the user whose row this is.
-- ---------------------------------------------------------------------------

create or replace function public.retirement_override_validate()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  plan_row public.reconciliation_plans%rowtype;
  guard    jsonb;
begin
  select * into plan_row
    from public.reconciliation_plans p
   where p.id = new.plan_id;

  if not found then
    raise exception 'override: reconciliation plan % does not exist', new.plan_id
      using errcode = '23503';
  end if;

  -- Attribution is structural. The composite foreign key already forbids a row
  -- whose user_id differs from the plan's; this says so in an error a person
  -- can read, and closes the case where the FK is ever relaxed.
  if new.user_id is distinct from plan_row.user_id then
    raise exception 'override: the override actor must be the owner of the plan'
      using errcode = '42501';
  end if;

  -- An override is only meaningful against a guard that actually blocked THIS
  -- plan. Recording one for a guard that passed would put a defensible-looking
  -- audit row behind a decision it did not justify.
  select g into guard
    from jsonb_array_elements(plan_row.guard_results) g
   where g->>'id' = new.guard_id
   limit 1;

  if guard is null then
    raise exception 'override: guard % did not run on plan %', new.guard_id, new.plan_id
      using errcode = '22023';
  end if;
  if guard->>'outcome' is distinct from 'blocked' then
    raise exception
      'override: guard % did not block plan % (outcome %), so there is nothing to override',
      new.guard_id, new.plan_id, guard->>'outcome'
      using errcode = '22023';
  end if;

  -- Strong confirmation: the user typed the number of records they are about
  -- to retire. Checked against the PLAN, so it cannot be satisfied by typing
  -- whatever the client happened to send.
  if btrim(coalesce(new.typed_confirmation, '')) is distinct from plan_row.retire_count::text then
    raise exception
      'override: the typed confirmation must be the retire count (%), got %',
      plan_row.retire_count, coalesce(new.typed_confirmation, '(null)')
      using errcode = '22023';
  end if;

  if new.acknowledged is not true then
    raise exception
      'override: the user must acknowledge that proceeding may retire historical records'
      using errcode = '22023';
  end if;

  -- A reason is required and must say something. Ten characters is not a test
  -- of sincerity; it is enough to stop an empty string or a single keystroke
  -- from standing as the record of why history was retired.
  if length(btrim(coalesce(new.reason, ''))) < 10 then
    raise exception
      'override: a reason of at least 10 characters is required, got %',
      length(btrim(coalesce(new.reason, '')))
      using errcode = '22023';
  end if;

  -- Evidence, derived rather than accepted.
  new.guard_outcome := guard->>'outcome';
  new.guard_detail  := guard->>'detail';
  new.overridden_at := coalesce(new.overridden_at, now());

  return new;
end;
$$;

comment on function public.retirement_override_validate() is
  'Phase 5.1. Every requirement of a G4 override, enforced where the row is written: the guard really blocked this plan, the typed confirmation matches the plan''s own retire count, the acknowledgement was given, a substantive reason was supplied, and the guard evidence is copied from the plan rather than trusted from the caller.';

create trigger retirement_overrides_validate
  before insert on public.retirement_overrides
  for each row execute function public.retirement_override_validate();

-- An override is an audit record. It is written once and never edited.
create or replace function public.retirement_override_is_immutable()
returns trigger
language plpgsql
as $$
begin
  raise exception 'retirement_overrides is an audit record: it cannot be % once written',
    lower(tg_op)
    using errcode = '42501';
end;
$$;

create trigger retirement_overrides_immutable
  before update or delete on public.retirement_overrides
  for each row execute function public.retirement_override_is_immutable();

-- ---------------------------------------------------------------------------
-- 3. The predicate: has every guard that blocked this plan been overridden?
--
-- This is the single definition of "validly overridden", and all three
-- enforcement points below consult it rather than restating it.
--
-- G9 needs no special case here. retirement_overrides_guard_overridable makes
-- an override row for G9 unwritable, so a plan G9 blocked can never satisfy
-- this predicate. The absolute guard stays absolute because the audit table
-- refuses to record the thing that would excuse it.
-- ---------------------------------------------------------------------------

create or replace function public.reconciliation_plan_override_is_complete(p_plan_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    -- At least one guard blocked, and every one of them has an override.
    exists (
      select 1
        from public.reconciliation_plans p
        cross join lateral jsonb_array_elements(p.guard_results) g
       where p.id = p_plan_id and g->>'outcome' = 'blocked'
    )
    and not exists (
      select 1
        from public.reconciliation_plans p
        cross join lateral jsonb_array_elements(p.guard_results) g
       where p.id = p_plan_id
         and g->>'outcome' = 'blocked'
         and not exists (
           select 1
             from public.retirement_overrides o
            where o.plan_id  = p.id
              and o.user_id  = p.user_id
              and o.guard_id = g->>'id'
              and o.acknowledged
         )
    );
$$;

comment on function public.reconciliation_plan_override_is_complete(uuid) is
  'Phase 5.1. True when every guard that blocked this plan carries an acknowledged override row belonging to the plan''s owner. The single definition of "validly overridden", consulted by the confirmation trigger, the retiring-status trigger and the retirement guard.';

-- ---------------------------------------------------------------------------
-- 4. Confirmation. The CHECK constraint that made "blocked" absolute is
--    replaced by a trigger that can express the relational rule the constraint
--    could not.
-- ---------------------------------------------------------------------------

alter table public.reconciliation_plans
  drop constraint reconciliation_plans_blocked_is_never_confirmed;

create or replace function public.assert_plan_confirmation_is_permitted()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  unoverridden text;
begin
  if new.verdict <> 'blocked' then
    return new;
  end if;

  if public.reconciliation_plan_override_is_complete(new.id) then
    return new;
  end if;

  select string_agg(g->>'id', ', ' order by g->>'id') into unoverridden
    from jsonb_array_elements(new.guard_results) g
   where g->>'outcome' = 'blocked'
     and not exists (
       select 1 from public.retirement_overrides o
        where o.plan_id = new.id and o.guard_id = g->>'id' and o.acknowledged
     );

  raise exception
    'I-10: plan % is blocked and cannot be confirmed. Guard(s) % have no acknowledged override. A blocked plan is confirmable only when every guard that blocked it has been explicitly overridden by its owner; G9 can never be overridden at all.',
    new.id, coalesce(unoverridden, '(none recorded)')
    using errcode = '42501';
end;
$$;

comment on function public.assert_plan_confirmation_is_permitted() is
  'Phase 5.1, replacing CHECK reconciliation_plans_blocked_is_never_confirmed. A blocked plan may be confirmed only when every guard that blocked it carries an acknowledged override. The verdict is never rewritten: it still reads blocked afterwards.';

-- Both write paths. The CHECK constraint this replaces covered INSERT as well
-- as UPDATE, and a plan inserted already confirmed would otherwise walk past
-- the rule entirely. Only the worker can insert a plan today, which is exactly
-- the kind of "today" that stops being true later.
create trigger reconciliation_plans_confirmation_permitted_ins
  before insert on public.reconciliation_plans
  for each row when (new.decision = 'confirmed')
  execute function public.assert_plan_confirmation_is_permitted();

create trigger reconciliation_plans_confirmation_permitted_upd
  before update on public.reconciliation_plans
  for each row when (old.decision is null and new.decision = 'confirmed')
  execute function public.assert_plan_confirmation_is_permitted();

-- ---------------------------------------------------------------------------
-- 4b. A decision, once taken, is a fact.
--
-- The Phase 3 trigger refused a CHANGE of decision but let a repeat of the
-- same decision through, which quietly moved decided_at. That is a second
-- audit record for the same event wearing the first one's clothes, and Phase
-- 5.1 has to be able to say when an override was taken. All three decision
-- columns are now frozen together once a decision exists.
-- ---------------------------------------------------------------------------

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

  if old.decision is not null
     and (new.decision       is distinct from old.decision
       or new.decided_at     is distinct from old.decided_at
       or new.decided_reason is distinct from old.decided_reason)
  then
    raise exception
      'reconciliation_plans: the decision on this plan is already recorded (% at %) and cannot be re-recorded or amended',
      old.decision, old.decided_at
      using errcode = '42501';
  end if;

  return new;
end;
$$;

comment on function public.reconciliation_plans_decision_only_update() is
  'v3 section 4.2 plus Phase 5.1. The plan body is immutable once computed, and the decision record is immutable once taken: a repeat submission cannot move decided_at or rewrite the reason.';

-- ---------------------------------------------------------------------------
-- 5. The two retirement gates learn the same rule.
--
-- Both previously required verdict <> 'blocked'. Both now require a confirmed
-- plan that is either unblocked or validly overridden. Nothing else about them
-- changes; in particular the retirement guard still evaluates G9 on the row's
-- own provenance first, with no override path.
-- ---------------------------------------------------------------------------

create or replace function public.assert_retiring_status_is_confirmed()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (
    select 1 from public.reconciliation_plans p
     where p.import_id = new.id
       and p.user_id   = new.user_id
       and p.decision  = 'confirmed'
       and (p.verdict <> 'blocked'
            or public.reconciliation_plan_override_is_complete(p.id))
  ) then
    raise exception
      'v3 section 4.1: import % cannot enter the retiring stage without a confirmed reconciliation plan that either passed its guards or was explicitly overridden',
      new.id
      using errcode = '42501';
  end if;
  return new;
end;
$$;

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
  -- anywhere, so no vendor snapshot may retire it. Phase 5.1 does not touch
  -- this: an override buys permission to proceed past a blocked VERDICT, and
  -- never permission to retire a manual record.
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

  -- I-10: a persisted plan, confirmed by a human, naming this exact row, and
  -- either unblocked or explicitly overridden. Retirement therefore still
  -- executes against the plan's own key set and never against a recomputed one.
  select exists (
    select 1
      from public.reconciliation_plans p
     where p.import_id = new.retired_by_import_id
       and p.user_id   = new.user_id
       and p.decision  = 'confirmed'
       and p.retire_natural_keys @> array[new.natural_key]
       and (p.verdict <> 'blocked'
            or public.reconciliation_plan_override_is_complete(p.id))
  ) into plan_permits;

  if not plan_permits then
    raise exception
      'I-10: retiring %.% requires a persisted reconciliation_plan for import % that is confirmed, lists this natural key, and is either unblocked or explicitly overridden',
      tg_table_name, new.natural_key, new.retired_by_import_id
      using errcode = '42501';
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. The audit view.
--
-- One row per reconciliation plan, answering the questions the override
-- contract has to be able to answer: why was it blocked, who overrode it,
-- when, why, and against which import.
-- ---------------------------------------------------------------------------

create view public.v_retirement_audit with (security_invoker = true) as
  select
    p.id                       as plan_id,
    p.user_id,
    p.import_id,
    i.file_name,
    i.source_key,
    p.computed_at,
    p.verdict                  as original_verdict,
    p.retire_count,
    p.existing_in_scope_count,
    p.retire_ratio,
    p.decision,
    p.decided_at,
    p.decided_reason,
    -- The distinction the contract exists to preserve. It is derived, not
    -- stored: the verdict and the override rows are the facts, and this is
    -- what they mean together.
    (p.verdict = 'blocked' and p.decision = 'confirmed') as was_safety_override,
    coalesce((
      select jsonb_agg(jsonb_build_object('id', g->>'id', 'detail', g->>'detail')
                         order by g->>'id')
        from jsonb_array_elements(p.guard_results) g
       where g->>'outcome' = 'blocked'
    ), '[]'::jsonb) as blocking_guards,
    coalesce((
      select jsonb_agg(jsonb_build_object(
               'guard_id',           o.guard_id,
               'guard_detail',       o.guard_detail,
               'overridden_by',      o.user_id,
               'overridden_at',      o.overridden_at,
               'reason',             o.reason,
               'acknowledged',       o.acknowledged,
               'typed_confirmation', o.typed_confirmation
             ) order by o.guard_id)
        from public.retirement_overrides o
       where o.plan_id = p.id
    ), '[]'::jsonb) as overrides
  from public.reconciliation_plans p
  join public.data_imports i on i.id = p.import_id and i.user_id = p.user_id;

comment on view public.v_retirement_audit is
  'Phase 5.1. The retirement audit trail: the original guard verdict, the decision taken, and the override that permitted it where one was needed. was_safety_override distinguishes "G4 passed, then retirement" from "G4 blocked, then a human overrode it, then retirement".';

-- ---------------------------------------------------------------------------
-- 7. Privileges.
--
-- The predicate is called only from SECURITY DEFINER triggers owned by the
-- migration role, so no client role needs to execute it, and none does. This
-- is asserted in the Phase 5.1 suite rather than assumed: EXECUTE defaults to
-- PUBLIC.
-- ---------------------------------------------------------------------------

revoke all on function public.reconciliation_plan_override_is_complete(uuid) from public, anon, authenticated;
revoke all on function public.assert_plan_confirmation_is_permitted() from public, anon, authenticated;
revoke all on function public.retirement_override_validate() from public, anon, authenticated;
revoke all on function public.retirement_override_is_immutable() from public, anon, authenticated;
revoke all on function public.assert_retiring_status_is_confirmed() from public, anon, authenticated;
revoke all on function public.assert_retirement_is_planned_and_permitted() from public, anon, authenticated;

revoke all on public.v_retirement_audit from anon, authenticated;
grant select on public.v_retirement_audit to authenticated;
