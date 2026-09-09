#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Phase 5 exit-criterion suite.
#
#   10_analytics.sql   canonical-vs-derived correctness, provenance, retirement,
#                      idempotency, corrections, failure recovery, concurrency,
#                      isolation, and a full rebuild from canonical truth.
#   20_benchmark.sql   the same read-model questions asked both ways over one
#                      large dataset: the Phase 4 query-time path and the
#                      Phase 5 derived path, timed on the same machine.
#
# Rebuilds a throwaway database from the committed migrations and seeds first.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DB_NAME="${PHASE5_TEST_DB:-health_platform_phase5_test}"

if ! psql -X -q -d postgres -c 'select 1' >/dev/null 2>&1; then
  echo "ERROR: no reachable PostgreSQL server. Try: pg_ctlcluster 16 main start" >&2
  exit 1
fi

bash "${REPO_ROOT}/scripts/db-local-apply.sh" "${DB_NAME}"

for suite in 10_analytics 20_benchmark; do
  echo ""
  echo "==> ${suite}"
  echo ""
  psql -X -q -v ON_ERROR_STOP=1 -d "${DB_NAME}" \
    -f "${REPO_ROOT}/tests/phase5/${suite}.sql" 2>&1 \
    | grep -Ev '^(SET|DO|BEGIN|COMMIT|ROLLBACK|TRUNCATE|INSERT [0-9]|SELECT [0-9]|UPDATE [0-9]|DELETE [0-9]|CREATE FUNCTION| pg_temp|-+|\([0-9]+ rows?\))$' \
    | grep -Ev '^\s*$' \
    | sed -E 's/^psql:[^ ]+ //; s/^NOTICE:  //'
done

echo ""
echo "==> Phase 5 suite completed successfully"
