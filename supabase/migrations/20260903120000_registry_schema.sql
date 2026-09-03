-- ============================================================================
-- 20260903120000_registry_schema.sql
-- Phase 1 — Foundation: system + user registry tables.
--
-- Scope (CLAUDE.md §4, Phase 1):
--   sources, units, unit_conversions, metric_definitions, metric_aliases,
--   exercise_definitions, exercise_aliases, activity_types, event_definitions
--
-- Invariants honoured here:
--   I-6  No free-text identifiers. Every metric / exercise / activity / event
--        resolves to a registry row; aliases are the only free text and they
--        exist solely to resolve TO a registry row.
--   I-7  Measurement values are NUMERIC(18,6). See the note on
--        unit_conversions.factor below for the one deliberate exception.
--   I-8  Every table carries user_id and an RLS policy (policies live in the
--        next migration). No policy requires a join.
--   I-9  Vendor names never appear in engine code. `source_key` is metadata.
--
-- Ownership model
--   user_id IS NULL      -> system registry row, readable by every user,
--                           writable by nobody through the client API.
--   user_id = auth.uid() -> user-owned registry row, private to that user.
--   This keeps I-8 satisfiable (the column exists on every table and the
--   policy predicate is join-free) while still allowing one shared canonical
--   registry, which I-6 requires.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Helper functions
-- ---------------------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

comment on function public.set_updated_at() is
  'Maintains updated_at on registry tables. Registry tables are mutable metadata, not canonical measurement rows; I-4 does not apply to them.';

-- Prevents a user-owned registry row from referencing another user''s private
-- registry row. RLS hides such a row from SELECT, but a foreign key would
-- still accept a known UUID, which would leak existence and corrupt
-- resolution. Runs SECURITY DEFINER because it must see rows RLS hides.
create or replace function public.registry_assert_parent_ownership()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  parent_table  text := tg_argv[0];
  fk_column     text := tg_argv[1];
  parent_id     uuid;
  child_owner   uuid;
  parent_owner  uuid;
  parent_exists boolean := false;
begin
  parent_id   := (to_jsonb(new) ->> fk_column)::uuid;
  child_owner := (to_jsonb(new) ->> 'user_id')::uuid;

  if parent_id is null then
    return new;
  end if;

  execute format('select user_id, true from public.%I where id = $1', parent_table)
    into parent_owner, parent_exists
    using parent_id;

  if not coalesce(parent_exists, false) then
    raise exception 'registry parent %.% = % does not exist', parent_table, fk_column, parent_id
      using errcode = '23503';
  end if;

  -- A system parent (user_id IS NULL) may be referenced by anyone.
  if parent_owner is not null and parent_owner is distinct from child_owner then
    raise exception 'cross-user registry reference: %.% = % is owned by another user',
      parent_table, fk_column, parent_id
      using errcode = '42501';
  end if;

  return new;
end;
$$;

comment on function public.registry_assert_parent_ownership() is
  'Trigger guard: a registry child row may only reference a system parent or a parent owned by the same user.';

create or replace function public.unit_conversions_assert_same_dimension()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  from_dimension text;
  to_dimension   text;
begin
  select dimension into from_dimension from public.units where id = new.from_unit_id;
  select dimension into to_dimension   from public.units where id = new.to_unit_id;

  if from_dimension is distinct from to_dimension then
    raise exception 'unit_conversions: cannot convert between dimensions % and %', from_dimension, to_dimension
      using errcode = '23514';
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- sources
--   Provenance registry. source_key is metadata written onto rows and read
--   only by source precedence resolution (I-9).
-- ---------------------------------------------------------------------------

create table public.sources (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid references auth.users (id) on delete cascade,
  source_key       text not null,
  display_name     text not null,
  description      text,
  precedence_rank  integer not null default 0,
  is_active        boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint sources_source_key_format
    check (source_key ~ '^[a-z0-9]+(_[a-z0-9]+)*$'),
  constraint sources_display_name_not_blank
    check (length(btrim(display_name)) > 0)
);

create unique index sources_system_key_uniq
  on public.sources (source_key) where user_id is null;
create unique index sources_user_key_uniq
  on public.sources (user_id, source_key) where user_id is not null;
create index sources_user_id_idx on public.sources (user_id);

comment on column public.sources.precedence_rank is
  'Higher wins when two sources report the same canonical fact. Read only by source precedence resolution (I-9).';

-- ---------------------------------------------------------------------------
-- units
-- ---------------------------------------------------------------------------

create table public.units (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid references auth.users (id) on delete cascade,
  key           text not null,
  display_name  text not null,
  symbol        text,
  dimension     text not null,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint units_key_format
    check (key ~ '^[a-z0-9]+(_[a-z0-9]+)*$'),
  constraint units_dimension_allowed
    check (dimension in (
      'mass', 'length', 'time', 'energy', 'count',
      'frequency', 'ratio', 'temperature', 'dimensionless'
    ))
);

create unique index units_system_key_uniq
  on public.units (key) where user_id is null;
create unique index units_user_key_uniq
  on public.units (user_id, key) where user_id is not null;
create index units_user_id_idx on public.units (user_id);

-- ---------------------------------------------------------------------------
-- unit_conversions
--   value_in_to_unit = value_in_from_unit * factor + "offset"
--
--   NOTE ON I-7: I-7 fixes *measurement values* at NUMERIC(18,6). A conversion
--   factor is a coefficient, not a value. Storing 1 lb -> kg as NUMERIC(18,6)
--   would truncate the exact factor 0.45359237 to 0.453592, injecting a
--   systematic ~1.6e-7 relative error into every imported imperial mass before
--   it is ever rounded to a stored value. factor/"offset" are therefore
--   NUMERIC(30,15). Every column that holds a measurement remains
--   NUMERIC(18,6). This is called out explicitly rather than decided silently.
-- ---------------------------------------------------------------------------

create table public.unit_conversions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid references auth.users (id) on delete cascade,
  from_unit_id  uuid not null references public.units (id) on delete restrict,
  to_unit_id    uuid not null references public.units (id) on delete restrict,
  factor        numeric(30,15) not null,
  "offset"      numeric(30,15) not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint unit_conversions_distinct_units
    check (from_unit_id <> to_unit_id),
  constraint unit_conversions_factor_nonzero
    check (factor <> 0)
);

create unique index unit_conversions_system_pair_uniq
  on public.unit_conversions (from_unit_id, to_unit_id) where user_id is null;
create unique index unit_conversions_user_pair_uniq
  on public.unit_conversions (user_id, from_unit_id, to_unit_id) where user_id is not null;
create index unit_conversions_user_id_idx on public.unit_conversions (user_id);
create index unit_conversions_from_unit_idx on public.unit_conversions (from_unit_id);
create index unit_conversions_to_unit_idx on public.unit_conversions (to_unit_id);

-- ---------------------------------------------------------------------------
-- metric_definitions
-- ---------------------------------------------------------------------------

create table public.metric_definitions (
  id                   uuid primary key default gen_random_uuid(),
  user_id              uuid references auth.users (id) on delete cascade,
  key                  text not null,
  display_name         text not null,
  description          text,
  canonical_unit_id    uuid not null references public.units (id) on delete restrict,
  default_aggregation  text not null,
  is_active            boolean not null default true,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint metric_definitions_key_format
    check (key ~ '^[a-z0-9]+(_[a-z0-9]+)*$'),
  constraint metric_definitions_aggregation_allowed
    check (default_aggregation in ('sum', 'mean', 'min', 'max', 'first', 'last', 'count'))
);

create unique index metric_definitions_system_key_uniq
  on public.metric_definitions (key) where user_id is null;
create unique index metric_definitions_user_key_uniq
  on public.metric_definitions (user_id, key) where user_id is not null;
create index metric_definitions_user_id_idx on public.metric_definitions (user_id);
create index metric_definitions_canonical_unit_idx on public.metric_definitions (canonical_unit_id);

comment on column public.metric_definitions.default_aggregation is
  'How same-day observations of this metric collapse to one daily figure. Intrinsic to the metric (steps sum, weight averages); consumed by later rollup phases.';

-- ---------------------------------------------------------------------------
-- metric_aliases
--   The only free text in the registry, and it exists solely to resolve to a
--   metric_definitions row (I-6). Matching is proposal-only during mapping.
-- ---------------------------------------------------------------------------

create table public.metric_aliases (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid references auth.users (id) on delete cascade,
  metric_definition_id  uuid not null references public.metric_definitions (id) on delete cascade,
  alias                 text not null,
  source_key            text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint metric_aliases_alias_not_blank
    check (length(btrim(alias)) > 0),
  constraint metric_aliases_source_key_format
    check (source_key is null or source_key ~ '^[a-z0-9]+(_[a-z0-9]+)*$')
);

create unique index metric_aliases_system_alias_uniq
  on public.metric_aliases (lower(btrim(alias)), coalesce(source_key, '')) where user_id is null;
create unique index metric_aliases_user_alias_uniq
  on public.metric_aliases (user_id, lower(btrim(alias)), coalesce(source_key, '')) where user_id is not null;
create index metric_aliases_user_id_idx on public.metric_aliases (user_id);
create index metric_aliases_definition_idx on public.metric_aliases (metric_definition_id);
create index metric_aliases_lookup_idx on public.metric_aliases (lower(btrim(alias)));

-- ---------------------------------------------------------------------------
-- exercise_definitions
-- ---------------------------------------------------------------------------

create table public.exercise_definitions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid references auth.users (id) on delete cascade,
  key           text not null,
  display_name  text not null,
  description   text,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint exercise_definitions_key_format
    check (key ~ '^[a-z0-9]+(_[a-z0-9]+)*$')
);

create unique index exercise_definitions_system_key_uniq
  on public.exercise_definitions (key) where user_id is null;
create unique index exercise_definitions_user_key_uniq
  on public.exercise_definitions (user_id, key) where user_id is not null;
create index exercise_definitions_user_id_idx on public.exercise_definitions (user_id);

-- ---------------------------------------------------------------------------
-- exercise_aliases
-- ---------------------------------------------------------------------------

create table public.exercise_aliases (
  id                      uuid primary key default gen_random_uuid(),
  user_id                 uuid references auth.users (id) on delete cascade,
  exercise_definition_id  uuid not null references public.exercise_definitions (id) on delete cascade,
  alias                   text not null,
  source_key              text,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  constraint exercise_aliases_alias_not_blank
    check (length(btrim(alias)) > 0),
  constraint exercise_aliases_source_key_format
    check (source_key is null or source_key ~ '^[a-z0-9]+(_[a-z0-9]+)*$')
);

create unique index exercise_aliases_system_alias_uniq
  on public.exercise_aliases (lower(btrim(alias)), coalesce(source_key, '')) where user_id is null;
create unique index exercise_aliases_user_alias_uniq
  on public.exercise_aliases (user_id, lower(btrim(alias)), coalesce(source_key, '')) where user_id is not null;
create index exercise_aliases_user_id_idx on public.exercise_aliases (user_id);
create index exercise_aliases_definition_idx on public.exercise_aliases (exercise_definition_id);
create index exercise_aliases_lookup_idx on public.exercise_aliases (lower(btrim(alias)));

-- ---------------------------------------------------------------------------
-- activity_types
-- ---------------------------------------------------------------------------

create table public.activity_types (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid references auth.users (id) on delete cascade,
  key           text not null,
  display_name  text not null,
  description   text,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint activity_types_key_format
    check (key ~ '^[a-z0-9]+(_[a-z0-9]+)*$')
);

create unique index activity_types_system_key_uniq
  on public.activity_types (key) where user_id is null;
create unique index activity_types_user_key_uniq
  on public.activity_types (user_id, key) where user_id is not null;
create index activity_types_user_id_idx on public.activity_types (user_id);

-- ---------------------------------------------------------------------------
-- event_definitions
-- ---------------------------------------------------------------------------

create table public.event_definitions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid references auth.users (id) on delete cascade,
  key           text not null,
  display_name  text not null,
  description   text,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint event_definitions_key_format
    check (key ~ '^[a-z0-9]+(_[a-z0-9]+)*$')
);

create unique index event_definitions_system_key_uniq
  on public.event_definitions (key) where user_id is null;
create unique index event_definitions_user_key_uniq
  on public.event_definitions (user_id, key) where user_id is not null;
create index event_definitions_user_id_idx on public.event_definitions (user_id);

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------

create trigger sources_set_updated_at
  before update on public.sources
  for each row execute function public.set_updated_at();

create trigger units_set_updated_at
  before update on public.units
  for each row execute function public.set_updated_at();

create trigger unit_conversions_set_updated_at
  before update on public.unit_conversions
  for each row execute function public.set_updated_at();

create trigger metric_definitions_set_updated_at
  before update on public.metric_definitions
  for each row execute function public.set_updated_at();

create trigger metric_aliases_set_updated_at
  before update on public.metric_aliases
  for each row execute function public.set_updated_at();

create trigger exercise_definitions_set_updated_at
  before update on public.exercise_definitions
  for each row execute function public.set_updated_at();

create trigger exercise_aliases_set_updated_at
  before update on public.exercise_aliases
  for each row execute function public.set_updated_at();

create trigger activity_types_set_updated_at
  before update on public.activity_types
  for each row execute function public.set_updated_at();

create trigger event_definitions_set_updated_at
  before update on public.event_definitions
  for each row execute function public.set_updated_at();

create trigger unit_conversions_parent_ownership_from
  before insert or update on public.unit_conversions
  for each row execute function public.registry_assert_parent_ownership('units', 'from_unit_id');

create trigger unit_conversions_parent_ownership_to
  before insert or update on public.unit_conversions
  for each row execute function public.registry_assert_parent_ownership('units', 'to_unit_id');

create trigger unit_conversions_same_dimension
  before insert or update on public.unit_conversions
  for each row execute function public.unit_conversions_assert_same_dimension();

create trigger metric_definitions_parent_ownership_unit
  before insert or update on public.metric_definitions
  for each row execute function public.registry_assert_parent_ownership('units', 'canonical_unit_id');

create trigger metric_aliases_parent_ownership_definition
  before insert or update on public.metric_aliases
  for each row execute function public.registry_assert_parent_ownership('metric_definitions', 'metric_definition_id');

create trigger exercise_aliases_parent_ownership_definition
  before insert or update on public.exercise_aliases
  for each row execute function public.registry_assert_parent_ownership('exercise_definitions', 'exercise_definition_id');
