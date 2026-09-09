-- ============================================================================
-- 20260904100200_phase3_step0_alias_normalization.sql
-- Phase 3 Step 0, item 3: resolve alias vs alias_normalized before any profile
-- mapping code exists.
--
-- The canonical architecture name is alias_normalized (v2 section 2.1). Phase 1
-- shipped `alias`, storing the raw string and normalizing only inside the
-- unique index expression, which meant two different normalizations could
-- disagree and punctuation was never stripped at all.
--
-- This migration RENAMES the column rather than adding a second one. There is
-- no dual-write window and there are never two competing alias fields, which
-- the ruling forbids. A rename is safe here because nothing reads the column:
-- no application code references it, and the only other consumers are the seed
-- and the test suites, all updated in the same commit. It is the smallest
-- forward-only change that reaches the required state.
--
-- THE NORMALIZATION CONTRACT
--
-- normalize_alias(text) is deterministic, IMMUTABLE, and applied in this order:
--
--   1. lowercase
--   2. replace every run of characters that is neither alphanumeric nor
--      whitespace with a single space (this is the "strip punctuation" step;
--      replacing with a space rather than deleting keeps "body-fat" as
--      "body fat" instead of gluing it into "bodyfat")
--   3. collapse every run of whitespace to one space
--   4. trim leading and trailing whitespace
--
-- The column then stores the already-normalized form, enforced by a check
-- constraint, so the unique indexes are plain column indexes and no caller can
-- write an unnormalized alias. Matching is therefore an equality test against
-- normalize_alias(incoming_header), with no normalization logic duplicated in
-- application code.
--
-- Unit suffix stripping (v2 section 6.3 mentions it for header tokens) is
-- deliberately NOT part of this contract: "weight kg" and "weight lb" must
-- stay distinct aliases, because they carry the unit the source reported.
-- ============================================================================

create or replace function public.normalize_alias(value text)
returns text
language sql
immutable
strict
parallel safe
as $$
  select btrim(
           regexp_replace(
             regexp_replace(lower(value), '[^[:alnum:][:space:]]+', ' ', 'g'),
             '[[:space:]]+', ' ', 'g'
           )
         )
$$;

comment on function public.normalize_alias(text) is
  'The single alias normalization contract: lowercase, punctuation to space, collapse whitespace, trim. Used by the stored-form check constraints and by mapping-time lookups, so the two can never disagree.';

-- ---------------------------------------------------------------------------
-- metric_aliases
-- ---------------------------------------------------------------------------

drop index public.metric_aliases_system_alias_uniq;
drop index public.metric_aliases_user_alias_uniq;
drop index public.metric_aliases_lookup_idx;

alter table public.metric_aliases rename column alias to alias_normalized;

update public.metric_aliases
   set alias_normalized = public.normalize_alias(alias_normalized)
 where alias_normalized is distinct from public.normalize_alias(alias_normalized);

-- Normalization collapses variants that differed only in punctuation. Where a
-- collapsed group resolves to a single definition the extra rows are redundant
-- and are removed. Where it would resolve to more than one, the registry is
-- genuinely ambiguous and a migration must not pick a winner silently.
do $$
declare ambiguous text;
begin
  select string_agg(alias_normalized || ' (' || n || ' definitions)', '; ')
    into ambiguous
    from (
      select alias_normalized, count(distinct metric_definition_id) as n
        from public.metric_aliases
       group by coalesce(user_id::text, '__system__'), alias_normalized, coalesce(source_key, '')
      having count(distinct metric_definition_id) > 1
    ) q;
  if ambiguous is not null then
    raise exception
      'metric_aliases: normalization would collapse aliases that point at different metric definitions: %. Resolve the registry before migrating.',
      ambiguous;
  end if;
end
$$;

delete from public.metric_aliases a
 using (
   select id,
          row_number() over (
            partition by coalesce(user_id::text, '__system__'),
                         alias_normalized,
                         coalesce(source_key, '')
            order by created_at, id
          ) as rn
     from public.metric_aliases
 ) d
 where d.id = a.id and d.rn > 1;

alter table public.metric_aliases
  add constraint metric_aliases_alias_is_normalized
    check (alias_normalized = public.normalize_alias(alias_normalized));

create unique index metric_aliases_system_alias_uniq
  on public.metric_aliases (alias_normalized, coalesce(source_key, '')) where user_id is null;
create unique index metric_aliases_user_alias_uniq
  on public.metric_aliases (user_id, alias_normalized, coalesce(source_key, '')) where user_id is not null;
create index metric_aliases_lookup_idx on public.metric_aliases (alias_normalized);

comment on column public.metric_aliases.alias_normalized is
  'v2 section 2.1. Stored already normalized by public.normalize_alias and held there by a check constraint. Match by equality against normalize_alias(incoming_header).';

-- ---------------------------------------------------------------------------
-- exercise_aliases
-- ---------------------------------------------------------------------------

drop index public.exercise_aliases_system_alias_uniq;
drop index public.exercise_aliases_user_alias_uniq;
drop index public.exercise_aliases_lookup_idx;

alter table public.exercise_aliases rename column alias to alias_normalized;

update public.exercise_aliases
   set alias_normalized = public.normalize_alias(alias_normalized)
 where alias_normalized is distinct from public.normalize_alias(alias_normalized);

do $$
declare ambiguous text;
begin
  select string_agg(alias_normalized || ' (' || n || ' definitions)', '; ')
    into ambiguous
    from (
      select alias_normalized, count(distinct exercise_definition_id) as n
        from public.exercise_aliases
       group by coalesce(user_id::text, '__system__'), alias_normalized, coalesce(source_key, '')
      having count(distinct exercise_definition_id) > 1
    ) q;
  if ambiguous is not null then
    raise exception
      'exercise_aliases: normalization would collapse aliases that point at different exercise definitions: %. Resolve the registry before migrating.',
      ambiguous;
  end if;
end
$$;

delete from public.exercise_aliases a
 using (
   select id,
          row_number() over (
            partition by coalesce(user_id::text, '__system__'),
                         alias_normalized,
                         coalesce(source_key, '')
            order by created_at, id
          ) as rn
     from public.exercise_aliases
 ) d
 where d.id = a.id and d.rn > 1;

alter table public.exercise_aliases
  add constraint exercise_aliases_alias_is_normalized
    check (alias_normalized = public.normalize_alias(alias_normalized));

create unique index exercise_aliases_system_alias_uniq
  on public.exercise_aliases (alias_normalized, coalesce(source_key, '')) where user_id is null;
create unique index exercise_aliases_user_alias_uniq
  on public.exercise_aliases (user_id, alias_normalized, coalesce(source_key, '')) where user_id is not null;
create index exercise_aliases_lookup_idx on public.exercise_aliases (alias_normalized);

comment on column public.exercise_aliases.alias_normalized is
  'v2 section 2.1. Stored already normalized by public.normalize_alias and held there by a check constraint.';

grant execute on function public.normalize_alias(text) to authenticated;
