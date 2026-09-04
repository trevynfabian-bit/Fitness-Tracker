-- ============================================================================
-- 0001_system_registry.sql
-- System registry reference data. NOT a schema migration (CLAUDE.md §5:
-- "Reference data is seeded separately from schema migrations, via idempotent
-- upserts"). Re-running this file is a no-op beyond refreshing updated_at.
--
-- Every row here has user_id = NULL: it is system registry, shared by all
-- users, read-only through the client API. This file must be executed with a
-- privileged connection (migration role / service role) because RLS forbids
-- authenticated users from writing user_id IS NULL rows.
--
-- This file contains reference data only. It contains no health measurements,
-- no observations, and no demo rows of any kind (CLAUDE.md §4: "No mock health
-- data. Ever.").
--
-- Phase 1 seeds the metric registry required by CLAUDE.md §4:
--   weight, body_fat_percentage, waist_circumference, resting_heart_rate,
--   heart_rate_variability, sleep_duration, steps, active_energy,
--   recovery_score
-- plus the units and unit conversions those definitions depend on.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- units
-- ---------------------------------------------------------------------------

insert into public.units (user_id, key, display_name, symbol, dimension)
values
  (null, 'kg',      'Kilogram',              'kg',    'mass'),
  (null, 'g',       'Gram',                  'g',     'mass'),
  (null, 'lb',      'Pound',                 'lb',    'mass'),
  (null, 'cm',      'Centimetre',            'cm',    'length'),
  (null, 'm',       'Metre',                 'm',     'length'),
  (null, 'km',      'Kilometre',             'km',    'length'),
  (null, 'in',      'Inch',                  'in',    'length'),
  (null, 'ms',      'Millisecond',           'ms',    'time'),
  (null, 's',       'Second',                's',     'time'),
  (null, 'min',     'Minute',                'min',   'time'),
  (null, 'h',       'Hour',                  'h',     'time'),
  (null, 'kcal',    'Kilocalorie',           'kcal',  'energy'),
  (null, 'kj',      'Kilojoule',             'kJ',    'energy'),
  (null, 'count',   'Count',                 null,    'count'),
  (null, 'bpm',     'Beats per minute',      'bpm',   'frequency'),
  (null, 'percent', 'Percent',               '%',     'ratio'),
  (null, 'score',   'Score',                 null,    'dimensionless')
on conflict (key) where user_id is null
do update set
  display_name = excluded.display_name,
  symbol       = excluded.symbol,
  dimension    = excluded.dimension,
  is_active    = true,
  updated_at   = now();

-- ---------------------------------------------------------------------------
-- unit_conversions
--   value_in_to_unit = value_in_from_unit * factor
--   Exact factors where an exact decimal exists; otherwise the reciprocal
--   rounded to the column's 15 fractional digits.
-- ---------------------------------------------------------------------------

insert into public.unit_conversions (user_id, from_unit_id, to_unit_id, factor)
select null, f.id, t.id, v.factor
from (
  values
    -- mass
    ('g',    'kg',   0.001000000000000::numeric),
    ('kg',   'g',    1000.000000000000000::numeric),
    ('lb',   'kg',   0.453592370000000::numeric),
    ('kg',   'lb',   2.204622621848776::numeric),
    -- length
    ('m',    'cm',   100.000000000000000::numeric),
    ('cm',   'm',    0.010000000000000::numeric),
    ('in',   'cm',   2.540000000000000::numeric),
    ('cm',   'in',   0.393700787401575::numeric),
    ('km',   'm',    1000.000000000000000::numeric),
    ('m',    'km',   0.001000000000000::numeric),
    ('km',   'cm',   100000.000000000000000::numeric),
    ('cm',   'km',   0.000010000000000::numeric),
    -- time
    ('ms',   's',    0.001000000000000::numeric),
    ('s',    'ms',   1000.000000000000000::numeric),
    ('ms',   'min',  0.000016666666667::numeric),
    ('min',  'ms',   60000.000000000000000::numeric),
    ('ms',   'h',    0.000000277777778::numeric),
    ('h',    'ms',   3600000.000000000000000::numeric),
    ('s',    'min',  0.016666666666667::numeric),
    ('min',  's',    60.000000000000000::numeric),
    ('s',    'h',    0.000277777777778::numeric),
    ('h',    's',    3600.000000000000000::numeric),
    ('min',  'h',    0.016666666666667::numeric),
    ('h',    'min',  60.000000000000000::numeric),
    -- energy
    ('kj',   'kcal', 0.239005736137667::numeric),
    ('kcal', 'kj',   4.184000000000000::numeric)
) as v (from_key, to_key, factor)
join public.units f on f.key = v.from_key and f.user_id is null
join public.units t on t.key = v.to_key   and t.user_id is null
on conflict (from_unit_id, to_unit_id) where user_id is null
do update set
  factor     = excluded.factor,
  "offset"   = excluded."offset",
  updated_at = now();

-- ---------------------------------------------------------------------------
-- metric_definitions
-- ---------------------------------------------------------------------------

insert into public.metric_definitions
  (user_id, key, display_name, description, canonical_unit_id, default_aggregation)
select null, v.key, v.display_name, v.description, u.id, v.default_aggregation
from (
  values
    ('weight',                 'Weight',                 'Total body mass.',                                              'kg',      'mean'),
    ('body_fat_percentage',    'Body Fat Percentage',    'Proportion of total body mass that is fat mass.',               'percent', 'mean'),
    ('waist_circumference',    'Waist Circumference',    'Circumference of the waist at the measurement site.',           'cm',      'mean'),
    ('resting_heart_rate',     'Resting Heart Rate',     'Heart rate measured at rest.',                                  'bpm',     'mean'),
    ('heart_rate_variability', 'Heart Rate Variability', 'Beat-to-beat variation in heart rate.',                         'ms',      'mean'),
    ('sleep_duration',         'Sleep Duration',         'Total time asleep across a sleep period.',                      'min',     'sum'),
    ('steps',                  'Steps',                  'Number of steps taken.',                                        'count',   'sum'),
    ('active_energy',          'Active Energy',          'Energy expended above resting metabolic rate.',                 'kcal',    'sum'),
    ('recovery_score',         'Recovery Score',         'Composite readiness or recovery index reported by a source.',   'score',   'mean')
) as v (key, display_name, description, unit_key, default_aggregation)
join public.units u on u.key = v.unit_key and u.user_id is null
on conflict (key) where user_id is null
do update set
  display_name        = excluded.display_name,
  description         = excluded.description,
  canonical_unit_id   = excluded.canonical_unit_id,
  default_aggregation = excluded.default_aggregation,
  is_active           = true,
  updated_at          = now();

-- ---------------------------------------------------------------------------
-- metric_aliases
--   Source-agnostic aliases (source_key IS NULL). Vendor-scoped aliases are
--   added by the vendor's import profile, not here (I-9).
--
--   Every value below is already in the form public.normalize_alias produces
--   (lowercase, punctuation to space, whitespace collapsed, trimmed), which the
--   metric_aliases_alias_is_normalized check constraint requires. Variants that
--   differed only in punctuation, such as body_fat and "body fat %", collapse
--   to one entry and are not repeated here.
-- ---------------------------------------------------------------------------

insert into public.metric_aliases (user_id, metric_definition_id, alias_normalized, source_key)
select null, d.id, v.alias_normalized, null
from (
  values
    ('weight',                 'weight'),
    ('weight',                 'body weight'),
    ('weight',                 'bodyweight'),
    ('weight',                 'weight kg'),
    ('weight',                 'weight lb'),

    ('body_fat_percentage',    'body fat'),
    ('body_fat_percentage',    'body fat percentage'),
    ('body_fat_percentage',    'bodyfat'),
    ('body_fat_percentage',    'fat percentage'),

    ('waist_circumference',    'waist'),
    ('waist_circumference',    'waist circumference'),
    ('waist_circumference',    'waist cm'),

    ('resting_heart_rate',     'rhr'),
    ('resting_heart_rate',     'resting hr'),
    ('resting_heart_rate',     'resting heart rate'),

    ('heart_rate_variability', 'hrv'),
    ('heart_rate_variability', 'heart rate variability'),
    ('heart_rate_variability', 'rmssd'),

    ('sleep_duration',         'sleep'),
    ('sleep_duration',         'sleep duration'),
    ('sleep_duration',         'time asleep'),
    ('sleep_duration',         'total sleep'),
    ('sleep_duration',         'asleep duration'),

    ('steps',                  'steps'),
    ('steps',                  'step count'),
    ('steps',                  'daily steps'),

    ('active_energy',          'active energy'),
    ('active_energy',          'active energy burned'),
    ('active_energy',          'active calories'),
    ('active_energy',          'calories burned'),

    ('recovery_score',         'recovery'),
    ('recovery_score',         'recovery score'),
    ('recovery_score',         'readiness'),
    ('recovery_score',         'readiness score')
) as v (metric_key, alias_normalized)
join public.metric_definitions d on d.key = v.metric_key and d.user_id is null
on conflict (alias_normalized, coalesce(source_key, '')) where user_id is null
do update set
  metric_definition_id = excluded.metric_definition_id,
  updated_at           = now();

commit;
