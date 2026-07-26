#!/usr/bin/env bash
# Bring up the Vapi tunnel and PROVE it carries a real callback.
#
#   ops/tunnel.sh                 # start tunnel, verify, record artifact
#   NETWORK=hotspot ops/tunnel.sh # same, labelled as the hotspot run
#
# Vapi needs a public HTTPS URL to reach our mid-call Custom Tool and Knowledge
# Base endpoints. AgentMail avoids this with websockets; Vapi has no equivalent.
# Per the risk register the MOBILE HOTSPOT is PRIMARY, not backup - venue wifi is
# the failure mode we cannot debug live. Run this on BOTH networks and keep both
# artifacts.
#
# A 200 on a GET is NOT sufficient evidence. Vapi POSTs a JSON body, so this
# verifies an external POST actually reaches the local server with its method and
# body intact - that is the difference between "the tunnel is up" and "the tunnel
# carries Vapi's callbacks".
set -uo pipefail
cd "$(dirname "$0")/.."

PORT="${PORT:-8000}"
NETWORK="${NETWORK:-unknown}"
STAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"
OUT="evidence/tunnel_proof_${NETWORK}.log"
CFLOG="/tmp/traction-cfd-${NETWORK}.log"

command -v cloudflared >/dev/null || { echo "cloudflared not installed"; exit 1; }

echo "==> checking the local server is up on :$PORT"
if ! curl -s -m 3 -o /dev/null "http://127.0.0.1:$PORT/healthz"; then
  echo "!! nothing healthy on :$PORT - run ops/restart.sh first"; exit 1
fi

# Reuse a live tunnel rather than churning hostnames. Every restart issues a NEW
# hostname, and every new hostname has to be re-pointed in Vapi's dashboard - so
# a needless restart during the demo window is a self-inflicted outage. Pass
# FORCE_NEW=1 to deliberately cycle it.
EXISTING=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$CFLOG" 2>/dev/null | head -1)
if [ -n "$EXISTING" ] && [ "${FORCE_NEW:-0}" != "1" ] && pgrep -f "cloudflared tunnel" >/dev/null; then
  echo "==> reusing the live tunnel (FORCE_NEW=1 to cycle it)"
  URL="$EXISTING"
else
  echo "==> starting cloudflared quick tunnel"
  pkill -f "cloudflared tunnel" 2>/dev/null || true
  sleep 1
  nohup cloudflared tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate \
    > "$CFLOG" 2>&1 &
fi

for _ in $(seq 1 40); do
  [ -n "${URL:-}" ] && break
  URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$CFLOG" 2>/dev/null | head -1)
  [ -n "$URL" ] && break
  sleep 1
done
[ -z "$URL" ] && { echo "!! no tunnel URL issued after 40s"; tail -20 "$CFLOG"; exit 1; }
echo "    $URL"

sleep 3
echo "==> waiting for the edge to actually serve (the URL is issued before it works)"
# Two independent gotchas are handled here.
#
# 1. cloudflared prints the hostname as soon as it is allocated, several seconds
#    before the edge connection is registered.
#
# 2. THE LOCAL RESOLVER MAY NOT RESOLVE *.trycloudflare.com AT ALL. Measured on
#    this network: nameserver 10.104.0.1 returns NXDOMAIN for the quick-tunnel
#    host while 1.1.1.1 resolves it fine and the URL answers 200. That is the
#    venue-wifi failure mode in the risk register, and it is a trap: the tunnel
#    is HEALTHY and reachable by Vapi (whose servers use their own resolvers),
#    but a curl from this laptop reports "Could not resolve host" and looks like
#    a dead tunnel. So verification goes over DNS-over-HTTPS, which tests what
#    Vapi actually experiences rather than what our DHCP resolver permits.
DOH=(--doh-url https://1.1.1.1/dns-query)
GET_CODE="000"
for _ in $(seq 1 30); do
  GET_CODE=$(curl -s "${DOH[@]}" -m 10 -o /dev/null -w "%{http_code}" "$URL/healthz")
  [ "$GET_CODE" != "000" ] && break
  sleep 2
done
if [ "$GET_CODE" = "000" ]; then
  echo "!! tunnel never served after 60s"; tail -20 "$CFLOG"
fi

# Does the LOCAL resolver see it? Not required for Vapi, but worth recording.
if curl -s -m 8 -o /dev/null "$URL/healthz" 2>/dev/null; then
  LOCAL_DNS="resolves"
else
  LOCAL_DNS="BLOCKED (local resolver cannot see *.trycloudflare.com - does NOT affect Vapi)"
fi

echo "==> verifying from OUTSIDE, through the tunnel"

GET_TIME=$(curl -s "${DOH[@]}" -m 20 -o /dev/null -w "%{time_total}" "$URL/healthz")

# A real Vapi-shaped callback: POST + JSON body to a walker route.
POST_BODY=$(curl -s "${DOH[@]}" -m 20 -X POST "$URL/function/get_run_state" \
  -H 'Content-Type: application/json' -d '{}')
POST_CODE=$(curl -s "${DOH[@]}" -m 20 -o /dev/null -w "%{http_code}" -X POST \
  "$URL/function/get_run_state" -H 'Content-Type: application/json' -d '{}')

EGRESS=$(curl -s -m 10 https://api.ipify.org || echo "unknown")
EDGE=$(grep -oE 'location=[a-z0-9]+' "$CFLOG" | head -1)

# The POST must round-trip the envelope, not merely return 200 - that proves the
# body reached the app and the app's reply came back.
if echo "$POST_BODY" | grep -q '"ok"'; then POST_ROUNDTRIP="YES"; else POST_ROUNDTRIP="NO"; fi

{
  echo "===================================================================="
  echo "TRACTION - Vapi tunnel proof"
  echo "===================================================================="
  echo "captured    : $STAMP"
  echo "network     : $NETWORK"
  echo "public url  : $URL"
  echo "egress ip   : $EGRESS"
  echo "cf edge     : $EDGE"
  echo "local dns   : $LOCAL_DNS"
  echo
  echo "external GET  /healthz            -> $GET_CODE  (${GET_TIME}s)"
  echo "external POST /function/get_run_state -> $POST_CODE"
  echo "POST body round-tripped envelope  -> $POST_ROUNDTRIP"
  echo
  echo "response body (first 300 chars):"
  echo "$POST_BODY" | head -c 300
  echo
  echo
  if [ "$GET_CODE" = "200" ] && [ "$POST_CODE" = "200" ] && [ "$POST_ROUNDTRIP" = "YES" ]; then
    echo "TUNNEL_CARRIES_VAPI_CALLBACKS = True"
  else
    echo "TUNNEL_CARRIES_VAPI_CALLBACKS = False"
  fi
  echo
  echo "NOTE: quick-tunnel hostnames change on every restart."
  echo "      Re-point Vapi's Custom Tool + Knowledge Base URLs to the host above."
} | tee "$OUT"

echo
echo "artifact: $OUT"
echo "tunnel still running (pid $(pgrep -f 'cloudflared tunnel' | head -1)) - leave it up."
