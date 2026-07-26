#!/usr/bin/env bash
# Snapshot and restore the pre-warmed graph.
#
#   ops/warm.sh save      # after a good pre-warm, before the demo
#   ops/warm.sh restore   # after the guest-root corruption bricks the server
#   ops/warm.sh status
#
# WHY THIS EXISTS
# The guest-root corruption is written into .jac/data/anchor_store.db and
# SURVIVES A RESTART. Measured back to back:
#     ops/restart.sh            (keeps .jac/data)  -> 500 500 500
#     ops/restart.sh --clean    (wipes .jac/data)  -> 200 200 200 200 200
# So the only recovery found is wiping the graph - which would also destroy the
# pre-warmed research run that section 6 of the master plan depends on to fit a
# 6-8 minute pipeline into a 4-minute slot.
#
# A snapshot turns "wipe and lose the pre-warm" into "restore and keep it".
# Take one the moment the pre-warm looks good. It costs a directory copy.
set -uo pipefail
cd "$(dirname "$0")/.."

SNAP=".jac/data.warm"
LIVE=".jac/data"
PORT="${PORT:-8000}"

usage() { echo "usage: ops/warm.sh {save|restore|status}"; exit 1; }
[ $# -ge 1 ] || usage

case "$1" in
  save)
    if [ ! -d "$LIVE" ]; then
      echo "!! no $LIVE to snapshot - is the server running?"; exit 1
    fi
    # Refuse to snapshot a graph that is already broken, or the snapshot just
    # preserves the corruption and restore becomes a no-op.
    CODE=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST \
      "http://127.0.0.1:$PORT/function/get_run_state" \
      -H 'Content-Type: application/json' -d '{}' 2>/dev/null)
    if [ "$CODE" != "200" ]; then
      echo "!! server answered $CODE, not 200 - refusing to snapshot a graph that is"
      echo "   already corrupt. Fix it first (ops/restart.sh --clean), re-warm, then save."
      exit 1
    fi
    rm -rf "$SNAP"
    cp -R "$LIVE" "$SNAP"
    echo "saved $LIVE -> $SNAP  ($(du -sh "$SNAP" | cut -f1))"
    echo "verified healthy (200) at snapshot time."
    ;;

  restore)
    if [ ! -d "$SNAP" ]; then
      echo "!! no snapshot at $SNAP - nothing to restore."
      echo "   Without one the only recovery is ops/restart.sh --clean, which"
      echo "   WIPES the graph including any pre-warmed run."
      exit 1
    fi
    echo "==> stopping the server before touching the data dir"
    # Wiping data under a live process is what creates this corruption in the
    # first place, so never skip the wait.
    pkill -f "jac start" 2>/dev/null || true
    for _ in $(seq 1 30); do
      pgrep -f "jac start" >/dev/null 2>&1 || break
      sleep 0.5
    done
    pkill -9 -f "jac start" 2>/dev/null || true
    sleep 1

    rm -rf "$LIVE"
    cp -R "$SNAP" "$LIVE"
    echo "restored $SNAP -> $LIVE"
    echo "==> restarting (NOT --clean: that would undo the restore)"
    ./ops/restart.sh
    ;;

  status)
    if [ -d "$SNAP" ]; then
      echo "snapshot : $SNAP  ($(du -sh "$SNAP" | cut -f1))"
    else
      echo "snapshot : NONE - a corruption right now would cost the pre-warm"
    fi
    [ -d "$LIVE" ] && echo "live     : $LIVE  ($(du -sh "$LIVE" | cut -f1))" \
                   || echo "live     : NONE"
    CODE=$(curl -s -m 8 -o /dev/null -w '%{http_code}' -X POST \
      "http://127.0.0.1:$PORT/function/get_run_state" \
      -H 'Content-Type: application/json' -d '{}' 2>/dev/null)
    echo "server   : ${CODE:-unreachable}"
    [ "$CODE" = "500" ] && echo "           ^ likely the guest-root corruption. ops/warm.sh restore"
    ;;

  *) usage ;;
esac
