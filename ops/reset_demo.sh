#!/usr/bin/env bash
# Put the demo back to its opening state. One command, no server restart.
#
#   ops/reset_demo.sh
#   ops/reset_demo.sh --port 8000
#
# WHY THIS EXISTS
# ---------------
# Running the demo mutates the graph, and that is correct behaviour: a real
# send writes an EmailThread, a real call writes a CallSession, a real booking
# writes a Booking edge. Becky's card then reads `Booked`, and the UI - also
# correctly - disables Send and shows "Already sent", because on a live system
# you do not re-pitch someone you have already booked.
#
# So the second run through the demo is not the same as the first, and the only
# way back was `ops/restart.sh --clean` plus a reseed: a full recompile, a
# minute of downtime, and a new guest root. That is a terrible thing to need
# between takes.
#
# This does it over HTTP against the running server instead. Two calls, a few
# seconds, and the server never stops.
#
# WHAT IT DOES NOT DO
# -------------------
# It does not touch anything outside this graph. Calendar events already
# created, emails already sent and calls already placed are real things that
# happened in the world; deleting our record of them would not undo them, it
# would only make our graph disagree with reality. Clean those up in Google
# Calendar directly if a previous take left artifacts.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${PORT:-8000}"
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    *) echo "unknown argument: $1"; exit 2 ;;
  esac
done
BASE="http://127.0.0.1:$PORT"

post() { curl -s -m 60 -X POST "$BASE/$1" -H 'Content-Type: application/json' -d "${2:-\{\}}"; }

# Gate on a real endpoint, never /healthz - it answers 200 for the entire
# duration of a _lock failure while every walker 500s.
echo "==> checking $BASE"
CODE="$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST "$BASE/function/graph_health" \
        -H 'Content-Type: application/json' -d '{}' || true)"
if [ "${CODE:-000}" != "200" ]; then
  echo "!! server is not answering on $PORT (graph_health -> ${CODE:-000})."
  echo "   Start it with: ops/serve.sh --port $PORT --dir ."
  exit 1
fi

echo "==> before"
post function/graph_health | python3 -c "import json,sys; print('   ', json.load(sys.stdin)['data']['result'])"

# reset_workspace deletes the Founder and every Prospect hanging off root.
# Everything else in the graph - runs, lanes, evidence, threads, bookings -
# hangs off those two, so removing them takes the whole tree with it.
echo "==> clearing"
post function/reset_workspace > /dev/null

echo "==> reseeding"
python3 ops/seed_demo.py 2>&1 | sed 's/^/   /'

echo "==> after"
post function/bootstrap_workspace | python3 -c "
import json, sys
w = json.load(sys.stdin)['data']['result']
print('   founder  :', w.get('founder_name'), '|', w.get('founder_email'))
print('   prospects:', len(w.get('prospects') or []))
for p in (w.get('prospects') or []):
    name = (p.get('name') or '')[:20].ljust(20)
    mail = (p.get('email') or '(dropped)')[:26].ljust(26)
    print(f'      - {name} | {mail} | {p.get(\"status\")}')
"

echo
echo "Reload the browser tab. Every prospect is back at 'Found' and Send is live again."
