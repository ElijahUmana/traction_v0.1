#!/usr/bin/env python3
"""Seed a run-shaped graph and capture REAL wire responses for the contract doc.

Every JSON in docs/FRONTEND_INTEGRATION.md comes from this script's output.
Nothing is hand-written.
"""
import json
import time
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8000"
OUT = "/tmp/traction-evidence"


def call(path, body, tries=4):
    """POST with retry.

    Retries cover ordinary transient failures only.

    They do NOT cover the `'JacScaleUserManager' object has no attribute
    '_lock'` 500. That one NEVER recovers - measured 6/6 failures 0.6s apart.
    It means the guest root in users.db disagrees with anchor_store.db, which
    happens when a data dir is wiped under a live process or two servers share
    one checkout. Retrying is the wrong response; see docs/RUNBOOK.md.
    """
    last = None
    for attempt in range(tries):
        req = urllib.request.Request(
            BASE + path, data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            last = f"HTTP {e.code}: {e.read().decode()[:200]}"
            time.sleep(0.7 * (attempt + 1))
        except urllib.error.URLError as e:
            last = f"URLError: {e}"
            time.sleep(0.7 * (attempt + 1))
    raise SystemExit(f"{path} failed after {tries} tries -> {last}")


def rep(resp):
    return resp["data"]["reports"][0]


def main():
    print("== seeding run ==")
    r = call("/walker/SeedRehearsalRun", {"confirm": "yes", "status": "running"})
    print(" ", rep(r))

    sentences = [
        ("A", "Scanning comments under mid-tier practitioner posts; skipping the "
              "90%-'great post!' megathreads by design.", "observe"),
        ("A", "Found a commenter describing their eval harness breaking weekly - "
              "that is a first-person problem statement, not clout.", "judge"),
        ("B", "Post author writes in first person about shipping without regression "
              "tests on prompts. Keeping.", "observe"),
        ("C", "'LLM ops' is returning vendor marketing, not practitioners. This angle "
              "is dry - switching to 'model monitoring'.", "pivot"),
        ("D", "GitHub search: repos touching eval harnesses updated in the last 30 "
              "days, 2+ contributors.", "observe"),
        ("D", "Commit email resolved from search/commits in one global call.", "hit"),
    ]
    for lane, s, kind in sentences:
        call("/walker/SeedRehearsalReasoning",
             {"confirm": "yes", "lane_id": lane, "sentence": s, "kind": kind})
    print(f"  seeded {len(sentences)} reasoning sentences")

    print("== seeding ledger (survivors AND drops) ==")
    p1 = rep(call("/walker/SeedRehearsalSurfaced", {
        "confirm": "yes", "lane_id": "A", "name": "Rehearsal Practitioner",
        "handle": "rehearsal-practitioner", "headline": "Staff engineer, ML platform",
        "company": "Rehearsal Co", "email": "rehearsal.survivor@example.invalid",
        "tier": "S", "score": 0.94, "score_pre_crosslink": 0.71}))
    print("  survivor:", p1)
    call("/walker/SeedRehearsalSurfaced", {
        "confirm": "yes", "lane_id": "B", "name": "Rehearsal Second",
        "handle": "rehearsal-second", "headline": "Founding engineer",
        "company": "Second Co", "email": "rehearsal.second@example.invalid",
        "tier": "A", "score": 0.62, "score_pre_crosslink": 0.62})
    call("/walker/SeedRehearsalSurfaced", {
        "confirm": "yes", "lane_id": "C", "name": "Rehearsal Dropped",
        "handle": "rehearsal-dropped", "headline": "Indie hacker",
        "company": "", "email": "", "tier": "DROPPED", "score": 0.0,
        "dropped_reason": "no email resolvable after all six waterfall steps"})

    if p1.get("ok"):
        c = rep(call("/walker/SeedRehearsalConvergence", {
            "confirm": "yes", "prospect_jid": p1["prospect"], "lane_id": "D"}))
        print("  convergence:", c)

    print("== capturing real envelopes ==")
    captures = {}
    for name, path, body in [
        ("get_run_state", "/function/get_run_state", {}),
        ("list_lanes", "/function/list_lanes", {}),
        ("list_prospects", "/function/list_prospects", {}),
        ("feed_since", "/function/feed_since", {"since": 0}),
    ]:
        captures[name] = call(path, body)
        print(f"  {name}: ok")

    with open(f"{OUT}/captured-envelopes.json", "w") as f:
        json.dump(captures, f, indent=2)
    print(f"wrote {OUT}/captured-envelopes.json")

    # stable-jid proof: same call twice
    a = call("/function/list_lanes", {})
    b = call("/function/list_lanes", {})
    ia = [x["_jac_id"] for x in a["data"]["result"]]
    ib = [x["_jac_id"] for x in b["data"]["result"]]
    print("JID_STABLE_ACROSS_CALLS =", ia == ib)


if __name__ == "__main__":
    main()
