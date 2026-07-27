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
# macOS always ships /usr/bin/sqlite3; prefer it over whatever conda put first
# on PATH so the preflight behaves the same on every machine.
SQLITE="$( [ -x /usr/bin/sqlite3 ] && echo /usr/bin/sqlite3 || command -v sqlite3 || true )"

# -----------------------------------------------------------------------------
# stop
# -----------------------------------------------------------------------------
# Deliberately NOT port-scoped. A stale server on another port still holds this
# same .jac/data, and that is the thing that corrupts it (see docs/RUNBOOK.md:
# one process at a time - the graph store is shared and unsynchronised).
echo "==> stopping any running server"
pkill -f "jac start" 2>/dev/null || true

for _ in $(seq 1 30); do
  if ! pgrep -f "jac start" >/dev/null 2>&1 && ! lsof -ti tcp:"$PORT" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

if pgrep -f "jac start" >/dev/null 2>&1 || lsof -ti tcp:"$PORT" >/dev/null 2>&1; then
  echo "    still alive after SIGTERM - sending SIGKILL"
  pkill -9 -f "jac start" 2>/dev/null || true
  lsof -ti tcp:"$PORT" 2>/dev/null | xargs -r kill -9 2>/dev/null || true
  sleep 2
fi
echo "    port $PORT is free"

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

  # 90s is not enough after `--clean`: `jac clean --all` throws away the
  # compiled JIR too, so the next boot recompiles the whole project before it
  # binds the port. Timing out here and printing "server never became healthy"
  # while the compiler is still working is how you end up wiping a data dir
  # that was never the problem.
  local i
  for i in $(seq 1 300); do
    if curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/healthz" 2>/dev/null; then
      echo "    healthy after ${i}s"
      return 0
    fi
    if [ $((i % 30)) -eq 0 ]; then
      echo "    still booting (${i}s) - a post-\`jac clean\` boot recompiles everything"
    fi
    sleep 1
  done
  return 1
}

echo "==> starting"
if [ -f ./.env ]; then
  echo "    sourcing .env (jac start does not read it itself)"
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "    !! WARNING: ANTHROPIC_API_KEY still unset - every by llm() call will return null"
  fi
else
  echo "    !! WARNING: no .env found - every by llm() call will return null"
fi

if ! start_server; then
  echo "!! server never became healthy - see $LOG"; tail -20 "$LOG"; exit 1
fi

echo "==> warmup (first anonymous request also initialises the guest root)"
curl -s -m 10 -o /dev/null -w "    warmup: %{http_code}\n" -X POST \
  "http://127.0.0.1:$PORT/function/get_run_state" \
  -H 'Content-Type: application/json' -d '{}'

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
      -d "$body" 2>/dev/null || echo 000)"
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
    pkill -9 -f "jac start" 2>/dev/null || true
    sleep 3
    repair_guest_root
    if ! start_server; then
      echo "!! server never became healthy after repair - see $LOG"; tail -30 "$LOG"; exit 1
    fi
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
