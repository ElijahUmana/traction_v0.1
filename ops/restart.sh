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

echo "==> starting (stdin detached - jac start exits when stdin closes)"
nohup jac start main.jac --no-client -p "$PORT" < /dev/null > "$LOG" 2>&1 &

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
