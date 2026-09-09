-- ============================================================================
-- 20260904090100_phase2_import_layer.sql
-- Phase 2 - Data foundation: the import layer.
--
-- Scope is fixed by ruling R1. This migration creates five of the nine Phase 2
-- tables: import_profiles, data_imports, import_jobs, raw_records,
-- import_coverage. Canonical tables are the next migration. RLS, grants and
-- canonical views are the migration after that.
--
-- Specification:
--   v2 section 2.2   import_profiles, data_imports, import_jobs, raw_records
--   v2 section 5.1   import status lifecycle, superseded by v3 section 4.1
--   v2 section 5.3   rollback as the one sanctioned raw_records deletion
--   v3 section 2.7   import_coverage
--   v3 section 2.8   the tier and reduction columns
--   v3 section 3.1   built-in profiles are seeded with user_id IS NULL
--
-- Invariants:
--   I-2  raw_records is append-only, enforced by trigger below.
--   I-7  measurement values are NUMERIC(18,6). No column here holds one.
--   I-8  every table carries user_id; policies are in the RLS migration.
--   I-9  no vendor name appears anywhere in this file. source_key and
--        template are data columns whose values arrive from profile JSON.
--
-- No storage bucket, no ingest worker, no importer UI. Those are out of Phase
-- 2 by R1.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- import_profiles
--   v2 section 2.2. user_id is nullable because v3 section 3.1 requires
--   built-in profiles to be seeded with user_id IS NULL, using the same
--   system/user ownership model as the Phase 1 registries (ruling R6).
-- ---------------------------------------------------------------------------

create table public.import_profiles (
  id                   uuid primary key default gen_random_uuid(),
  user_id              uuid references auth.users (id) on delete cascade,
  name                 text not null,
  template             text not null,
  source_key           text not null,
  signature_hash       text not null,
  header_tokens        text[] not null,
  mapping_spec         jsonb not null,
  import_mode          text not null default 'append',
  snapshot_scope       jsonb,
  retention_overrides  jsonb not null default '{}'::jsonb,
  profile_version      integer not null default 1,
  times_used           integer not null default 0,
  last_used_at         timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint import_profiles_template_allowed
    check (template in ('metrics', 'activities', 'strength', 'labs', 'events')),
  constraint import_profiles_import_mode_allowed
    check (import_mode in ('append', 'full_snapshot')),
  -- v2 section 2.2: snapshot_scope is "required when full_snapshot".
  constraint import_profiles_snapshot_scope_required
    check (import_mode <> 'full_snapshot' or snapshot_scope is not null),
  constraint import_profiles_source_key_format
    check (source_key ~ '^[a-z0-9]+(_[a-z0-9]+)*$'),
  constraint import_profiles_profile_version_positive
    check (profile_version >= 1)
);

create index import_profiles_user_signature_idx
  on public.import_profiles (user_id, signature_hash);
create index import_profiles_user_id_idx on public.import_profiles (user_id);
create index import_profiles_system_signature_idx
  on public.import_profiles (signature_hash) where user_id is null;

comment on table public.import_profiles is
  'Reusable file-shape template. A profile is data, never code (ADR-12). The ingestion engine branches on nothing in this table.';
comment on column public.import_profiles.retention_overrides is
  'v3 section 2.8. metric_key -> tier overrides for this specific file shape.';

-- ---------------------------------------------------------------------------
-- data_imports
--   v2 section 2.2 plus the four v3 section 2.8 columns. Status vocabulary is
--   v2 section 5.1 as amended by v3 section 4.1, which inserts
--   planning_reconciliation and awaiting_retirement_confirmation so that
--   retirement can never run unattended (I-10).
-- ---------------------------------------------------------------------------

create table public.data_imports (
  id                     uuid primary key default gen_random_uuid(),
  user_id                uuid not null references auth.users (id) on delete cascade,
  source_key             text not null,
  template               text not null,
  profile_id             uuid references public.import_profiles (id),
  storage_path           text,
  file_name              text,
  file_type              text,
  file_bytes             bigint,
  file_sha256            text,
  mapping_spec_snapshot  jsonb not null,
  normalize_version      integer not null,
  import_mode            text not null,
  status                 text not null,
  raw_granularity        text not null default 'row',
  reduction_version      integer,
  reduction_spec         jsonb,
  file_required          boolean not null default false,
  rows_total             integer,
  rows_ingested          integer,
  records_added          integer,
  records_updated        integer,
  duplicates_skipped     integer,
  records_retired        integer,
  records_invalid        integer,
  error_log              jsonb,
  imported_at            timestamptz,
  rolled_back_at         timestamptz,
  created_at             timestamptz not null default now(),
  constraint data_imports_template_allowed
    check (template in ('metrics', 'activities', 'strength', 'labs', 'events')),
  constraint data_imports_import_mode_allowed
    check (import_mode in ('append', 'full_snapshot')),
  constraint data_imports_file_type_allowed
    check (file_type is null or file_type in ('csv', 'xlsx', 'manual')),
  constraint data_imports_raw_granularity_allowed
    check (raw_granularity in ('row', 'reduced', 'mixed')),
  -- v2 section 5.1 as amended by v3 section 4.1.
  constraint data_imports_status_allowed
    check (status in (
      'draft', 'profiling', 'awaiting_mapping', 'validating', 'preview_ready',
      'queued', 'ingesting', 'normalizing',
      'planning_reconciliation', 'awaiting_retirement_confirmation', 'retiring',
      'aggregating',
      'completed', 'completed_with_errors', 'failed', 'cancelled', 'rolled_back'
    )),
  constraint data_imports_source_key_format
    check (source_key ~ '^[a-z0-9]+(_[a-z0-9]+)*$'),
  -- v3 section 2.4: a Tier R import may not exist without its original file.
  constraint data_imports_file_required_needs_path
    check (file_required = false or storage_path is not null),
  -- v3 section 2.7 / 2.8: reduced imports carry a reduction version.
  constraint data_imports_reduced_needs_version
    check (raw_granularity = 'row' or reduction_version is not null),
  constraint data_imports_counts_non_negative
    check (
      coalesce(rows_total, 0) >= 0 and coalesce(rows_ingested, 0) >= 0
      and coalesce(records_added, 0) >= 0 and coalesce(records_updated, 0) >= 0
      and coalesce(duplicates_skipped, 0) >= 0 and coalesce(records_retired, 0) >= 0
      and coalesce(records_invalid, 0) >= 0
    ),
  -- Required by the composite foreign keys that keep the whole import graph
  -- inside one user without any policy needing a join (I-8).
  constraint data_imports_id_user_uq unique (id, user_id)
);

create index data_imports_user_created_idx
  on public.data_imports (user_id, created_at desc);
create index data_imports_user_status_idx on public.data_imports (user_id, status);
create index data_imports_profile_idx on public.data_imports (profile_id);
-- v2 section 5.2: exact-file re-upload detection.
create index data_imports_user_sha_idx
  on public.data_imports (user_id, file_sha256) where file_sha256 is not null;
-- v2 section 4.4: rebuild replays imports in ascending imported_at order.
create index data_imports_user_imported_at_idx
  on public.data_imports (user_id, imported_at) where imported_at is not null;

comment on column public.data_imports.mapping_spec_snapshot is
  'v2 section 3. Frozen copy of the profile mapping at import time, so editing a profile later cannot retroactively change what a past import meant.';
comment on column public.data_imports.imported_at is
  'v2 section 4.4. Rebuild replays imports in this order, so full_snapshot retirement reproduces. Never mutate this value.';

-- ---------------------------------------------------------------------------
-- import_jobs
--   v2 section 2.2. One row per stage, so a failure in a late stage does not
--   require re-ingesting the file.
-- ---------------------------------------------------------------------------

create table public.import_jobs (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  import_id     uuid not null,
  stage         text not null,
  state         text not null default 'queued',
  cursor        jsonb not null default '{}'::jsonb,
  attempts      integer not null default 0,
  last_error    text,
  started_at    timestamptz,
  finished_at   timestamptz,
  heartbeat_at  timestamptz,
  created_at    timestamptz not null default now(),
  constraint import_jobs_stage_allowed
    check (stage in ('ingest', 'normalize', 'retire', 'rollup', 'derive', 'timeline', 'insights')),
  constraint import_jobs_state_allowed
    check (state in ('queued', 'running', 'paused', 'done', 'failed', 'cancelled')),
  -- v2 section 5.3: max 5 attempts.
  constraint import_jobs_attempts_bounded
    check (attempts >= 0 and attempts <= 5),
  constraint import_jobs_import_fk
    foreign key (import_id, user_id)
    references public.data_imports (id, user_id) on delete cascade
);

create index import_jobs_queue_idx
  on public.import_jobs (state, stage) where state in ('queued', 'running');
create index import_jobs_user_id_idx on public.import_jobs (user_id);
create index import_jobs_import_idx on public.import_jobs (import_id);
-- v2 section 5.3: a job whose heartbeat is older than 5 minutes is stuck.
create index import_jobs_heartbeat_idx
  on public.import_jobs (heartbeat_at) where state = 'running';

-- ---------------------------------------------------------------------------
-- raw_records
--   v2 section 2.2 plus v3 section 2.8. BIGSERIAL, per v2's own DDL and
--   because v2 section 2.3 declares every canonical raw_record_id as BIGINT.
--
--   This is the provenance spine. Everything canonical points back here, and
--   this table points back to data_imports and from there to the original
--   file (PRD section 4.4, section 19).
-- ---------------------------------------------------------------------------

create table public.raw_records (
  id                      bigserial primary key,
  user_id                 uuid not null references auth.users (id) on delete cascade,
  import_id               uuid not null,
  source_key              text not null,
  row_number              integer,
  external_id             text,
  payload                 jsonb not null,
  row_hash                text not null,
  precedence_rank         smallint not null default 0,
  supersedes_natural_key  text,
  observed_at             timestamptz not null default now(),
  granularity             text not null default 'row',
  bucket_metric_key       text,
  bucket_local_date       date,
  bucket_sample_count     integer,
  processed_at            timestamptz,
  normalize_version       integer,
  normalize_status        text not null default 'pending',
  normalize_error         text,
  normalized_keys         text[],
  constraint raw_records_granularity_allowed
    check (granularity in ('row', 'reduced')),
  constraint raw_records_normalize_status_allowed
    check (normalize_status in ('pending', 'ok', 'invalid', 'skipped')),
  -- v2 section 4.3: 0 imported, 10 manual entry, 20 manual correction.
  constraint raw_records_precedence_rank_allowed
    check (precedence_rank in (0, 10, 20)),
  -- v3 section 1.4: a reduced record is a bucket and must describe its bucket.
  constraint raw_records_reduced_bucket_complete
    check (
      granularity = 'row'
      or (bucket_metric_key is not null
          and bucket_local_date is not null
          and bucket_sample_count is not null
          and bucket_sample_count > 0)
    ),
  constraint raw_records_row_has_no_bucket
    check (
      granularity = 'reduced'
      or (bucket_metric_key is null
          and bucket_local_date is null
          and bucket_sample_count is null)
    ),
  constraint raw_records_import_fk
    foreign key (import_id, user_id)
    references public.data_imports (id, user_id) on delete cascade,
  constraint raw_records_id_user_uq unique (id, user_id)
);

-- v2 section 2.2 index set.
create index raw_records_import_id_idx on public.raw_records (import_id, id);
create index raw_records_pending_idx
  on public.raw_records (user_id, normalize_status) where normalize_status = 'pending';
-- Intra-file duplicate guard. Makes chunk replay idempotent (v2 section 5.2).
create unique index raw_records_import_row_hash_uq
  on public.raw_records (import_id, row_hash);
-- v2 section 7.3 / v3 section 2.8: history lookup by produced natural key.
create index raw_records_normalized_keys_gin
  on public.raw_records using gin (normalized_keys);
create index raw_records_user_id_idx on public.raw_records (user_id);
create index raw_records_supersedes_idx
  on public.raw_records (supersedes_natural_key) where supersedes_natural_key is not null;

comment on table public.raw_records is
  'Append-only. Every canonical row originates from exactly one row here (I-1). Enforced by raw_records_append_only().';
comment on column public.raw_records.precedence_rank is
  'v2 section 4.3, ADR-07. 0 imported, 10 manual entry, 20 manual correction. Conflict resolution sorts precedence_rank DESC, observed_at DESC, id DESC. Distinct from sources.precedence_rank and from the Phase 5 source_precedence.priority, which orders ascending.';

-- ---------------------------------------------------------------------------
-- Append-only enforcement (I-2, v2 section 2.2, v2 section 5.3)
-- ---------------------------------------------------------------------------

create or replace function public.raw_records_append_only()
returns trigger
language plpgsql
as $$
declare
  -- The only columns normalization is allowed to write back.
  mutable_columns text[] := array[
    'processed_at', 'normalize_version', 'normalize_status',
    'normalize_error', 'normalized_keys'
  ];
  deletion_reason text;
begin
  if tg_op = 'DELETE' then
    -- I-2 permits exactly two deletion paths: a user-initiated import
    -- rollback (v2 section 5.3) and a Tier R re-reduce (v3 section 2.7 step 4).
    -- Both must announce themselves on the session before deleting.
    deletion_reason := current_setting('app.raw_records_deletion_reason', true);
    if deletion_reason is null
       or deletion_reason not in ('import_rollback', 'tier_r_re_reduce') then
      raise exception
        'raw_records is append-only: DELETE requires app.raw_records_deletion_reason to be import_rollback or tier_r_re_reduce (I-2)'
        using errcode = '42501';
    end if;
    return old;
  end if;

  if to_jsonb(old) - mutable_columns is distinct from to_jsonb(new) - mutable_columns then
    raise exception
      'raw_records is append-only: only %  may be updated (I-2)',
      array_to_string(mutable_columns, ', ')
      using errcode = '42501';
  end if;

  return new;
end;
$$;

comment on function public.raw_records_append_only() is
  'I-2. Rejects any UPDATE touching a column outside the normalization write-back set, and any DELETE not announced as one of the two sanctioned paths.';

create trigger raw_records_append_only
  before update or delete on public.raw_records
  for each row execute function public.raw_records_append_only();

-- ---------------------------------------------------------------------------
-- import_coverage
--   v3 section 2.7. Answers "which file holds raw samples for this metric in
--   this date range" in one indexed query, which re-tiering requires and the
--   provenance UI uses.
-- ---------------------------------------------------------------------------

create table public.import_coverage (
  id                   uuid primary key default gen_random_uuid(),
  user_id              uuid not null references auth.users (id) on delete cascade,
  import_id            uuid not null,
  template             text not null,
  metric_key           text,
  granularity          text not null,
  date_from            date not null,
  date_to              date not null,
  source_row_count     integer not null,
  canonical_row_count  integer not null,
  created_at           timestamptz not null default now(),
  constraint import_coverage_template_allowed
    check (template in ('metrics', 'activities', 'strength', 'labs', 'events')),
  constraint import_coverage_granularity_allowed
    check (granularity in ('event', 'daily', 'reduced')),
  constraint import_coverage_date_range_ordered
    check (date_from <= date_to),
  constraint import_coverage_counts_non_negative
    check (source_row_count >= 0 and canonical_row_count >= 0),
  constraint import_coverage_import_fk
    foreign key (import_id, user_id)
    references public.data_imports (id, user_id) on delete cascade
);

create index import_coverage_lookup_idx
  on public.import_coverage (user_id, metric_key, date_from, date_to);
create index import_coverage_import_idx on public.import_coverage (import_id);
create index import_coverage_user_id_idx on public.import_coverage (user_id);
