import { defineConfig } from "@playwright/test";

const PORT = Number(process.env.E2E_PORT ?? 3000);
const BASE_URL = `http://127.0.0.1:${PORT}`;

/**
 * End-to-end configuration for the Phase 1 auth + RLS suite.
 *
 * The suite drives the real application against a real Supabase stack
 * (GoTrue, PostgREST, Kong). Run it through tests/e2e/run-e2e-tests.sh, which
 * exports the stack's URL and anon key first.
 */
export default defineConfig({
  testDir: "./tests/e2e",
  fullyParallel: false,
  workers: 1,
  timeout: 90_000,
  expect: { timeout: 15_000 },
  reporter: [["list"]],
  use: {
    baseURL: BASE_URL,
    trace: "retain-on-failure",
    launchOptions: {
      // This environment ships a pre-installed Chromium that may not match the
      // revision @playwright/test would download. Point at it explicitly when
      // PLAYWRIGHT_CHROMIUM_PATH is set; otherwise use Playwright's own.
      ...(process.env.PLAYWRIGHT_CHROMIUM_PATH
        ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_PATH }
        : {}),
    },
  },
  webServer: {
    command: `npx next build && npx next start -p ${PORT}`,
    url: `${BASE_URL}/login`,
    reuseExistingServer: false,
    timeout: 240_000,
    stdout: "ignore",
    stderr: "pipe",
  },
});
