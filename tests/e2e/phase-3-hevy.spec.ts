import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { expect, test, type Page } from "@playwright/test";

import { deleteAllMessages, waitForConfirmationLink } from "./mailpit";

/**
 * Phase 3 hard gates.
 *
 *   Test A: import a real Hevy export and verify raw records, workouts,
 *           exercises and sets, with every canonical row tracing back to its
 *           raw record and to the original file.
 *
 *   Test B: import a deliberately truncated copy in full_snapshot mode. G4 must
 *           block retirement, the projected impact must be displayed, and the
 *           append-only fallback must be offered.
 *
 * Both drive the real application in a real browser against a real Supabase
 * stack. The file is parsed in the page and PUT straight to storage; the API
 * never receives the bytes.
 *
 * The service key is used for verification reads only, never to make the
 * application work. Every user action goes through the user's own session.
 */

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const SERVICE_KEY = process.env.E2E_SERVICE_ROLE_KEY!;
const WORKER_SECRET = process.env.IMPORT_WORKER_SECRET!;
const BASE = process.env.E2E_BASE_URL ?? "http://127.0.0.1:3000";

const RUN = Date.now();
const USER = { email: `hevy-${RUN}@example.test`, password: "hevy-import-password-1" };

const FULL_EXPORT = "tests/fixtures/hevy/hevy-export.csv";
const TRUNCATED_EXPORT = "tests/fixtures/hevy/hevy-export-truncated.csv";

let admin: SupabaseClient;
let userId = "";

/** Runs the worker to quiescence, exactly as a cron tick would. */
async function runWorker(): Promise<unknown[]> {
  const outcomes: unknown[] = [];
  for (let tick = 0; tick < 30; tick += 1) {
    const response = await fetch(`${BASE}/api/worker`, {
      method: "POST",
      headers: { "x-worker-secret": WORKER_SECRET },
    });
    expect(response.status, "worker invocation").toBe(200);
    const body = (await response.json()) as { batches: number; outcomes: unknown[]; failed: unknown[] };
    outcomes.push(...body.outcomes);
    expect(body.failed, `worker batch failed: ${JSON.stringify(body.failed)}`).toHaveLength(0);
    if (body.batches === 0) break;
  }
  return outcomes;
}

async function signUpAndConfirm(page: Page) {
  await deleteAllMessages();
  await page.goto("/signup");
  await page.getByLabel("Email").fill(USER.email);
  await page.getByLabel("Password", { exact: true }).fill(USER.password);
  await page.getByLabel("Confirm password").fill(USER.password);
  await page.getByRole("button", { name: "Create account" }).click();
  await expect(page.getByRole("status")).toContainText(/confirmation link/i);
  await page.goto(await waitForConfirmationLink(USER.email));
  await page.waitForURL("**/dashboard");
}

/** Each Playwright test gets a fresh browser context, so each signs in again. */
async function logIn(page: Page) {
  await page.goto("/login");
  await page.getByLabel("Email").fill(USER.email);
  await page.getByLabel("Password", { exact: true }).fill(USER.password);
  await page.getByRole("button", { name: "Sign in" }).click();
  await page.waitForURL("**/dashboard");
}

async function uploadAndPreview(page: Page, fixture: string) {
  await logIn(page);
  await page.goto("/import");
  await page.setInputFiles("#file", fixture);
  await expect(page.getByText("Preview", { exact: true })).toBeVisible({ timeout: 30_000 });
}

test.describe.configure({ mode: "serial" });

test.describe("Phase 3 — the Hevy vertical slice", () => {
  test.beforeAll(async () => {
    expect(SUPABASE_URL && ANON_KEY && SERVICE_KEY && WORKER_SECRET).toBeTruthy();
    admin = createClient(SUPABASE_URL, SERVICE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
  });

  test("a user signs up and reaches the import screen", async ({ page }) => {
    await signUpAndConfirm(page);
    const { data } = await admin.auth.admin.listUsers();
    userId = data.users.find((u) => u.email === USER.email)!.id;
    expect(userId).toBeTruthy();

    await page.goto("/import");
    await expect(page.getByRole("heading", { name: "Import" })).toBeVisible();
  });

  // =========================================================================
  // TEST A
  // =========================================================================

  test("TEST A: the profile is detected and the preview is honest before anything is written", async ({
    page,
  }) => {
    await uploadAndPreview(page, FULL_EXPORT);

    // 4. Detection: the built-in profile matches at high confidence.
    await expect(page.getByText("Hevy — Workout export")).toBeVisible();
    await expect(page.getByText(/high · 100% similar/)).toBeVisible();

    // 9. Preview: the real mapping, run over the file, reporting what would happen.
    await expect(page.getByText("Rows in file")).toBeVisible();
    const stats = page.locator("dl").first();
    await expect(stats).toContainText("20");

    // I-6: no identity is created silently. Every exercise must be confirmed once.
    await expect(page.getByText(/exercises need a registry entry/)).toBeVisible();

    // Nothing has been written yet.
    const { count } = await admin
      .from("strength_workouts")
      .select("id", { count: "exact", head: true })
      .eq("user_id", userId);
    expect(count ?? 0).toBe(0);
  });

  test("TEST A: confirmation ingests and normalizes the export", async ({ page }) => {
    await uploadAndPreview(page, FULL_EXPORT);
    await page.getByRole("button", { name: "Confirm and import" }).click();
    await page.waitForURL("**/import/**");

    const outcomes = await runWorker();
    expect(outcomes.length).toBeGreaterThan(0);

    await page.reload();
    await expect(page.getByText(/status (completed|completed_with_errors)/)).toBeVisible({
      timeout: 20_000,
    });
  });

  test("TEST A: raw records, workouts, exercises and sets are all correct", async () => {
    const [imports, raws, workouts, sets] = await Promise.all([
      // The preview-only test left a draft behind, so take the confirmed one.
      admin
        .from("data_imports")
        .select("*")
        .eq("user_id", userId)
        .eq("file_name", "hevy-export.csv")
        .in("status", ["completed", "completed_with_errors"])
        .order("created_at", { ascending: false })
        .limit(1)
        .single(),
      admin.from("raw_records").select("id, row_number, payload, normalize_status, normalized_keys").eq("user_id", userId),
      admin.from("strength_workouts").select("*").eq("user_id", userId).order("local_date"),
      admin.from("strength_sets").select("*").eq("user_id", userId),
    ]);

    expect(raws.data).toHaveLength(20);
    expect(raws.data!.every((r) => r.normalize_status === "ok")).toBe(true);
    expect(workouts.data).toHaveLength(5);
    expect(sets.data).toHaveLength(20);

    const { data: exercises } = await admin
      .from("strength_exercises")
      .select("id, workout_id, order_index, exercise_definition_id, exercise_name_raw")
      .eq("user_id", userId);
    // Five workouts with two exercises each: ten (workout, exercise) rows,
    // drawn from eight distinct registry definitions because Bench Press and
    // Lat Pulldown each appear in two different workouts.
    expect(exercises).toHaveLength(10);
    expect(new Set(exercises!.map((e) => e.exercise_definition_id)).size).toBe(8);
    expect(exercises!.every((e) => e.exercise_definition_id !== null)).toBe(true);

    // The interleaved superset resolved to two exercises, not four.
    const pullDay = workouts.data!.find((w) => w.local_date === "2026-01-07")!;
    expect(exercises!.filter((e) => e.workout_id === pullDay.id)).toHaveLength(2);

    // Values landed correctly, and a blank cell stayed null rather than zero.
    // PostgREST renders numeric as a JSON number, so the comparison is
    // numeric here; the stored column precision itself is asserted by the
    // Phase 2 precision matrix test.
    const sixtyKg = sets.data!.filter((s) => Number(s.weight_kg) === 60);
    expect(sixtyKg.length).toBeGreaterThan(0);
    expect(sets.data!.some((s) => Number(s.rpe) === 9.5)).toBe(true);
    const carry = sets.data!.find((s) => s.distance_m !== null);
    expect(Number(carry!.distance_m)).toBe(40);       // 0.04 km converted to metres
    expect(carry!.reps).toBeNull();
    expect(carry!.duration_s).toBe(45);
    expect(sets.data!.filter((s) => s.rpe === null).length).toBeGreaterThan(0);
    // volume_kg is generated by the database, never written by the engine.
    const bench = sets.data!.find((s) => Number(s.weight_kg) === 60 && Number(s.reps) === 8)!;
    expect(Number(bench.volume_kg)).toBe(480);
    // Every set type in the fixture mapped onto the canonical vocabulary.
    expect(new Set(sets.data!.map((s) => s.set_type))).toEqual(
      new Set(["warmup", "working", "failure", "drop"]),
    );

    expect(imports.data!.status).toMatch(/^completed/);
    expect(Number(imports.data!.rows_total)).toBe(20);
    expect(Number(imports.data!.records_added)).toBe(20);
    expect(Number(imports.data!.records_invalid)).toBe(0);
  });

  test("TEST A: every canonical row traces to its raw record and to the original file", async () => {
    // The provenance chain is the joins below: set -> raw record -> import ->
    // the original file still sitting in storage (PRD section 4.4, section 19).
    const { data: sets } = await admin
      .from("strength_sets")
      .select("id, natural_key, raw_record_id, user_id")
      .eq("user_id", userId);
    const { data: raws } = await admin
      .from("raw_records")
      .select("id, user_id, import_id, normalized_keys")
      .eq("user_id", userId);
    const { data: imports } = await admin
      .from("data_imports")
      .select("id, storage_path, file_sha256")
      .eq("user_id", userId);

    const rawById = new Map(raws!.map((r) => [r.id as number, r]));
    const importById = new Map(imports!.map((i) => [i.id as string, i]));

    for (const set of sets!) {
      const raw = rawById.get(set.raw_record_id as number);
      expect(raw, `set ${set.id} has no raw record`).toBeTruthy();
      expect(raw!.user_id).toBe(set.user_id);
      const record = importById.get(raw!.import_id as string);
      expect(record, `raw record ${raw!.id} has no import`).toBeTruthy();
      expect(record!.storage_path).toBeTruthy();
      expect(record!.file_sha256).toHaveLength(64);
      // The raw record records which canonical keys it produced (v2 §7.3).
      expect(raw!.normalized_keys as string[]).toContain(set.natural_key);
    }

    // And the original file is still there to be re-read.
    const path = imports![0]!.storage_path as string;
    const { data: file } = await admin.storage.from("imports").download(path);
    expect(file).toBeTruthy();
    expect((await file!.text()).split("\n")[0]).toContain("exercise_title");
  });

  test("TEST A: re-importing the same file adds nothing", async ({ page }) => {
    const before = await admin.from("strength_sets").select("id", { count: "exact", head: true }).eq("user_id", userId);

    await uploadAndPreview(page, FULL_EXPORT);
    await page.getByRole("button", { name: "Confirm and import" }).click();
    await page.waitForURL("**/import/**");
    await runWorker();

    const after = await admin.from("strength_sets").select("id", { count: "exact", head: true }).eq("user_id", userId);
    expect(after.count).toBe(before.count);

    const { data: second } = await admin
      .from("data_imports")
      .select("records_added, duplicates_skipped")
      .eq("user_id", userId)
      .order("created_at", { ascending: false })
      .limit(1)
      .single();
    expect(Number(second!.records_added)).toBe(0);
    expect(Number(second!.duplicates_skipped)).toBe(20);
  });

  // =========================================================================
  // TEST B — the hard gate
  // =========================================================================

  test("TEST B: a truncated snapshot is blocked by G4 and offers append-only", async ({ page }) => {
    const workoutsBefore = await admin
      .from("strength_workouts")
      .select("id", { count: "exact", head: true })
      .eq("user_id", userId)
      .is("retired_at", null);
    expect(workoutsBefore.count).toBe(5);

    await uploadAndPreview(page, TRUNCATED_EXPORT);
    await page.getByRole("button", { name: "Confirm and import" }).click();
    await page.waitForURL("**/import/**");
    const importId = page.url().split("/").pop()!;

    await runWorker();
    await page.reload();

    // The retire stage computed a plan, persisted it and HALTED.
    const { data: plan } = await admin
      .from("reconciliation_plans")
      .select("*")
      .eq("import_id", importId)
      .single();
    expect(plan, "a reconciliation plan must be persisted").toBeTruthy();
    expect(plan!.verdict).toBe("blocked");
    expect(Number(plan!.retire_count)).toBe(2);
    expect(plan!.decision).toBeNull();

    const guards = plan!.guard_results as { id: string; outcome: string; detail: string }[];
    const g4 = guards.find((g) => g.id === "G4")!;
    expect(g4.outcome).toBe("blocked");
    expect(g4.detail).toContain("60%");

    const { data: importRow } = await admin.from("data_imports").select("status").eq("id", importId).single();
    expect(importRow!.status).toBe("awaiting_retirement_confirmation");

    // Nothing has been retired.
    const stillVisible = await admin
      .from("strength_workouts")
      .select("id", { count: "exact", head: true })
      .eq("user_id", userId)
      .is("retired_at", null);
    expect(stillVisible.count).toBe(5);

    // The confirmation screen shows the projected impact.
    await expect(page.getByText("Snapshot import — confirmation required")).toBeVisible();
    await expect(page.getByText(/2 of 5 existing records in this scope would be retired/)).toBeVisible();
    await expect(page.getByText(/Guard G4 triggered/)).toBeVisible();
    await expect(page.getByText(/partial rather than complete/)).toBeVisible();
    await expect(page.getByText("Retirements by month")).toBeVisible();
    await expect(page.getByText("Examples of what would be retired")).toBeVisible();

    // The append-only fallback is offered, and confirming is not.
    await expect(page.getByRole("button", { name: "Import without retiring (recommended)" })).toBeVisible();
    await expect(page.getByRole("button", { name: /^Confirm and retire/ })).toHaveCount(0);
  });

  test("TEST B: the database refuses retirement even if the API is bypassed", async () => {
    const { data: plan } = await admin
      .from("reconciliation_plans")
      .select("*")
      .eq("verdict", "blocked")
      .order("computed_at", { ascending: false })
      .limit(1)
      .single();

    // Confirming a blocked plan is refused by the check constraint.
    const confirmAttempt = await admin
      .from("reconciliation_plans")
      .update({ decision: "confirmed", decided_at: new Date().toISOString() })
      .eq("id", plan!.id);
    expect(confirmAttempt.error, "a blocked plan must not be confirmable").toBeTruthy();

    // And retiring a row directly, with the elevated key, is refused too.
    const keys = plan!.retire_natural_keys as string[];
    const retireAttempt = await admin
      .from("strength_workouts")
      .update({ retired_at: new Date().toISOString(), retired_by_import_id: plan!.import_id })
      .eq("user_id", userId)
      .in("natural_key", keys);
    expect(retireAttempt.error, "retirement without a confirmed plan must be refused").toBeTruthy();
    expect(retireAttempt.error!.message).toMatch(/I-10|reconciliation_plan/);

    const stillVisible = await admin
      .from("strength_workouts")
      .select("id", { count: "exact", head: true })
      .eq("user_id", userId)
      .is("retired_at", null);
    expect(stillVisible.count).toBe(5);
  });

  test("TEST B: the append-only fallback completes the import, retiring nothing", async ({ page }) => {
    const { data: pending } = await admin
      .from("reconciliation_plans")
      .select("id, import_id")
      .is("decision", null)
      .order("computed_at", { ascending: false })
      .limit(1)
      .single();

    await logIn(page);
    await page.goto(`/import/${pending!.import_id}`);
    await page.getByRole("button", { name: "Import without retiring (recommended)" }).click();
    // Once decided there is no pending plan, so the confirmation panel is gone
    // and the import reads as completed.
    await expect(page.getByText("Snapshot import — confirmation required")).toHaveCount(0, {
      timeout: 20_000,
    });
    await expect(page.getByText(/status completed/)).toBeVisible();

    const { data: after } = await admin
      .from("data_imports")
      .select("status, records_retired")
      .eq("id", pending!.import_id)
      .single();
    expect(after!.status).toBe("completed");
    expect(Number(after!.records_retired)).toBe(0);

    const stillVisible = await admin
      .from("strength_workouts")
      .select("id", { count: "exact", head: true })
      .eq("user_id", userId)
      .is("retired_at", null);
    expect(stillVisible.count).toBe(5);

    const { data: plan } = await admin.from("reconciliation_plans").select("decision").eq("id", pending!.id).single();
    expect(plan!.decision).toBe("skipped");
  });
});
