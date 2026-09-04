import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { expect, test, type Page } from "@playwright/test";

import { deleteAllMessages, waitForConfirmationLink } from "./mailpit";

/**
 * Phase 1 exit criteria, verified end to end against a real Supabase stack
 * (GoTrue auth, Kong, PostgREST) and the real application.
 *
 * Nothing here uses the service role. Every auth call goes through the
 * application UI or through @supabase/supabase-js with the anon key, and every
 * registry read and write carries a real user JWT.
 */

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;

const RUN = Date.now();
const USER_A = { email: `user-a-${RUN}@example.test`, password: "user-a-password-1" };
const USER_B = { email: `user-b-${RUN}@example.test`, password: "user-b-password-1" };

const KEY_A = `private_metric_a_${RUN}`;
const KEY_B = `private_metric_b_${RUN}`;

/** Ids captured during the run so each user can attempt to touch the other's rows. */
const owned = {
  a: { userId: "", definitionId: "" },
  b: { userId: "", definitionId: "" },
};

function anonClient(): SupabaseClient {
  return createClient(SUPABASE_URL, ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/** A supabase-js client holding a real user session, exactly as the app's would. */
async function signedInClient(credentials: {
  email: string;
  password: string;
}): Promise<{ client: SupabaseClient; userId: string }> {
  const client = anonClient();
  const { data, error } = await client.auth.signInWithPassword(credentials);
  expect(error, `sign-in failed for ${credentials.email}`).toBeNull();
  expect(data.session?.access_token).toBeTruthy();
  expect(data.user?.id).toBeTruthy();
  return { client, userId: data.user!.id };
}

async function signUpThroughUi(page: Page, user: { email: string; password: string }) {
  await page.goto("/signup");
  await page.getByLabel("Email").fill(user.email);
  await page.getByLabel("Password", { exact: true }).fill(user.password);
  await page.getByLabel("Confirm password").fill(user.password);
  await page.getByRole("button", { name: "Create account" }).click();
}

async function logInThroughUi(page: Page, user: { email: string; password: string }) {
  await page.goto("/login");
  await page.getByLabel("Email").fill(user.email);
  await page.getByLabel("Password", { exact: true }).fill(user.password);
  await page.getByRole("button", { name: "Sign in" }).click();
  await page.waitForURL("**/dashboard");
}

test.describe.configure({ mode: "serial" });

test.describe("Phase 1 — auth and RLS against a real Supabase project", () => {
  test.beforeAll(async () => {
    expect(SUPABASE_URL, "NEXT_PUBLIC_SUPABASE_URL must be set").toBeTruthy();
    expect(ANON_KEY, "NEXT_PUBLIC_SUPABASE_ANON_KEY must be set").toBeTruthy();
    await deleteAllMessages();
  });

  // -------------------------------------------------------------------------
  // Criterion 6 — unauthenticated access is refused
  // -------------------------------------------------------------------------

  test("C6 unauthenticated visitor is redirected away from protected routes", async ({
    page,
  }) => {
    await page.goto("/dashboard");
    await expect(page).toHaveURL(/\/login\?redirectTo=%2Fdashboard$/);
    await expect(page.getByRole("heading", { name: "Sign in" })).toBeVisible();

    await page.goto("/dashboard/settings");
    await expect(page).toHaveURL(/\/login\?redirectTo=%2Fdashboard%2Fsettings$/);

    await page.goto("/");
    await expect(page).toHaveURL(/\/login$/);
  });

  // -------------------------------------------------------------------------
  // Criteria 1 and 2 — real signup and real email confirmation
  // -------------------------------------------------------------------------

  test("C1+C2 user A signs up and confirms by email", async ({ page }) => {
    await signUpThroughUi(page, USER_A);

    await expect(page.getByRole("status")).toContainText(/confirmation link/i);

    // The account exists but has no session until the email is confirmed.
    const preConfirm = anonClient();
    const { error: preConfirmError } = await preConfirm.auth.signInWithPassword(USER_A);
    expect(preConfirmError?.message ?? "").toMatch(/not confirmed/i);

    const link = await waitForConfirmationLink(USER_A.email);
    expect(link).toContain("/auth/confirm?token_hash=");

    await page.goto(link);
    await page.waitForURL("**/dashboard");
    await expect(page.getByText(`Signed in as ${USER_A.email}`)).toBeVisible();
  });

  // -------------------------------------------------------------------------
  // Criteria 5 and 10 — protected route reachable, system registry readable
  // -------------------------------------------------------------------------

  test("C5+C10 authenticated user reaches the dashboard and reads the system registry", async ({
    page,
  }) => {
    await logInThroughUi(page, USER_A);

    await expect(page.getByRole("heading", { name: "Dashboard" })).toBeVisible();
    await expect(page.getByText(`Signed in as ${USER_A.email}`)).toBeVisible();

    for (const key of [
      "weight",
      "body_fat_percentage",
      "waist_circumference",
      "resting_heart_rate",
      "heart_rate_variability",
      "sleep_duration",
      "steps",
      "active_energy",
      "recovery_score",
    ]) {
      await expect(page.getByRole("cell", { name: key, exact: true })).toBeVisible();
    }

    await expect(page.getByRole("cell", { name: "system", exact: true })).toHaveCount(9);
  });

  // -------------------------------------------------------------------------
  // Criterion 4 — logout
  // -------------------------------------------------------------------------

  test("C4 user A signs out and loses access to the protected route", async ({ page }) => {
    await logInThroughUi(page, USER_A);

    await page.getByRole("button", { name: "Sign out" }).click();
    await page.waitForURL("**/login");
    await expect(page.getByRole("heading", { name: "Sign in" })).toBeVisible();

    await page.goto("/dashboard");
    await expect(page).toHaveURL(/\/login\?redirectTo=%2Fdashboard$/);
    await expect(page.getByText("Metric registry")).toHaveCount(0);
  });

  // -------------------------------------------------------------------------
  // Criterion 3 — user B signs up, confirms, and logs in
  // -------------------------------------------------------------------------

  test("C3 user B signs up, confirms and logs in", async ({ page }) => {
    await signUpThroughUi(page, USER_B);
    await expect(page.getByRole("status")).toContainText(/confirmation link/i);

    const link = await waitForConfirmationLink(USER_B.email);
    await page.goto(link);
    await page.waitForURL("**/dashboard");

    await page.getByRole("button", { name: "Sign out" }).click();
    await page.waitForURL("**/login");

    await logInThroughUi(page, USER_B);
    await expect(page.getByText(`Signed in as ${USER_B.email}`)).toBeVisible();
  });

  // -------------------------------------------------------------------------
  // Criteria 7 to 10 — RLS through the real Supabase client / PostgREST path
  // -------------------------------------------------------------------------

  test("C7 each user creates a private registry row through the Supabase client", async () => {
    for (const [label, credentials, key] of [
      ["a", USER_A, KEY_A],
      ["b", USER_B, KEY_B],
    ] as const) {
      const { client, userId } = await signedInClient(credentials);
      owned[label].userId = userId;

      const { data: unit, error: unitError } = await client
        .from("units")
        .select("id")
        .eq("key", "kg")
        .is("user_id", null)
        .single();
      expect(unitError, "system unit must be readable by an authenticated user").toBeNull();

      const { data: inserted, error: insertError } = await client
        .from("metric_definitions")
        .insert({
          user_id: userId,
          key,
          display_name: `Private metric ${label.toUpperCase()}`,
          canonical_unit_id: unit!.id,
          default_aggregation: "mean",
        })
        .select("id")
        .single();

      expect(insertError, `insert failed for user ${label}`).toBeNull();
      owned[label].definitionId = inserted!.id;
    }

    expect(owned.a.userId).not.toBe(owned.b.userId);
    expect(owned.a.definitionId).toBeTruthy();
    expect(owned.b.definitionId).toBeTruthy();
  });

  test("C8 user A cannot read user B's rows through the Supabase client", async () => {
    const { client, userId } = await signedInClient(USER_A);

    const { data: all, error } = await client
      .from("metric_definitions")
      .select("key, user_id");
    expect(error).toBeNull();

    const keys = (all ?? []).map((row) => row.key);
    expect(keys).toContain(KEY_A);
    expect(keys).not.toContain(KEY_B);

    const foreign = (all ?? []).filter(
      (row) => row.user_id !== null && row.user_id !== userId,
    );
    expect(foreign).toHaveLength(0);

    const { data: targeted } = await client
      .from("metric_definitions")
      .select("key")
      .eq("user_id", owned.b.userId);
    expect(targeted).toEqual([]);

    const { data: byId } = await client
      .from("metric_definitions")
      .select("key")
      .eq("id", owned.b.definitionId);
    expect(byId).toEqual([]);
  });

  test("C9 user B cannot read user A's rows through the Supabase client", async () => {
    const { client, userId } = await signedInClient(USER_B);

    const { data: all, error } = await client
      .from("metric_definitions")
      .select("key, user_id");
    expect(error).toBeNull();

    const keys = (all ?? []).map((row) => row.key);
    expect(keys).toContain(KEY_B);
    expect(keys).not.toContain(KEY_A);

    const foreign = (all ?? []).filter(
      (row) => row.user_id !== null && row.user_id !== userId,
    );
    expect(foreign).toHaveLength(0);

    const { data: targeted } = await client
      .from("metric_definitions")
      .select("key")
      .eq("user_id", owned.a.userId);
    expect(targeted).toEqual([]);
  });

  test("C10 system registry stays readable while user rows stay isolated", async () => {
    for (const [label, credentials, ownKey, otherKey] of [
      ["a", USER_A, KEY_A, KEY_B],
      ["b", USER_B, KEY_B, KEY_A],
    ] as const) {
      const { client } = await signedInClient(credentials);

      const { data, error } = await client
        .from("metric_definitions")
        .select("key, user_id");
      expect(error, `read failed for user ${label}`).toBeNull();

      const systemKeys = (data ?? []).filter((row) => row.user_id === null).map((r) => r.key);
      const userKeys = (data ?? []).filter((row) => row.user_id !== null).map((r) => r.key);

      expect(systemKeys.sort()).toEqual([
        "active_energy",
        "body_fat_percentage",
        "heart_rate_variability",
        "recovery_score",
        "resting_heart_rate",
        "sleep_duration",
        "steps",
        "waist_circumference",
        "weight",
      ]);
      expect(userKeys).toEqual([ownKey]);
      expect(userKeys).not.toContain(otherKey);
    }
  });

  test("write isolation holds through PostgREST", async () => {
    const { client } = await signedInClient(USER_A);

    // Forging another user's user_id is rejected by the insert policy.
    const { data: unit } = await client
      .from("units")
      .select("id")
      .eq("key", "kg")
      .is("user_id", null)
      .single();

    const { error: forgeError } = await client.from("metric_definitions").insert({
      user_id: owned.b.userId,
      key: `forged_${RUN}`,
      display_name: "Forged",
      canonical_unit_id: unit!.id,
      default_aggregation: "mean",
    });
    expect(forgeError?.code).toBe("42501");

    // Writing a system row is rejected by the same policy.
    const { error: systemInsertError } = await client.from("metric_definitions").insert({
      user_id: null,
      key: `orphan_${RUN}`,
      display_name: "Orphan",
      canonical_unit_id: unit!.id,
      default_aggregation: "mean",
    });
    expect(systemInsertError?.code).toBe("42501");

    // Updating and deleting another user's row affect nothing.
    const { data: updated } = await client
      .from("metric_definitions")
      .update({ display_name: "Hijacked" })
      .eq("id", owned.b.definitionId)
      .select("id");
    expect(updated).toEqual([]);

    const { data: deleted } = await client
      .from("metric_definitions")
      .delete()
      .eq("id", owned.b.definitionId)
      .select("id");
    expect(deleted).toEqual([]);

    // Cross-user parent reference is blocked by the ownership trigger.
    // alias_normalized must already be in normalized form (lowercase, no
    // punctuation, single spaces); the value below is.
    const { error: aliasError } = await client.from("metric_aliases").insert({
      user_id: owned.a.userId,
      metric_definition_id: owned.b.definitionId,
      alias_normalized: `stolen alias ${RUN}`,
    });
    expect(aliasError?.code).toBe("42501");
  });

  test("an unauthenticated Supabase client is denied outright", async () => {
    const { error } = await anonClient().from("metric_definitions").select("key");
    expect(error?.code).toBe("42501");
    expect(error?.message).toMatch(/permission denied/i);
  });

  // -------------------------------------------------------------------------
  // Criteria 8 to 10 again, this time through the application UI
  // -------------------------------------------------------------------------

  test("C8+C9 the dashboard shows each user only their own registry row", async ({
    page,
  }) => {
    await logInThroughUi(page, USER_A);
    await expect(page.getByRole("cell", { name: KEY_A, exact: true })).toBeVisible();
    await expect(page.getByRole("cell", { name: KEY_B, exact: true })).toHaveCount(0);
    await expect(page.getByRole("cell", { name: "yours", exact: true })).toHaveCount(1);
    await expect(page.getByRole("cell", { name: "weight", exact: true })).toBeVisible();

    await page.getByRole("button", { name: "Sign out" }).click();
    await page.waitForURL("**/login");

    await logInThroughUi(page, USER_B);
    await expect(page.getByRole("cell", { name: KEY_B, exact: true })).toBeVisible();
    await expect(page.getByRole("cell", { name: KEY_A, exact: true })).toHaveCount(0);
    await expect(page.getByRole("cell", { name: "yours", exact: true })).toHaveCount(1);
    await expect(page.getByRole("cell", { name: "weight", exact: true })).toBeVisible();
  });
});
