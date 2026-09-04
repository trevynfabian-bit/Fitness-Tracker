import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { expect, test, type Page } from "@playwright/test";

import { deleteAllMessages, waitForConfirmationLink } from "./mailpit";

/**
 * Phase 4 hard gates, in a real browser against a real Supabase stack.
 *
 *   Gate A  product flow: import -> dashboard -> history -> workout detail ->
 *           exercise explorer -> exercise progression.
 *   Gate B  empty state: a new account shows no charts and no fabricated
 *           zeros, and offers the one action that changes that.
 *   Gate C  data isolation: a second user asking for the first user's workout
 *           and exercise by uuid sees nothing.
 *   Gate D  pagination: the history page renders one server-side page and its
 *           offset window is addressable. (The same paging contract at 2,000
 *           workouts is asserted in tests/phase4/20_scale.sql.)
 *
 * Every user action goes through the UI under that user's own session. The
 * service key is used only to read back ids for the isolation attempt, never
 * to make the application work.
 */

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const SERVICE_KEY = process.env.E2E_SERVICE_ROLE_KEY!;
const WORKER_SECRET = process.env.IMPORT_WORKER_SECRET!;
const BASE = process.env.E2E_BASE_URL ?? "http://127.0.0.1:3000";

const RUN = Date.now();
const OWNER = { email: `p4-owner-${RUN}@example.test`, password: "phase-4-owner-password-1" };
const OTHER = { email: `p4-other-${RUN}@example.test`, password: "phase-4-other-password-1" };

const EXPORT = "tests/fixtures/hevy/hevy-export-extended.csv";

let admin: SupabaseClient;
let ownerId = "";
let ownerWorkoutId = "";
let ownerExerciseDefinitionId = "";

async function runWorker(): Promise<void> {
  for (let tick = 0; tick < 30; tick += 1) {
    const response = await fetch(`${BASE}/api/worker`, {
      method: "POST",
      headers: { "x-worker-secret": WORKER_SECRET },
    });
    expect(response.status, "worker invocation").toBe(200);
    const body = (await response.json()) as { batches: number; failed: unknown[] };
    expect(body.failed, `worker batch failed: ${JSON.stringify(body.failed)}`).toHaveLength(0);
    if (body.batches === 0) break;
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

/** Each Playwright test gets a fresh browser context, so each signs in again. */
async function logIn(page: Page, user: { email: string; password: string }) {
  await page.goto("/login");
  await page.getByLabel("Email").fill(user.email);
  await page.getByLabel("Password", { exact: true }).fill(user.password);
  await page.getByRole("button", { name: "Sign in" }).click();
  await page.waitForURL("**/dashboard");
}

test.describe.configure({ mode: "serial" });

test.describe("Phase 4 — the product surface", () => {
  test.beforeAll(async () => {
    expect(SUPABASE_URL && SERVICE_KEY && WORKER_SECRET).toBeTruthy();
    admin = createClient(SUPABASE_URL, SERVICE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
  });

  // =========================================================================
  // GATE B — the empty state
  // =========================================================================

  test("GATE B: a new account shows an empty state, not zero-filled analytics", async ({
    page,
  }) => {
    await signUpAndConfirm(page, OWNER);
    const { data } = await admin.auth.admin.listUsers();
    ownerId = data.users.find((u) => u.email === OWNER.email)!.id;
    expect(ownerId).toBeTruthy();

    await expect(page.getByRole("heading", { name: "No training data yet" })).toBeVisible();
    await expect(page.getByRole("link", { name: "Import training data" })).toBeVisible();

    // No chart, no stat tiles, no fabricated totals of any kind.
    await expect(page.getByText("Training frequency")).toHaveCount(0);
    await expect(page.getByText("Volume trend")).toHaveCount(0);
    await expect(page.getByText("Total volume")).toHaveCount(0);
    await expect(page.locator("svg.recharts-surface")).toHaveCount(0);

    await page.goto("/history");
    await expect(page.getByRole("heading", { name: "No training data yet" })).toBeVisible();

    await page.goto("/exercises");
    await expect(page.getByRole("heading", { name: "No exercises yet" })).toBeVisible();
  });

  // =========================================================================
  // GATE A — the product flow, end to end from a real import
  // =========================================================================

  test("GATE A: an import through the real engine populates the product", async ({ page }) => {
    await logIn(page, OWNER);
    await page.goto("/import");
    await page.setInputFiles("#file", EXPORT);
    await expect(page.getByText("Preview", { exact: true })).toBeVisible({ timeout: 30_000 });
    await page.getByRole("button", { name: "Confirm and import" }).click();
    await page.waitForURL("**/import/**");

    await runWorker();
    await page.reload();
    await expect(page.getByText(/status (completed|completed_with_errors)/)).toBeVisible({
      timeout: 20_000,
    });

    // 11 workouts, all normalized from the file. Verified through the database
    // so the UI assertions below are checked against a known truth.
    const { data: workouts } = await admin
      .from("strength_workouts")
      .select("id, local_date, title")
      .eq("user_id", ownerId)
      .is("retired_at", null)
      .order("local_date", { ascending: false });
    expect(workouts).toHaveLength(11);
    ownerWorkoutId = workouts![0]!.id as string;

    const { data: exercises } = await admin
      .from("strength_exercises")
      .select("exercise_definition_id, exercise_name_raw")
      .eq("user_id", ownerId);
    ownerExerciseDefinitionId = exercises!.find(
      (e) => e.exercise_name_raw === "Bench Press (Barbell)",
    )!.exercise_definition_id as string;
    expect(ownerExerciseDefinitionId).toBeTruthy();
  });

  test("GATE A: the dashboard reports the imported history", async ({ page }) => {
    await logIn(page, OWNER);

    await expect(page.getByRole("heading", { name: "No training data yet" })).toHaveCount(0);

    // Overview tiles, read from the read model rather than recomputed per tile.
    const workoutTile = page.locator("div", { hasText: /^Workouts/ }).last();
    await expect(workoutTile).toContainText("11");
    await expect(page.getByText("Total volume")).toBeVisible();

    // Both charts render, each as a single-series chart with a table view.
    await expect(page.getByRole("heading", { name: "Training frequency" })).toBeVisible();
    await expect(page.getByRole("heading", { name: "Volume trend" })).toBeVisible();
    expect(await page.locator("svg.recharts-surface").count()).toBeGreaterThanOrEqual(2);
    await expect(
      page.getByText(/Volume is weight × reps, summed over sets recording both/),
    ).toBeVisible();

    // Recent activity, and the route into the full history.
    await expect(page.getByRole("heading", { name: "Recent activity" })).toBeVisible();
    await expect(page.getByRole("link", { name: /See all 11/ })).toBeVisible();
  });

  test("GATE A: history lists every session newest first and opens one", async ({ page }) => {
    await logIn(page, OWNER);
    await page.goto("/history");

    await expect(page.getByRole("heading", { name: "Workout history" })).toBeVisible();
    await expect(page.getByText("Showing 1–11 of 11 workouts")).toBeVisible();

    const items = page.locator("main ul > li");
    await expect(items).toHaveCount(11);
    // Newest first: the last session in the file is 30 January 2026.
    await expect(items.first()).toContainText("30 Jan 2026");
    await expect(items.last()).toContainText("5 Jan 2026");

    await items.first().getByRole("link").click();
    await page.waitForURL("**/history/**");
    await expect(page.getByRole("heading", { name: "Legs" })).toBeVisible();
  });

  test("GATE A: a workout detail renders only the columns its sets carry", async ({ page }) => {
    await logIn(page, OWNER);
    // The Legs session on 9 January contains a barbell squat and a loaded carry
    // recorded with distance and duration but no reps.
    const { data: legs } = await admin
      .from("strength_workouts")
      .select("id")
      .eq("user_id", ownerId)
      .eq("local_date", "2026-01-09")
      .single();
    await page.goto(`/history/${legs!.id}`);

    await expect(page.getByRole("heading", { name: "Legs" })).toBeVisible();
    await expect(page.getByText("9 January 2026")).toBeVisible();

    const squat = page.locator("article", {
      has: page.getByRole("heading", { name: "Squat (Barbell)" }),
    });
    await expect(squat.getByRole("columnheader", { name: "Weight" })).toBeVisible();
    await expect(squat.getByRole("columnheader", { name: "Reps" })).toBeVisible();
    await expect(squat.getByRole("columnheader", { name: "Volume" })).toBeVisible();
    await expect(squat.getByRole("columnheader", { name: "Distance" })).toHaveCount(0);
    // The warmup set keeps its type rather than being flattened into the rest.
    await expect(squat.getByText("warmup")).toBeVisible();

    const carry = page.locator("article", {
      has: page.getByRole("heading", { name: "Farmers Walk (Dumbbell)" }),
    });
    await expect(carry.getByRole("columnheader", { name: "Distance" })).toBeVisible();
    await expect(carry.getByRole("columnheader", { name: "Duration" })).toBeVisible();
    // No reps were recorded, so there is no reps column and no volume column:
    // the strength shape is never forced onto a set that does not carry it.
    await expect(carry.getByRole("columnheader", { name: "Reps" })).toHaveCount(0);
    await expect(carry.getByRole("columnheader", { name: "Volume" })).toHaveCount(0);
    await expect(carry.getByText("40 m")).toBeVisible();
    await expect(carry.getByText("45s")).toBeVisible();
  });

  test("GATE A: the exercise explorer and a load progression", async ({ page }) => {
    await logIn(page, OWNER);
    await page.goto("/exercises");

    await expect(page.getByRole("heading", { name: "Exercises" })).toBeVisible();
    await expect(page.getByRole("link", { name: /Bench Press \(Barbell\)/ })).toBeVisible();

    await page.goto(`/exercises/${ownerExerciseDefinitionId}`);
    await expect(page.getByRole("heading", { name: "Bench Press (Barbell)" })).toBeVisible();
    await expect(page.getByText("Load × reps", { exact: true })).toBeVisible();

    // Four sessions, which is above the floor, so the load progression is drawn
    // and the session volume gets its own chart rather than a second y axis.
    await expect(page.getByRole("heading", { name: "Heaviest set" })).toBeVisible();
    await expect(page.getByRole("heading", { name: "Session volume" })).toBeVisible();
    expect(await page.locator("svg.recharts-surface").count()).toBe(2);

    await expect(page.getByRole("heading", { name: "Sessions" })).toBeVisible();
    await expect(page.getByRole("columnheader", { name: "Top set" })).toBeVisible();
    await expect(page.getByRole("columnheader", { name: "Distance" })).toHaveCount(0);
  });

  test("GATE A: a distance exercise is compared on distance, never on load", async ({ page }) => {
    await logIn(page, OWNER);
    const { data: carry } = await admin
      .from("strength_exercises")
      .select("exercise_definition_id")
      .eq("user_id", ownerId)
      .eq("exercise_name_raw", "Farmers Walk (Dumbbell)")
      .limit(1)
      .single();

    await page.goto(`/exercises/${carry!.exercise_definition_id}`);
    await expect(page.getByRole("heading", { name: "Farmers Walk (Dumbbell)" })).toBeVisible();
    // Weight is recorded but reps are not, so this is not load progression.
    await expect(page.getByText("Distance", { exact: true }).first()).toBeVisible();
    await expect(page.getByRole("heading", { name: "Distance per session" })).toBeVisible();
    await expect(page.getByRole("heading", { name: "Heaviest set" })).toHaveCount(0);
    await expect(page.getByRole("heading", { name: "Session volume" })).toHaveCount(0);
  });

  test("GATE A: an exercise with too few sessions is refused, not drawn", async ({ page }) => {
    await logIn(page, OWNER);
    // Overhead Press appears in one session only.
    const { data: ohp } = await admin
      .from("strength_exercises")
      .select("exercise_definition_id")
      .eq("user_id", ownerId)
      .eq("exercise_name_raw", "Overhead Press (Barbell)")
      .limit(1)
      .single();

    await page.goto(`/exercises/${ohp!.exercise_definition_id}`);
    await expect(page.getByText(/No progression is drawn for this exercise/)).toBeVisible();
    await expect(page.getByText(/A progression needs at least 3/)).toBeVisible();
    await expect(page.locator("svg.recharts-surface")).toHaveCount(0);
  });

  // =========================================================================
  // GATE D — pagination
  // =========================================================================

  test("GATE D: history renders one server-side page and its window is addressable", async ({
    page,
  }) => {
    await logIn(page, OWNER);

    await page.goto("/history?offset=5");
    await expect(page.getByText("Showing 6–11 of 11 workouts")).toBeVisible();
    // Only the window is rendered; the rest of the history is not in the page.
    await expect(page.locator("main ul > li")).toHaveCount(6);
    const previous = page.getByRole("link", { name: "Previous" });
    await expect(previous).toHaveAttribute("href", "/history");
    await expect(page.getByRole("link", { name: "Next" })).toHaveCount(0);

    // Wait for hydration to settle before clicking: an App Router Link clicked
    // mid-hydration can be swallowed, which is a test race rather than a
    // product defect. The href assertion above is what proves the control.
    await page.waitForLoadState("networkidle");
    await previous.click();
    await page.waitForURL((url) => !url.searchParams.has("offset"));
    await expect(page.getByText("Showing 1–11 of 11 workouts")).toBeVisible();

    // A filter narrows the server-side query rather than the rendered list.
    await page.goto("/history?from=2026-01-01&to=2026-01-09");
    await expect(page.getByText("Showing 1–3 of 3 workouts")).toBeVisible();
    await expect(page.locator("main ul > li")).toHaveCount(3);
  });

  // =========================================================================
  // GATE C — data isolation between two users
  // =========================================================================

  test("GATE C: a second user sees none of the first user's training data", async ({ page }) => {
    expect(ownerWorkoutId, "the owner's workout id").toBeTruthy();
    expect(ownerExerciseDefinitionId, "the owner's exercise id").toBeTruthy();

    await signUpAndConfirm(page, OTHER);

    // Its own dashboard is empty, which is the truth for this account.
    await expect(page.getByRole("heading", { name: "No training data yet" })).toBeVisible();

    // Asking for the other user's workout by uuid: not found, and the page
    // says nothing about whether that id exists for somebody else.
    await page.goto(`/history/${ownerWorkoutId}`);
    await expect(page.getByRole("heading", { name: "Not found" })).toBeVisible();
    await expect(page.getByText("Legs")).toHaveCount(0);
    await expect(page.getByText("Push Day")).toHaveCount(0);

    await page.goto(`/exercises/${ownerExerciseDefinitionId}`);
    await expect(page.getByRole("heading", { name: "Not found" })).toBeVisible();
    await expect(page.getByText("Heaviest set")).toHaveCount(0);

    await page.goto("/history");
    await expect(page.getByRole("heading", { name: "No training data yet" })).toBeVisible();

    await page.goto("/exercises");
    await expect(page.getByRole("heading", { name: "No exercises yet" })).toBeVisible();
  });

  test("GATE C: the read model itself refuses, not merely the page", async () => {
    // The same attempt one level below the UI: a real user session calling the
    // read model directly with the other user's uuid. RLS, not the React tree,
    // is what makes this empty.
    const anon = createClient(SUPABASE_URL, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { error: signInError } = await anon.auth.signInWithPassword({
      email: OTHER.email,
      password: OTHER.password,
    });
    expect(signInError).toBeNull();

    const detail = await anon.rpc("training_workout_detail", { p_workout_id: ownerWorkoutId });
    expect(detail.error).toBeNull();
    expect(detail.data).toBeNull();

    const progression = await anon.rpc("training_exercise_progression", {
      p_exercise_definition_id: ownerExerciseDefinitionId,
    });
    expect(progression.error).toBeNull();
    expect(progression.data).toEqual([]);

    const summaries = await anon.rpc("training_workout_summaries", { p_limit: 100, p_offset: 0 });
    expect(summaries.error).toBeNull();
    expect(summaries.data).toEqual([]);

    const overview = await anon.rpc("training_overview");
    expect(overview.error).toBeNull();
    expect(Number((overview.data as { total_workouts: number }[])[0]!.total_workouts)).toBe(0);

    await anon.auth.signOut();
  });

  test("GATE C: an unauthenticated caller cannot reach the read model at all", async () => {
    // EXECUTE on a function is granted to PUBLIC by default; the migration
    // revokes it. Without this the anon key could call the read model and rely
    // on RLS alone to return nothing.
    const anon = createClient(SUPABASE_URL, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const result = await anon.rpc("training_overview");
    expect(result.error, "anon must be refused, not merely filtered").toBeTruthy();
    expect(result.data).toBeNull();
  });
});
