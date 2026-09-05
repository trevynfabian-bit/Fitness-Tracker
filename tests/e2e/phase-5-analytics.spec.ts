import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { expect, test, type Page } from "@playwright/test";

import { deleteAllMessages, waitForConfirmationLink } from "./mailpit";

/**
 * Phase 5 hard gates at the application surface.
 *
 *   Gate A  a real import drives the rollup, and the dashboard's numbers come
 *           from the derived series and equal canonical aggregation.
 *   Gate B  a retirement taken through the product's own confirmation flow
 *           removes that data from the derived metrics after processing.
 *   Gate C  running the worker repeatedly changes nothing.
 *   Gate D  a second user's analytics contain none of the first user's, and an
 *           unauthenticated caller cannot execute a rollup function or read a
 *           derived row.
 *
 * The SQL suite proves the same properties against the tables directly. This
 * one proves the wiring: that the import lifecycle actually enqueues, that the
 * worker endpoint actually drains, and that the screens actually read the
 * result.
 */

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const SERVICE_KEY = process.env.E2E_SERVICE_ROLE_KEY!;
const WORKER_SECRET = process.env.IMPORT_WORKER_SECRET!;
const BASE = process.env.E2E_BASE_URL ?? "http://127.0.0.1:3000";

const RUN = Date.now();
const OWNER = { email: `p5-owner-${RUN}@example.test`, password: "phase-5-owner-password-1" };
const OTHER = { email: `p5-other-${RUN}@example.test`, password: "phase-5-other-password-1" };

const FULL_EXPORT = "tests/fixtures/hevy/hevy-export.csv";
/**
 * Four of the five workouts. A full_snapshot import of it covers 80% of what
 * exists and proposes retiring one workout, which is inside every guard: above
 * G4's 70% floor and below G6's 25% ratio. That is the point — this gate is
 * about what a CONFIRMED retirement does to derived metrics, and the guards
 * themselves are Phase 3's gate, proven in tests/e2e/phase-3-hevy.spec.ts.
 */
const SNAPSHOT_MINUS_ONE = "tests/fixtures/hevy/hevy-export-minus-one.csv";

let admin: SupabaseClient;
let ownerId = "";

type WorkerResponse = {
  batches: number;
  failed: unknown[];
  rollup: { processed: number; failed: number; reclaimed: number; errors: unknown[] };
};

async function runWorker(): Promise<WorkerResponse[]> {
  const responses: WorkerResponse[] = [];
  for (let tick = 0; tick < 30; tick += 1) {
    const response = await fetch(`${BASE}/api/worker`, {
      method: "POST",
      headers: { "x-worker-secret": WORKER_SECRET },
    });
    expect(response.status, "worker invocation").toBe(200);
    const body = (await response.json()) as WorkerResponse;
    expect(body.failed, `worker batch failed: ${JSON.stringify(body.failed)}`).toHaveLength(0);
    expect(body.rollup.failed, `rollup failed: ${JSON.stringify(body.rollup.errors)}`).toBe(0);
    responses.push(body);
    if (body.batches === 0 && body.rollup.processed === 0) break;
  }
  return responses;
}

async function signUpAndConfirm(page: Page, user: { email: string; password: string }) {
  await deleteAllMessages();
  await page.goto("/signup");
  await page.getByLabel("Email").fill(user.email);
  await page.getByLabel("Password", { exact: true }).fill(user.password);
  await page.getByLabel("Confirm password").fill(user.password);
  await page.getByRole("button", { name: "Create account" }).click();
  await expect(page.getByRole("status")).toContainText(/confirmation link/i);
  await page.goto(await waitForConfirmationLink(user.email));
  await page.waitForURL("**/dashboard");
}

async function logIn(page: Page, user: { email: string; password: string }) {
  await page.goto("/login");
  await page.getByLabel("Email").fill(user.email);
  await page.getByLabel("Password", { exact: true }).fill(user.password);
  await page.getByRole("button", { name: "Sign in" }).click();
  await page.waitForURL("**/dashboard");
}

async function importFile(page: Page, fixture: string) {
  await page.goto("/import");
  await page.setInputFiles("#file", fixture);
  await expect(page.getByText("Preview", { exact: true })).toBeVisible({ timeout: 30_000 });
  await page.getByRole("button", { name: "Confirm and import" }).click();
  await page.waitForURL("**/import/**");
  return page.url().split("/").pop()!;
}

/** Canonical truth, read with the elevated key for verification only. */
async function canonicalTotals(userId: string) {
  const { data: workouts } = await admin
    .from("v_strength_workouts")
    .select("id")
    .eq("user_id", userId);
  const { data: sets } = await admin
    .from("v_strength_sets")
    .select("weight_kg, reps, volume_kg")
    .eq("user_id", userId);

  const loaded = (sets ?? []).filter((s) => s.weight_kg !== null && s.reps !== null);
  return {
    workouts: (workouts ?? []).length,
    sets: (sets ?? []).length,
    volumeSets: loaded.length,
    volumeKg: loaded.reduce((total, s) => total + Number(s.volume_kg), 0),
  };
}

/** The derived series, summed the way the read model sums it. */
async function derivedTotals(userId: string) {
  const { data } = await admin
    .from("metric_daily")
    .select("metric_key, value")
    .eq("user_id", userId);
  const sum = (key: string) =>
    (data ?? [])
      .filter((r) => r.metric_key === key)
      .reduce((total, r) => total + Number(r.value), 0);
  return {
    workouts: sum("training_workouts"),
    sets: sum("training_sets"),
    volumeSets: sum("training_volume_sets"),
    volumeKg: sum("training_volume_kg"),
  };
}

test.describe.configure({ mode: "serial" });

test.describe("Phase 5 — the analytics foundation", () => {
  test.beforeAll(async () => {
    expect(SUPABASE_URL && ANON_KEY && SERVICE_KEY && WORKER_SECRET).toBeTruthy();
    admin = createClient(SUPABASE_URL, SERVICE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
  });

  // =========================================================================
  // GATE A — an import drives the rollup, and the derived values are right
  // =========================================================================

  test("GATE A: an import enqueues analytics scopes and the worker drains them", async ({
    page,
  }) => {
    await signUpAndConfirm(page, OWNER);
    const { data } = await admin.auth.admin.listUsers();
    ownerId = data.users.find((u) => u.email === OWNER.email)!.id;
    expect(ownerId).toBeTruthy();

    // A brand new account has no derived rows and no queued work.
    expect((await derivedTotals(ownerId)).workouts).toBe(0);

    await importFile(page, FULL_EXPORT);

    // Normalization has run nothing yet, so nothing is enqueued yet either:
    // a confirmed-but-unprocessed import must not produce analytics.
    const { count: beforeWorker } = await admin
      .from("metric_daily")
      .select("metric_key", { count: "exact", head: true })
      .eq("user_id", ownerId);
    expect(beforeWorker ?? 0).toBe(0);

    const responses = await runWorker();
    const processed = responses.reduce((total, r) => total + r.rollup.processed, 0);
    expect(processed, "the worker must have processed analytics scopes").toBeGreaterThan(0);

    // Every queued scope is done. Nothing pending, nothing parked.
    const { data: queue } = await admin
      .from("rollup_queue")
      .select("state, last_error")
      .eq("user_id", ownerId);
    expect(queue!.length).toBeGreaterThan(0);
    expect(queue!.every((q) => q.state === "done")).toBe(true);
  });

  test("GATE A: derived metric values equal canonical aggregation", async () => {
    const canonical = await canonicalTotals(ownerId);
    const derived = await derivedTotals(ownerId);

    expect(canonical.workouts).toBe(5);
    expect(derived.workouts).toBe(canonical.workouts);
    expect(derived.sets).toBe(canonical.sets);
    expect(derived.volumeSets).toBe(canonical.volumeSets);
    expect(derived.volumeKg).toBeCloseTo(canonical.volumeKg, 6);

    // Provenance: every tier-1 row names live canonical workouts.
    const { data: tier1 } = await admin
      .from("metric_daily_source")
      .select("metric_key, local_date, contributing_workout_ids")
      .eq("user_id", ownerId);
    expect(tier1!.length).toBeGreaterThan(0);
    const { data: liveWorkouts } = await admin
      .from("v_strength_workouts")
      .select("id")
      .eq("user_id", ownerId);
    const live = new Set((liveWorkouts ?? []).map((w) => w.id as string));
    for (const row of tier1!) {
      const ids = row.contributing_workout_ids as string[];
      expect(ids.length, `${row.metric_key} on ${row.local_date} names no workout`).toBeGreaterThan(0);
      for (const id of ids) expect(live.has(id)).toBe(true);
    }
  });

  test("GATE A: the dashboard renders the derived numbers", async ({ page }) => {
    await logIn(page, OWNER);
    const derived = await derivedTotals(ownerId);

    const workoutTile = page.locator("div", { hasText: /^Workouts/ }).last();
    await expect(workoutTile).toContainText(String(derived.workouts));
    await expect(page.getByRole("heading", { name: "Training frequency" })).toBeVisible();
    await expect(page.getByRole("heading", { name: "Volume trend" })).toBeVisible();

    // The exercise explorer reads the exercise grain.
    await page.goto("/exercises");
    const { data: exerciseDaily } = await admin
      .from("exercise_daily")
      .select("exercise_definition_id")
      .eq("user_id", ownerId);
    const distinct = new Set((exerciseDaily ?? []).map((r) => r.exercise_definition_id as string));
    await expect(page.locator("main ul > li")).toHaveCount(distinct.size);
  });

  // =========================================================================
  // GATE C — idempotency
  // =========================================================================

  test("GATE C: running the worker again changes nothing", async () => {
    const before = await derivedTotals(ownerId);
    const { count: rowsBefore } = await admin
      .from("metric_daily")
      .select("metric_key", { count: "exact", head: true })
      .eq("user_id", ownerId);

    await runWorker();
    await runWorker();

    const after = await derivedTotals(ownerId);
    const { count: rowsAfter } = await admin
      .from("metric_daily")
      .select("metric_key", { count: "exact", head: true })
      .eq("user_id", ownerId);

    expect(after).toEqual(before);
    expect(rowsAfter).toBe(rowsBefore);
  });

  test("GATE C: re-importing the same file leaves the metrics identical", async ({ page }) => {
    const before = await derivedTotals(ownerId);

    await logIn(page, OWNER);
    await importFile(page, FULL_EXPORT);
    await runWorker();

    expect(await derivedTotals(ownerId)).toEqual(before);
  });

  // =========================================================================
  // GATE B — retirement, through the product's own confirmation flow
  // =========================================================================

  test("GATE B: a confirmed retirement removes that data from the derived metrics", async ({
    page,
  }) => {
    const before = await derivedTotals(ownerId);
    expect(before.workouts).toBe(5);

    await logIn(page, OWNER);
    const importId = await importFile(page, SNAPSHOT_MINUS_ONE);
    await runWorker();
    await page.reload();

    // The plan passes every guard and still stops for a human, because
    // retirement is never unattended (I-10).
    await expect(page.getByText("Snapshot import — confirmation required")).toBeVisible();
    const { data: plan } = await admin
      .from("reconciliation_plans")
      .select("retire_count, verdict")
      .eq("import_id", importId)
      .single();
    expect(plan!.verdict).not.toBe("blocked");
    expect(Number(plan!.retire_count)).toBe(1);

    await page.getByRole("button", { name: /^Confirm and retire 1/ }).click();
    await expect(page.getByText("Snapshot import — confirmation required")).toHaveCount(0, {
      timeout: 20_000,
    });

    const { count: liveAfterRetire } = await admin
      .from("v_strength_workouts")
      .select("id", { count: "exact", head: true })
      .eq("user_id", ownerId);
    expect(liveAfterRetire).toBe(4);

    // Retirement dirtied the affected scopes. Until the worker runs, the
    // derived series is knowingly stale; after it runs, it agrees again.
    await runWorker();

    const canonical = await canonicalTotals(ownerId);
    const derived = await derivedTotals(ownerId);
    expect(canonical.workouts).toBe(4);
    expect(derived.workouts).toBe(canonical.workouts);
    expect(derived.sets).toBe(canonical.sets);
    expect(derived.volumeKg).toBeCloseTo(canonical.volumeKg, 6);

    // No retired workout may still be named as a contributor.
    const { data: retiredWorkouts } = await admin
      .from("strength_workouts")
      .select("id")
      .eq("user_id", ownerId)
      .not("retired_at", "is", null);
    const retiredIds = new Set((retiredWorkouts ?? []).map((w) => w.id as string));
    expect(retiredIds.size).toBe(1);
    const { data: tier1 } = await admin
      .from("metric_daily_source")
      .select("contributing_workout_ids")
      .eq("user_id", ownerId);
    for (const row of tier1!) {
      for (const id of row.contributing_workout_ids as string[]) {
        expect(retiredIds.has(id), "a retired workout is still named in provenance").toBe(false);
      }
    }
  });

  test("GATE B: the dashboard reflects the retirement", async ({ page }) => {
    await logIn(page, OWNER);
    const workoutTile = page.locator("div", { hasText: /^Workouts/ }).last();
    await expect(workoutTile).toContainText("4");
  });

  // =========================================================================
  // GATE D — isolation
  // =========================================================================

  test("GATE D: a second user's analytics contain none of the first user's", async ({ page }) => {
    await signUpAndConfirm(page, OTHER);

    // Its own dashboard is empty, which is the truth for this account.
    await expect(page.getByRole("heading", { name: "No training data yet" })).toBeVisible();

    const anon = createClient(SUPABASE_URL, ANON_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { error: signInError } = await anon.auth.signInWithPassword({
      email: OTHER.email,
      password: OTHER.password,
    });
    expect(signInError).toBeNull();

    for (const table of ["metric_daily", "metric_daily_source", "exercise_daily", "rollup_queue"]) {
      const { data, error } = await anon.from(table).select("user_id");
      expect(error, `${table} must be readable`).toBeNull();
      expect(data, `${table} leaked rows to a user with no data`).toEqual([]);
    }

    // Naming the other user's id explicitly changes nothing: RLS, not the
    // absence of a filter, is what makes this empty.
    const { data: named } = await anon.from("metric_daily").select("value").eq("user_id", ownerId);
    expect(named).toEqual([]);

    // And the client cannot write derived data, whoever it claims to be.
    const insert = await anon.from("metric_daily").insert({
      user_id: ownerId,
      metric_key: "training_volume_kg",
      local_date: "2026-01-05",
      value: 999999,
      count: 1,
      winning_source: "forged",
      source_count: 1,
    });
    expect(insert.error, "a client must not be able to write a derived metric").toBeTruthy();

    await anon.auth.signOut();
  });

  test("GATE D: no client role can execute a rollup function", async () => {
    const anon = createClient(SUPABASE_URL, ANON_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    // Unauthenticated.
    for (const fn of ["rollup_process_pending", "rollup_reclaim_stale"]) {
      const result = await anon.rpc(fn, {});
      expect(result.error, `anon must not be able to call ${fn}`).toBeTruthy();
    }
    const rebuild = await anon.rpc("rollup_rebuild_user", { p_user_id: ownerId });
    expect(rebuild.error, "anon must not be able to rebuild another user's analytics").toBeTruthy();

    // Authenticated, which is the case that matters: a signed-in user must not
    // be able to recompute or enqueue anything, for themselves or anyone else.
    const { error: signInError } = await anon.auth.signInWithPassword({
      email: OTHER.email,
      password: OTHER.password,
    });
    expect(signInError).toBeNull();

    const recompute = await anon.rpc("rollup_recompute_training_day", {
      p_user_id: ownerId,
      p_local_date: "2026-01-05",
    });
    expect(recompute.error, "an authenticated user must not recompute analytics").toBeTruthy();

    const enqueue = await anon.rpc("rollup_enqueue_training_days", {
      p_user_id: ownerId,
      p_dates: ["2026-01-05"],
      p_reason: "import",
    });
    expect(enqueue.error, "an authenticated user must not enqueue analytics work").toBeTruthy();

    await anon.auth.signOut();
  });

  test("GATE D: the first user's metrics are untouched by any of that", async () => {
    const canonical = await canonicalTotals(ownerId);
    const derived = await derivedTotals(ownerId);
    expect(derived.workouts).toBe(canonical.workouts);
    expect(derived.volumeKg).toBeCloseTo(canonical.volumeKg, 6);
  });
});
