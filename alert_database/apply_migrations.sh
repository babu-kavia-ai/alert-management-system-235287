#!/bin/bash
set -euo pipefail

# Apply migrations and seed data for the alert management system.
# Uses the connection string stored in db_connection.txt per container convention.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONN_FILE="${ROOT_DIR}/db_connection.txt"

if [ ! -f "${CONN_FILE}" ]; then
  echo "ERROR: db_connection.txt not found at: ${CONN_FILE}"
  echo "Start the database first (startup.sh) to generate it."
  exit 1
fi

CONN_CMD="$(cat "${CONN_FILE}")"

echo "Using connection: ${CONN_CMD}"

# Ensure migration tracking table exists
${CONN_CMD} -c "CREATE TABLE IF NOT EXISTS schema_migrations (version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());"

apply_sql_file() {
  local file_path="$1"
  local version="$2"

  local applied
  applied="$(${CONN_CMD} -t -A -c "SELECT 1 FROM schema_migrations WHERE version='${version}'" || true)"

  if [ "${applied}" = "1" ]; then
    echo "✓ Skipping ${version} (already applied)"
    return 0
  fi

  echo "→ Applying ${version} from ${file_path}"
  ${CONN_CMD} -v ON_ERROR_STOP=1 -f "${file_path}"
  ${CONN_CMD} -c "INSERT INTO schema_migrations(version) VALUES ('${version}') ON CONFLICT DO NOTHING;"
  echo "✓ Applied ${version}"
}

apply_sql_file "${ROOT_DIR}/migrations/001_init_schema.sql" "001_init_schema"
apply_sql_file "${ROOT_DIR}/seed/001_seed_data.sql" "seed_001_seed_data"

echo "All migrations and seed data applied successfully."
