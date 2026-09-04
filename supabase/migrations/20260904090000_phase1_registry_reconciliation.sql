-- ============================================================================
-- 20260904090000_phase1_registry_reconciliation.sql
-- Phase 1 registry reconciliation (ruling R2). Additive and forward-only.
--
-- Adds the five columns the authoritative documents require on
-- metric_definitions and that Phase 1 did not have. Nothing is renamed,
-- dropped or retyped. The full column-by-column diff, including every
-- divergence deliberately left alone because only a future phase needs it, is
-- in docs/phase-2-reconciliation-audit.md section C.1.
--
--   retention_tier, day_attribution, gap_policy   v3 section 2.8
--   plausibility_min, plausibility_max            ruling R4
--
-- Values for the nine system metrics are set by the reference-data seed
-- supabase/seeds/0002_metric_registry_policy.sql, not here.
-- ============================================================================

alter table public.metric_definitions
  add column retention_tier text not null default 'daily',
  add column day_attribution text not null default 'event_date',
  add column gap_policy text not null default 'null',
  add column plausibility_min numeric(18,6),
  add column plausibility_max numeric(18,6);

alter table public.metric_definitions
  add constraint metric_definitions_retention_tier_allowed
    check (retention_tier in ('event', 'daily', 'reduced')),
  add constraint metric_definitions_day_attribution_allowed
    check (day_attribution in ('event_date', 'wake_date')),
  add constraint metric_definitions_gap_policy_allowed
    check (gap_policy in ('zero', 'carry_forward', 'null')),
  add constraint metric_definitions_plausibility_ordered
    check (
      plausibility_min is null
      or plausibility_max is null
      or plausibility_min <= plausibility_max
    );

comment on column public.metric_definitions.retention_tier is
  'v3 section 2.2/2.3. Declares whether this metric is stored event-level, daily-level, or reduced from high-frequency samples. Read by tier selection during profiling; raw_records.granularity follows from it.';

comment on column public.metric_definitions.day_attribution is
  'v3 section 2.8, v2 section 8.4. Which local date an observation belongs to. Sleep is attributed to the wake date; everything else to the event date.';

comment on column public.metric_definitions.gap_policy is
  'v2 section 9.4. How the analytics layer treats a day with no observation. Applied at read time, never in storage.';

comment on column public.metric_definitions.plausibility_min is
  'Ruling R4. Lower plausibility bound in the canonical unit, NUMERIC(18,6) per I-7. NULL means unbounded. A value below this bound makes the raw record normalize_status = invalid; it never enters a canonical table, and the raw payload is preserved.';

comment on column public.metric_definitions.plausibility_max is
  'Ruling R4. Upper plausibility bound in the canonical unit. See plausibility_min.';
