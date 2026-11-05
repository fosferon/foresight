# shellcheck shell=bash
# Hardened startup helpers for local hindsight-api operator scripts.

readonly HG_EXIT_PORT_BUSY=10
readonly HG_EXIT_ALREADY_MANAGED=11
readonly HG_EXIT_HEALTH_FAILED=12
readonly HG_EXIT_ZOMBIES=13
readonly HG_EXIT_PRECOND=14

_HG_CHILD=""
_HG_PIDFILE=""
_HG_LOCKFILE=""
_HG_LOCK_FD=""

hg_err() { printf 'ERROR: %s\n' "$*" >&2; }

hg_pidfile() { printf '/tmp/hindsight-api-%s.pid' "$1"; }
hg_lockfile() { printf '/tmp/hindsight-api-%s.lock' "$1"; }

hg_require() {
  command -v "$1" >/dev/null 2>&1 && return 0
  hg_err "required command '$1' not found on PATH."
  hg_err "Remediation: install it / fix PATH, then retry."
  exit "$HG_EXIT_PRECOND"
}

hg_cleanup() {
  trap - SIGINT SIGTERM EXIT
  if [[ -n "$_HG_CHILD" ]] && kill -0 "$_HG_CHILD" 2>/dev/null; then
    kill -TERM -- "-$_HG_CHILD" 2>/dev/null || kill -TERM "$_HG_CHILD" 2>/dev/null
    for _ in 1 2 3 4 5; do
      kill -0 "$_HG_CHILD" 2>/dev/null || break
      sleep 0.3
    done
    kill -KILL -- "-$_HG_CHILD" 2>/dev/null || kill -KILL "$_HG_CHILD" 2>/dev/null || true
  fi
  [[ -n "$_HG_PIDFILE" ]] && rm -f "$_HG_PIDFILE"
  if [[ -n "$_HG_LOCK_FD" ]]; then
    eval "exec ${_HG_LOCK_FD}>&-" 2>/dev/null || true
  fi
}

hg_preflight() {
  local port="$1"
  _HG_PIDFILE="$(hg_pidfile "$port")"
  _HG_LOCKFILE="$(hg_lockfile "$port")"

  if command -v flock >/dev/null 2>&1; then
    exec {_HG_LOCK_FD}>"$_HG_LOCKFILE"
    if ! flock -n "$_HG_LOCK_FD"; then
      hg_err "hindsight-api on port $port is already being started/managed (lock $_HG_LOCKFILE held)."
      hg_err "Remediation: stop the existing instance first, or remove the lock if you're sure it's dead."
      exit "$HG_EXIT_ALREADY_MANAGED"
    fi
  fi

  if [[ -f "$_HG_PIDFILE" ]]; then
    local oldpid
    oldpid="$(cat "$_HG_PIDFILE" 2>/dev/null)"
    if [[ -n "$oldpid" ]] && kill -0 "$oldpid" 2>/dev/null; then
      local started
      started="$(ps -o lstart= -p "$oldpid" 2>/dev/null | xargs)"
      hg_err "hindsight-api on port $port already managed by PID $oldpid (started ${started:-unknown})."
      hg_err "Remediation: stop it first — kill $oldpid   (or: rm $_HG_PIDFILE if you're sure it's dead)."
      exit "$HG_EXIT_ALREADY_MANAGED"
    fi
    rm -f "$_HG_PIDFILE"
  fi

  local binder
  binder="$( { lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true; } | head -1 )"
  if [[ -n "$binder" ]]; then
    local pname
    pname="$(ps -o comm= -p "$binder" 2>/dev/null | xargs)"
    hg_err "port $port already in use by PID $binder (process ${pname:-unknown})."
    hg_err "Remediation: kill $binder   — or stop the existing service first."
    exit "$HG_EXIT_PORT_BUSY"
  fi

  local zombies
  zombies="$( { pgrep -f "hindsight-api --port $port" 2>/dev/null || true; } | xargs )"
  if [[ -n "$zombies" ]]; then
    hg_err "zombie hindsight-api processes detected (PIDs: $zombies)."
    hg_err "Remediation: pkill -9 -f 'hindsight-api --port $port'   to clear them, then retry."
    exit "$HG_EXIT_ZOMBIES"
  fi
}

hindsight_guarded_start() {
  local port="$1"
  shift
  local health_path="${HG_HEALTH_PATH:-/healthz}"

  hg_require uv
  hg_require lsof
  hg_require curl
  hg_require pgrep

  hg_preflight "$port"

  trap hg_cleanup SIGINT SIGTERM EXIT

  set -m
  uv run hindsight-api --port "$port" "$@" &
  _HG_CHILD=$!
  set +m

  printf '%s' "$_HG_CHILD" > "$_HG_PIDFILE"

  local healthy=0 _
  for _ in $(seq 1 30); do
    if ! kill -0 "$_HG_CHILD" 2>/dev/null; then
      hg_err "hindsight-api (PID $_HG_CHILD) exited during startup on port $port."
      hg_err "Remediation: re-run and read the traceback above; check DB URL / provider config."
      exit "$HG_EXIT_HEALTH_FAILED"
    fi
    if curl -fsS "http://127.0.0.1:$port$health_path" >/dev/null 2>&1; then
      healthy=1
      break
    fi
    sleep 1
  done

  if [[ "$healthy" -ne 1 ]]; then
    hg_err "health probe failed — http://127.0.0.1:$port$health_path not OK after 30s."
    hg_err "Remediation: process will now be stopped; inspect logs and retry."
    exit "$HG_EXIT_HEALTH_FAILED"
  fi

  echo "✅ hindsight-api healthy on http://127.0.0.1:$port$health_path  (PID $_HG_CHILD, pidfile $_HG_PIDFILE)"
  echo "   Press Ctrl-C to stop — the whole process group will be cleaned up."

  wait "$_HG_CHILD"
}
