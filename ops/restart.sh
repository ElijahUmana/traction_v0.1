#!/usr/bin/env bash
# Restart the TRACTION API server SAFELY.
#
# Why this exists: wiping .jac/data while an old `jac start` is still alive
# leaves the surviving process holding a guest-root id that no longer exists in
# the anchor store. The next request logs
#   "Guest root anchor <id> is missing from the anchor store; minting a fresh
#    guest root."
# and then dies with
#   "'JacScaleUserManager' object has no attribute '_lock'"  (HTTP 500)
# and the server stays bricked until it is restarted. Every 500 of this kind we
# saw traced back to a stale process racing a wiped data dir.
#
# So: kill completely, WAIT for the port to be free, only then wipe, then start.
#
#   ops/restart.sh          # keep the graph
#   ops/restart.sh --clean  # wipe the graph too (after a schema change)
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${PORT:-8000}"
LOG="${LOG:-/tmp/traction-server.log}"

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
  rm -rf .jac/data
fi

echo "==> starting"
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

nohup sh -c "tail -f /dev/null | jac start main.jac --no-client -p $PORT" \
  > "$LOG" 2>&1 &

for i in $(seq 1 90); do
  if curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/healthz" 2>/dev/null; then
    echo "    healthy after ${i}s"
    break
  fi
  sleep 1
done

if ! curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/healthz" 2>/dev/null; then
  echo "!! server never became healthy - see $LOG"; tail -20 "$LOG"; exit 1
fi

echo "==> warmup (first anonymous request also initialises the guest root)"
curl -s -m 10 -o /dev/null -w "    warmup: %{http_code}\n" -X POST \
  "http://127.0.0.1:$PORT/function/get_run_state" \
  -H 'Content-Type: application/json' -d '{}'

echo "==> websocket routes registered:"
grep -i 'Registered WebSocket' "$LOG" | sed 's/^/    /' || {
  echo "    !! NONE. [scale.websocket] missing from jac.toml, or jac install not run."
  echo "       Without it @restspec(protocol=APIProtocol.WEBSOCKET) is silently ignored."
  exit 1
}
echo "==> ready on http://127.0.0.1:$PORT"
