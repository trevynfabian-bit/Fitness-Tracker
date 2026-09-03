#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Phase 1 exit-criterion test: RLS user isolation with two authenticated users.
#
# Rebuilds a throwaway database from the committed migrations + seed, then runs
# tests/rls/10_isolation.sql. Every registry read and write in that file runs as
# the `authenticated` Postgres role with a JWT subject claim — the same context
# a Supabase client request executes in. The service role is never used to
# validate a policy.
#
# Requires a reachable PostgreSQL server and a superuser psql connection.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DB_NAME="${RLS_TEST_DB:-health_platform_rls_test}"

bash "${REPO_ROOT}/scripts/db-local-apply.sh" "${DB_NAME}"

echo ""
echo "==> running RLS isolation suite against ${DB_NAME}"
echo ""

psql -X -q -v ON_ERROR_STOP=1 -d "${DB_NAME}" \
  -f "${REPO_ROOT}/tests/rls/10_isolation.sql" 2>&1 \
  | grep -Ev '^(SET|DO|BEGIN|COMMIT|ROLLBACK|INSERT [0-9]|SELECT [0-9]|UPDATE [0-9]|DELETE [0-9])$' \
  | grep -Ev '^\s*$' \
  | sed -E 's/^psql:[^ ]+ //; s/^NOTICE:  //'

echo ""
echo "==> RLS isolation suite completed successfully"
