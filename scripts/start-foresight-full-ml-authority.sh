#!/bin/bash
# Start a local full-ML Foresight authority for real embedding/reranking/reflect qualification.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PORT="${FORESIGHT_PORT:-4012}"
HOST="${FORESIGHT_HOST:-127.0.0.1}"
DATABASE_URL="${FORESIGHT_DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/foresight_full_ml_authority_dev}"
SERVICE_API_KEY="${FORESIGHT_SERVICE_API_KEY:-foresight-service-key}"
LOCAL_ML_BACKEND="${FORESIGHT_LOCAL_ML_BACKEND:-sentence_transformers}"
# Path to a Python 3 with sentence-transformers installed — typically the venv
# from a Hindsight checkout, e.g. <hindsight>/.venv/bin/python3. Override with
# FORESIGHT_ML_PYTHON; the bare python3 default only works when that
# interpreter already carries the ML stack.
ML_PYTHON="${FORESIGHT_ML_PYTHON:-python3}"
PRELOAD_LOCAL_MODELS="${FORESIGHT_PRELOAD_LOCAL_MODELS:-1}"

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
export FORESIGHT_LOCAL_ML_BACKEND="$LOCAL_ML_BACKEND"
export FORESIGHT_PRELOAD_LOCAL_MODELS="$PRELOAD_LOCAL_MODELS"

if [[ "$LOCAL_ML_BACKEND" == "sentence_transformers" ]]; then
  export FORESIGHT_ML_PYTHON="$ML_PYTHON"
fi

echo "Starting local Foresight full-ML authority..."
echo "  Project: $PROJECT_DIR"
echo "  URL: http://$HOST:$PORT"
echo "  Database: $DATABASE_URL"
echo "  Service key: $SERVICE_API_KEY"
echo "  Local ML backend: $LOCAL_ML_BACKEND"
echo "  Preload local models: $PRELOAD_LOCAL_MODELS"

if [[ "$LOCAL_ML_BACKEND" == "sentence_transformers" ]]; then
  echo "  Python executable: $FORESIGHT_ML_PYTHON"
fi

echo ""
echo "Real ML qualification notes:"
echo "  - embedder/reranker run locally through the configured backend"
echo "  - reflect runs through FORESIGHT_LLM_PROVIDER / FORESIGHT_LLM_BASE_URL / FORESIGHT_LLM_MODEL"
echo ""

mix run --no-halt scripts/start-foresight-full-ml-authority.exs
