import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { expect, test, type Page } from "@playwright/test";

import { deleteAllMessages, waitForConfirmationLink } from "./mailpit";

/**
 * Phase 6 — manual body tracking, end to end.
 *
 * The exit criterion is that a corrected measurement survives a full normalize
 * rebuild with the corrected value intact. That is asserted here by actually
 * running the rebuild against the real application, not by reasoning about it.
 *
 * Everything the user does goes through the UI. The service key is used only
 * to read back canonical rows and to invoke the rebuild, which is a
 * maintenance operation authorised by the worker secret rather than a session.
 */

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const SERVICE_KEY = process.env.E2E_SERVICE_ROLE_KEY!;
const WORKER_SECRET = process.env.IMPORT_WORKER_SECRET!;
const BASE = process.env.E2E_BASE_URL ?? "http://127.0.0.1:3000";

const RUN = Date.now();
const OWNER = { email: `p6-owner-${RUN}@example.test`, password: "phase-6-owner-password-1" };
const OTHER = { email: `p6-other-${RUN}@example.test`, password: "phase-6-other-password-1" };

let admin: SupabaseClient;
let ownerId = "";

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

/** The canonical metric rows currently in force for a user. */
async function canonicalMetrics(userId: string) {
  const { data } = await admin
    .from("v_metrics")
    .select("natural_key, metric_key, value_num, unit, source_value_num, source_unit, revision, raw_record_id")
    .eq("user_id", userId)
    .order("timestamp_utc");
  return data ?? [];
}

async function rawRecords(userId: string) {
  const { data } = await admin
    .from("raw_records")
    .select("id, precedence_rank, supersedes_natural_key, payload, normalize_status")
    .eq("user_id", userId)
    .order("id");
  return data ?? [];
}

test.describe.configure({ mode: "serial" });

test.describe("Phase 6 — manual body tracking", () => {
  test.beforeAll(async () => {
    expect(SUPABASE_URL && ANON_KEY && SERVICE_KEY && WORKER_SECRET).toBeTruthy();
    admin = createClient(SUPABASE_URL, SERVICE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
  });

  test("a new account has nothing recorded and offers only measurable metrics", async ({
    page,
  }) => {
    await signUpAndConfirm(page, OWNER);
    const { data } = await admin.auth.admin.listUsers();
    ownerId = data.users.find((u) => u.email === OWNER.email)!.id;
    expect(ownerId).toBeTruthy();

    await page.goto("/body");
    await expect(page.getByRole("heading", { name: "Body" })).toBeVisible();
    await expect(page.getByText(/Nothing recorded yet/)).toBeVisible();

    // The registry decides what can be typed. A derived aggregate must not be
    // on the list: it is computed, and a typed value would compete with it.
    const options = await page.locator("#metric option").allTextContents();
    expect(options).toContain("Weight");
    expect(options).toContain("Waist Circumference");
    expect(options.join("|")).not.toMatch(/Training/);
  });

  test("recording a measurement writes a raw record and a canonical metric", async ({ page }) => {
    await logIn(page, OWNER);
    await page.goto("/body");

    await page.selectOption("#metric", "weight");
    await page.fill("#measured-at", "2026-08-03T07:30");
    await page.fill("#value", "82.4");
    await page.selectOption("#unit", "kg");
    await page.getByRole("button", { name: "Record measurement" }).click();

    await expect(page.getByText("82.4")).toBeVisible({ timeout: 15_000 });

    // I-1: the canonical row exists because a raw record does, not instead.
    const raw = await rawRecords(ownerId);
    expect(raw).toHaveLength(1);
    expect(raw[0]!.precedence_rank).toBe(10);
    expect(raw[0]!.supersedes_natural_key).toBeNull();
    expect(raw[0]!.normalize_status).toBe("ok");

    const metrics = await canonicalMetrics(ownerId);
    expect(metrics).toHaveLength(1);
    expect(metrics[0]!.metric_key).toBe("weight");
    expect(Number(metrics[0]!.value_num)).toBeCloseTo(82.4, 6);
    expect(metrics[0]!.unit).toBe("kg");
    expect(metrics[0]!.revision).toBe(1);
    expect(metrics[0]!.raw_record_id).toBe(raw[0]!.id);

    // The synthetic import is a real import, with no file.
    const { data: imports } = await admin
      .from("data_imports")
      .select("source_key, template, file_type, storage_path, status, import_mode")
      .eq("user_id", ownerId);
    expect(imports).toHaveLength(1);
    expect(imports![0]!.source_key).toBe("manual");
    expect(imports![0]!.template).toBe("metrics");
    expect(imports![0]!.file_type).toBe("manual");
    expect(imports![0]!.storage_path).toBeNull();
    expect(imports![0]!.status).toMatch(/^completed/);
  });

  test("a value entered in another unit is stored canonically and shown back as typed", async ({
    page,
  }) => {
    await logIn(page, OWNER);
    await page.goto("/body");

    await page.selectOption("#metric", "weight");
    await page.fill("#measured-at", "2026-08-04T07:30");
    await page.fill("#value", "181.7");
    await page.selectOption("#unit", "lb");
    await page.getByRole("button", { name: "Record measurement" }).click();

    await expect(page.getByText(/entered 181.7 lb/)).toBeVisible({ timeout: 15_000 });

    const metrics = await canonicalMetrics(ownerId);
    const converted = metrics.find((m) => m.source_unit === "lb")!;
    expect(Number(converted.value_num)).toBeCloseTo(181.7 * 0.45359237, 5);
    expect(converted.unit).toBe("kg");
    expect(Number(converted.source_value_num)).toBeCloseTo(181.7, 6);
  });

  test("a correction supersedes the entry rather than editing it", async ({ page }) => {
    await logIn(page, OWNER);
    await page.goto("/body");

    // Scoped by date: the pound entry converts to 82.42 kg, so "82.4" alone
    // names two rows.
    const row = page.locator("main ul > li").filter({ hasText: "3 Aug 2026" });
    await expect(row).toHaveCount(1);
    await expect(row).toContainText("82.4");
    await row.getByRole("button", { name: "Correct" }).click();
    await expect(page.getByText(/The original entry is kept/)).toBeVisible();

    await page.locator("#value").last().fill("81.9");
    await page.getByRole("button", { name: "Record correction" }).click();

    const correctedRow = page.locator("main ul > li").filter({ hasText: "3 Aug 2026" });
    await expect(correctedRow).toContainText("81.9", { timeout: 15_000 });
    await expect(correctedRow.getByText("corrected")).toBeVisible();
    // The unrelated entry is untouched.
    await expect(
      page.locator("main ul > li").filter({ hasText: "4 Aug 2026" }),
    ).toContainText("82.42");

    // Three raw records; the original is untouched and still says 82.4 (I-2).
    const raw = await rawRecords(ownerId);
    expect(raw).toHaveLength(3);
    const correction = raw.find((r) => r.precedence_rank === 20)!;
    expect(correction.supersedes_natural_key).toBeTruthy();
    const original = raw.find((r) => r.precedence_rank === 10 && r.payload.value === "82.4")!;
    expect(original.payload.value).toBe("82.4");

    // One canonical row for that observation, now at revision 2.
    const metrics = await canonicalMetrics(ownerId);
    expect(metrics).toHaveLength(2);
    const corrected = metrics.find((m) => m.natural_key === correction.supersedes_natural_key)!;
    expect(Number(corrected.value_num)).toBeCloseTo(81.9, 6);
    expect(corrected.revision).toBe(2);
  });

  // =========================================================================
  // THE EXIT CRITERION
  // =========================================================================

  test("the corrected value survives a full normalize rebuild", async () => {
    const before = await canonicalMetrics(ownerId);
    expect(before.some((m) => Math.abs(Number(m.value_num) - 81.9) < 1e-6)).toBe(true);

    const response = await fetch(`${BASE}/api/worker/rebuild`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-worker-secret": WORKER_SECRET },
      body: JSON.stringify({ userId: ownerId, template: "metrics" }),
    });
    expect(response.status).toBe(200);
    const body = (await response.json()) as { importsQueued: number; failed: unknown[] };
    expect(body.importsQueued).toBeGreaterThan(0);
    expect(body.failed).toHaveLength(0);

    // Every raw record was genuinely replayed, not skipped.
    const raw = await rawRecords(ownerId);
    expect(raw.every((r) => r.normalize_status === "ok")).toBe(true);

    const after = await canonicalMetrics(ownerId);
    // The whole canonical answer is identical, value and revision alike. An
    // unchanged revision is the stronger claim: the rebuild recognised that
    // nothing had changed rather than churning every row back to the same
    // number.
    expect(after).toEqual(before);

    // The corrected observation specifically: 81.9, not the 82.4 it was
    // entered as. Asserted on that row rather than on "some row", because the
    // pound entry converts to 82.42 kg and would answer a looser question.
    const correctedRow = after.find((m) => m.revision === 2)!;
    expect(correctedRow).toBeTruthy();
    expect(Number(correctedRow.value_num)).toBeCloseTo(81.9, 6);
    expect(after.every((m) => Math.abs(Number(m.value_num) - 82.4) > 1e-6)).toBe(true);
  });

  test("the rebuilt value is what the page shows", async ({ page }) => {
    await logIn(page, OWNER);
    await page.goto("/body");
    const row = page.locator("main ul > li").filter({ hasText: "3 Aug 2026" });
    await expect(row).toContainText("81.9");
    await expect(row).not.toContainText("82.4");
  });

  // =========================================================================
  // Boundaries
  // =========================================================================

  test("a derived metric cannot be recorded by hand", async ({ page }) => {
    await logIn(page, OWNER);
    const response = await page.request.post(`${BASE}/api/measurements`, {
      data: {
        measurements: [
          {
            metricKey: "training_volume_kg",
            value: "99999",
            unit: "kg",
            measuredAt: "2026-08-05T07:30:00+01:00",
          },
        ],
      },
    });
    expect(response.status()).toBe(422);
    expect((await response.json()).metrics).toEqual(["training_volume_kg"]);

    const metrics = await canonicalMetrics(ownerId);
    expect(metrics.some((m) => m.metric_key === "training_volume_kg")).toBe(false);
  });

  test("the rebuild endpoint requires the worker secret", async () => {
    const unauthorised = await fetch(`${BASE}/api/worker/rebuild`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ userId: ownerId }),
    });
    expect(unauthorised.status).toBe(401);

    const wrong = await fetch(`${BASE}/api/worker/rebuild`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-worker-secret": "not-the-secret" },
      body: JSON.stringify({ userId: ownerId }),
    });
    expect(wrong.status).toBe(401);
  });

  test("another user sees none of this and cannot correct any of it", async ({ page }) => {
    const ownerMetrics = await canonicalMetrics(ownerId);
    const ownerKey = ownerMetrics[0]!.natural_key as string;

    await signUpAndConfirm(page, OTHER);
    await page.goto("/body");
    await expect(page.getByText(/Nothing recorded yet/)).toBeVisible();

    // Naming the other user's observation explicitly: row level security makes
    // it invisible, so the correction has nothing to attach to.
    const attempt = await page.request.post(`${BASE}/api/measurements`, {
      data: {
        measurements: [
          {
            metricKey: "weight",
            value: "1",
            unit: "kg",
            measuredAt: "2026-08-06T07:30:00+01:00",
            supersedesNaturalKey: ownerKey,
          },
        ],
      },
    });
    expect(attempt.status()).toBe(404);

    const anon = createClient(SUPABASE_URL, ANON_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { error: signInError } = await anon.auth.signInWithPassword(OTHER);
    expect(signInError).toBeNull();
    const { data: visible } = await anon.from("v_metrics").select("natural_key");
    expect(visible).toEqual([]);
    const { data: readModel } = await anon.rpc("body_measurements", { p_limit: 100, p_offset: 0 });
    expect(readModel).toEqual([]);
    await anon.auth.signOut();

    // The owner's data is exactly as it was.
    expect(await canonicalMetrics(ownerId)).toEqual(ownerMetrics);
  });

  test("an unauthenticated caller can neither record nor read a measurement", async () => {
    const post = await fetch(`${BASE}/api/measurements`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        measurements: [
          { metricKey: "weight", value: "70", unit: "kg", measuredAt: "2026-08-07T07:30:00+01:00" },
        ],
      }),
    });
    expect(post.status).toBe(401);

    const anon = createClient(SUPABASE_URL, ANON_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const result = await anon.rpc("body_measurements", { p_limit: 10, p_offset: 0 });
    expect(result.error, "anon must not be able to read measurements").toBeTruthy();
  });
});
