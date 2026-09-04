#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Phase 4 exit-criterion suite.
#
#   10_read_model.sql  builds a canonical training history for two users and a
#                      third empty account, then asserts every read-model
#                      function against it as the authenticated role.
#   20_scale.sql       hard gate D: the same functions over 2,000 workouts and
#                      30,000 sets, timed, with the paging contract re-checked
#                      at that size.
#
# Rebuilds a throwaway database from the committed migrations and seeds first.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DB_NAME="${PHASE4_TEST_DB:-health_platform_phase4_test}"

if ! psql -X -q -d postgres -c 'select 1' >/dev/null 2>&1; then
  echo "ERROR: no reachable PostgreSQL server. Try: pg_ctlcluster 16 main start" >&2
  exit 1
fi

bash "${REPO_ROOT}/scripts/db-local-apply.sh" "${DB_NAME}"

for suite in 10_read_model 20_scale; do
  echo ""
  echo "==> ${suite}"
  echo ""
  psql -X -q -v ON_ERROR_STOP=1 -d "${DB_NAME}" \
    -f "${REPO_ROOT}/tests/phase4/${suite}.sql" 2>&1 \
    | grep -Ev '^(SET|DO|BEGIN|COMMIT|ROLLBACK|INSERT [0-9]|SELECT [0-9]|UPDATE [0-9]|DELETE [0-9]|CREATE FUNCTION| pg_temp|-+|\([0-9]+ rows?\))$' \
    | grep -Ev '^\s*$' \
    | sed -E 's/^psql:[^ ]+ //; s/^NOTICE:  //'
done

echo ""
echo "==> Phase 4 suite completed successfully"
