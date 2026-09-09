import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { expect, test, type Page } from "@playwright/test";

import { deleteAllMessages, waitForConfirmationLink } from "./mailpit";

/**
 * Phase 7 — body and recovery charts, end to end.
 *
 * The exit criterion is the whole path, so the whole path is walked here:
 *
 *   type a measurement in the UI
 *     -> a raw record and a canonical metric exist
 *     -> the metrics rollup scope for that day was enqueued
 *     -> the worker processed it
 *     -> metric_daily holds the value
 *     -> the chart on /body draws it
 *
 * and then the derived layer is destroyed and rebuilt through the real worker
 * endpoint, to prove the chart is reading metric_daily rather than reaching
 * past it to canonical data.
 *
 * Everything the user does goes through the UI. The service key is used only
 * to read back rows and to destroy the derived layer, never to stand in for a
 * user's own reads: every isolation assertion below is made through a real
 * authenticated session.
 */

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const SERVICE_KEY = process.env.E2E_SERVICE_ROLE_KEY!;
const WORKER_SECRET = process.env.IMPORT_WORKER_SECRET!;
const BASE = process.env.E2E_BASE_URL ?? "http://127.0.0.1:3000";

const RUN = Date.now();
const OWNER = { email: `p7-owner-${RUN}@example.test`, password: "phase-7-owner-password-1" };
const OTHER = { email: `p7-other-${RUN}@example.test`, password: "phase-7-other-password-1" };

let admin: SupabaseClient;
let ownerId = "";

/**
 * Dates relative to today, because the ranges are anchored on today.
 *
 * A fixture on fixed calendar dates would drift out of the 7-day window the
 * day after it was written and the test would start passing for the wrong
 * reason.
 */
function daysAgo(n: number): string {
  const d = new Date();
  d.setDate(d.getDate() - n);
  const y = d.getFullYear();
  const m = `${d.getMonth() + 1}`.padStart(2, "0");
  const day = `${d.getDate()}`.padStart(2, "0");
  return `${y}-${m}-${day}`;
}

/** Midday, so a timezone offset can never move the measurement to another day. */
const at = (n: number) => `${daysAgo(n)}T12:00`;

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

/**
 * Records one measurement and waits for it to actually land.
 *
 * The wait is on the recorded-measurements list, not on the page heading: the
 * heading is already visible before the click, so asserting it would return
 * immediately and the next navigation would abort the in-flight request.
 */
async function record(page: Page, metric: string, value: string, when: string, unit = "kg") {
  await page.goto("/body");
  const before = await page.locator("main ul > li").count();
  await page.selectOption("#metric", metric);
  await page.fill("#measured-at", when);
  await page.fill("#value", value);
  await page.selectOption("#unit", unit);
  await page.getByRole("button", { name: "Record measurement" }).click();
  await expect(page.locator("main ul > li")).toHaveCount(before + 1, { timeout: 30_000 });
}

async function metricDaily(userId: string, metricKey: string) {
  const { data } = await admin
    .from("metric_daily")
    .select("metric_key, local_date, value, count, winning_source")
    .eq("user_id", userId)
    .eq("metric_key", metricKey)
    .order("local_date");
  return data ?? [];
}

async function rollupScopes(userId: string, domain: string) {
  const { data } = await admin
    .from("rollup_queue")
    .select("domain, local_date, state, reason")
    .eq("user_id", userId)
    .eq("domain", domain)
    .order("local_date");
  return data ?? [];
}

test.describe.configure({ mode: "serial" });

test.describe("Phase 7 — body and recovery charts", () => {
  test.beforeAll(async () => {
    expect(SUPABASE_URL && ANON_KEY && SERVICE_KEY && WORKER_SECRET).toBeTruthy();
    admin = createClient(SUPABASE_URL, SERVICE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
  });

  test("GATE: an empty account shows an empty state, not a zero-filled chart", async ({
    page,
  }) => {
    await signUpAndConfirm(page, OWNER);
    const { data } = await admin.auth.admin.listUsers();
    ownerId = data.users.find((u) => u.email === OWNER.email)!.id;
    expect(ownerId).toBeTruthy();

    await page.goto("/body");
    await expect(page.getByTestId("charts-empty")).toBeVisible();
    await expect(page.getByTestId("metric-card-weight")).toHaveCount(0);

    // The range control is present even with nothing to draw: it says which
    // window you are looking at, which an empty account still needs.
    await expect(page.getByRole("group", { name: "Chart range" })).toBeVisible();
  });

  test("GATE: a typed measurement travels the whole path to metric_daily", async ({ page }) => {
    await logIn(page, OWNER);

    await record(page, "weight", "82.4", at(6));
    await record(page, "weight", "82.0", at(3));
    await record(page, "weight", "81.6", at(0));

    // The canonical rows exist, and they exist because raw records do (I-1).
    const { data: raw } = await admin
      .from("raw_records")
      .select("id, precedence_rank, normalize_status")
      .eq("user_id", ownerId);
    expect(raw!.length).toBe(3);
    expect(raw!.every((r) => r.normalize_status === "ok")).toBe(true);

    const { data: canonical } = await admin
      .from("v_metrics")
      .select("metric_key, local_date, value_num")
      .eq("user_id", ownerId)
      .eq("metric_key", "weight")
      .order("local_date");
    expect(canonical!.length).toBe(3);

    // The metrics rollup domain was invalidated for exactly those three days.
    const scopes = await rollupScopes(ownerId, "metrics");
    expect(scopes.length).toBe(3);
    expect(scopes.map((s) => s.local_date)).toEqual([daysAgo(6), daysAgo(3), daysAgo(0)]);
    expect(scopes.every((s) => s.reason === "import")).toBe(true);
    // Processed, not merely queued: manual entry drains inline.
    expect(scopes.every((s) => s.state === "done")).toBe(true);

    // And metric_daily holds the resolved values.
    const daily = await metricDaily(ownerId, "weight");
    expect(daily.map((d) => d.local_date)).toEqual([daysAgo(6), daysAgo(3), daysAgo(0)]);
    expect(Number(daily[0]!.value)).toBeCloseTo(82.4, 6);
    expect(Number(daily[2]!.value)).toBeCloseTo(81.6, 6);
    expect(daily.every((d) => d.winning_source === "manual")).toBe(true);
  });

  test("GATE: the chart on /body draws the value that reached metric_daily", async ({ page }) => {
    await logIn(page, OWNER);
    await page.goto("/body?range=30D");

    await expect(page.getByTestId("charts-empty")).toHaveCount(0);
    const card = page.getByTestId("metric-card-weight");
    await expect(card).toBeVisible();

    // The headline is the latest measurement, and the change is shown because
    // three observations clear the gate.
    await expect(card).toContainText("81.6 kg");
    await expect(card).toContainText(/-0\.8 kg/);
    await expect(card.getByTestId("insufficient-weight")).toHaveCount(0);

    // The table behind the disclosure is the accessibility path, and it is the
    // same numbers the chart draws.
    await card.getByText("View measurements as a table").click();
    await expect(card.locator("table")).toContainText("82.40");
    await expect(card.locator("table")).toContainText("81.60");
  });

  test("GATE: too few measurements are refused, not drawn", async ({ page }) => {
    await logIn(page, OWNER);
    await record(page, "heart_rate_variability", "62", at(4), "ms");

    await page.goto("/body?range=30D");
    const card = page.getByTestId("metric-card-heart_rate_variability");
    await expect(card).toBeVisible();
    // The measurement itself is shown; only the trend is withheld.
    await expect(card).toContainText("62.0 ms");
    await expect(card.getByTestId("insufficient-heart_rate_variability")).toContainText(
      "1 measurement in this range. A trend needs at least 3.",
    );
  });

  test("GATE: every range is addressable and changes the window", async ({ page }) => {
    await logIn(page, OWNER);

    // The links carry the full label as their accessible name and the short
    // code visually, so the assertion uses the name a screen reader would.
    const LABELS: Record<string, string> = {
      "7D": "7 days",
      "30D": "30 days",
      "90D": "90 days",
      "1Y": "1 year",
      ALL: "All time",
    };

    for (const [range, label] of Object.entries(LABELS)) {
      await page.goto(`/body?range=${range}`);
      await expect(page.getByRole("heading", { name: "Body", exact: true })).toBeVisible();
      await expect(page.getByRole("link", { name: label, exact: true })).toHaveAttribute(
        "aria-current",
        "true",
      );
      await expect(page.getByTestId("metric-card-weight")).toBeVisible();
    }

    // The window is real, not decorative: 7 days reaches back to the reading
    // from six days ago and includes it.
    await page.goto("/body?range=7D");
    const card = page.getByTestId("metric-card-weight");
    await card.getByText("View measurements as a table").click();
    await expect(card.locator("table")).toContainText("82.40");

    // An unrecognised range falls back to the default rather than erroring.
    await page.goto("/body?range=nonsense");
    await expect(page.getByRole("heading", { name: "Body", exact: true })).toBeVisible();
    await expect(page.getByRole("link", { name: "90 days", exact: true })).toHaveAttribute(
      "aria-current",
      "true",
    );
  });

  test("GATE: a correction moves the chart, through the pipeline", async ({ page }) => {
    await logIn(page, OWNER);
    await page.goto("/body?range=30D");

    // Correct today's weight through the UI's own correction path. The row is
    // located by its value rather than by position, so a change in list
    // ordering cannot silently correct a different measurement.
    const row = page.locator("li").filter({ hasText: "81.6" }).first();
    await row.getByRole("button", { name: "Correct" }).click();
    await row.locator("#value").fill("80.9");
    await row.getByRole("button", { name: "Record correction" }).click();
    await expect(
      page.locator("main ul > li").filter({ hasText: "corrected" }),
    ).toBeVisible({ timeout: 30_000 });

    const daily = await metricDaily(ownerId, "weight");
    const today = daily.find((d) => d.local_date === daysAgo(0))!;
    expect(Number(today.value)).toBeCloseTo(80.9, 6);

    await page.goto("/body?range=30D");
    await expect(page.getByTestId("metric-card-weight")).toContainText("80.9 kg");
  });

  test("GATE: the chart reads metric_daily, and the worker rebuilds it", async ({ page }) => {
    // Destroy the derived layer. If the chart were reaching past it to
    // canonical metrics, this would change nothing and the test would be
    // meaningless.
    const { error } = await admin.from("metric_daily").delete().eq("user_id", ownerId);
    expect(error).toBeNull();
    await admin.from("metric_daily_source").delete().eq("user_id", ownerId);
    expect(await metricDaily(ownerId, "weight")).toHaveLength(0);

    await logIn(page, OWNER);
    await page.goto("/body?range=30D");
    await expect(page.getByTestId("charts-empty")).toBeVisible();

    // Rebuild through the real worker endpoint, authorised by the worker
    // secret rather than by the session.
    const response = await fetch(`${BASE}/api/worker/rebuild`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-worker-secret": WORKER_SECRET },
      body: JSON.stringify({ userId: ownerId }),
    });
    expect(response.status).toBe(200);
    const body = (await response.json()) as { rollup: { processed: number; failed: number } };
    expect(body.rollup.failed).toBe(0);
    expect(body.rollup.processed).toBeGreaterThan(0);

    const daily = await metricDaily(ownerId, "weight");
    expect(daily).toHaveLength(3);
    expect(Number(daily.find((d) => d.local_date === daysAgo(0))!.value)).toBeCloseTo(80.9, 6);

    await page.goto("/body?range=30D");
    await expect(page.getByTestId("charts-empty")).toHaveCount(0);
    await expect(page.getByTestId("metric-card-weight")).toContainText("80.9 kg");
  });

  test("GATE: a second user sees none of the first user's series", async ({ page }) => {
    await signUpAndConfirm(page, OTHER);

    await page.goto("/body?range=30D");
    await expect(page.getByTestId("charts-empty")).toBeVisible();
    await expect(page.getByTestId("metric-card-weight")).toHaveCount(0);
    await expect(page.locator("body")).not.toContainText("80.9");
    await expect(page.locator("body")).not.toContainText("82.4");
  });

  test("GATE: the read model itself refuses, not merely the page", async () => {
    // The other user's own authenticated client, calling the chart functions
    // directly. They take no user id, so this is exactly the call the first
    // user's page makes; only the session differs. Row level security is the
    // only thing standing between them.
    const asOther = createClient(SUPABASE_URL, ANON_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { error: signInError } = await asOther.auth.signInWithPassword({
      email: OTHER.email,
      password: OTHER.password,
    });
    expect(signInError).toBeNull();

    const { data, error } = await asOther.rpc("body_metric_series", {
      p_metric_keys: ["weight"],
      p_from: daysAgo(30),
      p_to: daysAgo(0),
    });
    expect(error).toBeNull();
    // 31 days of rows, every one of them unobserved: the first user's
    // measurements are not merely hidden from the page, they are not returned.
    const rows = data as { observed: boolean }[];
    expect(rows.length).toBe(31);
    expect(rows.every((row) => row.observed === false)).toBe(true);

    const { data: summary } = await asOther.rpc("body_metric_summary", {
      p_metric_keys: ["weight"],
      p_from: daysAgo(30),
      p_to: daysAgo(0),
      p_min_observations: 3,
    });
    const first = (summary as { observation_count: number; sufficient: boolean }[])[0]!;
    expect(Number(first.observation_count)).toBe(0);
    expect(first.sufficient).toBe(false);
  });

  test("GATE: an unauthenticated caller cannot reach the chart read model at all", async () => {
    const anon = createClient(SUPABASE_URL, ANON_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { error } = await anon.rpc("body_metric_series", {
      p_metric_keys: ["weight"],
      p_from: daysAgo(30),
      p_to: daysAgo(0),
    });
    expect(error).not.toBeNull();
  });
});
