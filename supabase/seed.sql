-- Entry point used by `supabase db reset` for local development.
-- Reference data only. Keep every statement idempotent.
-- No health measurements are ever seeded (CLAUDE.md §4).
\ir seeds/0001_system_registry.sql
