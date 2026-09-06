-- ============================================================================
-- 20260908090000_phase6_manual_entry.sql
-- Phase 6: manual body tracking — the canonical write path.
--
-- WHAT THIS ADDS
--
-- Two functions. Everything else manual entry needs already exists, because
-- the schema was built expecting it: data_imports.file_type allows 'manual',
-- storage_path is nullable, raw_records carries precedence_rank (0 imported,
-- 10 manual entry, 20 manual correction) and supersedes_natural_key, and
-- metrics is the canonical scalar table with its natural-key unique index.
--
-- I-1 IS NOT BENT FOR CONVENIENCE
--
-- A typed measurement is not written to metrics. It becomes a synthetic import
-- and a raw record, and the same normalization that turns a Hevy CSV row into
-- a set turns that raw record into a metric. The value in metrics is therefore
-- reproducible from the raw layer, which is the property the whole design
-- rests on, and a correction is a new raw record rather than an UPDATE.
--
-- PRECEDENCE, AND WHY IT LIVES HERE
--
-- Normalization is pure (I-3): it cannot read the row it is about to replace,
-- so it cannot decide whether it should. That decision needs both the incoming
-- raw record and the existing row's origin, which is a database read, so it
-- belongs in the upsert.
--
-- v2 §4.3 fixes the order: precedence_rank DESC, observed_at DESC, id DESC. A
-- record that loses is not an error and not a duplicate — it is simply not the
-- winner, and the canonical row is left alone. That is what makes a rebuild
-- order-independent: whichever order the raw records are replayed in, the same
-- one wins, so a correction survives.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Which metrics a person may record by hand.
--
-- The registry has to answer this, because the alternative is a hard-coded
-- list of metric keys in the UI, which is exactly the free-text identifier
-- I-6 exists to forbid. It is also a real registry property: body mass is
-- something a person measures, training volume is something the system
-- computes, and nothing but the definition knows which is which.
--
-- Default false, so a metric is enterable only when its definition says so.
-- Seed 0001 marks the nine measurable ones; seed 0003 leaves the training
-- aggregates false and says why.
-- ---------------------------------------------------------------------------

alter table public.metric_definitions
  add column manual_entry boolean not null default false;

comment on column public.metric_definitions.manual_entry is
  'True when a person can meaningfully record this metric by hand. False for anything the system derives, which must not be typeable.';

-- ---------------------------------------------------------------------------
-- 1. metrics upsert (v2 §7.2 semantics, plus §4.3 precedence)
-- ---------------------------------------------------------------------------

create or replace function public.import_upsert_metric(
  p_user_id               uuid,
  p_natural_key           text,
  p_metric_definition_id  uuid,
  p_metric_key            text,
  p_qualifier             text,
  p_timestamp_utc         timestamptz,
  p_tz_offset_minutes     integer,
  p_tz_name               text,
  p_local_date            date,
  p_value_num             numeric,
  p_unit_id               uuid,
  p_unit                  text,
  p_source_key            text,
  p_source_value_num      numeric,
  p_source_unit           text,
  p_raw_record_id         bigint,
  p_import_id             uuid
)
returns public.upsert_outcome
language plpgsql
as $$
declare
  existing        public.metrics%rowtype;
  incoming_rank   smallint;
  incoming_seen   timestamptz;
  existing_rank   smallint;
  existing_seen   timestamptz;
  existing_raw_id bigint;
begin
  select r.precedence_rank, r.observed_at
    into incoming_rank, incoming_seen
    from public.raw_records r
   where r.id = p_raw_record_id;

  if incoming_rank is null then
    raise exception 'import_upsert_metric: raw record % does not exist (I-1)', p_raw_record_id
      using errcode = '23503';
  end if;

  select * into existing
    from public.metrics
   where natural_key = p_natural_key and is_derived = false;

  if not found then
    insert into public.metrics
      (user_id, metric_definition_id, metric_key, qualifier, timestamp_utc,
       tz_offset_minutes, tz_name, local_date, value_num, unit_id, unit,
       source_key, source_value_num, source_unit, natural_key, raw_record_id, import_id)
    values
      (p_user_id, p_metric_definition_id, p_metric_key, p_qualifier, p_timestamp_utc,
       p_tz_offset_minutes, p_tz_name, p_local_date, p_value_num, p_unit_id, p_unit,
       p_source_key, p_source_value_num, p_source_unit, p_natural_key, p_raw_record_id, p_import_id);
    return 'added';
  end if;

  -- v2 §4.3: precedence_rank DESC, observed_at DESC, id DESC. The existing
  -- row's standing comes from the raw record it originated in, not from the
  -- canonical row, because provenance is where that fact lives.
  select r.precedence_rank, r.observed_at, r.id
    into existing_rank, existing_seen, existing_raw_id
    from public.raw_records r
   where r.id = existing.raw_record_id;

  if (incoming_rank, incoming_seen, p_raw_record_id)
     < (coalesce(existing_rank, 0), coalesce(existing_seen, '-infinity'::timestamptz), coalesce(existing_raw_id, 0))
  then
    -- A lower-precedence record cannot overwrite a higher-precedence one. This
    -- is the whole mechanism behind "a correction survives a rebuild": replay
    -- the entry after the correction and it loses, every time.
    return 'unchanged';
  end if;

  if existing.value_num        is distinct from p_value_num
     or existing.timestamp_utc is distinct from p_timestamp_utc
     or existing.local_date    is distinct from p_local_date
     or existing.unit_id       is distinct from p_unit_id
     or existing.qualifier     is distinct from p_qualifier
     or existing.source_value_num is distinct from p_source_value_num
     or existing.source_unit   is distinct from p_source_unit
     or existing.raw_record_id is distinct from p_raw_record_id
     or existing.retired_at    is not null
  then
    update public.metrics
       set metric_definition_id = p_metric_definition_id,
           metric_key           = p_metric_key,
           qualifier            = p_qualifier,
           timestamp_utc        = p_timestamp_utc,
           tz_offset_minutes    = p_tz_offset_minutes,
           tz_name              = p_tz_name,
           local_date           = p_local_date,
           value_num            = p_value_num,
           unit_id              = p_unit_id,
           unit                 = p_unit,
           source_value_num     = p_source_value_num,
           source_unit          = p_source_unit,
           raw_record_id        = p_raw_record_id,
           import_id            = p_import_id,
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

comment on function public.import_upsert_metric is
  'v2 §7.2 upsert plus §4.3 precedence. A lower-precedence raw record never overwrites a higher-precedence one, which is what makes a normalize rebuild order-independent and lets a manual correction survive it.';

-- ---------------------------------------------------------------------------
-- 2. Rebuild.
--
-- Canonical rows are reproducible from the raw layer — that is v2 §1.4's claim
-- and I-3's purpose. This function makes the claim executable: it returns the
-- scope's raw records to 'pending' and queues a fresh normalize job per
-- import, so the ordinary worker replays them through the ordinary path.
--
-- It writes only the five columns the append-only trigger permits (I-2). It
-- creates no canonical rows itself and deletes nothing: replaying an unchanged
-- raw layer through a pure function must land on the same answer, and if it
-- does not, that is a bug worth seeing rather than one to paper over by
-- clearing the table first.
-- ---------------------------------------------------------------------------

create or replace function public.normalize_rebuild_enqueue(
  p_user_id  uuid,
  p_template text default null
)
returns integer
language plpgsql
as $$
declare
  queued integer := 0;
  imp    record;
begin
  for imp in
    select i.id, i.user_id
      from public.data_imports i
     where i.user_id = p_user_id
       and (p_template is null or i.template = p_template)
       and i.status in ('completed', 'completed_with_errors')
     order by i.created_at
  loop
    update public.raw_records
       set normalize_status = 'pending',
           processed_at     = null,
           normalize_error  = null
     where import_id = imp.id
       and user_id   = imp.user_id;

    insert into public.import_jobs (user_id, import_id, stage, state, cursor)
    values (imp.user_id, imp.id, 'normalize', 'queued', '{}'::jsonb);

    queued := queued + 1;
  end loop;

  return queued;
end;
$$;

comment on function public.normalize_rebuild_enqueue(uuid, text) is
  'Phase 6. Replays a user''s raw layer through normalization by resetting raw_records to pending and queueing a normalize job per import. The rebuild uses the ordinary worker and the ordinary upsert path; nothing about it is special-cased.';

-- ---------------------------------------------------------------------------
-- 3. The read model for recorded measurements.
--
-- SECURITY INVOKER over v_metrics (I-5), so retired rows are excluded and RLS
-- scopes the read to the caller. It takes no user id: there is no parameter
-- with which to ask for someone else's measurements.
--
-- natural_key is returned because it is what a correction names. That is the
-- one piece of canonical identity the client legitimately needs: it cannot
-- write a metric row, but it can record a raw record that supersedes one.
-- ---------------------------------------------------------------------------

create or replace function public.body_measurements(
  p_limit      integer default 50,
  p_offset     integer default 0,
  p_metric_key text default null
)
returns table (
  id               bigint,
  natural_key      text,
  metric_key       text,
  display_name     text,
  qualifier        text,
  timestamp_utc    timestamptz,
  local_date       date,
  value_num        numeric,
  unit             text,
  source_value_num numeric,
  source_unit      text,
  revision         integer,
  precedence_rank  smallint,
  corrected        boolean,
  recorded_at      timestamptz,
  total_count      bigint
)
language sql
stable
as $$
  with rows_ as (
    select
      m.id,
      m.natural_key,
      m.metric_key,
      d.display_name,
      m.qualifier,
      m.timestamp_utc,
      m.local_date,
      m.value_num,
      m.unit,
      m.source_value_num,
      m.source_unit,
      m.revision,
      r.precedence_rank,
      -- The row currently in force originated in a correction, so what is
      -- displayed is not what was first recorded.
      (r.precedence_rank >= 20) as corrected,
      r.observed_at as recorded_at,
      count(*) over () as total_count
    from public.v_metrics m
    join public.metric_definitions d on d.id = m.metric_definition_id
    join public.raw_records r on r.id = m.raw_record_id and r.user_id = m.user_id
    where m.is_derived = false
      and (p_metric_key is null or m.metric_key = p_metric_key)
  )
  select * from rows_
   order by rows_.timestamp_utc desc, rows_.metric_key
   limit greatest(p_limit, 0) offset greatest(p_offset, 0);
$$;

comment on function public.body_measurements(integer, integer, text) is
  'Phase 6 read model. The measurements currently in force for the signed-in user, with the provenance that says whether each one is an original entry or a correction.';

grant execute on function public.body_measurements(integer, integer, text) to authenticated;
revoke all on function public.body_measurements(integer, integer, text) from public, anon;

-- ---------------------------------------------------------------------------
-- 4. Privileges. Both are worker-side: normalization is the sanctioned
--    canonical write path and the client roles hold SELECT only (I-4, RD-3).
-- ---------------------------------------------------------------------------

revoke all on function public.import_upsert_metric(
  uuid, text, uuid, text, text, timestamptz, integer, text, date, numeric, uuid, text,
  text, numeric, text, bigint, uuid
) from public, anon, authenticated;

revoke all on function public.normalize_rebuild_enqueue(uuid, text) from public, anon, authenticated;
