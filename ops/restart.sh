#!/usr/bin/env bash
# Restart the TRACTION API server SAFELY.
#
#   ops/restart.sh          # keep the graph
#   ops/restart.sh --clean  # wipe the graph too (after a schema change)
#
# -----------------------------------------------------------------------------
# THE 500 THIS SCRIPT EXISTS TO PREVENT
# -----------------------------------------------------------------------------
# Symptom: every request returns
#   {"detail":"'JacScaleUserManager' object has no attribute '_lock'"}
# and the server never recovers. To a dashboard it looks like a freeze, not an
# error. Root cause, read out of the jaclang 0.34.7 runtime source that ships
# inside the `jac` binary (~/.cache/jac/rt/*/site/jaclang), not guessed:
#
#  1. jaclang ALWAYS loads its `scale` subsystem. `jac0core/runtime.jac:85
#     def _scale_provider` is a bare `try { import jaclang.scale.plugin }
#     except ImportError { }`, and scale ships inside the binary, so the import
#     never fails. It is NOT gated on jac.toml. Deleting [scale.websocket]
#     changes nothing - A/B verified, 60/60 requests green both ways, and the
#     WebSocket routes register either way. Do not "fix" this by editing
#     jac.toml; that trades away nothing and gains nothing.
#
#  2. So the server's user manager is always JacScaleUserManager. Its postinit
#     (scale/identity/impl/user_manager.impl.jac:1) overrides
#     UserManager.postinit and never calls it - and the parent
#     (runtimelib/impl/server.impl.jac:12) is the only place that ever sets
#     `self._lock = threading.RLock()`. The scale user manager therefore has no
#     `_lock` attribute at all, from boot, permanently.
#
#  3. That stays harmless until the guest root id recorded in
#     .jac/data/users.db is absent from .jac/data/anchor_store.db. Then every
#     request takes the guest self-heal branch in
#     runtimelib/impl/server.impl.jac:271:
#         "Guest root anchor <id> is missing from the anchor store"
#          -> user_manager.reset_root()      <- NOT overridden by the subclass
#          -> `with self._lock { ... }`
#          -> AttributeError -> HTTP 500
#     reset_root IS the repair path, so it can never repair itself. Bricked
#     until the on-disk divergence is fixed from outside.
#
# The two files diverge whenever one is replaced without the other - exactly
# what a surviving `jac start` racing `rm -rf .jac/data` does. Hence:
#   (1) kill completely and WAIT before touching the data dir,
#   (2) detect the divergence BEFORE serving and repair it,
#   (3) smoke-test after boot, and self-repair once if a 500 still gets out.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${PORT:-8000}"
LOG="${LOG:-/tmp/traction-server.log}"
DATA=".jac/data"
# Lives above .jac/data so it survives a `rm -rf .jac/data`.
LOCK=".jac/serving.lock"
# macOS always ships /usr/bin/sqlite3; prefer it over whatever conda put first
# on PATH so the preflight behaves the same on every machine.
SQLITE="$( [ -x /usr/bin/sqlite3 ] && echo /usr/bin/sqlite3 || command -v sqlite3 || true )"

# -----------------------------------------------------------------------------
# who is holding this data dir?
# -----------------------------------------------------------------------------
# The real hazard is not "another server on my port", it is ANY second process
# with .jac/data open - `jac run`, `jac test`, a stray server on another port.
# N processes against one SQLite anchor store is what corrupts the guest root in
# the first place (docs/JAC_GOTCHAS.md 8e), and OUTREACH measured the trigger:
# 12 sequential writes are fine, 20 concurrent corrupt it.
#
# So ask the filesystem who has the store open rather than guessing from process
# names. This catches `jac run` and `jac test`, which a pkill on "jac start"
# never would.
data_dir_holders() {
  local exclude="${1:-}" f pids=""
  for f in "$DATA/anchor_store.db" "$DATA/users.db" "$DATA/main.db"; do
    [ -f "$f" ] || continue
    pids="$pids $(lsof -t -- "$f" 2>/dev/null || true)"
  done
  # shellcheck disable=SC2086
  printf '%s\n' $pids | sort -u | grep -v '^$' | grep -vx "$exclude" || true
}

describe_pids() {
  local pid
  for pid in $@; do
    echo "       pid $pid: $(ps -o command= -p "$pid" 2>/dev/null | cut -c1-100)"
  done
}

# -----------------------------------------------------------------------------
# stop - ONLY what belongs to this directory
# -----------------------------------------------------------------------------
# Scoped deliberately. A global `pkill -f "jac start"` kills every teammate's
# isolated server too, and we did exactly that to FRONTEND's instance on 8099.
# Authority over our own data dir, none over anyone else's.
echo "==> stopping this directory's server"

# whatever we recorded last time, whatever port it was on
if [ -f "$LOCK" ]; then
  LOCK_PID="$(sed -n 's/^pid=//p' "$LOCK" | head -1)"
  if [ -n "${LOCK_PID:-}" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    echo "    stopping recorded server pid $LOCK_PID"
    kill "$LOCK_PID" 2>/dev/null || true
  fi
fi
# and whatever is on our port, however it got there
pkill -f "jac start main.jac --no-client -p $PORT" 2>/dev/null || true
lsof -ti tcp:"$PORT" 2>/dev/null | xargs -r kill 2>/dev/null || true

for _ in $(seq 1 30); do
  lsof -ti tcp:"$PORT" >/dev/null 2>&1 || break
  sleep 0.5
done
if lsof -ti tcp:"$PORT" >/dev/null 2>&1; then
  echo "    still bound after SIGTERM - sending SIGKILL"
  pkill -9 -f "jac start main.jac --no-client -p $PORT" 2>/dev/null || true
  lsof -ti tcp:"$PORT" 2>/dev/null | xargs -r kill -9 2>/dev/null || true
  sleep 2
fi
rm -f "$LOCK"
echo "    port $PORT is free"

# -----------------------------------------------------------------------------
# the guard: refuse to start a second process against a data dir in use
# -----------------------------------------------------------------------------
# This is the one that makes the corruption structurally impossible rather than
# a rule someone has to remember at 19:00.
HOLDERS="$(data_dir_holders "$$" | tr '\n' ' ')"
if [ -n "${HOLDERS// /}" ]; then
  echo "!! REFUSING TO START. Another process still has $DATA open:"
  # shellcheck disable=SC2086
  describe_pids $HOLDERS
  echo "    Two processes on one SQLite anchor store is what corrupts the guest"
  echo "    root and produces the permanent _lock 500s. Stop them, or serve this"
  echo "    checkout from its own directory with: ops/serve.sh"
  exit 1
fi

if [ "${1:-}" = "--clean" ]; then
  echo "==> wiping cache + graph (safe now: nothing is holding it)"
  jac clean --all --force >/dev/null 2>&1 || true
  rm -rf "$DATA"
fi

# -----------------------------------------------------------------------------
# guest-root preflight
# -----------------------------------------------------------------------------
# users.db (scale's SqliteIdentityStorage) records the guest's root_id as bare
# hex; anchor_store.db keys the same uuid WITH dashes. Compare with the dashes
# stripped or this check silently "fails" every time and repairs on every boot.
guest_root_is_orphaned() {
  [ -f "$DATA/users.db" ] || return 1              # no identities yet - fine
  [ -f "$DATA/anchor_store.db" ] && : || return 0  # identities but no graph - orphaned
  [ -n "$SQLITE" ] || return 1                     # cannot tell; smoke gate still covers us
  local root count
  root="$("$SQLITE" "$DATA/users.db" \
    "select root_id from identity_users where identities like '%__guest__%';" \
    2>/dev/null | head -1)"
  [ -n "$root" ] || return 1                       # guest not minted yet - fine
  count="$("$SQLITE" "$DATA/anchor_store.db" \
    "select count(*) from anchors where replace(id,'-','')='$root';" 2>/dev/null)"
  [ "${count:-0}" = "0" ]
}

# Drop ONLY users.db. anchor_store.db - the actual prospect graph - survives, and
# the next boot mints a fresh guest whose root anchor really exists. Nothing is
# lost: every TRACTION endpoint is anonymous (walker:pub on the guest graph), so
# there are no real accounts in users.db to preserve.
repair_guest_root() {
  echo "    !! .jac/data is divergent: users.db points the guest at a root that"
  echo "       anchor_store.db does not contain. Left alone, EVERY request would"
  echo "       500 with the _lock AttributeError described at the top of this file."
  echo "    -> dropping users.db only; the graph in anchor_store.db is preserved"
  rm -f "$DATA/users.db"
}

echo "==> guest-root preflight"
if guest_root_is_orphaned; then
  repair_guest_root
else
  echo "    consistent (or nothing to check yet)"
fi

# -----------------------------------------------------------------------------
# start
# -----------------------------------------------------------------------------
start_server() {
  # Two things about this launch line, both learned the hard way:
  #
  #  1. `jac start` does NOT read .env. Without sourcing it, litellm never sees
  #     ANTHROPIC_API_KEY and every `by llm()` call returns null while the server
  #     looks perfectly healthy. That failure is invisible until a walker quietly
  #     produces nothing.
  #  2. `jac start` exits on stdin EOF. `< /dev/null` therefore serves fine for a
  #     while and then logs `drain: started` and dies mid-session. Something must
  #     hold stdin open for the life of the process.
  #
  #     NOT `sleep infinity` - that is a GNU extension. macOS BSD sleep rejects it
  #     ("usage: sleep number[unit]") and exits IMMEDIATELY, which closes the pipe
  #     and reproduces the exact death it was meant to prevent, just as silently.
  #     `tail -f /dev/null` is portable and actually blocks.
  #
  # Do not "simplify" either half of this.
  nohup sh -c "tail -f /dev/null | jac start main.jac --no-client -p $PORT" \
    > "$LOG" 2>&1 &

  # READINESS IS A REAL ENDPOINT, NEVER /healthz.
  # FRONTEND caught /healthz returning {"status":"ok"} for the entire duration of
  # the _lock failure while all five function endpoints 500'd. Gating on it means
  # declaring a dead server up. graph_health traverses
  # founders -> Runs -> HasLane, so a 200 from it proves the persisted graph is
  # actually readable - which is the property we care about.
  #
  # 300s, not 90s: `jac clean --all` throws away the compiled JIR, so the next
  # boot recompiles the whole project before it binds. Timing out mid-compile and
  # printing "server never became healthy" is how you end up wiping a data dir
  # that was never the problem.
  # Count WALL SECONDS, not loop iterations. Each pass costs the curl timeout
  # plus the sleep, so a 300-iteration loop is really up to 30 minutes and every
  # "still booting (30s)" line understates the truth by 6x. Deadline arithmetic
  # on SECONDS is the only honest way to say how long we have waited.
  local code bound=0 deadline=$((SECONDS + 300)) next=$((SECONDS + 30))
  while [ "$SECONDS" -lt "$deadline" ]; do
    code="$(curl -s -m 3 -o /dev/null -w '%{http_code}' -X POST \
      "http://127.0.0.1:$PORT/function/graph_health" \
      -H 'Content-Type: application/json' -d '{}' 2>/dev/null || true)"
    code="${code:-000}"
    if [ "$code" = "200" ]; then
      echo "    serving real traffic after $((SECONDS - deadline + 300))s (graph_health 200)"
      return 0
    fi
    if [ "$code" != "000" ] && [ "$bound" = "0" ]; then
      bound=1
      echo "    port bound, but graph_health says $code - still waiting for a REAL 200"
    fi
    # Do not sit out the full 300s waiting for a process that is already gone.
    # A `jac start` that dies at launch leaves an EMPTY log and a silent wait,
    # which reads exactly like a slow compile - that cost real time to diagnose.
    if ! pgrep -f "jac start main.jac --no-client -p $PORT" >/dev/null 2>&1; then
      echo "    !! the jac process is gone - it died at launch, it is not compiling"
      echo "       (log is $LOG, $(wc -c < "$LOG" 2>/dev/null || echo 0) bytes)"
      tail -15 "$LOG" 2>/dev/null | sed 's/^/       /'
      return 1
    fi
    if [ "$SECONDS" -ge "$next" ]; then
      next=$((SECONDS + 30))
      echo "    still booting ($((SECONDS - deadline + 300))s elapsed) - a first boot in a fresh dir compiles the whole project"
    fi
    sleep 1
  done
  echo "    gave up after 300s (last graph_health: ${code:-none})"
  return 1
}

echo "==> starting"
# PARSE .env, do not `.` it. `jac start` does not read it itself, so we must
# export it - but sourcing executes the file, and under `set -euo pipefail` one
# unquoted value with a space in it (SPOKEN_NAME=Elijah Oo-mah-na) aborts the
# whole script before it ever reaches the start line. That cost us an afternoon.
# Take only KEY=VALUE lines and quote every value.
load_env() {
  # Read KEY=VALUE and export it WITHOUT eval. Two failure modes this avoids,
  # both of which we actually hit:
  #   1. `. ./.env` EXECUTES the file. Under `set -euo pipefail` one unquoted
  #      value with a space (SPOKEN_NAME=Elijah Oo-mah-na) aborts the script
  #      before it reaches the start line.
  #   2. The obvious "fix", re-quoting every value with sed, breaks the moment a
  #      value is ALREADY quoted: SPOKEN_NAME="Elijah Zhu" becomes
  #      SPOKEN_NAME=""Elijah Zhu"" and the shell tries to run `Zhu`. Found by
  #      running this script, not by reading it.
  # So: no eval anywhere. Strip at most one layer of matching quotes and export.
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"                       # tolerate CRLF
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    val="${line#*=}"
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    export "$key=$val"
  done < "$1"
}

if [ -f ./.env ]; then
  echo "    loading .env (parsed, never evaluated)"
  load_env ./.env
  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "    !! WARNING: ANTHROPIC_API_KEY still unset - every by llm() call will return null"
  fi
else
  echo "    !! WARNING: no .env found - every by llm() call will return null"
fi

if ! start_server; then
  echo "!! server never became healthy - see $LOG"; tail -20 "$LOG"; exit 1
fi

# Record who owns this data dir, so the next restart stops exactly this process
# and no one else's. Above .jac/data so a `rm -rf .jac/data` cannot orphan it.
SERVER_PID="$(pgrep -f "jac start main.jac --no-client -p $PORT" | head -1)"
mkdir -p "$(dirname "$LOCK")"
{ echo "pid=${SERVER_PID:-unknown}"; echo "port=$PORT"; echo "dir=$PWD"; } > "$LOCK"
echo "==> holding $LOCK (pid ${SERVER_PID:-unknown}, port $PORT)"

echo "==> warmup (first anonymous request also initialises the guest root)"
WARM="$(curl -s -m 15 -o /dev/null -w '%{http_code}' -X POST \
  "http://127.0.0.1:$PORT/function/get_run_state" \
  -H 'Content-Type: application/json' -d '{}' 2>/dev/null || true)"
WARM="${WARM:-000}"
echo "    warmup: $WARM"
if [ "$WARM" != "200" ]; then
  echo "    !! warmup did not return 200 - falling through to the smoke gate,"
  echo "       which will repair or fail loudly rather than report a dead server ready"
fi

# -----------------------------------------------------------------------------
# smoke gate
# -----------------------------------------------------------------------------
# The dashboard polls feed_since/list_lanes/list_prospects continuously, so a
# server that answers /healthz but 500s on walkers is worse than one that never
# started - it presents as a frozen UI. Refuse to report ready until real
# anonymous endpoint traffic comes back clean.
smoke() {
  local n code ep body fails=0
  # Exactly the four the dashboard polls (docs/FRONTEND_INTEGRATION.md). Testing
  # something the dashboard does not call would prove nothing about the demo.
  for n in $(seq 1 12); do
    case $((n % 4)) in
      0) ep="function/graph_health";   body='{}' ;;
      1) ep="function/list_lanes";     body='{}' ;;
      2) ep="function/feed_since";     body='{"since":"0"}' ;;
      3) ep="function/list_prospects"; body='{}' ;;
    esac
    code="$(curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST \
      "http://127.0.0.1:$PORT/$ep" -H 'Content-Type: application/json' \
      -d "$body" 2>/dev/null || true)"
    code="${code:-000}"
    [ "$code" = "200" ] || { fails=$((fails+1)); echo "    !! $ep -> $code"; }
  done
  [ "$fails" -eq 0 ]
}

echo "==> smoke gate (12 anonymous walker/function POSTs)"
if smoke; then
  echo "    12/12 OK"
else
  echo "    !! smoke gate FAILED"
  if grep -q "no attribute '_lock'" "$LOG"; then
    echo "    -> _lock AttributeError in the log: divergent guest root got through"
    echo "       the preflight. Repairing and restarting ONCE."
    pkill -9 -f "jac start main.jac --no-client -p $PORT" 2>/dev/null || true
    lsof -ti tcp:"$PORT" 2>/dev/null | xargs -r kill -9 2>/dev/null || true
    sleep 3
    repair_guest_root
    if ! start_server; then
      echo "!! server never became healthy after repair - see $LOG"; tail -30 "$LOG"; exit 1
    fi
    SERVER_PID="$(pgrep -f "jac start main.jac --no-client -p $PORT" | head -1)"
    { echo "pid=${SERVER_PID:-unknown}"; echo "port=$PORT"; echo "dir=$PWD"; } > "$LOCK"
    if smoke; then
      echo "    12/12 OK after repair"
    else
      echo "!! still failing after repair. Do NOT demo against this server."
      echo "   Last resort: ops/restart.sh --clean (wipes the graph, reseed after)."
      tail -30 "$LOG"; exit 1
    fi
  else
    echo "!! failures are not the _lock bug - read $LOG before demoing."
    tail -30 "$LOG"; exit 1
  fi
fi

echo "==> websocket routes registered:"
grep -i 'Registered WebSocket' "$LOG" | sed 's/^/    /' || {
  echo "    !! NONE - the LiveFeed walker will not be reachable over ws://."
  echo "       The dashboard falls back to polling feed_since (see"
  echo "       docs/FRONTEND_INTEGRATION.md), so this is a warning, not fatal."
}
echo "==> ready on http://127.0.0.1:$PORT"
echo "    data dir : $PWD/$DATA   (anchor_store.db resolves relative to CWD -"
echo "               a dedicated data dir means a dedicated DIRECTORY, never"
echo "               JAC_DATA_PATH, which moves users.db but not the anchor store)"
echo "    lock     : $PWD/$LOCK"
echo "    NOTHING else may run jac in this directory while this server is up."
