# CLAUDE.md

Operating instructions for agents working in this repository. Read this fully before writing any code.

---

## 1. What this is

A personal longitudinal health and performance intelligence platform. The product is **the historical data foundation**, not the dashboard. Fragmented health data (strength, activity, recovery, body, labs) is imported from CSV/XLSX, normalized into a canonical database, and analyzed over years.

Stack: Next.js + TypeScript + Tailwind + shadcn/ui, Supabase (Postgres, Auth, RLS, Storage), Recharts, Vercel.

---

## 2. Authoritative documents

| Document | Role |
|---|---|
| `docs/architecture/health-platform-architecture-v2.md` | Base specification |
| `docs/architecture/health-platform-architecture-v3.md` | Amendment + Architecture Decision Record |
| `docs/prd.md` | Product requirements |

**v3 supersedes v2 in these sections only:** §2.2 (`raw_records`), §5 (job lifecycle), §7.4 (snapshot reconciliation), §12 (implementation order), §13 (open decisions). Everything else in v2 stands.

The architecture is **frozen**. Do not propose architectural changes, alternative schemas, or "simpler" approaches. If implementation surfaces a genuine correctness or data-integrity problem that the architecture cannot express, stop and raise it explicitly rather than working around it. Convenience, unfamiliarity, and extra effort are not correctness problems.

Every decision in v3 §6 (the ADR) is settled. Read it before questioning anything.

---

## 3. Non-negotiable invariants

Violating any of these silently destroys the product's core guarantee. They are not style preferences.

**I-1. Single write path.** Every canonical row originates from a `raw_record`. No exceptions — not manual entry, not corrections, not seeds, not fixes. Manual entry creates a synthetic import.

**I-2. `raw_records` is append-only.** Enforced by a database trigger. Only `processed_at`, `normalize_version`, `normalize_status`, `normalize_error`, and `normalized_keys` may be updated. The only deletion paths are an explicit user-initiated import rollback and a Tier R re-reduce.

**I-3. Normalization is a pure function.** `normalize(raw_record, mapping_spec, registry_snapshot, version) → rows`. No database reads inside. No clock reads. No randomness. This is what makes rebuild trustworthy and the function unit-testable.

**I-4. Never `UPDATE` a canonical table from application code.** Corrections are new raw records with higher `precedence_rank`. An `UPDATE` to `metrics` to "quickly fix" something is reverted by the next rebuild and nothing will report it.

**I-5. Application code queries views, not canonical tables.** `v_metrics`, `v_activities`, `v_strength_sets`, `v_sleep_sessions` apply `retired_at IS NULL`. Forgetting that filter in a raw query resurrects retired records in a trend line, invisibly.

**I-6. No free-text identifiers.** Every metric, exercise, activity type, and event resolves to a registry row. Fuzzy matching happens only during mapping and only as a proposal a human confirms.

**I-7. Values are `NUMERIC(18,6)`.** Never `float8`, never `real`.

**I-8. Every table carries `user_id` and an RLS policy.** Including child tables. No policy may require a join.

**I-9. Vendor names never appear in engine code.** `source_key` is metadata written to rows and read only by `source_precedence`. Vendor specifics live in profile JSON and in the named transform library. `if (source === 'hevy')` anywhere in the ingestion pipeline is a bug.

**I-10. Retirement is soft, planned, and confirmed.** No code path retires records without a persisted `reconciliation_plan`, guard evaluation, and explicit user confirmation. Guard G9 (manual records are never retirable) has no override.

---

## 4. Phase discipline

Implement one phase at a time. Do not start the next phase until the current one's exit criteria are verified by an actual test run.

After each phase, produce an **Implementation Report**:

- Files created
- Files modified
- Migrations added
- Tests run (the commands)
- Test results (the actual output)
- Known limitations
- Next-phase readiness: yes / no, and why

**Never claim something works without having run it.** "Should work", "this implements X", and "the tests are set up" are not results. If you did not execute it, say so.

### Phase 1 — Foundation
Next.js + TypeScript project structure, env var validation, Supabase integration. Auth: sign up, login, logout, protected routes. Migrations for `sources`, `units`, `unit_conversions`, `metric_definitions`, `metric_aliases`, `exercise_definitions`, `exercise_aliases`, `activity_types`, `event_definitions`. RLS on every user-owned table. Seed system registry for: weight, body_fat_percentage, waist_circumference, resting_heart_rate, heart_rate_variability, sleep_duration, steps, active_energy, recovery_score.

No mock health data. Ever.

**Exit:** a user can sign up, log in, reach a protected route, and query only their own rows. RLS tested explicitly with two accounts, attempting a cross-user read from the client and confirming it returns zero rows.

### Phase 2 — Data foundation
`import_profiles`, `data_imports`, `import_jobs`, `raw_records`, `import_coverage`. Canonical tables for the first slice only: `metrics`, `strength_workouts`, `strength_exercises`, `strength_sets`. Append-only trigger, natural keys, revision strategy, import modes, status lifecycle, constraints and indexes.

No importer UI yet. No other domains yet.

**Exit:** the schema supports a complete Hevy import pipeline with no further schema changes required. Demonstrate by writing the pipeline's inserts as raw SQL against a sample row and showing every constraint holds.

### Phase 3 — First vertical slice: Hevy (hard gate)
End-to-end Universal Import Engine: upload, profiling, template selection, column mapping, preview, confirmation, background job, progress, summary. Hevy ships as a profile JSON plus a fixture, using the declarative transform library.

**Test A:** import a real Hevy export. Verify raw records, normalized workouts/exercises/sets, and that every canonical row traces back to its raw record and file.

**Test B:** import a deliberately truncated copy of the same export in `full_snapshot` mode. Guard G4 must block retirement, the projected impact must be displayed, and append-only fallback must be offered.

**If Test B fails, STOP.** Do not work around it, do not soften the guard, do not proceed to Phase 4. Fix the reconciliation implementation.

### Phase 4 — Manual body tracking
Manual entry for weight, body fat, waist, and other measurements — routed through synthetic import → raw record → normalization → canonical metric. Corrections via superseding raw records with higher `precedence_rank`.

**Exit:** a corrected measurement survives a full normalize rebuild with the corrected value intact. Verified by running the rebuild and comparing before/after.

### Phase 5 — Analytics foundation
`metric_daily`, `metric_daily_source`, `rollup_queue`, incremental rollups. Charts for weight, body fat, waist, HRV, RHR, sleep. Ranges: 7D, 30D, 90D, 1Y, all time. Missing-data handling per `gap_policy`, division-by-zero protection, minimum-observation checks.

No AI. No insights. No Apple Health.

---

## 5. Working conventions

**Before writing code in any phase:** inspect the repository first. Read existing files. Do not overwrite working code blindly. Do not recreate a file that already exists without reading it.

**Database changes are migrations only.** Numbered, forward-only, in `supabase/migrations/`. Never edit an applied migration. Never make a manual change in the Supabase dashboard. Expand-contract for anything breaking.

**Reference data is seeded separately** from schema migrations, via idempotent upserts. Adding a metric definition must never require a schema change.

**Tests use fixtures, not generated data.** Every import profile ships with a committed anonymized real export and a snapshot test asserting exact canonical output. A profile is not complete until its fixture test passes against a real file.

**Prefer boring.** No abstractions invented ahead of their second use. No premature optimization. The architecture already made the hard calls.

---

## 6. Things that are explicitly out of scope right now

Do not build these, do not scaffold them, do not add "future-proofing" hooks for them:

Apple Health, Garmin, Oura, Fitbit, or any vendor beyond Hevy. AI or LLM anything. Insights engine. Timeline. Derived metrics. Cross-source entity resolution. Sleep sessions. Labs. Custom events. Weekly/monthly rollup tables. Table partitioning. Multi-user UI. Mobile. PDF/OCR.

They are in the roadmap. They are not in the next five phases.

---

## 7. When to stop and ask

Stop and raise it rather than deciding yourself if:

- An invariant in §3 cannot be satisfied by the intended implementation.
- A phase exit criterion cannot be met and the fix would require an architectural change.
- The architecture documents contradict each other on a point v3 does not resolve.
- A test fails in a way that suggests the design is wrong rather than the code.

Do not silently relax a guard, widen a scope, or add a special case to make a test pass.
