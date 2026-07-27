#!/usr/bin/env bash
# Measure how reliable a cold start actually is, and whether a warmup fixes it.
# Usage: ops/coldstart_probe.sh [N]
set -u
N="${1:-3}"
cd "$(dirname "$0")/.."

# ---------------------------------------------------------------------------
# DESTRUCTIVE. This script calls `jac clean --all --force`, which DELETES
# .jac/data - the graph.
#
# This is not hypothetical: it wiped the demo graph at 17:18 today. 702 anchors
# gone (29 Prospects, 18 Founders, 73 Lanes, 44 Evidence), recovered only
# because a snapshot happened to be taken one minute earlier. Anyone following
# our own documented test procedure destroyed the demo state.
#
# So it refuses to run against the primary checkout unless you say so out loud.
# Tests belong in a throwaway clone anyway - see docs/RUNBOOK.md.
# ---------------------------------------------------------------------------
PRIMARY="/Users/elijahumana/jachacks-traction"
HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
if [ "$HERE" = "$PRIMARY" ] && [ "${YES_WIPE:-0}" != "1" ]; then
  echo "REFUSING: this wipes .jac/data (the graph) and you are in the primary checkout:"
  echo "  $HERE"
  echo
  echo "Run it in a throwaway clone instead:"
  echo "  git clone $PRIMARY /tmp/tr-test && cd /tmp/tr-test && ops/$(basename "$0")"
  echo
  echo "Or, if you really mean to wipe the graph here:  YES_WIPE=1 ops/$(basename "$0")"
  exit 2
fi
pass=0; recovered=0; failed=0

for i in $(seq 1 "$N"); do
  pkill -f "jac start" 2>/dev/null; sleep 2
  jac clean --all --force >/dev/null 2>&1; rm -rf .jac/data
  nohup jac start main.jac --no-client -p 8000 < /dev/null > "/tmp/coldstart-$i.log" 2>&1 &
  for _ in $(seq 1 60); do
    curl -s -m 2 -o /dev/null http://127.0.0.1:8000/healthz 2>/dev/null && break
    sleep 1
  done

  first=$(curl -s -m 10 -o /dev/null -w "%{http_code}" -X POST \
    http://127.0.0.1:8000/function/get_run_state -H 'Content-Type: application/json' -d '{}')

  # retry a few times to see whether it is transient or terminal
  after="$first"
  for _ in 1 2 3 4 5; do
    [ "$after" = "200" ] && break
    sleep 1
    after=$(curl -s -m 10 -o /dev/null -w "%{http_code}" -X POST \
      http://127.0.0.1:8000/function/get_run_state -H 'Content-Type: application/json' -d '{}')
  done

  if [ "$first" = "200" ]; then
    echo "run $i: first=$first                 -> CLEAN"; pass=$((pass+1))
  elif [ "$after" = "200" ]; then
    echo "run $i: first=$first after-retry=$after -> RECOVERED"; recovered=$((recovered+1))
  else
    echo "run $i: first=$first after-retry=$after -> TERMINAL (server bricked)"; failed=$((failed+1))
  fi
done

echo "----"
echo "clean=$pass recovered=$recovered terminal=$failed  of $N cold starts"
