#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Phase 1 exit-criterion test: protected routes reject unauthenticated access.
#
# Builds the application, starts the production server and asserts the HTTP
# responses an unauthenticated visitor receives.
#
# This test does not need a live Supabase project: with no session cookie there
# is no token for the auth server to verify, so the middleware's getUser() call
# resolves locally to "no user". The Supabase URL/key below only have to be
# well-formed enough to pass env validation. If NEXT_PUBLIC_SUPABASE_URL is
# already exported, the real project is used instead.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

PORT="${ROUTE_TEST_PORT:-3111}"
export NEXT_PUBLIC_SUPABASE_URL="${NEXT_PUBLIC_SUPABASE_URL:-https://route-protection-test.supabase.co}"
export NEXT_PUBLIC_SUPABASE_ANON_KEY="${NEXT_PUBLIC_SUPABASE_ANON_KEY:-route-protection-test-anon-key}"
export NEXT_PUBLIC_SITE_URL="${NEXT_PUBLIC_SITE_URL:-http://127.0.0.1:${PORT}}"

echo "==> building"
npx next build >/dev/null

echo "==> starting server on port ${PORT}"
npx next start -p "$PORT" >/tmp/route-protection-server.log 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do
  if curl -sS -o /dev/null "http://127.0.0.1:${PORT}/login" 2>/dev/null; then
    break
  fi
  sleep 1
done

failures=0

assert_redirect() {
  local path="$1" expected_location="$2"
  local out status location
  out="$(curl -sS -o /dev/null -D - "http://127.0.0.1:${PORT}${path}")"
  status="$(printf '%s' "$out" | head -n1 | awk '{print $2}')"
  location="$(printf '%s' "$out" | grep -i '^location:' | tr -d '\r' | sed 's/^[Ll]ocation: *//')"

  if [[ "$status" != "307" && "$status" != "302" ]]; then
    echo "FAIL  ${path} -> HTTP ${status}, expected a redirect"
    failures=$((failures + 1))
    return
  fi
  if [[ "$location" != "$expected_location" ]]; then
    echo "FAIL  ${path} -> redirected to '${location}', expected '${expected_location}'"
    failures=$((failures + 1))
    return
  fi
  echo "PASS  ${path} -> ${status} ${location}"
}

assert_status() {
  local path="$1" expected="$2"
  local status
  status="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}${path}")"
  if [[ "$status" != "$expected" ]]; then
    echo "FAIL  ${path} -> HTTP ${status}, expected ${expected}"
    failures=$((failures + 1))
    return
  fi
  echo "PASS  ${path} -> HTTP ${status}"
}

assert_body_absent() {
  local path="$1" needle="$2"
  if curl -sSL "http://127.0.0.1:${PORT}${path}" | grep -qi -- "$needle"; then
    echo "FAIL  ${path} body contains '${needle}'"
    failures=$((failures + 1))
    return
  fi
  echo "PASS  ${path} body does not contain '${needle}'"
}

echo ""
echo "==> unauthenticated access to protected routes"
assert_redirect "/dashboard"          "/login?redirectTo=%2Fdashboard"
assert_redirect "/dashboard/settings" "/login?redirectTo=%2Fdashboard%2Fsettings"
assert_redirect "/registry"           "/login?redirectTo=%2Fregistry"
assert_redirect "/history"            "/login?redirectTo=%2Fhistory"
assert_redirect "/history/abc"        "/login?redirectTo=%2Fhistory%2Fabc"
assert_redirect "/exercises"          "/login?redirectTo=%2Fexercises"
assert_redirect "/exercises/abc"      "/login?redirectTo=%2Fexercises%2Fabc"
assert_redirect "/settings"           "/login?redirectTo=%2Fsettings"
assert_redirect "/import"             "/login?redirectTo=%2Fimport"
assert_redirect "/"                   "/login"

echo ""
echo "==> public routes remain reachable"
assert_status "/login"  "200"
assert_status "/signup" "200"

echo ""
echo "==> protected content is never served to an unauthenticated visitor"
assert_body_absent "/dashboard" "Training frequency"
assert_body_absent "/dashboard" "Sign out"
assert_body_absent "/history"   "Workout history"
assert_body_absent "/exercises" "Every exercise you have actually performed"
assert_body_absent "/settings"  "Metric registry"

echo ""
if [[ "$failures" -ne 0 ]]; then
  echo "================================================================"
  echo " ROUTE PROTECTION SUITE: ${failures} assertion(s) FAILED"
  echo "================================================================"
  exit 1
fi

echo "================================================================"
echo " ROUTE PROTECTION SUITE: all assertions passed"
echo "================================================================"
