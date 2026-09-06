-- ============================================================================
-- 0003_training_metric_registry.sql
-- System metric definitions for the Phase 5 analytics layer. NOT a schema
-- migration (CLAUDE.md §5: reference data is seeded separately, via idempotent
-- upserts, and adding a metric definition must never require a schema change).
--
-- Re-running this file is a no-op beyond refreshing updated_at.
--
-- These are definitions, not measurements. This file contains no health data.
--
-- WHY EACH GAP POLICY IS WHAT IT IS
--
-- gap_policy says what a day with no row MEANS. metric_daily stores only days
-- with observations (v2 §9.4), so the policy is the only thing that
-- distinguishes "none happened" from "nothing was recorded".
--
--   training_workouts, training_exercise_slots, training_sets,
--   training_volume_sets  -> 'zero'. A day with no row is a day the user did
--   not train, and zero workouts is a true statement about it.
--
--   training_volume_kg -> 'null'. This is the one that repays explanation.
--   v2 §9.4 gives "training volume gaps are genuine zeros" as its example of a
--   zero policy, and for a day with no training that is right. But a day WITH
--   training and no loaded set — a session of planks and carries — also has no
--   volume row, and calling that zero conflates "no load was recorded" with
--   "zero load was lifted". The first is an absence of observation; the second
--   is a measurement. The analytics layer cannot tell them apart from the
--   volume series alone, so it declines to invent the difference and reports a
--   gap, which is what the Phase 4 product surface already showed and said.
--   See docs/architecture-implementation-notes.md N-6.
--
--   training_reps, training_duration_s -> 'null', for the same reason: a
--   session recording neither is an absence, not a zero.
-- ============================================================================

begin;

-- manual_entry is false for every one of these: they are aggregations the
-- rollup computes from canonical training data. A typed value would be a
-- second, unreconcilable source of truth for a figure that already has one.
insert into public.metric_definitions
  (user_id, key, display_name, description, canonical_unit_id, default_aggregation, gap_policy, manual_entry)
select null, v.key, v.display_name, v.description, u.id, v.default_aggregation, v.gap_policy, false
from (
  values
    ('training_workouts',       'Training Workouts',
     'Number of training sessions recorded on a day.',
     'count', 'sum', 'zero'),
    ('training_exercise_slots', 'Training Exercise Slots',
     'Number of exercises performed across the day''s sessions, counting an exercise once per session it appears in.',
     'count', 'sum', 'zero'),
    ('training_sets',           'Training Sets',
     'Number of sets recorded across the day''s sessions.',
     'count', 'sum', 'zero'),
    ('training_volume_sets',    'Training Volume Sets',
     'Number of sets recording both a load and a rep count, and therefore contributing to training volume.',
     'count', 'sum', 'zero'),
    ('training_volume_kg',      'Training Volume',
     'Sum of load multiplied by repetitions, over sets recording both. Sets carrying no load contribute nothing rather than zero.',
     'kg', 'sum', 'null'),
    ('training_reps',           'Training Reps',
     'Sum of repetitions across sets recording a rep count.',
     'count', 'sum', 'null'),
    ('training_duration_s',     'Training Duration',
     'Sum of session durations across the day''s sessions.',
     's', 'sum', 'null')
) as v (key, display_name, description, unit_key, default_aggregation, gap_policy)
join public.units u on u.key = v.unit_key and u.user_id is null
on conflict (key) where user_id is null
do update set
  display_name        = excluded.display_name,
  description         = excluded.description,
  canonical_unit_id   = excluded.canonical_unit_id,
  default_aggregation = excluded.default_aggregation,
  gap_policy          = excluded.gap_policy,
  manual_entry        = excluded.manual_entry,
  is_active           = true,
  updated_at          = now();

commit;
