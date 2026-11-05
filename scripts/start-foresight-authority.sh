#!/bin/bash
# Start a local Foresight authority for live consumer cutover rehearsal.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PORT="${FORESIGHT_PORT:-4011}"
HOST="${FORESIGHT_HOST:-127.0.0.1}"
DATABASE_URL="${FORESIGHT_DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/foresight_live_authority_dev}"
SERVICE_API_KEY="${FORESIGHT_SERVICE_API_KEY:-foresight-service-key}"

ensure_database() {
  local db_name
  db_name="${DATABASE_URL##*/}"

  command -v createdb >/dev/null 2>&1 || return 0
  command -v psql >/dev/null 2>&1 || return 0

  if psql "$DATABASE_URL" -c 'select 1' >/dev/null 2>&1; then
    return 0
  fi

  echo "Creating scratch Postgres database: $db_name"
  createdb "$db_name" >/dev/null
}

ensure_database

cd "$PROJECT_DIR"

export FORESIGHT_PORT="$PORT"
export FORESIGHT_HOST="$HOST"
export FORESIGHT_DATABASE_URL="$DATABASE_URL"
export FORESIGHT_SERVICE_API_KEY="$SERVICE_API_KEY"

echo "Starting local Foresight authority..."
echo "  Project: $PROJECT_DIR"
echo "  URL: http://$HOST:$PORT"
echo "  Database: $DATABASE_URL"
echo "  Service key: $SERVICE_API_KEY"
echo ""

mix run --no-halt scripts/start-foresight-authority.exs
