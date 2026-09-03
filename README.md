# Health Platform

Personal longitudinal health and performance intelligence platform.
The product is the historical data foundation, not the dashboard.

`CLAUDE.md` is the operating specification. Read it before changing anything.

**Current state: Phase 1 (Foundation) complete.** There is no import pipeline,
no canonical measurement tables and no health data. Nothing in this repository
fabricates measurements.

---

## Stack

Next.js (App Router) · TypeScript · Tailwind · Supabase (Postgres, Auth, RLS)

## Getting started

```bash
npm install
cp .env.example .env.local     # fill in your Supabase project URL and anon key
npm run dev
```

Both `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` are
validated at boot by `src/lib/env.ts`. A missing or malformed value aborts the
build and the server with a readable message rather than failing at first
request.

The Supabase **service role key is deliberately not part of the application
environment**. No application code path may bypass RLS.

## Database

Schema changes are migrations only: numbered, forward-only, in
`supabase/migrations/`. Never edit an applied migration. Never change anything
through the Supabase dashboard.

```bash
supabase link --project-ref <ref>
supabase db push                 # apply migrations
psql "$DATABASE_URL" -f supabase/seeds/0001_system_registry.sql
```

Reference data lives in `supabase/seeds/`, separate from schema migrations, as
idempotent upserts. Adding a metric definition must never require a schema
change.

### Local database without Docker

`supabase start` needs a Docker daemon. Where one is unavailable, the same SQL
files can be applied to any local PostgreSQL 16 server:

```bash
scripts/db-local-apply.sh my_local_db
```

That script applies `tests/rls/harness/00_supabase_auth_shim.sql` first, which
recreates the small part of Supabase's `auth` schema the migrations depend on
(`auth.users`, `auth.uid()`, the `anon` / `authenticated` / `service_role`
roles). The shim is a **test harness only** and is never applied to a Supabase
project.

## Registry ownership model

Every registry table carries `user_id` and has an RLS policy (invariant I-8),
and no policy requires a join.

| `user_id` | Meaning | Read | Write |
|---|---|---|---|
| `NULL` | System registry, shared | every authenticated user | privileged connection only |
| `= auth.uid()` | User-defined | that user only | that user only |

A trigger additionally prevents a user-owned child row from referencing another
user's private parent row, which a foreign key alone would allow.

## Tests

```bash
npm run typecheck        # tsc --noEmit
npm run test             # vitest: env validation, route classification, auth actions
npm run test:rls         # RLS isolation with two authenticated users (needs Postgres)
npm run test:routes      # protected routes reject unauthenticated access (builds + serves)
npm run test:all         # all of the above
```

`npm run test:rls` rebuilds a throwaway database from the committed migrations
and seed, then runs every assertion as the `authenticated` Postgres role with a
JWT subject claim. The service role is never used to validate a policy.
