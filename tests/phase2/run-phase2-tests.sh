#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Phase 2 exit-criterion suite.
#
#   10_pipeline_constraints.sql  walks one source row through the whole import
#                                chain as raw SQL, then attacks every
#                                constraint and invariant in turn.
#   20_rls_and_views.sql         RLS and canonical view isolation for two
#                                authenticated users.
#
# Rebuilds a throwaway database from the committed migrations and seeds first.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DB_NAME="${PHASE2_TEST_DB:-health_platform_phase2_test}"

if ! psql -X -q -d postgres -c 'select 1' >/dev/null 2>&1; then
  echo "ERROR: no reachable PostgreSQL server. Try: pg_ctlcluster 16 main start" >&2
  exit 1
fi

bash "${REPO_ROOT}/scripts/db-local-apply.sh" "${DB_NAME}"

for suite in 10_pipeline_constraints 20_rls_and_views; do
  echo ""
  echo "==> ${suite}"
  echo ""
  psql -X -q -v ON_ERROR_STOP=1 -d "${DB_NAME}" \
    -f "${REPO_ROOT}/tests/phase2/${suite}.sql" 2>&1 \
    | grep -Ev '^(SET|DO|BEGIN|COMMIT|ROLLBACK|INSERT [0-9]|SELECT [0-9]|UPDATE [0-9]|DELETE [0-9]|CREATE FUNCTION| pg_temp|-+|\([0-9]+ rows?\))$' \
    | grep -Ev '^\s*$' \
    | sed -E 's/^psql:[^ ]+ //; s/^NOTICE:  //'
done

echo ""
echo "==> Phase 2 suite completed successfully"
