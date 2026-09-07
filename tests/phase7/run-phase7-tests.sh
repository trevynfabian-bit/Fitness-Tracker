#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Phase 7 exit-criterion suite.
#
#   10_metrics_rollup.sql     the metrics rollup domain: invalidation, the
#                             dispatch, tier 1 and tier 2, precedence,
#                             retirement, idempotence, cross-domain isolation
#                             and the security surface.
#   20_chart_read_model.sql   the chart layer: every range, every gap policy,
#                             the minimum-observation gate and the
#                             zero-baseline guard.
#
# Rebuilds a throwaway database from the committed migrations and seeds first.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DB_NAME="${PHASE7_TEST_DB:-health_platform_phase7_test}"

if ! psql -X -q -d postgres -c 'select 1' >/dev/null 2>&1; then
  echo "ERROR: no reachable PostgreSQL server. Try: pg_ctlcluster 16 main start" >&2
  exit 1
fi

bash "${REPO_ROOT}/scripts/db-local-apply.sh" "${DB_NAME}"

for suite in 10_metrics_rollup 20_chart_read_model; do
  echo ""
  echo "==> ${suite}"
  echo ""
  psql -X -q -v ON_ERROR_STOP=1 -d "${DB_NAME}" \
    -f "${REPO_ROOT}/tests/phase7/${suite}.sql" 2>&1 \
    | grep -Ev '^(SET|DO|BEGIN|COMMIT|ROLLBACK|INSERT [0-9]|SELECT [0-9]|UPDATE [0-9]|DELETE [0-9]|CREATE FUNCTION|ALTER TABLE| pg_temp|-+|\([0-9]+ rows?\))$' \
    | grep -Ev '^\s*$' \
    | sed -E 's/^psql:[^ ]+ //; s/^NOTICE:  //'
done

echo ""
echo "==> Phase 7 suite completed successfully"
