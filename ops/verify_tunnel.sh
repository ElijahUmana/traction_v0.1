#!/usr/bin/env bash
# Verify the Vapi callback path end to end, THROUGH the public tunnel.
#
# The failure mode this exists for: cloudflared quick-tunnel hostnames rotate on
# every restart. After a bounce, PUBLIC_BASE_URL in .env is stale, ScheduleCall
# renders tool_urls off the stale host, and the mid-call booking 404s while
# every other part of the demo looks perfectly healthy.
#
#   ./ops/verify_tunnel.sh            checks reachability
#   ./ops/verify_tunnel.sh <jid>      also runs a ScheduleCall dry-run
set -uo pipefail
cd "$(dirname "$0")/.."
PUB=$(grep "^PUBLIC_BASE_URL=" .env | cut -d= -f2- | tr -d ' "')
JID="${1:-}"
fail=0

echo "PUBLIC_BASE_URL = $PUB"

code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "http://localhost:8000/healthz")
echo "  local  /healthz            HTTP $code"
[ "$code" = "200" ] || { echo "  !! local server is not listening on :8000 - nothing below can pass"; exit 1; }

code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 25 "$PUB/healthz")
echo "  public /healthz            HTTP $code"
if [ "$code" != "200" ]; then
  echo "  !! the tunnel hostname in .env does NOT reach this server."
  echo "     cloudflared quick tunnels rotate on restart - read the new hostname"
  echo "     from the cloudflared output and update PUBLIC_BASE_URL, then re-run."
  exit 1
fi

# Each callback must answer FROM THE WALKER. A tunnel 404/502 means the route
# never arrived; a 4xx/5xx from the app means it did.
for w in KbQuery BookInterview OnCallEnd; do
  code=$(curl -s -o /tmp/vt_$w -w "%{http_code}" --max-time 30 -X POST "$PUB/walker/$w" \
         -H 'Content-Type: application/json' -d '{}')
  head=$(head -c 60 /tmp/vt_$w | tr -d '\n')
  case "$code" in
    404|502|503|000) echo "  $w  HTTP $code  UNREACHABLE through the tunnel"; fail=1 ;;
    *)               echo "  $w  HTTP $code  reached the walker: $head" ;;
  esac
done

if [ -n "$JID" ]; then
  echo "ScheduleCall dry-run for $JID"
  curl -s --max-time 60 -X POST "http://localhost:8000/walker/ScheduleCall" \
    -H 'Content-Type: application/json' \
    -d "{\"prospect_id\":\"$JID\",\"dry_run\":true}" | tee /tmp/vt_sched | head -c 900
  echo
  # Every rendered callback URL must carry the CURRENT hostname.
  host=${PUB#https://}
  if grep -q "$host" /tmp/vt_sched; then
    echo "  rendered URLs carry the current hostname"
  else
    echo "  !! rendered tool_urls/server_url do NOT contain $host - they are stale"
    fail=1
  fi
fi

[ "$fail" = "0" ] && echo "TUNNEL_OK=True" || echo "TUNNEL_OK=False"
exit $fail
