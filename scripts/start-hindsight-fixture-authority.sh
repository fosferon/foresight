#!/bin/bash
# Start a local hindsight-api authority for Foresight live fixture recording.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Root of a Hindsight checkout containing hindsight-api/. Defaults to the
# sibling hindsight/ directory next to this repository; override with
# HINDSIGHT_ROOT if your checkout lives elsewhere.
HINDSIGHT_ROOT="${HINDSIGHT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)/hindsight}"
HINDSIGHT_API_DIR="${HINDSIGHT_API_DIR:-$HINDSIGHT_ROOT/hindsight-api}"
PORT="${HINDSIGHT_PORT:-8888}"
HOST="${HINDSIGHT_HOST:-127.0.0.1}"
FIXTURE_API_KEY="${HINDSIGHT_FIXTURE_API_KEY:-sk-foresight-fixtures-dev}"
DATABASE_URL="${HINDSIGHT_API_DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/foresight_hindsight_dev}"

# shellcheck source=scripts/lib/hindsight-guard.sh
source "$SCRIPT_DIR/lib/hindsight-guard.sh"

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

configure_provider() {
  if [[ -n "${OPENROUTER_API_KEY:-}" && "${HINDSIGHT_USE_LMSTUDIO:-0}" != "1" ]]; then
    export HINDSIGHT_API_LLM_PROVIDER="${HINDSIGHT_API_LLM_PROVIDER:-openai}"
    export HINDSIGHT_API_LLM_BASE_URL="${HINDSIGHT_API_LLM_BASE_URL:-https://openrouter.ai/api/v1}"
    export HINDSIGHT_API_LLM_API_KEY="${HINDSIGHT_API_LLM_API_KEY:-$OPENROUTER_API_KEY}"
    export HINDSIGHT_API_LLM_MODEL="${HINDSIGHT_API_LLM_MODEL:-openai/gpt-4o-mini}"
    export HINDSIGHT_API_REFLECT_LLM_PROVIDER="${HINDSIGHT_API_REFLECT_LLM_PROVIDER:-openai}"
    export HINDSIGHT_API_REFLECT_LLM_BASE_URL="${HINDSIGHT_API_REFLECT_LLM_BASE_URL:-https://openrouter.ai/api/v1}"
    export HINDSIGHT_API_REFLECT_LLM_API_KEY="${HINDSIGHT_API_REFLECT_LLM_API_KEY:-$OPENROUTER_API_KEY}"
    export HINDSIGHT_API_REFLECT_LLM_MODEL="${HINDSIGHT_API_REFLECT_LLM_MODEL:-anthropic/claude-sonnet-4.6}"
    export HINDSIGHT_API_REFLECT_LLM_TIMEOUT="${HINDSIGHT_API_REFLECT_LLM_TIMEOUT:-120}"
    PROVIDER_LABEL="OpenRouter"
  else
    export HINDSIGHT_API_LLM_PROVIDER="${HINDSIGHT_API_LLM_PROVIDER:-openai}"
    export HINDSIGHT_API_LLM_BASE_URL="${HINDSIGHT_API_LLM_BASE_URL:-${LMSTUDIO_BASE_URL:-http://127.0.0.1:1234/v1}}"
    export HINDSIGHT_API_LLM_API_KEY="${HINDSIGHT_API_LLM_API_KEY:-${LMSTUDIO_API_KEY:-lm-studio}}"
    export HINDSIGHT_API_LLM_MODEL="${HINDSIGHT_API_LLM_MODEL:-${LMSTUDIO_MODEL:-local-model}}"

    # FAIRNESS: the matched-model Foresight-vs-Hindsight scoreboard is only
    # trustworthy if Hindsight runs REFLECT and CONSOLIDATION on the SAME reader
    # as its primary LLM (e.g. a local gpt-oss). Hindsight resolves these as
    # SEPARATE families; if left unset they fall back to library defaults (a
    # different/unconfigured model), silently comparing two different readers.
    # Default each family to the resolved LLM_* values; explicit overrides still win.
    export HINDSIGHT_API_REFLECT_LLM_PROVIDER="${HINDSIGHT_API_REFLECT_LLM_PROVIDER:-$HINDSIGHT_API_LLM_PROVIDER}"
    export HINDSIGHT_API_REFLECT_LLM_BASE_URL="${HINDSIGHT_API_REFLECT_LLM_BASE_URL:-$HINDSIGHT_API_LLM_BASE_URL}"
    export HINDSIGHT_API_REFLECT_LLM_API_KEY="${HINDSIGHT_API_REFLECT_LLM_API_KEY:-$HINDSIGHT_API_LLM_API_KEY}"
    export HINDSIGHT_API_REFLECT_LLM_MODEL="${HINDSIGHT_API_REFLECT_LLM_MODEL:-$HINDSIGHT_API_LLM_MODEL}"
    export HINDSIGHT_API_REFLECT_LLM_TIMEOUT="${HINDSIGHT_API_REFLECT_LLM_TIMEOUT:-300}"

    export HINDSIGHT_API_CONSOLIDATION_LLM_PROVIDER="${HINDSIGHT_API_CONSOLIDATION_LLM_PROVIDER:-$HINDSIGHT_API_LLM_PROVIDER}"
    export HINDSIGHT_API_CONSOLIDATION_LLM_BASE_URL="${HINDSIGHT_API_CONSOLIDATION_LLM_BASE_URL:-$HINDSIGHT_API_LLM_BASE_URL}"
    export HINDSIGHT_API_CONSOLIDATION_LLM_API_KEY="${HINDSIGHT_API_CONSOLIDATION_LLM_API_KEY:-$HINDSIGHT_API_LLM_API_KEY}"
    export HINDSIGHT_API_CONSOLIDATION_LLM_MODEL="${HINDSIGHT_API_CONSOLIDATION_LLM_MODEL:-$HINDSIGHT_API_LLM_MODEL}"
    export HINDSIGHT_API_CONSOLIDATION_LLM_TIMEOUT="${HINDSIGHT_API_CONSOLIDATION_LLM_TIMEOUT:-300}"

    PROVIDER_LABEL="LMStudio (reader+reflect+consolidation: $HINDSIGHT_API_LLM_MODEL)"
  fi
}

ensure_database
configure_provider

cd "$HINDSIGHT_API_DIR"

export HINDSIGHT_API_DATABASE_URL="$DATABASE_URL"
export HINDSIGHT_API_TENANT_EXTENSION="hindsight_api.extensions.builtin.tenant:ApiKeyTenantExtension"
export HINDSIGHT_API_TENANT_API_KEY="$FIXTURE_API_KEY"
export HG_HEALTH_PATH="${HG_HEALTH_PATH:-/health}"

echo "Starting local Hindsight for Foresight fixture capture..."
echo "  Project: $PROJECT_DIR"
echo "  Hindsight API dir: $HINDSIGHT_API_DIR"
echo "  URL: http://$HOST:$PORT"
echo "  Database: $DATABASE_URL"
echo "  API key: $FIXTURE_API_KEY"
echo "  Provider: $PROVIDER_LABEL"
echo ""
echo "Recorder command:"
echo "  HINDSIGHT_FIXTURE_BASE_URL=http://$HOST:$PORT HINDSIGHT_FIXTURE_API_KEY=$FIXTURE_API_KEY mix foresight.record_floor_fixtures"
echo ""

hindsight_guarded_start "$PORT" --host "$HOST"
