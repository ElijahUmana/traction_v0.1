#!/usr/bin/env bash
# THE CHAIN — drive the whole product over HTTP, against a live server, and read
# the GRAPH back at every boundary.
#
#   ops/chain.sh                              # everything that is safe to run live
#   ops/chain.sh --host http://127.0.0.1:8902 # point at your own instance
#   ops/chain.sh --send                       # also send a real email to a real human
#   ops/chain.sh --call                       # also place a real phone call
#
# -----------------------------------------------------------------------------
# WHY THIS EXISTS, AND WHY IT IS HTTP AND NOT `jac run`
# -----------------------------------------------------------------------------
# Every segment of this product has a strong individual proof. None of them
# proved the product, because they were `jac run` proofs and `jac run` writes
# the LOCAL root while the server reads the GUEST root. A walker can therefore
# be green under `jac run` and a silent no-op over HTTP - which is exactly what
# `RunResearch` was until 18:5x today (HTTP 200, `[]`, 0.0s, nothing written).
#
# So this script asserts on the GRAPH, never on a walker's return value. Every
# stage prints a census read back out of the server with `graph_health`, and a
# stage that reports success without moving a count is called a FAILURE here no
# matter how green it looked. That is the failure mode this project hits most.
#
# -----------------------------------------------------------------------------
# WHAT IS GATED, AND WHY THAT IS NOT A HEDGE
# -----------------------------------------------------------------------------
# Three links end at a real human being: an email to a real stranger, a phone
# call that rings a real phone, and a calendar invite on a real calendar. They
# are OFF by default and each one names the segment proof that covers it. A
# chain artifact with an unmarked gap is worse than one that names its gaps.
set -uo pipefail
cd "$(dirname "$0")/.."

HOST="${HOST:-http://127.0.0.1:8902}"
DO_SEND=0
DO_CALL=0
DO_BOOK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --send) DO_SEND=1; shift ;;
    --call) DO_CALL=1; shift ;;
    --book) DO_BOOK=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo "!! jq is required"; exit 1; }

# --- redaction ---------------------------------------------------------------
# Two raw provider dumps leaked account identifiers today and blocked every push
# for the whole team. Nothing reaches stdout without passing through this, so a
# secret cannot reach the artifact even if a provider starts echoing one.
redact() {
  sed -E \
    -e 's/AC[0-9a-fA-F]{32}/AC<REDACTED-TWILIO-SID>/g' \
    -e 's/SK[0-9a-fA-F]{32}/SK<REDACTED-TWILIO-KEY>/g' \
    -e 's/sk-[A-Za-z0-9_-]{20,}/sk-<REDACTED-API-KEY>/g' \
    -e 's/(Bearer|bearer) +[A-Za-z0-9._-]{16,}/Bearer <REDACTED>/g' \
    -e 's/\+1[0-9]{10}/+1<REDACTED-PHONE>/g' \
    -e 's/"number" *: *"[^"]*"/"number":"<REDACTED-PHONE>"/g' \
    -e 's/"would_call" *: *"[^"]*"/"would_call":"<REDACTED-PHONE>"/g' \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g'
}

hr()  { printf '%s\n' "--------------------------------------------------------------------------------"; }
step() { hr; printf '### %s\n' "$*"; hr; }
note() { printf '    %s\n' "$*"; }

# POST a walker/function and print its reports. Never used as proof on its own.
#
# The body is also tee'd to /tmp/chain-last.json so `errcheck` can look at it.
# Without that, an `{"ok":false,"type":"error",...}` body renders as an EMPTY
# reports list through `jq '.data.reports[]?'` and a dead stage reads as a quiet
# one - which is the exact failure mode this whole script exists to catch.
post() { # post <path> <json>
  curl -s -m 900 -X POST "$HOST$1" -H 'Content-Type: application/json' -d "$2" \
    | tee /tmp/chain-last.json
}

# Surface a server-side execution error loudly. Call after any stage that matters.
errcheck() { # errcheck <stage label>
  local ok msg
  # NOTE: `jq '.ok // "absent"'` is WRONG here and cost a run to find. jq's `//`
  # is "alternative on false OR null", so an `{"ok": false}` body evaluates to
  # "absent" and the error check silently passes. Test for the KEY, not the value.
  ok="$(jq -r 'if has("ok") then (.ok|tostring) else "absent" end' /tmp/chain-last.json 2>/dev/null)"
  if [ "$ok" = "false" ]; then
    msg="$(jq -r '.error.message // .error.code // "unknown"' /tmp/chain-last.json 2>/dev/null)"
    printf '    !! SERVER ERROR in %s\n' "$1"
    printf '    !! %s\n' "$(printf '%s' "$msg" | redact | head -c 300)"
    printf '    !! This stage did NOT run. Any count that moved was moved by an earlier stage.\n'
  fi
}

# --- the census --------------------------------------------------------------
# Read straight off the server. This is the only thing this script trusts.
CENSUS_PREV=""
census() { # census <label>
  local raw c
  raw="$(post /function/graph_health '{}')"
  c="$(printf '%s' "$raw" | jq -c '.data.result' 2>/dev/null)"
  if [ -z "$c" ] || [ "$c" = "null" ]; then
    printf '  GRAPH [%s]  !! graph_health did not answer: %s\n' "$1" "$(printf '%s' "$raw" | head -c 200 | redact)"
    return
  fi
  printf '  GRAPH [%s]\n' "$1"
  printf '%s' "$c" | jq -r 'to_entries[] | "      \(.key): \(.value)"'
  if [ -n "$CENSUS_PREV" ]; then
    local delta
    delta="$(jq -n --argjson a "$CENSUS_PREV" --argjson b "$c" \
      '[$b|to_entries[]|select(.value != ($a[.key]))|"\(.key) \($a[.key])->\(.value)"]|join("  ")' 2>/dev/null)"
    if [ "$delta" = '""' ] || [ -z "$delta" ] || [ "$delta" = "" ]; then
      printf '      (no change)\n'
    else
      printf '      MOVED: %s\n' "$(printf '%s' "$delta" | tr -d '"')"
    fi
  fi
  CENSUS_PREV="$c"
}

# =============================================================================
step "0. PREFLIGHT — is this a real server, and is it anonymous?"
HEALTH="$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST "$HOST/function/graph_health" -H 'Content-Type: application/json' -d '{}')"
note "host                : $HOST"
note "graph_health        : HTTP $HEALTH   (/healthz is NOT used here - it returns 200 through a total outage)"
[ "$HEALTH" = "200" ] || { echo "!! server is not serving. ops/serve.sh first."; exit 1; }
ROUTES="$(curl -s -m 15 "$HOST/openapi.json" | jq -r '.paths|keys[]' | grep -c '^/walker/[A-Za-z]*$')"
note "walker endpoints    : $ROUTES registered"
note "anonymous POST      : no Authorization header is sent anywhere in this script"
census "start"

# =============================================================================
step "1. INTAKE — a Founder on the graph"
# The real intake is bridge.begin_product, which did not exist when this was
# written, and `PlanCampaign`'s own error text points at an `IntakeFounder`
# walker that exists nowhere in the repo. `ResearchWarmLead` (lane_w.jac) is the
# only walker that builds a REAL Founder from .env - but main.jac does not
# import lane_w, so it is not registered. Try it anyway: the day it is
# registered this script starts using the real door with no edit.
RWL="$(curl -s -m 300 -o /tmp/chain-rwl.json -w '%{http_code}' -X POST "$HOST/walker/ResearchWarmLead" -H 'Content-Type: application/json' -d '{}')"
if [ "$RWL" = "200" ]; then
  note "intake source       : /walker/ResearchWarmLead  (REAL intake)"
  jq -c '.data.reports' /tmp/chain-rwl.json 2>/dev/null | redact | head -c 600; echo
else
  note "intake source       : ResearchWarmLead returned HTTP $RWL - not registered on this build."
  note "                      main.jac has no 'import from lane_w', so the route does not exist."
  note "!! FALLING BACK to SeedRehearsalProspect. THIS IS REHEARSAL SCAFFOLDING, NOT INTAKE."
  note "   The Founder it builds is real (name/one-liner from .env); the prospect it"
  note "   attaches is seeded, and every downstream count is therefore attributable to"
  note "   the seed rather than to research UNTIL RunResearch runs in stage 3."
  SEED_QUOTE="${CHAIN_SEED_QUOTE:-}"
  if [ -z "$SEED_QUOTE" ]; then
    note "   CHAIN_SEED_QUOTE is unset. The seeder refuses to create an evidence-free"
    note "   prospect (by design - it would let ComposeOutreach appear to work while"
    note "   producing a generic email). Seeding the FOUNDER ONLY via SeedRehearsalRun."
    post /walker/SeedRehearsalRun '{"confirm":"yes"}' | jq -c '.data.reports[0] // .data' 2>/dev/null | redact | head -c 400; echo
  else
    post /walker/SeedRehearsalProspect "$(jq -n --arg q "$SEED_QUOTE" '{confirm:"rehearsal",linkedin_quote:$q}')" \
      | jq -c '.data.reports' 2>/dev/null | redact | head -c 600; echo
  fi
fi
census "after intake"

# =============================================================================
step "2. PLAN — Founder -> ICP"
post /walker/PlanCampaign '{}' | jq -r '.data.reports[0] // .data | tojson' 2>/dev/null | redact | head -c 900; echo
errcheck "PlanCampaign"
census "after PlanCampaign"

# =============================================================================
step "3. RESEARCH — the Go button, four lanes plus the warm lead"
# `run` is sent explicitly as null. `has run: any = None` emits NO default into
# the OpenAPI schema, so the endpoint builder marks it REQUIRED and a plain
# `{}` body is rejected with HTTP 422 before the walker ever runs:
#     {"detail":[{"type":"missing","loc":["body","run"],"msg":"Field required"}]}
# That is a live defect on the demo's critical path, and this line is the
# workaround, not a fix. Same class hits LaneA/LaneB/LaneC/LinkedInLane
# (tactics, lane_node, browser).
note "sending {\"run\": null} - a bare {} is HTTP 422 on this build, see comment above"
RSTART=$(date +%s)
RCODE="$(curl -s -m 900 -o /tmp/chain-research.json -w '%{http_code}' -X POST "$HOST/walker/RunResearch" -H 'Content-Type: application/json' -d '{"run": null}')"
cp /tmp/chain-research.json /tmp/chain-last.json
REL=$(( $(date +%s) - RSTART ))
note "HTTP status         : $RCODE"
note "wall clock          : ${REL}s"
errcheck "RunResearch"
note "reports             :"
jq -r '.data.reports[]? | tojson' /tmp/chain-research.json 2>/dev/null | redact | head -c 2500 | sed 's/^/      /'; echo
if [ "$REL" -lt 2 ]; then
  note "!! UNDER 2 SECONDS. A real fan-out cannot finish that fast. Treat as a no-op"
  note "   until the census below proves otherwise."
fi
census "after RunResearch"
note "lanes as the dashboard sees them:"
post /function/list_lanes '{}' | jq -r '.data.result[]? | "      lane \(.lane_id)  state=\(.state // "?")  prospects=\(.prospect_count // 0)  \(.doctrine // "" | .[0:60])"' 2>/dev/null | redact

# =============================================================================
step "4. CROSS-LINK — one human across two networks"
post /walker/CrossLinkToLinkedIn '{}' | jq -c '.data.reports' 2>/dev/null | redact | head -c 700; echo
post /walker/CrossLinkToGithub   '{}' | jq -c '.data.reports' 2>/dev/null | redact | head -c 700; echo
census "after cross-link"

# =============================================================================
step "5. IDENTITY — the email waterfall and its refusal gate"
post /walker/ResolveEmail '{}' | jq -r '.data.reports[0] // {} | tojson' 2>/dev/null | redact | head -c 1200; echo
census "after ResolveEmail"

# =============================================================================
step "6. RANK — S/A tiering, convergence multiplier, drop ledger"
post /walker/RankAndSelect '{"top_n":3}' | jq -r '.data.reports[0] // {} | tojson' 2>/dev/null | redact | head -c 1500; echo
census "after RankAndSelect"
note "prospects as the dashboard sees them:"
post /function/list_prospects '{}' \
  | jq -r '.data.result[]? | "      \(.name // "?")  tier=\(.tier // "?")  score=\(.score // 0)  email=\(if (.email // "") != "" then "yes" else "no" end)"' 2>/dev/null | redact

# Pick the best-scoring prospect that has an email — the one the rest of the
# chain acts on. Chosen from the GRAPH, not carried forward from a report.
TARGET="$(post /function/list_prospects '{}' \
  | jq -r '[.data.result[]? | select((.email // "") != "")] | sort_by(-(.score // 0)) | .[0].jid // .[0].id // empty' 2>/dev/null)"
TARGET_NAME="$(post /function/list_prospects '{}' \
  | jq -r '[.data.result[]? | select((.email // "") != "")] | sort_by(-(.score // 0)) | .[0].name // empty' 2>/dev/null)"
note "chain target        : ${TARGET_NAME:-<none>}  id=${TARGET:-<none>}"

# =============================================================================
step "7. COMPOSE — a cited email, or a refusal"
if [ -z "${TARGET:-}" ]; then
  note "!! no prospect with an email on the graph. The chain stops being able to act here."
  note "   That is a real outcome, not a script bug: lanes A and C surface zero today"
  note "   (LinkedIn rotated their class names) and Lane W is skipped when"
  note "   TEAMMATE_LINKEDIN_URL is unset."
else
  post /walker/ComposeOutreach "$(jq -n --arg p "$TARGET" '{prospect_id:$p}')" \
    | jq -r '.data.reports[0] // {} | tojson' 2>/dev/null | redact | head -c 2000; echo
  errcheck "ComposeOutreach"
fi
census "after ComposeOutreach"

# =============================================================================
step "8. SEND — GATED (a real email to a real human)"
if [ "$DO_SEND" = "1" ] && [ -n "${TARGET:-}" ]; then
  note "--send was passed. Sending for real."
  post /walker/SendOutreach "$(jq -n --arg p "$TARGET" '{prospect_id:$p}')" \
    | jq -r '.data.reports[0] // {} | tojson' 2>/dev/null | redact | head -c 1200; echo
  census "after SendOutreach"
else
  note "NOT RUN. This link ends at a real stranger's inbox and is off by default."
  note "COVERED BY SEGMENT PROOF: evidence/lane_w_to_email.txt - live LinkedIn ->"
  note "  Lane W -> ComposeOutreach with refused:False, addressed_as the name she"
  note "  actually goes by, a verbatim citation from her real About section, and"
  note "  EmailThread count 0 -> 1. Re-run this script with --send to close it live."
fi

# =============================================================================
step "9. CALL — GATED (a real phone rings)"
if [ "$DO_CALL" = "1" ] && [ -n "${TARGET:-}" ]; then
  note "--call was passed. Placing a real call."
  post /walker/ScheduleCall "$(jq -n --arg p "$TARGET" '{prospect_id:$p}')" \
    | jq -r '.data.reports[0] // {} | tojson' 2>/dev/null | redact | head -c 1200; echo
elif [ -n "${TARGET:-}" ]; then
  note "NOT RUN LIVE. Running ScheduleCall with dry_run=true instead: every id is"
  note "resolved from the live Vapi account and the dossier is built from the graph,"
  note "but no phone rings."
  post /walker/ScheduleCall "$(jq -n --arg p "$TARGET" '{prospect_id:$p,dry_run:true}')" \
    | jq -r '.data.reports[0] // {} | {ok,dry_run,prospect,dossier_chars,tool_urls,server_url,earliest_at} | tojson' 2>/dev/null | redact | head -c 1200; echo
  note "NOTE: dry_run disengages BEFORE creating a CallSession, so stage 10 below"
  note "cannot resolve a dossier from it. That is honest, not a gap in the script."
fi
census "after ScheduleCall"

# =============================================================================
step "10. MID-CALL — the tool endpoint Vapi actually calls"
# This is the segment that failed on call 019fa115: the graph lookup resolved in
# 0.013ms and Vapi still said "No result returned", because the response was
# wrapped in the standard {"ok":...,"data":...} envelope. `@restspec(
# envelope=False)` on a def:pub adapter is the fix. What is asserted here is the
# WIRE FORMAT, byte for byte, because that is what was broken.
cat > /tmp/chain-kb.json <<'PAYLOAD'
{"message":{"type":"tool-calls","toolCallList":[{"id":"chain_probe_001","type":"function","function":{"name":"answer_from_graph","arguments":{"question":"What do you already know about me?"}}}],"call":{"id":"chain-probe-no-live-call"}}}
PAYLOAD
curl -s -m 30 -X POST "$HOST/vapi/kb" -H 'Content-Type: application/json' --data @/tmp/chain-kb.json -o /tmp/chain-kb-out.json
note "RAW response body ($(wc -c < /tmp/chain-kb-out.json | tr -d ' ') bytes), byte for byte:"
cat /tmp/chain-kb-out.json | redact | sed 's/^/      /'; echo
if jq -e '(keys == ["results"])' /tmp/chain-kb-out.json >/dev/null 2>&1; then
  note "PASS  top-level keys are exactly [\"results\"] - no ok/data/type/meta wrapper"
else
  note "FAIL  top-level keys are $(jq -c 'keys' /tmp/chain-kb-out.json 2>/dev/null) - the envelope is back"
fi
jq -r 'if (.results[0].result|type)=="string" then "    PASS  result is a STRING, matching the OpenAPI type: string"
       else "    FAIL  result is a " + (.results[0].result|type) end' /tmp/chain-kb-out.json 2>/dev/null
jq -r '"    toolCallId echoed: " + (.results[0].toolCallId // "MISSING")' /tmp/chain-kb-out.json 2>/dev/null
RESOLVED="$(jq -r '.results[0].result' /tmp/chain-kb-out.json 2>/dev/null | head -c 60)"
case "$RESOLVED" in
  "No research is on file"*)
    note "!! this is the FALLBACK string. KbQuery resolves a dossier from a CallSession"
    note "   (cache -> graph -> sole-session), and no CallSession exists without a real"
    note "   call. So the WIRE FORMAT is proven here and the GRAPH-BACKED ANSWER is not."
    note "COVERED BY SEGMENT PROOF: evidence/voice_call_019fa115_analysis.txt - the"
    note "   dossier lookup resolving in 0.013ms with resolved_by: cache on a live call."
    note "   Together: 019fa115 proves the lookup, this proves the wire format it"
    note "   needed. Run with --call to join them in one pass." ;;
  *) note "graph-backed answer returned (not the fallback string)." ;;
esac

# =============================================================================
step "11. BOOK — GATED (a real event on a real calendar)"
if [ "$DO_BOOK" = "1" ]; then
  note "--book was passed."
  post /walker/BookInterview "$(jq -n --arg p "${TARGET:-}" '{prospect_id:$p,spoken_time:"tomorrow at 2pm",duration_minutes:30}')" \
    | jq -r '.data.reports[0] // {} | tojson' 2>/dev/null | redact | head -c 1200; echo
else
  note "NOT RUN. Writes a real Google Calendar event and emails an invite to a real"
  note "person. COVERED BY SEGMENT PROOF: evidence/live_booking_proof / proof_outreach"
  note "  - a real Meet link created and both parties invited."
  note "The wire format of its Vapi adapter IS proven live - /vapi/book returns"
  note "  {\"results\":[{\"toolCallId\":\"...\",\"result\":\"<string>\"}]} on the failure"
  note "  path too, so the agent speaks the reason instead of claiming success."
fi
census "after booking stage"

# =============================================================================
step "12. SYNTHESIZE — call -> Insight nodes"
post /walker/OnCallEnd '{"message":{},"call_id":"chain-probe-no-live-call","transcript":""}' \
  | jq -r '.data.reports[0] // {} | tojson' 2>/dev/null | redact | head -c 900; echo
census "after OnCallEnd"

# =============================================================================
step "CHAIN COMPLETE"
note "Everything above was driven over HTTP against $HOST and every claim is"
note "backed by a census read back out of the server, not by a walker's return value."
note ""
note "GATES NOT CLOSED IN THIS RUN (each names the segment proof that covers it):"
[ "$DO_SEND" = "1" ] || note "  - SendOutreach   : real email to a real human      -> evidence/lane_w_to_email.txt"
[ "$DO_CALL" = "1" ] || note "  - ScheduleCall   : a real phone rings              -> evidence/voice_call_019fa115_analysis.txt"
[ "$DO_BOOK" = "1" ] || note "  - BookInterview  : a real calendar event           -> evidence/live_booking_proof"
note ""
note "Close them all in one pass with:  ops/chain.sh --send --call --book"
