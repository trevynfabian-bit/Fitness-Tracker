#!/usr/bin/env bash
# Phase 3 Step 0 safety suite. Rebuilds a throwaway database from the committed
# migrations and seeds, then proves the ownership, guard and alias rules.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DB_NAME="${STEP0_TEST_DB:-health_platform_step0_test}"

if ! psql -X -q -d postgres -c 'select 1' >/dev/null 2>&1; then
  echo "ERROR: no reachable PostgreSQL server. Try: pg_ctlcluster 16 main start" >&2
  exit 1
fi

bash "${REPO_ROOT}/scripts/db-local-apply.sh" "${DB_NAME}"
echo ""
psql -X -q -v ON_ERROR_STOP=1 -d "${DB_NAME}" -f "${REPO_ROOT}/tests/phase3/10_step0_safety.sql" 2>&1 \
  | grep -Ev '^(SET|DO|BEGIN|COMMIT|ROLLBACK|INSERT [0-9]|SELECT [0-9]|UPDATE [0-9]|DELETE [0-9]|CREATE FUNCTION| rejects|-+|\([0-9]+ rows?\))$' \
  | grep -Ev '^\s*$' \
  | sed -E 's/^psql:[^ ]+ //; s/^NOTICE:  //'
echo ""
echo "==> Phase 3 Step 0 suite completed successfully"
