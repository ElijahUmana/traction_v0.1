#!/usr/bin/env python3
"""Place one test call and MEASURE whether it held a conversation.

The point of this file is that "it worked" is not evidence. After the call ends
this pulls the artifact back out of Vapi and computes, from timestamps:

  * time-to-first-word  - how long after answer the agent started speaking
  * turn latency        - per reply, the gap between the human finishing and the
                          agent starting. This is the number that decides whether
                          it reads as a conversation or as a broken robocall.
  * tool invocation     - did it actually call answer_from_graph / book_interview,
                          what did it pass, what came back, and how long did it wait
  * barge-in            - overlaps where the human started talking while the agent
                          was still speaking, and whether the agent stopped

    ops/vapi_callcheck.py +1555XXXXXXX          place a call, wait, report
    ops/vapi_callcheck.py --call <uuid>         re-report an existing call

Nothing here dials anybody on its own - the number is always explicit on the
command line.
"""
import json
import os
import subprocess
import sys
import time

ASSISTANT_ID = "4534de4a-eff5-4c58-ae66-916faf724249"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def env(name: str, default: str | None = None) -> str:
    with open(os.path.join(ROOT, ".env"), encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line.startswith(f"{name}="):
                return line.split("=", 1)[1].strip().strip('"')
    if default is not None:
        return default
    raise SystemExit(f"{name} is not set in .env")


def api(method: str, path: str, body: dict | None = None) -> dict:
    """curl rather than urllib - Cloudflare 403s the default python agent."""
    cmd = [
        "curl", "-s", "-X", method, f"https://api.vapi.ai{path}",
        "-H", f"Authorization: Bearer {env('VAPI_API_KEY')}",
        "-H", "Content-Type: application/json",
    ]
    if body is not None:
        cmd += ["-d", json.dumps(body)]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=60).stdout
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        raise SystemExit(f"non-JSON from {method} {path}: {out[:400]}")


def tools() -> list[dict]:
    """Mirror of midcall_tools() in voice.jac.

    Deliberately duplicated rather than imported: this harness has to prove what
    the PRODUCTION call does, so it must send the same tool shapes through the
    same `tools:append` override that voice.jac uses. `tools:append` is a real
    whitelisted Vapi key - verified by sending a nonsense sibling key, which the
    API rejected with "property bananas:append should not exist" while
    validating the contents of tools:append against its tool-type enum.
    """
    base = env("PUBLIC_BASE_URL").rstrip("/")
    return [
        {
            "type": "function",
            "async": False,
            "function": {
                "name": "answer_from_graph",
                "description": (
                    "Look up what our research actually found about THIS person and use "
                    "it to answer any question about why this is relevant to them."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "question": {
                            "type": "string",
                            "description": "The question they just asked, in their own words.",
                        }
                    },
                    "required": ["question"],
                },
            },
            "server": {"url": f"{base}/walker/KbQuery", "timeoutSeconds": 10},
        },
        {
            "type": "function",
            "async": False,
            "function": {
                "name": "book_interview",
                "description": (
                    "Book the call with this person and email them a calendar invite. "
                    "Call this the moment they name a time that works."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "start_time": {
                            "type": "string",
                            "description": "ISO 8601 datetime with timezone offset.",
                        },
                        "duration_minutes": {"type": "number"},
                    },
                    "required": ["start_time"],
                },
            },
            "messages": [
                {"type": "request-start", "content": "Booking that now."},
                {
                    "type": "request-complete",
                    "content": "Done, the invite is on its way to your email.",
                },
                {
                    "type": "request-failed",
                    "content": "I couldn't get that booked, I'll follow up by email.",
                },
            ],
            "server": {"url": f"{base}/walker/BookInterview", "timeoutSeconds": 25},
        },
    ]


def place(number: str) -> str:
    phones = api("GET", "/phone-number")
    listing = phones if isinstance(phones, list) else phones.get("data", [])
    want = env("VAPI_PHONE_NUMBER")
    phone_id = next(
        (p["id"] for p in listing if p.get("number") == want),
        listing[0]["id"] if listing else None,
    )
    if not phone_id:
        raise SystemExit("no phone number on this Vapi account")

    created = api("POST", "/call", {
        "phoneNumberId": phone_id,
        "assistantId": ASSISTANT_ID,
        "customer": {"number": number, "name": "Test"},
        "assistantOverrides": {
            "variableValues": {
                "prospect_name": "Becky",
                "prospect_profile_name": "Becky",
                "prospect_headline": "test run",
                "prospect_company": "test",
                "founder_name": "Elijah Umana",
                "product_one_liner": (
                    "TRACTION, an AI agent that researches people and books "
                    "interviews with them"
                ),
                "dossier": (
                    "This is a rehearsal call placed by the engineer to test the "
                    "agent. Answer their questions normally."
                ),
            },
            "tools:append": tools(),
        },
    })
    call_id = created.get("id")
    if not call_id:
        raise SystemExit(f"no call id returned: {json.dumps(created)[:400]}")
    print(f"call {call_id} -> {number}\nringing; answer it and talk to the agent")
    return call_id


def wait(call_id: str, limit: int = 420) -> dict:
    started = time.time()
    seen = ""
    while time.time() - started < limit:
        call = api("GET", f"/call/{call_id}")
        status = call.get("status", "?")
        if status != seen:
            print(f"  [{int(time.time() - started):3d}s] {status}")
            seen = status
        if status == "ended":
            # The artifact (transcript, per-message timings) lands a beat after
            # the call flips to ended.
            time.sleep(6)
            return api("GET", f"/call/{call_id}")
        time.sleep(3)
    raise SystemExit("call did not end within the limit")


def report(call: dict) -> int:
    msgs = (call.get("artifact") or {}).get("messages") or call.get("messages") or []
    convo = [m for m in msgs if m.get("role") != "system"]

    def start(m):
        return float(m.get("secondsFromStart") or 0.0)

    def end(m):
        return start(m) + float(m.get("duration") or 0.0) / 1000.0

    print("\n" + "=" * 72)
    print("TRANSCRIPT (t = seconds from call start)")
    print("=" * 72)
    for m in convo:
        role = m.get("role", "?")
        text = (m.get("message") or "").strip()
        if role == "tool_calls":
            for tc in m.get("toolCalls", []):
                fn = tc.get("function", {})
                text = f"CALL {fn.get('name')}({fn.get('arguments')})"
        elif role == "tool_call_result":
            text = f"RESULT {(m.get('result') or '')[:200]}"
        print(f"[{start(m):6.2f}] {role:16s} {text[:160]}")

    # ---- time to first word -------------------------------------------------
    first_bot = next((m for m in convo if m.get("role") == "bot"), None)
    ttfw = start(first_bot) if first_bot else None

    # ---- turn latency: human stops -> agent starts ---------------------------
    turns = []
    for i, m in enumerate(convo):
        if m.get("role") != "bot":
            continue
        prev = next(
            (p for p in reversed(convo[:i]) if p.get("role") == "user"), None
        )
        if prev is None:
            continue
        gap = start(m) - end(prev)
        if gap >= 0:
            turns.append((gap, (prev.get("message") or "")[:44]))

    # ---- barge-in: human starts while agent still speaking -------------------
    overlaps = []
    for i, m in enumerate(convo):
        if m.get("role") != "user":
            continue
        prev = next((p for p in reversed(convo[:i]) if p.get("role") == "bot"), None)
        if prev is not None and start(m) < end(prev) - 0.05:
            overlaps.append((start(m), end(prev) - start(m),
                             (prev.get("message") or "")[:40]))

    tool_calls = [m for m in convo if m.get("role") == "tool_calls"]
    tool_results = [m for m in convo if m.get("role") == "tool_call_result"]
    names = [
        tc.get("function", {}).get("name")
        for m in tool_calls for tc in m.get("toolCalls", [])
    ]

    print("\n" + "=" * 72)
    print("MEASUREMENTS")
    print("=" * 72)
    print(f"ended reason        : {call.get('endedReason')}")
    print(f"duration            : {call.get('endedAt') and round(float(call.get('costBreakdown', {}).get('total', 0)), 4)} USD")
    print(f"time to first word  : {ttfw:.2f}s" if ttfw is not None else "time to first word  : n/a")
    if turns:
        vals = sorted(t[0] for t in turns)
        print(f"turn latency        : n={len(vals)}  "
              f"min {vals[0]:.2f}s  median {vals[len(vals)//2]:.2f}s  max {vals[-1]:.2f}s")
        for gap, said in turns:
            flag = "  <-- SLOW" if gap > 2.0 else ""
            print(f"    {gap:5.2f}s  after human said: {said!r}{flag}")
    else:
        print("turn latency        : NO HUMAN TURNS - nobody spoke to it")
    print(f"barge-in overlaps   : {len(overlaps)}")
    for at, dur, during in overlaps:
        print(f"    human cut in at {at:.2f}s, {dur:.2f}s before agent would have "
              f"finished: {during!r}")
    print(f"tool calls          : {names or 'NONE'}")
    for m in tool_results:
        print(f"    result: {(m.get('result') or '')[:160]}")

    print("\n" + "=" * 72)
    print("VERDICT")
    print("=" * 72)
    ok = True
    if not turns:
        print("  FAIL  no human turns captured - this proves nothing about conversation")
        ok = False
    else:
        vals = sorted(t[0] for t in turns)
        median = vals[len(vals) // 2]
        verdict = "PASS" if median <= 2.0 else "FAIL"
        ok &= median <= 2.0
        print(f"  {verdict}  median turn latency {median:.2f}s (target <= 2.0s)")
    if names:
        print(f"  PASS  the agent invoked {len(names)} tool(s): {names}")
    else:
        print("  WARN  no tool was called - ask it a substantive question next run")
    if overlaps:
        print(f"  INFO  {len(overlaps)} barge-in(s) captured")
    else:
        print("  WARN  nobody talked over the agent - barge-in still unproven")
    return 0 if ok else 1


def main() -> int:
    args = [a for a in sys.argv[1:]]
    if "--call" in args:
        call_id = args[args.index("--call") + 1]
        return report(api("GET", f"/call/{call_id}"))
    if not args or not args[0].startswith("+"):
        raise SystemExit(
            "usage: vapi_callcheck.py +1XXXXXXXXXX   |   --call <uuid>\n"
            "the number is required and explicit on purpose."
        )
    call_id = place(args[0])
    call = wait(call_id)
    path = os.path.join(ROOT, "evidence", f"voice_call_{call_id[:8]}.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(call, fh, indent=2)
    rc = report(call)
    print(f"\nfull artifact: {path}")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
