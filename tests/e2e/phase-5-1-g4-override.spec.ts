import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { expect, test, type Page } from "@playwright/test";

import { deleteAllMessages, waitForConfirmationLink } from "./mailpit";

/**
 * Phase 5.1 hard gates at the application surface.
 *
 * The property being proved is a pair: G4 still stops automatic retirement,
 * AND the owner can consciously proceed through a strongly confirmed, audited
 * override — with the analytics that follow staying equal to canonical truth.
 *
 * Before Phase 5.1 the product offered an override the backend could never
 * honour. Gate A here is the half that must not regress; Gate B is the half
 * that did not exist.
 *
 * The service key is used for verification reads only. Every user action goes
 * through the UI or through that user's own session.
 */

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const SERVICE_KEY = process.env.E2E_SERVICE_ROLE_KEY!;
const WORKER_SECRET = process.env.IMPORT_WORKER_SECRET!;
const BASE = process.env.E2E_BASE_URL ?? "http://127.0.0.1:3000";

const RUN = Date.now();
const OWNER = { email: `p51-owner-${RUN}@example.test`, password: "phase-51-owner-password-1" };
const OTHER = { email: `p51-other-${RUN}@example.test`, password: "phase-51-other-password-1" };

const FULL_EXPORT = "tests/fixtures/hevy/hevy-export.csv";
/** Three of five workouts: 60% coverage, under G4's 70% floor. */
const TRUNCATED_EXPORT = "tests/fixtures/hevy/hevy-export-truncated.csv";

const OVERRIDE_REASON =
  "This export is authoritative; the missing sessions were deleted deliberately.";

let admin: SupabaseClient;
let ownerId = "";
let blockedImportId = "";
let blockedPlanId = "";

async function runWorker(): Promise<void> {
  for (let tick = 0; tick < 30; tick += 1) {
    const response = await fetch(`${BASE}/api/worker`, {
      method: "POST",
      headers: { "x-worker-secret": WORKER_SECRET },
    });
    expect(response.status, "worker invocation").toBe(200);
    const body = (await response.json()) as {
      batches: number;
      failed: unknown[];
      rollup: { processed: number; failed: number; errors: unknown[] };
    };
    expect(body.failed, `worker batch failed: ${JSON.stringify(body.failed)}`).toHaveLength(0);
    expect(body.rollup.failed, `rollup failed: ${JSON.stringify(body.rollup.errors)}`).toBe(0);
    if (body.batches === 0 && body.rollup.processed === 0) break;
  }
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

async function importFile(page: Page, fixture: string): Promise<string> {
  await page.goto("/import");
  await page.setInputFiles("#file", fixture);
  await expect(page.getByText("Preview", { exact: true })).toBeVisible({ timeout: 30_000 });
  await page.getByRole("button", { name: "Confirm and import" }).click();
  await page.waitForURL("**/import/**");
  return page.url().split("/").pop()!;
}

async function canonical(userId: string) {
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
    volumeKg: loaded.reduce((total, s) => total + Number(s.volume_kg), 0),
  };
}

async function derived(userId: string) {
  const { data } = await admin
    .from("metric_daily")
    .select("metric_key, value")
    .eq("user_id", userId);
  const sum = (key: string) =>
    (data ?? []).filter((r) => r.metric_key === key).reduce((t, r) => t + Number(r.value), 0);
  return { workouts: sum("training_workouts"), sets: sum("training_sets"), volumeKg: sum("training_volume_kg") };
}

/**
 * The decision endpoint, called directly rather than through the panel.
 *
 * Issued through the page's own request context so it carries that browser's
 * session cookie: the route authenticates from the cookie, exactly as it does
 * for the real UI, so this is the same authenticated identity and not a
 * privileged side door.
 */
async function postDecision(
  page: Page,
  importId: string,
  body: Record<string, unknown>,
): Promise<{ status: number; body: Record<string, unknown> }> {
  const response = await page.request.post(`${BASE}/api/imports/${importId}/decision`, {
    data: body,
  });
  return { status: response.status(), body: (await response.json()) as Record<string, unknown> };
}

test.describe.configure({ mode: "serial" });

test.describe("Phase 5.1 — the G4 override", () => {
  test.beforeAll(async () => {
    expect(SUPABASE_URL && ANON_KEY && SERVICE_KEY && WORKER_SECRET).toBeTruthy();
    admin = createClient(SUPABASE_URL, SERVICE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
  });

  test("a full export is imported and rolled up", async ({ page }) => {
    await signUpAndConfirm(page, OWNER);
    const { data } = await admin.auth.admin.listUsers();
    ownerId = data.users.find((u) => u.email === OWNER.email)!.id;

    await importFile(page, FULL_EXPORT);
    await runWorker();

    expect((await canonical(ownerId)).workouts).toBe(5);
    expect((await derived(ownerId)).workouts).toBe(5);
  });

  // =========================================================================
  // GATE A — G4 still blocks automatic retirement
  // =========================================================================

  test("GATE A: a truncated snapshot is blocked and offers no one-click retire", async ({
    page,
  }) => {
    await logIn(page, OWNER);
    blockedImportId = await importFile(page, TRUNCATED_EXPORT);
    await runWorker();
    await page.reload();

    const { data: plan } = await admin
      .from("reconciliation_plans")
      .select("id, verdict, retire_count, decision")
      .eq("import_id", blockedImportId)
      .single();
    blockedPlanId = plan!.id as string;
    expect(plan!.verdict).toBe("blocked");
    expect(Number(plan!.retire_count)).toBe(2);
    expect(plan!.decision).toBeNull();

    await expect(page.getByText("Snapshot import — confirmation required")).toBeVisible();
    await expect(page.getByText(/Guard G4 triggered/)).toBeVisible();

    // The safe fallback is one click. Ordinary confirmation is not offered at all.
    await expect(
      page.getByRole("button", { name: "Import without retiring (recommended)" }),
    ).toBeVisible();
    await expect(page.getByRole("button", { name: /^Confirm and retire/ })).toHaveCount(0);

    // Nothing is retired.
    expect((await canonical(ownerId)).workouts).toBe(5);
  });

  test("GATE A: the API refuses a confirmation with no override", async ({ page }) => {
    await logIn(page, OWNER);
    const result = await postDecision(page, blockedImportId, {
      planId: blockedPlanId,
      decision: "confirmed",
    });
    expect(result.status).toBe(409);
    expect(result.body.overrideRequired).toBe(true);
    expect(result.body.blockedBy).toEqual(["G4"]);
    expect(result.body.appendOnlyAvailable).toBe(true);

    const { data: plan } = await admin
      .from("reconciliation_plans")
      .select("decision")
      .eq("id", blockedPlanId)
      .single();
    expect(plan!.decision).toBeNull();
    expect((await canonical(ownerId)).workouts).toBe(5);
  });

  test("GATE A: the override cannot be satisfied by asserting it", async ({ page }) => {
    await logIn(page, OWNER);
    // The client does not get to declare the requirements met. Each of these
    // is refused, and none of them records an override or a decision.
    const wrongCount = await postDecision(page, blockedImportId, {
      planId: blockedPlanId,
      decision: "confirmed",
      override: { acknowledged: true, typedConfirmation: "999", reason: OVERRIDE_REASON },
    });
    expect(wrongCount.status).toBe(400);

    const thinReason = await postDecision(page, blockedImportId, {
      planId: blockedPlanId,
      decision: "confirmed",
      override: { acknowledged: true, typedConfirmation: "2", reason: "ok" },
    });
    expect(thinReason.status).toBe(400);

    const notAcknowledged = await postDecision(page, blockedImportId, {
      planId: blockedPlanId,
      decision: "confirmed",
      override: { acknowledged: false, typedConfirmation: "2", reason: OVERRIDE_REASON },
    });
    expect(notAcknowledged.status).toBe(400);

    const { count: overrides } = await admin
      .from("retirement_overrides")
      .select("id", { count: "exact", head: true })
      .eq("plan_id", blockedPlanId);
    expect(overrides ?? 0).toBe(0);
    const { data: plan } = await admin
      .from("reconciliation_plans")
      .select("decision")
      .eq("id", blockedPlanId)
      .single();
    expect(plan!.decision).toBeNull();
    expect((await canonical(ownerId)).workouts).toBe(5);
  });

  // =========================================================================
  // GATE E — isolation (before the override is taken, so the plan is still open)
  // =========================================================================

  test("GATE E: another user cannot override or even see this plan", async ({ page }) => {
    await signUpAndConfirm(page, OTHER);

    const attempt = await postDecision(page, blockedImportId, {
      planId: blockedPlanId,
      decision: "confirmed",
      override: { acknowledged: true, typedConfirmation: "2", reason: OVERRIDE_REASON },
    });
    // RLS makes the plan invisible, so it is not found rather than forbidden.
    expect(attempt.status).toBe(404);

    const anon = createClient(SUPABASE_URL, ANON_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { error: signInError } = await anon.auth.signInWithPassword(OTHER);
    expect(signInError).toBeNull();

    // Directly at the database, with a real session: still nothing.
    const { data: plans } = await anon.from("reconciliation_plans").select("id");
    expect(plans).toEqual([]);
    const { data: audit } = await anon.from("v_retirement_audit").select("plan_id");
    expect(audit).toEqual([]);
    const forged = await anon.from("retirement_overrides").insert({
      user_id: ownerId,
      plan_id: blockedPlanId,
      guard_id: "G4",
      typed_confirmation: "2",
      acknowledged: true,
      reason: OVERRIDE_REASON,
    });
    expect(forged.error, "a user must not record an override on another user's plan").toBeTruthy();
    await anon.auth.signOut();

    // Unauthenticated.
    const anonymous = createClient(SUPABASE_URL, ANON_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const anonRead = await anonymous.from("v_retirement_audit").select("plan_id");
    expect(anonRead.error, "anon must not be able to read the audit trail").toBeTruthy();
    const anonWrite = await anonymous.from("retirement_overrides").insert({
      user_id: ownerId,
      plan_id: blockedPlanId,
      guard_id: "G4",
      typed_confirmation: "2",
      acknowledged: true,
      reason: OVERRIDE_REASON,
    });
    expect(anonWrite.error, "an anonymous caller must not record an override").toBeTruthy();

    const { count: overrides } = await admin
      .from("retirement_overrides")
      .select("id", { count: "exact", head: true })
      .eq("plan_id", blockedPlanId);
    expect(overrides ?? 0).toBe(0);
  });

  // =========================================================================
  // GATE B — the explicit override, through the real UI
  // =========================================================================

  test("GATE B: the override is offered but not one click", async ({ page }) => {
    await logIn(page, OWNER);
    await page.goto(`/import/${blockedImportId}`);

    await expect(page.getByText(/Override the safety block/)).toBeVisible();
    await page.getByText(/Override the safety block/).click();

    // The wording says what happened and what proceeding does. No soft language.
    await expect(
      page.getByText(/looks like a partial or incomplete snapshot/i),
    ).toBeVisible();
    await expect(page.getByText(/stopped the retirement automatically/i)).toBeVisible();
    await expect(page.getByText(/recorded against your account/i)).toBeVisible();

    const button = page.getByRole("button", { name: /^Override G4 and retire 2/ });
    await expect(button).toBeVisible();
    await expect(button).toBeDisabled();

    // Each requirement on its own is not enough.
    await page.getByLabel(/I understand this file may be incomplete/).check();
    await expect(button).toBeDisabled();
    await page.getByLabel(/Why are you overriding/).fill(OVERRIDE_REASON);
    await expect(button).toBeDisabled();
    await page.getByLabel(/Type 2 to confirm/).fill("1");
    await expect(button).toBeDisabled();
  });

  test("GATE B: completing the confirmation retires exactly the planned records", async ({
    page,
  }) => {
    await logIn(page, OWNER);
    await page.goto(`/import/${blockedImportId}`);
    await page.getByText(/Override the safety block/).click();
    await page.getByLabel(/I understand this file may be incomplete/).check();
    await page.getByLabel(/Why are you overriding/).fill(OVERRIDE_REASON);
    await page.getByLabel(/Type 2 to confirm/).fill("2");

    const button = page.getByRole("button", { name: /^Override G4 and retire 2/ });
    await expect(button).toBeEnabled();
    await button.click();

    await expect(page.getByText("Snapshot import — confirmation required")).toHaveCount(0, {
      timeout: 20_000,
    });

    const { data: plan } = await admin
      .from("reconciliation_plans")
      .select("verdict, decision, decided_reason, retire_natural_keys")
      .eq("id", blockedPlanId)
      .single();
    expect(plan!.decision).toBe("confirmed");
    // The original safety result is not rewritten.
    expect(plan!.verdict).toBe("blocked");

    // Exactly the plan's key set, and nothing else.
    const { data: retired } = await admin
      .from("strength_workouts")
      .select("natural_key")
      .eq("user_id", ownerId)
      .not("retired_at", "is", null);
    expect(retired!.length).toBe(2);
    const planned = new Set(plan!.retire_natural_keys as string[]);
    for (const row of retired!) expect(planned.has(row.natural_key as string)).toBe(true);
    expect((await canonical(ownerId)).workouts).toBe(3);
  });

  // =========================================================================
  // GATE C — auditability
  // =========================================================================

  test("GATE C: the audit trail answers why, who, when and on what", async () => {
    const anon = createClient(SUPABASE_URL, ANON_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { error: signInError } = await anon.auth.signInWithPassword(OWNER);
    expect(signInError).toBeNull();

    // Read through the OWNER'S OWN session: the audit is theirs to inspect.
    const { data: audit, error } = await anon
      .from("v_retirement_audit")
      .select("*")
      .eq("plan_id", blockedPlanId)
      .single();
    expect(error).toBeNull();

    expect(audit!.original_verdict).toBe("blocked");
    expect(audit!.was_safety_override).toBe(true);
    expect(audit!.decision).toBe("confirmed");
    expect(audit!.decided_at).toBeTruthy();
    expect(audit!.import_id).toBe(blockedImportId);
    expect(audit!.file_name).toBe("hevy-export-truncated.csv");

    const blocking = audit!.blocking_guards as { id: string; detail: string }[];
    expect(blocking.map((g) => g.id)).toEqual(["G4"]);
    expect(blocking[0]!.detail).toMatch(/partial rather than complete/);

    const overrides = audit!.overrides as {
      guard_id: string;
      guard_detail: string;
      overridden_by: string;
      overridden_at: string;
      reason: string;
      acknowledged: boolean;
    }[];
    expect(overrides).toHaveLength(1);
    expect(overrides[0]!.guard_id).toBe("G4");
    expect(overrides[0]!.overridden_by).toBe(ownerId);
    expect(overrides[0]!.overridden_at).toBeTruthy();
    expect(overrides[0]!.reason).toBe(OVERRIDE_REASON);
    expect(overrides[0]!.acknowledged).toBe(true);
    // Evidence derived by the database from the plan, not sent by the client.
    expect(overrides[0]!.guard_detail).toMatch(/partial rather than complete/);

    await anon.auth.signOut();
  });

  // =========================================================================
  // GATE F — analytics after the override
  // =========================================================================

  test("GATE F: derived metrics equal canonical truth after the override", async () => {
    await runWorker();

    const c = await canonical(ownerId);
    const d = await derived(ownerId);
    expect(c.workouts).toBe(3);
    expect(d.workouts).toBe(c.workouts);
    expect(d.sets).toBe(c.sets);
    expect(d.volumeKg).toBeCloseTo(c.volumeKg, 6);

    const { data: retiredIds } = await admin
      .from("strength_workouts")
      .select("id")
      .eq("user_id", ownerId)
      .not("retired_at", "is", null);
    const retired = new Set((retiredIds ?? []).map((r) => r.id as string));
    const { data: tier1 } = await admin
      .from("metric_daily_source")
      .select("contributing_workout_ids")
      .eq("user_id", ownerId);
    for (const row of tier1!) {
      for (const id of row.contributing_workout_ids as string[]) {
        expect(retired.has(id), "a retired workout is still named in provenance").toBe(false);
      }
    }
  });

  test("GATE F: the dashboard shows the post-override history", async ({ page }) => {
    await logIn(page, OWNER);
    const workoutTile = page.locator("div", { hasText: /^Workouts/ }).last();
    await expect(workoutTile).toContainText("3");
  });

  // =========================================================================
  // GATE G — idempotency
  // =========================================================================

  test("GATE G: resubmitting the override changes nothing", async ({ page }) => {
    await logIn(page, OWNER);
    const before = await derived(ownerId);
    const { count: overridesBefore } = await admin
      .from("retirement_overrides")
      .select("id", { count: "exact", head: true })
      .eq("plan_id", blockedPlanId);
    const { data: planBefore } = await admin
      .from("reconciliation_plans")
      .select("decided_at")
      .eq("id", blockedPlanId)
      .single();

    for (let attempt = 0; attempt < 3; attempt += 1) {
      const result = await postDecision(page, blockedImportId, {
        planId: blockedPlanId,
        decision: "confirmed",
        override: { acknowledged: true, typedConfirmation: "2", reason: OVERRIDE_REASON },
      });
      expect(result.status).toBe(200);
      expect(result.body.alreadyDecided).toBe(true);
      expect(Number(result.body.retired)).toBe(2);
    }
    await runWorker();

    const { count: overridesAfter } = await admin
      .from("retirement_overrides")
      .select("id", { count: "exact", head: true })
      .eq("plan_id", blockedPlanId);
    const { data: planAfter } = await admin
      .from("reconciliation_plans")
      .select("decided_at")
      .eq("id", blockedPlanId)
      .single();

    expect(overridesAfter).toBe(overridesBefore);
    // The decision timestamp is a fact about when it happened, not about the
    // last time somebody clicked.
    expect(planAfter!.decided_at).toBe(planBefore!.decided_at);
    expect((await canonical(ownerId)).workouts).toBe(3);
    expect(await derived(ownerId)).toEqual(before);
  });

  // =========================================================================
  // GATE D — the safe fallback is still there, on a fresh blocked plan
  // =========================================================================

  test("GATE D: append-only still completes a blocked import, retiring nothing", async ({
    page,
  }) => {
    await logIn(page, OWNER);

    // Restore the full history first, so the truncated file genuinely trips G4
    // again rather than matching what is left. Re-importing the complete export
    // also un-retires what the override retired, which is v3 section 4.4's undo
    // path, and the analytics follow it back.
    await importFile(page, FULL_EXPORT);
    await runWorker();
    expect((await canonical(ownerId)).workouts).toBe(5);
    expect((await derived(ownerId)).workouts).toBe(5);

    const importId = await importFile(page, TRUNCATED_EXPORT);
    await runWorker();
    await page.reload();

    const beforeCanonical = await canonical(ownerId);
    const beforeDerived = await derived(ownerId);

    const { data: blocked } = await admin
      .from("reconciliation_plans")
      .select("verdict, retire_count")
      .eq("import_id", importId)
      .single();
    expect(blocked!.verdict).toBe("blocked");
    expect(Number(blocked!.retire_count)).toBe(2);

    await expect(page.getByText("Snapshot import — confirmation required")).toBeVisible();
    await page.getByRole("button", { name: "Import without retiring (recommended)" }).click();
    await expect(page.getByText("Snapshot import — confirmation required")).toHaveCount(0, {
      timeout: 20_000,
    });
    await runWorker();

    const { data: record } = await admin
      .from("data_imports")
      .select("status, records_retired")
      .eq("id", importId)
      .single();
    expect(record!.status).toBe("completed");
    expect(Number(record!.records_retired)).toBe(0);

    const { data: plan } = await admin
      .from("reconciliation_plans")
      .select("decision, verdict")
      .eq("import_id", importId)
      .single();
    expect(plan!.decision).toBe("skipped");
    expect(plan!.verdict).toBe("blocked");

    // No override was recorded, and nothing moved.
    const { count: overrides } = await admin
      .from("retirement_overrides")
      .select("id", { count: "exact", head: true })
      .eq("plan_id", (await admin.from("reconciliation_plans").select("id").eq("import_id", importId).single()).data!.id);
    expect(overrides ?? 0).toBe(0);
    expect(await canonical(ownerId)).toEqual(beforeCanonical);
    expect(await derived(ownerId)).toEqual(beforeDerived);
  });
});
