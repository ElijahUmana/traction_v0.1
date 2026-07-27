#!/usr/bin/env bash
# Serve TRACTION from an isolated instance directory that nobody else can reach.
#
#   ops/serve.sh                 # start (or restart) the demo instance
#   ops/serve.sh --clean         # same, but wipe that instance's graph first
#   ops/serve.sh --status        # is it up? whose is it? where is its data?
#   ops/serve.sh --stop          # stop it, release the lock
#   ops/serve.sh --port 8801 --dir /tmp/my-instance
#
# -----------------------------------------------------------------------------
# WHY AN ISOLATED DIRECTORY AND NOT AN ENV VAR
# -----------------------------------------------------------------------------
# The corruption behind the `'JacScaleUserManager' object has no attribute
# '_lock'` 500s starts as two processes mutating one SQLite anchor store.
# OUTREACH measured the trigger: 12 sequential writes are fine, 20 concurrent
# corrupt the shared anonymous guest root. Every probe counts - a health check, a
# dashboard poll, a curl at the public tunnel. So the demo server needs a data
# dir no other operator can touch, not a convention people have to remember.
#
# The obvious way to do that is JAC_DATA_PATH. DO NOT. It is a trap that
# manufactures the exact bug. In jaclang 0.34.7:
#
#     main.db           honours JAC_DATA_PATH   runtimelib/impl/server.impl.jac:16
#     users.db          honours JAC_DATA_PATH   scale/identity/impl/user_manager.impl.jac:37
#     anchor_store.db   DOES NOT - hard-coded relative '.jac/data/anchor_store.db'
#                       scale/config/impl/config_loader.impl.jac:218, no env override
#
# Point JAC_DATA_PATH somewhere and users.db moves while anchor_store.db stays at
# $CWD/.jac/data. The guest root is then recorded in one store and absent from
# the other - which IS the divergence that bricks the server. You would be
# hand-building the failure you were trying to isolate away from.
#
# anchor_store.db resolves relative to the working directory, so the only thing
# that actually isolates a Jac server is its own DIRECTORY. Hence this script.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"

PORT="${PORT:-8800}"
DIR="${TRACTION_INSTANCE:-/tmp/traction-demo}"
CLEAN=""
ACTION="start"

while [ $# -gt 0 ]; do
  case "$1" in
    --port)   PORT="$2"; shift 2 ;;
    --dir)    DIR="$2";  shift 2 ;;
    --clean)  CLEAN="--clean"; shift ;;
    --status) ACTION="status"; shift ;;
    --stop)   ACTION="stop"; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac
done

LOG="${LOG:-/tmp/traction-$PORT.log}"
LOCK="$DIR/.jac/serving.lock"

# --- status -----------------------------------------------------------------
if [ "$ACTION" = "status" ]; then
  echo "instance : $DIR"
  echo "port     : $PORT"
  if [ -f "$LOCK" ]; then
    echo "lock     : $(tr '\n' ' ' < "$LOCK")"
    LP="$(sed -n 's/^pid=//p' "$LOCK" | head -1)"
    if [ -n "${LP:-}" ] && kill -0 "$LP" 2>/dev/null; then
      echo "holder   : pid $LP ALIVE"
    else
      echo "holder   : recorded pid $LP is GONE (stale lock)"
    fi
  else
    echo "lock     : none"
  fi
  # A 200 from /healthz proves nothing - it stays 200 through the whole _lock
  # failure. Only a real endpoint tells you anything.
  HZ="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/healthz" 2>/dev/null || echo 000)"
  GH="$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST \
        "http://127.0.0.1:$PORT/function/graph_health" \
        -H 'Content-Type: application/json' -d '{}' 2>/dev/null || echo 000)"
  echo "healthz  : $HZ   <- ignore this, it lies"
  echo "graph_health: $GH  <- this is the real answer"
  [ "$GH" = "200" ] || echo "         !! not serving. ops/serve.sh to (re)start."
  exit 0
fi

# --- stop -------------------------------------------------------------------
if [ "$ACTION" = "stop" ]; then
  if [ -f "$LOCK" ]; then
    LP="$(sed -n 's/^pid=//p' "$LOCK" | head -1)"
    [ -n "${LP:-}" ] && kill "$LP" 2>/dev/null || true
  fi
  pkill -f "jac start main.jac --no-client -p $PORT" 2>/dev/null || true
  lsof -ti tcp:"$PORT" 2>/dev/null | xargs -r kill 2>/dev/null || true
  rm -f "$LOCK"
  echo "stopped instance on :$PORT ($DIR)"
  exit 0
fi

# --- start ------------------------------------------------------------------
if [ "$DIR" = "$SRC" ]; then
  echo "!! --dir is the source checkout. That defeats the entire point of this"
  echo "   script: the instance must not share a data dir with anyone's jac run."
  exit 1
fi

echo "==> syncing code $SRC -> $DIR"
mkdir -p "$DIR"
# Exclude .jac so the instance KEEPS its own graph across a code refresh - you
# can pull in a teammate's walker fix mid-prep without losing the pre-warm.
# Exclude .git so nobody is tempted to commit from the instance.
rsync -a --delete \
  --exclude '.git' --exclude '.jac' --exclude '.pytest_cache' \
  --exclude '*.log' --exclude '.jac/data' \
  "$SRC/" "$DIR/"
[ -f "$SRC/.env" ] && cp "$SRC/.env" "$DIR/.env"
echo "    code synced; $DIR/.jac left untouched"

# restart.sh carries the guest-root preflight, the data-dir-in-use guard, the
# real-endpoint readiness gate and the smoke gate. Run the INSTANCE's copy, from
# the instance directory, so anchor_store.db resolves inside it.
cd "$DIR"
echo "==> handing off to the instance's own ops/restart.sh (port $PORT)"
PORT="$PORT" LOG="$LOG" bash ops/restart.sh $CLEAN

cat <<EOF

================================================================================
DEMO INSTANCE READY
  url      : http://127.0.0.1:$PORT
  directory: $DIR
  data     : $DIR/.jac/data
  log      : $LOG

  Nobody else's \`jac run\`, \`jac test\` or stray server touches this data dir,
  and ops/restart.sh will refuse to start here if anything else opens it.

  Check it with:  ops/serve.sh --status --port $PORT --dir $DIR
  Never with:     curl .../healthz   (returns 200 while every endpoint 500s)
================================================================================
EOF
