-- ============================================================================
-- 0002_metric_registry_policy.sql
-- Reference data, not a schema migration. Idempotent.
--
-- Sets the registry policy columns added by
-- 20260904090000_phase1_registry_reconciliation.sql on the nine system metrics
-- seeded by 0001. Runs after 0001 and touches only rows with user_id IS NULL.
--
-- EVERY value below is taken from an authoritative document. Where no document
-- states a value, the column keeps its schema default and is left alone. In
-- particular, no plausibility bound is invented: only weight and heart rate
-- are given bounds anywhere in the specifications (v2 section 4.2 step 6).
--
--   retention_tier    v3 section 2.2 "Tier D - daily-level, source already
--                     daily" names HRV, resting heart rate, recovery score,
--                     weight, body fat, waist circumference, daily step totals
--                     and daily active energy. sleep_duration is not named and
--                     therefore keeps the 'daily' schema default.
--   day_attribution   v2 section 8.4 and decision D7: sleep metrics are
--                     attributed to the wake date. Everything else keeps
--                     'event_date'.
--   gap_policy        v2 section 9.4 states weight gaps are carry-forward and
--                     HRV gaps are simply missing. No other metric is named,
--                     so the rest keep the 'null' default.
--   plausibility      v2 section 4.2 step 6: "weight 20 to 400 kg,
--                     HR 20 to 250 bpm".
--
-- This file contains registry policy only. It contains no measurements.
-- ============================================================================

begin;

-- v3 section 2.2, Tier D. Explicit rather than relying on the column default,
-- so the assignment is traceable to the document that made it.
update public.metric_definitions
   set retention_tier = 'daily',
       updated_at     = now()
 where user_id is null
   and key in (
     'heart_rate_variability', 'resting_heart_rate', 'recovery_score',
     'weight', 'body_fat_percentage', 'waist_circumference',
     'steps', 'active_energy'
   )
   and retention_tier is distinct from 'daily';

-- v2 section 8.4, decision D7.
update public.metric_definitions
   set day_attribution = 'wake_date',
       updated_at      = now()
 where user_id is null
   and key = 'sleep_duration'
   and day_attribution is distinct from 'wake_date';

-- v2 section 9.4: "weight gaps are carry-forward or interpolate".
update public.metric_definitions
   set gap_policy = 'carry_forward',
       updated_at = now()
 where user_id is null
   and key = 'weight'
   and gap_policy is distinct from 'carry_forward';

-- v2 section 9.4: "HRV gaps are simply missing". Same as the default, stated
-- explicitly because the document states it.
update public.metric_definitions
   set gap_policy = 'null',
       updated_at = now()
 where user_id is null
   and key = 'heart_rate_variability'
   and gap_policy is distinct from 'null';

-- v2 section 4.2 step 6. Bounds are in each metric's canonical unit:
-- weight in kg, resting_heart_rate in bpm.
update public.metric_definitions
   set plausibility_min = 20.000000,
       plausibility_max = 400.000000,
       updated_at       = now()
 where user_id is null
   and key = 'weight'
   and (plausibility_min is distinct from 20.000000
        or plausibility_max is distinct from 400.000000);

update public.metric_definitions
   set plausibility_min = 20.000000,
       plausibility_max = 250.000000,
       updated_at       = now()
 where user_id is null
   and key = 'resting_heart_rate'
   and (plausibility_min is distinct from 20.000000
        or plausibility_max is distinct from 250.000000);

commit;
