#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Phase 5.1 exit-criterion suite.
#
#   10_g4_override.sql  G4 still blocks automatic retirement; an owner can
#                       override it through an audited, attributable,
#                       idempotent workflow; the analytics that follow stay
#                       equal to canonical truth; and G9 stays absolute.
#
# Rebuilds a throwaway database from the committed migrations and seeds first.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DB_NAME="${PHASE51_TEST_DB:-health_platform_phase51_test}"

if ! psql -X -q -d postgres -c 'select 1' >/dev/null 2>&1; then
  echo "ERROR: no reachable PostgreSQL server. Try: pg_ctlcluster 16 main start" >&2
  exit 1
fi

bash "${REPO_ROOT}/scripts/db-local-apply.sh" "${DB_NAME}"

for suite in 10_g4_override; do
  echo ""
  echo "==> ${suite}"
  echo ""
  psql -X -q -v ON_ERROR_STOP=1 -d "${DB_NAME}" \
    -f "${REPO_ROOT}/tests/phase5_1/${suite}.sql" 2>&1 \
    | grep -Ev '^(SET|DO|BEGIN|COMMIT|ROLLBACK|INSERT [0-9]|SELECT [0-9]|UPDATE [0-9]|DELETE [0-9]|CREATE FUNCTION| pg_temp|-+|\([0-9]+ rows?\))$' \
    | grep -Ev '^\s*$' \
    | sed -E 's/^psql:[^ ]+ //; s/^NOTICE:  //'
done

echo ""
echo "==> Phase 5.1 suite completed successfully"
