#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Phase 1 exit-criterion test: real auth and real RLS, end to end.
#
# Drives the built application in a real browser against a running Supabase
# stack (GoTrue, Kong, PostgREST, Postgres) and asserts every Phase 1 exit
# criterion. Signup, email confirmation, login and logout are performed through
# the application UI. Registry reads and writes go through @supabase/supabase-js
# with the anon key and a real user JWT.
#
# The service role key is never read by this script or by the suite.
#
# Prerequisites: `supabase start` must have been run (this script verifies it).
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

if ! npx supabase status >/dev/null 2>&1; then
  cat >&2 <<'MSG'
ERROR: the local Supabase stack is not running.

Start it first:

    npx supabase start

That requires a running Docker daemon. To point this suite at a hosted project
instead, export NEXT_PUBLIC_SUPABASE_URL, NEXT_PUBLIC_SUPABASE_ANON_KEY and
MAILPIT_URL (or disable email confirmation on that project) before running.
MSG
  exit 1
fi

if [[ -z "${NEXT_PUBLIC_SUPABASE_URL:-}" ]]; then
  STATUS_ENV="$(npx supabase status -o env)"
  eval "$STATUS_ENV"
  export NEXT_PUBLIC_SUPABASE_URL="${API_URL}"
  export NEXT_PUBLIC_SUPABASE_ANON_KEY="${ANON_KEY}"
  export MAILPIT_URL="${MAILPIT_URL:-http://127.0.0.1:54324}"
  # Phase 3 needs two more, and they are scoped deliberately:
  #   SUPABASE_SERVICE_ROLE_KEY  the worker's elevated connection. Normalization
  #                              is the sanctioned canonical write path and the
  #                              client roles hold SELECT only (I-4, RD-3).
  #   E2E_SERVICE_ROLE_KEY       verification reads in the spec only. Every user
  #                              action in the spec still goes through the UI.
  export SUPABASE_SERVICE_ROLE_KEY="${SERVICE_ROLE_KEY}"
  export E2E_SERVICE_ROLE_KEY="${SERVICE_ROLE_KEY}"
  export IMPORT_WORKER_SECRET="${IMPORT_WORKER_SECRET:-local-e2e-worker-secret}"
  unset SERVICE_ROLE_KEY SECRET_KEY JWT_SECRET DB_URL
fi

# Use a pre-installed Chromium when one is present and Playwright has not
# downloaded its own matching revision.
if [[ -z "${PLAYWRIGHT_CHROMIUM_PATH:-}" && -x "/opt/pw-browsers/chromium" ]]; then
  export PLAYWRIGHT_CHROMIUM_PATH="/opt/pw-browsers/chromium"
fi

export E2E_PORT="${E2E_PORT:-3000}"
export NEXT_PUBLIC_SITE_URL="http://127.0.0.1:${E2E_PORT}"
export E2E_BASE_URL="http://127.0.0.1:${E2E_PORT}"

echo "==> Supabase API : ${NEXT_PUBLIC_SUPABASE_URL}"
echo "==> Mail capture : ${MAILPIT_URL}"
echo "==> App under test: ${NEXT_PUBLIC_SITE_URL}"
echo ""

npx playwright test "$@"
