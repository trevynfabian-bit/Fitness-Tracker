-- ============================================================================
-- 20260904110100_phase3_normalization_upserts.sql
-- Phase 3: the normalization write path and the reconciliation plan query.
--
-- These functions exist so that v2 section 7.2's upsert semantics live in one
-- place and cannot drift. The WHERE clause on the DO UPDATE is the important
-- part: without it every re-import bumps revision and updated_at on every
-- unchanged row, which destroys the accuracy of the import summary and makes
-- "what actually changed" unanswerable. Rows that fail it are counted as
-- duplicates_skipped.
--
-- They are SECURITY INVOKER and are executed by the worker's elevated
-- connection. The authenticated role is granted nothing on them, so this does
-- not open a client write path into a canonical table (I-4, RD-3).
--
-- No vendor appears here. The functions take canonical field values; the
-- profile and the transform library decided what those values are (I-9).
-- ============================================================================

create type public.upsert_outcome as enum ('added', 'updated', 'unchanged');

-- ---------------------------------------------------------------------------
-- strength_workouts
-- ---------------------------------------------------------------------------

create or replace function public.import_upsert_strength_workout(
  p_user_id            uuid,
  p_natural_key        text,
  p_start_utc          timestamptz,
  p_tz_offset_minutes  integer,
  p_local_date         date,
  p_duration_s         integer,
  p_title              text,
  p_source_key         text,
  p_external_id        text,
  p_raw_record_id      bigint,
  p_import_id          uuid,
  out outcome          public.upsert_outcome,
  out workout_id       uuid
)
language plpgsql
as $$
declare
  existing public.strength_workouts%rowtype;
begin
  select * into existing from public.strength_workouts where natural_key = p_natural_key;

  if not found then
    insert into public.strength_workouts
      (user_id, start_utc, tz_offset_minutes, local_date, duration_s, title,
       source_key, external_id, natural_key, raw_record_id, import_id)
    values (p_user_id, p_start_utc, p_tz_offset_minutes, p_local_date, p_duration_s, p_title,
            p_source_key, p_external_id, p_natural_key, p_raw_record_id, p_import_id)
    returning id into workout_id;
    outcome := 'added';
    return;
  end if;

  workout_id := existing.id;

  -- v2 section 7.2: only a real change counts as an update. retired_at is
  -- cleared because a row present in a new import is no longer retired.
  if existing.start_utc      is distinct from p_start_utc
     or existing.local_date  is distinct from p_local_date
     or existing.duration_s  is distinct from p_duration_s
     or existing.title       is distinct from p_title
     or existing.external_id is distinct from p_external_id
     or existing.retired_at  is not null
  then
    update public.strength_workouts
       set start_utc            = p_start_utc,
           tz_offset_minutes    = p_tz_offset_minutes,
           local_date           = p_local_date,
           duration_s           = p_duration_s,
           title                = p_title,
           external_id          = p_external_id,
           raw_record_id        = p_raw_record_id,
           import_id            = p_import_id,
           retired_at           = null,
           retired_by_import_id = null,
           revision             = existing.revision + 1,
           updated_at           = now()
     where id = existing.id;
    outcome := 'updated';
  else
    outcome := 'unchanged';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- strength_exercises. Identity is (workout_id, order_index), per v2 section 2.3.
-- ---------------------------------------------------------------------------

create or replace function public.import_upsert_strength_exercise(
  p_user_id                 uuid,
  p_workout_id              uuid,
  p_exercise_definition_id  uuid,
  p_exercise_name_raw       text,
  p_order_index             integer,
  p_raw_record_id           bigint,
  p_import_id               uuid
)
returns uuid
language plpgsql
as $$
declare
  exercise_id uuid;
begin
  insert into public.strength_exercises
    (user_id, workout_id, exercise_definition_id, exercise_name_raw, order_index,
     raw_record_id, import_id)
  values (p_user_id, p_workout_id, p_exercise_definition_id, p_exercise_name_raw, p_order_index,
          p_raw_record_id, p_import_id)
  on conflict (workout_id, order_index) do update
     set exercise_definition_id = excluded.exercise_definition_id,
         exercise_name_raw      = excluded.exercise_name_raw,
         updated_at             = now()
  returning id into exercise_id;

  return exercise_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- strength_sets
-- ---------------------------------------------------------------------------

create or replace function public.import_upsert_strength_set(
  p_user_id        uuid,
  p_natural_key    text,
  p_exercise_id    uuid,
  p_set_number     integer,
  p_set_type       text,
  p_weight_kg      numeric,
  p_reps           integer,
  p_rpe            numeric,
  p_duration_s     integer,
  p_distance_m     numeric,
  p_raw_record_id  bigint
)
returns public.upsert_outcome
language plpgsql
as $$
declare
  existing public.strength_sets%rowtype;
begin
  select * into existing from public.strength_sets where natural_key = p_natural_key;

  if not found then
    insert into public.strength_sets
      (user_id, exercise_id, set_number, set_type, weight_kg, reps, rpe, duration_s,
       distance_m, natural_key, raw_record_id)
    values (p_user_id, p_exercise_id, p_set_number, p_set_type, p_weight_kg, p_reps, p_rpe,
            p_duration_s, p_distance_m, p_natural_key, p_raw_record_id);
    return 'added';
  end if;

  if existing.weight_kg   is distinct from p_weight_kg
     or existing.reps     is distinct from p_reps
     or existing.rpe      is distinct from p_rpe
     or existing.set_type is distinct from p_set_type
     or existing.duration_s is distinct from p_duration_s
     or existing.distance_m is distinct from p_distance_m
     or existing.retired_at is not null
  then
    update public.strength_sets
       set set_type             = p_set_type,
           weight_kg            = p_weight_kg,
           reps                 = p_reps,
           rpe                  = p_rpe,
           duration_s           = p_duration_s,
           distance_m           = p_distance_m,
           raw_record_id        = p_raw_record_id,
           retired_at           = null,
           retired_by_import_id = null,
           revision             = existing.revision + 1,
           updated_at           = now()
     where id = existing.id;
    return 'updated';
  end if;

  return 'unchanged';
end;
$$;

-- ---------------------------------------------------------------------------
-- The reconciliation plan query.
--
-- Returns everything the guard evaluator needs, computed in one pass over the
-- scope rather than pulled into the worker row by row. The retire set is the
-- existing in-scope keys the incoming file does not contain; each candidate is
-- classified by the provenance rules G7, G8 and G9 test.
-- ---------------------------------------------------------------------------

create or replace function public.import_reconciliation_scope(
  p_user_id         uuid,
  p_source_key      text,
  p_date_from       date,
  p_date_to         date,
  p_incoming_keys   text[]
)
returns jsonb
language sql
stable
as $$
  with in_scope as (
    select w.natural_key,
           w.local_date,
           w.source_key,
           r.source_key      as origin_source_key,
           r.precedence_rank as origin_precedence
      from public.strength_workouts w
      join public.raw_records r on r.id = w.raw_record_id and r.user_id = w.user_id
     where w.user_id = p_user_id
       and w.retired_at is null
       and w.local_date between p_date_from and p_date_to
  ),
  retire as (
    select * from in_scope
     where not (natural_key = any (p_incoming_keys))
  )
  select jsonb_build_object(
    'existing_in_scope_count', (select count(*) from in_scope),
    'incoming_in_scope_count', (
      select count(*) from in_scope where natural_key = any (p_incoming_keys)
    ),
    'existing_date_from', (select min(local_date)::text from in_scope),
    'existing_date_to',   (select max(local_date)::text from in_scope),
    'retire_count',       (select count(*) from retire),
    'retire_keys',        coalesce((select jsonb_agg(natural_key order by local_date, natural_key) from retire), '[]'::jsonb),
    'retire_dates',       coalesce((select jsonb_agg(local_date::text order by local_date) from retire), '[]'::jsonb),
    'retire_sample',      coalesce((
        select jsonb_agg(jsonb_build_object('local_date', local_date::text, 'natural_key', natural_key))
          from (select local_date, natural_key from retire order by local_date, natural_key limit 50) s
      ), '[]'::jsonb),
    -- G8: a retirement targeting a different source than the profile declares.
    'retirements_from_other_sources', (
      select count(*) from retire where source_key is distinct from p_source_key
    ),
    -- G9: a retirement targeting a manual record. Structural provenance, not a
    -- string on the canonical row.
    'retirements_from_manual', (
      select count(*) from retire
       where origin_source_key = 'manual' or coalesce(origin_precedence, 0) > 0
    ),
    -- G7: a retirement outside the file's own date span.
    'retirements_outside_file_span', (
      select count(*) from retire
       where local_date < p_date_from or local_date > p_date_to
    )
  );
$$;

comment on function public.import_reconciliation_scope(uuid, text, date, date, text[]) is
  'v3 section 4.2/4.3. One pass over the snapshot scope producing the counts, the complete retire key set and the provenance classifications the guards need.';

-- The worker executes these on an elevated connection. The client roles get
-- nothing: normalization is not a client write path (I-4, RD-3).
revoke all on function public.import_upsert_strength_workout(uuid, text, timestamptz, integer, date, integer, text, text, text, bigint, uuid) from public, anon, authenticated;
revoke all on function public.import_upsert_strength_exercise(uuid, uuid, uuid, text, integer, bigint, uuid) from public, anon, authenticated;
revoke all on function public.import_upsert_strength_set(uuid, text, uuid, integer, text, numeric, integer, numeric, integer, numeric, bigint) from public, anon, authenticated;
revoke all on function public.import_reconciliation_scope(uuid, text, date, date, text[]) from public, anon, authenticated;
