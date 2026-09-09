# Health Platform

Personal longitudinal health and performance intelligence platform.
The product is the historical data foundation, not the dashboard.

`CLAUDE.md` is the operating specification. Read it before changing anything.

**Current state: Phases 1–6 complete.** Foundation and auth, the canonical
schema, the Universal Import Engine with the Hevy slice, the product surface
that reads it, the analytics layer underneath it, and manual entry of body
measurements. Nothing in this repository fabricates measurements: an account
with no imports shows an empty state, never a zero-filled chart, and a typed
measurement goes through the same pipeline an exported file does.

`docs/roadmap.md` is the authoritative statement of what is built and what
comes next.

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

   Run it again until it reports `"batches": 0` and `"rollup": {"processed": 0}`.
   Then reload the import page. The same call drains the analytics queue, so
   one worker run both imports the file and brings the dashboard up to date.

A `full_snapshot` import that proposes retirements stops at a confirmation
screen instead of retiring anything. That is deliberate, and the database
enforces it independently of the UI.

If the guards **block** the plan — usually because the file looks like a
partial export rather than a complete one — automatic retirement is refused and
the one-click action is "Import without retiring". You can still proceed, but
only deliberately: the override asks for an acknowledgement, a written reason,
and the number of records being retired typed out, and it records all three
against your account alongside the guard result it overrode. Every one of those
requirements is enforced by the database, not just by the screen.

Guard G9 — a retirement that would touch a manually entered record — has no
override and never will.

The audit trail is `v_retirement_audit`: one row per reconciliation plan, with
the original verdict, the decision taken, and who overrode what, when and why.

### The product surface

Once an import has completed, seven signed-in routes read it:

| Route | What it is |
|---|---|
| `/dashboard` | Lifetime totals, weekly training frequency, weekly volume trend, recent activity |
| `/history` | Every session, newest first, paginated server-side, with a title search and a date range |
| `/history/[id]` | One session: its exercises, and only the set columns those exercises actually recorded |
| `/exercises` | Every exercise performed, with what its data supports being compared on |
| `/exercises/[id]` | One exercise: its progression on the axis its own sets carry, and every session |
| `/body` | Measurements recorded by hand, and corrections to them |
| `/settings` | Account and the metric registry |

All six read through `public.training_*` functions. They are `SECURITY
INVOKER`, take no user id, and are the only way the product reads training
data. Neither Phase 4 nor Phase 5 writes a canonical row: those come from the
import pipeline and from nowhere else.

Four of those functions read the **derived daily series** built in Phase 5
(`training_overview`, `training_weekly_series`, `training_exercise_summaries`,
`training_exercise_detail`); three still read canonical data, because they ask
questions at a grain the analytics layer does not hold and are already bounded
by their own page limit (`training_workout_summaries`,
`training_workout_detail`, `training_exercise_progression`).

Two definitions worth knowing, because the UI states them rather than assuming
them:

- **Volume** is `weight × reps`, summed over sets that record *both*. A plank
  or a loaded carry contributes nothing rather than a zero, and a week with no
  loaded set reports `NULL`, drawn as a gap.
- **Frequency** counts workouts per ISO week over `local_date`. A week without
  training is a real zero, and is drawn as one.

### Recording a measurement by hand

`/body` records weight, body fat, waist and the other measurable metrics. A
typed measurement is **not** written straight into the canonical table: it
becomes a synthetic import and a raw record, and the same normalizer that turns
a Hevy CSV row into a set turns that raw record into a metric. There is no
second write path.

A correction is not an edit. It is another raw record, at a higher precedence
rank, naming the observation it supersedes. The original stays exactly where it
was. Because the upsert prefers the higher-precedence origin, replaying the raw
layer in any order lands on the corrected value — which is what makes this
true:

```bash
curl -X POST http://127.0.0.1:3000/api/worker/rebuild \
  -H "x-worker-secret: $IMPORT_WORKER_SECRET" \
  -H 'Content-Type: application/json' \
  -d '{"userId":"<uuid>","template":"metrics"}'
```

That replays every raw record through normalization. The canonical rows come
back identical, corrections included. It is the architecture's central claim,
made runnable.

Only metrics the registry marks `manual_entry` can be typed. Derived
aggregates — training volume and the rest — cannot be, because they already
have a source of truth.

### The analytics layer

Canonical training data → invalidation → queue → recomputation → derived
metrics → read model → UI.

| Object | What it is |
|---|---|
| `rollup_queue` | Dirty scopes. One scope is one `(user, day)`. At most one pending row per scope, so enqueuing twice is free |
| `metric_daily_source` | Tier 1: what one source said about one metric on one day, plus the canonical workout ids it was computed from |
| `metric_daily` | Tier 2: the resolved daily series the dashboard reads |
| `exercise_daily_source` / `exercise_daily` | The same two tiers at `(user, exercise, day)` |
| `source_precedence` | Which source wins when several report the same metric on the same day |

A day is marked dirty when the normalize stage finishes writing canonical rows
and when a retirement is applied. Nothing uses a database trigger (ADR-19), and
nothing adjusts a stored total by an arithmetic delta: a dirty scope is deleted
and rebuilt from canonical truth, which is why recomputation is idempotent and
why a crashed worker needs no repair beyond running the scope again.

Derived metrics are disposable. To rebuild everything for one user:

```sql
select public.rollup_rebuild_user('<user-uuid>');
select public.rollup_process_pending();
```

**After deploying the Phase 5 migration**, run the worker once (or the two
statements above): the migration marks every existing training day dirty but
computes nothing itself, so until the queue is drained the dashboard reads
zero.

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
npm run test:phase5      # the analytics layer: correctness, retirement, recovery, benchmark
npm run test:phase5_1    # the G4 override: blocking, override, audit, isolation, idempotency
npm run test:phase6      # manual entry, correction by supersession, and the rebuild
npm run test:phase7      # the metrics rollup domain and the chart read model
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

`npm run test:phase5` computes every figure twice — once by aggregating
canonical data, once from the derived series — and compares them, then retires
data, corrects data, crashes a worker mid-scope, and rebuilds the whole
analytics layer from scratch, checking the values after each. Its benchmark
asks the same three product questions both ways over one 37,000-set dataset.
