#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Rebuilds a local PostgreSQL database from scratch and applies, in order:
#   1. the Supabase auth shim (test harness only — Supabase supplies this)
#   2. every migration in supabase/migrations, in filename order
#   3. the system registry seed
#
# This exists because `supabase start` needs a Docker daemon. It runs the same
# SQL files a Supabase project runs, against a real Postgres server, so the
# schema, constraints, triggers and RLS policies are genuinely exercised.
#
# Usage:  scripts/db-local-apply.sh [database_name]
# Env:    PSQL_ADMIN_DB  maintenance database to connect to (default: postgres)
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_NAME="${1:-${LOCAL_DB_NAME:-health_platform_local}}"
ADMIN_DB="${PSQL_ADMIN_DB:-postgres}"

PSQL="psql -v ON_ERROR_STOP=1 -X -q"

echo "==> dropping and recreating database: ${DB_NAME}"
$PSQL -d "$ADMIN_DB" -c "drop database if exists \"${DB_NAME}\" with (force);" >/dev/null
$PSQL -d "$ADMIN_DB" -c "create database \"${DB_NAME}\";" >/dev/null

echo "==> applying auth shim (harness only)"
$PSQL -d "$DB_NAME" -f "${REPO_ROOT}/tests/rls/harness/00_supabase_auth_shim.sql"

echo "==> applying migrations"
for migration in "${REPO_ROOT}"/supabase/migrations/*.sql; do
  echo "    - $(basename "$migration")"
  $PSQL -d "$DB_NAME" -f "$migration"
done

echo "==> applying system registry seed"
$PSQL -d "$DB_NAME" -f "${REPO_ROOT}/supabase/seeds/0001_system_registry.sql"

echo "==> re-applying seed to prove idempotency"
$PSQL -d "$DB_NAME" -f "${REPO_ROOT}/supabase/seeds/0001_system_registry.sql"

echo "==> done: ${DB_NAME}"
