# Roadmap and phase status

**This file is the authoritative statement of what has been built and what
comes next.** Where it disagrees with the phase tables in
`docs/architecture/health-platform-architecture-v2.md` §12 or
`docs/architecture/health-platform-architecture-v3.md` §5, this file wins on
*sequencing only*. Those documents remain authoritative on architecture, and
nothing here changes a decision recorded in the v3 ADRs.

---

## 1. Why this file exists

The implementation order in v2 §12, restated in v3 §5, was written before any
code existed. Two things moved since:

1. **The product surface was pulled forward.** v3 §5 put charts in Phase 5 and
   the training-specific analytics (tonnage, training volume) in Phase 7. In
   practice, once the Hevy slice landed in Phase 3 there was a complete
   canonical training history and nothing to read it with, so the training
   product surface was built next and the body-tracking work that v2 §12 had
   in that slot moved back.
2. **The analytics foundation now serves training first, not body scalars.**
   The Phase 5 exit criterion in v3 §5 — "one-year chart renders from
   `metric_daily` in a single indexed query" — is unchanged. What changed is
   which metrics it renders first.

`CLAUDE.md` §4 has been updated to match this table. The architecture documents
have **not** been rewritten: they record decisions, and the decisions still
stand.

---

## 2. Status

| Phase | Name | Status | What it delivered |
|---|---|---|---|
| **1** | Foundation, authentication, security | **Complete** | Next.js + TypeScript + Tailwind, env validation, Supabase auth (sign up, confirm, log in, log out, protected routes), the nine registry tables, RLS on every user-owned table, the system registry seed |
| **2** | Canonical data architecture | **Complete** | `import_profiles`, `data_imports`, `import_jobs`, `raw_records`, `import_coverage`; canonical `metrics`, `strength_workouts`, `strength_exercises`, `strength_sets`; append-only trigger, natural keys, revision strategy, canonical views, privilege lockdown |
| **3** | Import, normalization, provenance, reconciliation | **Complete** | Universal Import Engine: profiling, detection, declarative mapping, closed transform library, preview, confirmation, checkpointed worker; Hevy as a profile JSON plus fixture; reconciliation plans, guards G1–G10, database-enforced retirement |
| **4** | Training product surface | **Complete** | The Phase 4 read model (`training_*` functions) and the six signed-in screens: dashboard, workout history, workout detail, exercise explorer, exercise progression, settings |
| **5** | Analytics foundation and incremental derived metrics | **Complete** | `source_precedence`, `metric_daily_source` → `metric_daily`, `exercise_daily_source` → `exercise_daily`, `rollup_queue`, invalidation and recomputation, rollup worker, read model migrated onto derived metrics |
| **5.1** | Reconciliation G4 override resolution | **Complete** | G4 becomes a safety gate with an audited human override: a blocked plan is confirmable only when every guard that blocked it carries an acknowledged, attributable, reasoned override. See `docs/architecture-implementation-notes.md` N-8 |
| **6** | Manual body tracking | **Complete** | Manual entry and correction through synthetic imports: the `metrics` template normalizer, precedence-aware upsert, the rebuild, and the `/body` surface. The work v2 §12 placed at Phase 4 |
| **7** | Body and recovery charts | Not started | Weight, body fat, waist, HRV, RHR, sleep rendered from `metric_daily`; ranges, gap policy, minimum-observation gates. The infrastructure Phase 5 builds; the metrics Phase 6 produces. **Includes wiring a `metrics` rollup domain**: Phase 6 lands scalars in `metrics`, and nothing aggregates them into `metric_daily` yet |

Phases 8 and beyond follow v3 §5 unchanged: further import profiles,
formula-versioned derived metrics, timeline, deterministic analytics, insights,
cross-source entity resolution, AI interpretation.

---

## 3. Scope changes, and what settled each one

**SC-1. Phase 4 is the training product surface, not manual body tracking.**
*Authority:* explicit user direction at the start of Phase 4.
*What moved:* manual body tracking, previously `CLAUDE.md` §4 Phase 4, is now
Phase 6. Its exit criterion is unchanged: a corrected measurement survives a
full normalize rebuild with the corrected value intact.
*What did not move:* nothing in the canonical model, the import pipeline or the
invariants. Phase 4 added no write path.

**SC-2. Phase 5 builds the analytics foundation for training metrics first.**
*Authority:* explicit user direction at the start of Phase 5.
*What this is:* v3 §5's Phase 5 — `rollup_queue`, both rollup tiers,
`source_precedence`, charts reading `metric_daily` — applied to the metrics the
product actually has, which are training metrics rather than body scalars.
*What this is not:* it is **not** v3 §5's Phase 7. No formula-versioned derived
rows are written into `metrics`, no `formula_version` regeneration exists, and
e1RM, pace, rolling baselines and sleep consistency remain out of scope. Daily
training aggregates are analytics-layer rows, disposable and regenerable from
canonical truth, exactly as v2 §1.4 requires of derived data.
*Consequence:* when Phase 6 lands body scalars in `metrics`, they roll up
through the same `metric_daily_source` → `metric_daily` path with no new
infrastructure, which is what v2 §9 intended.

**SC-4. G4 is a safety gate, not a prohibition.**
*Authority:* v3 §4.3, which always made G4 and G6 overridable; explicit user
direction to resolve the contradiction.
*What this fixes:* Phase 3 shipped an override the persistence layer refused,
so the product offered an action it could not complete. Phase 5.1 makes the
capability real and enforces its requirements in the database.
*What did not change:* G9 remains absolute, the verdict is never rewritten, and
an override buys permission to proceed past a blocked verdict and nothing else.

**SC-3. `CLAUDE.md` §6 narrowed on two lines.**
"Derived metrics" as an out-of-scope item meant v3 Phase 7's formula-versioned
metric rows, and that is still out of scope. Daily derived *aggregates* in the
analytics layer are the substance of Phase 5 and are now explicitly in scope.
"Weekly/monthly rollup tables" remain out of scope: weekly figures are
aggregated from `metric_daily` on read, per v2 §9.5 and v3 F-09.

---

## 4. What has not changed

- Every invariant in `CLAUDE.md` §3.
- Every ADR in v3 §6, including ADR-15 (two-tier rollups), ADR-19 (dirty-day
  queue, never database triggers) and ADR-21 (`NUMERIC(18,6)`).
- The single write path: canonical rows originate from `raw_records` and from
  nothing else. Phases 4 and 5 are read and analytics layers; neither writes a
  canonical row.
- The rule that derived data is disposable. `metric_daily`, `exercise_daily`
  and their tier-1 tables can be truncated and rebuilt from canonical truth.
