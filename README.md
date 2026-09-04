# Health Platform

Personal longitudinal health and performance intelligence platform.
The product is the historical data foundation, not the dashboard.

`CLAUDE.md` is the operating specification. Read it before changing anything.

**Current state: Phases 1–4 complete.** Foundation and auth, the canonical
schema, the Universal Import Engine with the Hevy slice, and the product
surface that reads it. Nothing in this repository fabricates measurements: an
account with no imports shows an empty state, never a zero-filled chart.

---

## Stack

Next.js (App Router) · TypeScript · Tailwind · Supabase (Postgres, Auth, RLS)

## Running it locally

You need **Node 22+** and **Docker** (Docker Desktop on macOS or Windows). Docker
is what runs the local Supabase stack: Postgres, Auth, PostgREST, Storage and a
mail catcher.

```bash
git clone https://github.com/trevynfabian-bit/Fitness-Tracker.git
cd Fitness-Tracker
npm install

npx supabase start        # first run pulls a few GB of images
npx supabase status       # prints the URLs and keys you need next
```

Create `.env.local` and fill it from what `supabase status` printed:

```bash
NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321      # API_URL
NEXT_PUBLIC_SUPABASE_ANON_KEY=...                    # ANON_KEY
NEXT_PUBLIC_SITE_URL=http://127.0.0.1:3000

# Server-only. The import worker needs these; nothing else reads them.
SUPABASE_SERVICE_ROLE_KEY=...                        # SERVICE_ROLE_KEY
IMPORT_WORKER_SECRET=any-long-random-string
```

Then:

```bash
npm run dev
```

Open <http://127.0.0.1:3000>. Use `127.0.0.1`, not `localhost`: the session
cookie is scoped to the host you sign in on, and mixing the two loses it.

### Signing up

Email confirmation is on, and local mail is captured rather than sent. After
signing up, open **<http://127.0.0.1:54324>**, click the confirmation link in
the message, and you land on the dashboard.

### Importing a file

1. Go to **/import** and choose a CSV. A Hevy-shaped sample lives at
   `tests/fixtures/hevy/hevy-export.csv`.
2. The file is parsed in your browser and uploaded straight to private storage.
   The preview shows what would happen and which exercises need a registry
   entry. Nothing is written yet.
3. Click **Confirm and import**.
4. **Run the worker.** There is no cron in local development, so nothing
   happens until you poke it:

   ```bash
   curl -X POST http://127.0.0.1:3000/api/worker \
     -H "x-worker-secret: $IMPORT_WORKER_SECRET"
   ```

   Run it again until it reports `"batches": 0`. Then reload the import page.

A `full_snapshot` import that proposes retirements stops at a confirmation
screen instead of retiring anything. That is deliberate, and the database
enforces it independently of the UI.

### The product surface

Once an import has completed, six signed-in routes read it:

| Route | What it is |
|---|---|
| `/dashboard` | Lifetime totals, weekly training frequency, weekly volume trend, recent activity |
| `/history` | Every session, newest first, paginated server-side, with a title search and a date range |
| `/history/[id]` | One session: its exercises, and only the set columns those exercises actually recorded |
| `/exercises` | Every exercise performed, with what its data supports being compared on |
| `/exercises/[id]` | One exercise: its progression on the axis its own sets carry, and every session |
| `/settings` | Account and the metric registry |

All six read through `public.training_*` functions (see
`supabase/migrations/20260905090000_phase4_training_read_model.sql`). They are
`SECURITY INVOKER` over the `v_*` views, take no user id, and are the only way
the product reads training data. Phase 4 writes nothing: canonical rows come
from the import pipeline and from nowhere else.

Two definitions worth knowing, because the UI states them rather than assuming
them:

- **Volume** is `weight × reps`, summed over sets that record *both*. A plank
  or a loaded carry contributes nothing rather than a zero, and a week with no
  loaded set reports `NULL`, drawn as a gap.
- **Frequency** counts workouts per ISO week over `local_date`. A week without
  training is a real zero, and is drawn as one.

### Other useful commands

```bash
npx supabase status     # URLs and keys
npx supabase db reset   # re-apply every migration and seed from scratch
npx supabase stop       # free the containers
npm run test:all        # the whole suite (needs the stack running)
```

Studio, for looking at the tables directly, is at <http://127.0.0.1:54323>.

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

### Local Supabase stack

```bash
npx supabase start        # Postgres + GoTrue + PostgREST + Kong + Mailpit
npx supabase db reset     # re-apply migrations and reference-data seeds
npx supabase status       # URLs and keys
```

Local auth email is captured by Mailpit at <http://127.0.0.1:54324> rather than
being delivered. Email confirmation is enabled (`[auth.email]
enable_confirmations = true`) so the confirmation flow is a tested path rather
than an untested branch, and `supabase/templates/confirmation.html` points the
link at the application's own `/auth/confirm` route.

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
npm run test:phase2      # import layer + canonical schema constraints (needs Postgres)
npm run test:step0       # provenance, reconciliation and alias safety (needs Postgres)
npm run test:phase4      # the training read model, and hard gate D at 2,000 workouts
npm run test:routes      # protected routes reject unauthenticated access (builds + serves)
npm run test:e2e         # real signup/confirm/login/logout, the Hevy import, the product surface
npm run test:all         # all of the above
```

`npm run test:e2e` drives the built application in a real browser against a
running Supabase stack: sign up, confirm by email, log in, log out, and
cross-user RLS both through `@supabase/supabase-js` and through the dashboard
itself. It reads only the anon key — the service role key is never exported to
it. To run it against a hosted project instead, export
`NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` and `MAILPIT_URL`
(or disable email confirmation on that project) before invoking it.

`npm run test:rls` rebuilds a throwaway database from the committed migrations
and seed, then runs every assertion as the `authenticated` Postgres role with a
JWT subject claim. The service role is never used to validate a policy.

`npm run test:phase4` does the same for the read model: it builds a canonical
training history with an empty week, a retired workout, and one exercise of
every progression kind, asserts every function against it, and then rebuilds at
2,000 workouts and 30,000 sets to time the queries a page actually issues.
