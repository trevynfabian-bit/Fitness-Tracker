# Phase 1 — Foundation: Implementation Report

Date: 2026-09-03
Branch: `claude/phase-1-foundation-zwjvhy`

---

## 0. Repository state before this change

The repository was empty: no commits on any branch, no files other than
`.git/`. This is a greenfield build, not a modification of existing code.

**The authoritative documents named in `CLAUDE.md` §2 are not present in the
repository and were not supplied:**

- `docs/architecture/health-platform-architecture-v2.md`
- `docs/architecture/health-platform-architecture-v3.md`
- `docs/prd.md`

Phase 1 was therefore implemented against `CLAUDE.md` §3 (invariants) and §4
(Phase 1 scope) alone. The nine table names, the RLS requirement and the seed
list are stated explicitly in `CLAUDE.md`; **column-level detail is inferred**
and is listed in §6 below so it can be checked against v2/v3 when those
documents are available. No architectural decisions were invented beyond what
was needed to create the nine named tables.

---

## 1. Ownership model for registry tables

Invariant I-8 requires `user_id` and an RLS policy on every table, with no
join in any policy. Invariant I-6 requires a single canonical registry that
every metric, exercise, activity and event resolves to. These are reconciled
as follows:

| `user_id` | Meaning | Read | Write |
|---|---|---|---|
| `NULL` | System registry, shared | every authenticated user | privileged connection only |
| `= auth.uid()` | User-defined | that user only | that user only |

Policy predicates are `user_id IS NULL OR user_id = (SELECT auth.uid())` for
read and `user_id = (SELECT auth.uid())` for write. Both read only the row's
own `user_id` column — no join. Uniqueness is enforced by paired partial
indexes so that a system key and a user key of the same name can coexist and
two users can each define the same key privately.

A `SECURITY DEFINER` trigger additionally rejects a user-owned child row that
references another user's private parent row. RLS hides such a parent from
`SELECT`, but a foreign key would still accept a known primary key.

---

## 2. Deliberate deviation flagged for review

Invariant I-7 states that values are `NUMERIC(18,6)`. Every column holding a
measurement is `NUMERIC(18,6)`.

`unit_conversions.factor` and `unit_conversions."offset"` are
`NUMERIC(30,15)`. A conversion factor is a coefficient, not a value: storing
1 lb → kg as `NUMERIC(18,6)` truncates the exact factor `0.45359237` to
`0.453592`, injecting a systematic ~1.6 × 10⁻⁷ relative error into every
imported imperial mass before it is ever rounded into a stored value. This is
raised here explicitly rather than decided silently. If v2/v3 states that
conversion factors are also `NUMERIC(18,6)`, a follow-up migration should
narrow them.

---

## 3. Test environment constraint

No Docker daemon is available in this environment, so `supabase start` cannot
run, and no Supabase project URL or keys were supplied. PostgreSQL 16.13 is
available locally.

Consequences:

- **RLS is verified against real PostgreSQL**, using the committed migrations
  and seed plus a small shim that recreates the part of Supabase's `auth`
  schema the migrations depend on (`auth.users`, `auth.uid()`, and the `anon`
  / `authenticated` / `service_role` roles). RLS is a PostgreSQL feature and
  `authenticated` + a JWT subject claim is exactly the context a Supabase
  client request runs in, so the policies themselves are genuinely exercised.
  It is *not* a live Supabase project and does not exercise PostgREST.
- **Sign up / login / logout against a real Supabase Auth server is not
  verified.** The action logic is unit tested against a stubbed client; the
  network round trip to GoTrue is not. See §7.

---

## 4. Files created

**Project configuration**
`package.json`, `package-lock.json`, `tsconfig.json`, `next.config.mjs`,
`postcss.config.mjs`, `tailwind.config.ts`, `vitest.config.ts`,
`.eslintrc.json`, `.gitignore`, `.env.example`, `README.md`

**Application**
`src/lib/env.ts`, `src/lib/utils.ts`, `src/lib/routes.ts`,
`src/lib/site-url.ts`, `src/lib/supabase/client.ts`,
`src/lib/supabase/server.ts`, `src/lib/supabase/middleware.ts`,
`src/middleware.ts`, `src/app/layout.tsx`, `src/app/globals.css`,
`src/app/page.tsx`, `src/app/login/page.tsx`, `src/app/signup/page.tsx`,
`src/app/dashboard/page.tsx`, `src/app/auth/actions.ts`,
`src/app/auth/confirm/route.ts`, `src/components/auth/credentials-form.tsx`,
`src/components/auth/sign-out-button.tsx`, `src/components/ui/button.tsx`,
`src/components/ui/input.tsx`, `src/components/ui/label.tsx`,
`src/components/ui/alert.tsx`

**Database**
`supabase/config.toml`,
`supabase/migrations/20260903120000_registry_schema.sql`,
`supabase/migrations/20260903120100_registry_rls.sql`,
`supabase/seeds/0001_system_registry.sql`, `supabase/seed.sql`

**Tests and scripts**
`tests/env.test.ts`, `tests/routes.test.ts`, `tests/auth-actions.test.ts`,
`tests/rls/10_isolation.sql`, `tests/rls/harness/00_supabase_auth_shim.sql`,
`tests/rls/run-rls-tests.sh`, `tests/http/run-route-protection-tests.sh`,
`scripts/db-local-apply.sh`

**Docs**
`docs/phase-1-implementation-report.md`

## 5. Files modified

None. The repository was empty.

## 6. Migrations added

| File | Contents |
|---|---|
| `20260903120000_registry_schema.sql` | 9 registry tables, partial unique indexes, check constraints, `updated_at` triggers, cross-user parent-ownership trigger, unit dimension trigger |
| `20260903120100_registry_rls.sql` | `ENABLE ROW LEVEL SECURITY` and 4 policies (select/insert/update/delete) per table, explicit grants to `authenticated`, no grants to `anon` |

Seed data is **not** in a migration: `supabase/seeds/0001_system_registry.sql`,
idempotent upserts, re-runnable.

Inferred (not specified in `CLAUDE.md`) columns, for review against v2/v3:
`sources.precedence_rank`, `units.dimension`, `unit_conversions.factor` /
`"offset"`, `metric_definitions.canonical_unit_id`,
`metric_definitions.default_aggregation`, `*_aliases.source_key`,
`is_active` / `description` on the definition tables.

## 7. Known limitations

1. Sign up, login and logout have not been executed against a live Supabase
   Auth server. No credentials and no Docker.
2. The dashboard's registry read has not been executed against PostgREST for
   the same reason. It uses only `select` + `order`, deliberately avoiding
   embedded-resource syntax that could not be verified.
3. `sources`, `exercise_definitions`, `exercise_aliases`, `activity_types` and
   `event_definitions` are created and secured but seeded with nothing.
   `CLAUDE.md` Phase 1 specifies seed content for metrics only.
4. Supabase's default privileges grant `ALL` on new `public` tables to `anon`
   and `authenticated`. The RLS migration revokes those explicitly. Every
   future table migration must include its own grants and policies; the
   defaults are not safe to rely on.
5. `metric_aliases` / `exercise_aliases` store raw alias text. Fuzzy matching
   during mapping (I-6) is Phase 3 and is not implemented.
