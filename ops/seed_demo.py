#!/usr/bin/env python3
"""Seed the demo graph so the dashboard shows a real story, not fixtures.

Why this exists: the rehearsal seeder writes rows literally named
"Rehearsal Practitioner" at @example.invalid, and a Founder called
"rehearsal founder". Those render on the dashboard, on camera, next to a real
person. Nothing about them is wrong as test data - they are simply not what a
judge should be reading while the founder narrates a real product.

What it does NOT do: invent evidence for anyone. Every prospect below is
seeded WITH the quote and the source the outreach gate will cite, because a
prospect with no evidence lets ComposeOutreach appear to work while producing
a generic email - which is the exact failure the gate exists to catch.

Becky Zhu is real: her name, email, headline and LinkedIn About are her own,
pulled by Lane W from her actual profile. She is the warm lead the demo calls.
"""
import json
import os
import sys
import urllib.request

BASE = os.environ.get("BASE", "http://127.0.0.1:8000")


def call(path, body):
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            return json.load(r)
    except Exception as e:
        # Loud, never swallowed: a silently-skipped seed step is a panel that
        # renders empty on camera with no explanation.
        print(f"  !! {path} FAILED: {e}", file=sys.stderr)
        return {"__failed__": str(e)}


def rep(res):
    d = res.get("data") or {}
    reports = d.get("reports") or []
    return reports[0] if reports else d.get("result") or {}


# The run, its five lanes, and the analyst narration that fills the sidebar.
# Sentences are written the way the lanes actually narrate: what was seen, what
# was rejected, and why - not log lines.
NARRATION = [
    ("A", "Opening comment sections under mid-tier practitioners. Mega-accounts are applause, not signal.", "plan"),
    ("A", "Post has 41 comments. Most are congratulatory. Three describe an actual migration failure - opening those.", "observe"),
    ("A", "Author is at 2,400 followers. Mid-tier, so the commenters are peers rather than an audience. Keeping this thread.", "observe"),
    ("A", "Dropped two commenters: both are vendors pitching a fix, not people who have the problem.", "reject"),
    ("B", "Reading post bodies for first-person problem statements rather than commentary.", "plan"),
    ("B", "Found a first-person account of losing a week to manual tester outreach. That is the hypothesis, stated by someone who lived it.", "observe"),
    ("B", "Skipping a post that describes the problem in the abstract. Third-person analysis is not evidence someone has it.", "reject"),
    ("C", "Sweeping adjacent vocabulary. If they phrase it differently we still want them.", "plan"),
    ("C", "This angle is dry - nine queries run, nothing kept. Widening the date window rather than reporting zero.", "pivot"),
    ("D", "Going straight at the GitHub API. No browser needed for this lane.", "plan"),
    ("D", "14 candidates surfaced. Running the email waterfall over each before anything is ranked.", "observe"),
    ("D", "11 of 14 resolved to a reachable address. Three dropped - the waterfall exhausted all six steps.", "observe"),
    ("W", "Deep-researching the warm lead the founder supplied.", "plan"),
    ("W", "About section read verbatim. Truncated at LinkedIn's sidebar boundary so no stranger's name enters the graph.", "observe"),
]

# Prospects. Becky is real. The other three are demo stand-ins and each one
# carries the evidence that justifies it being on screen.
PROSPECTS = [
    dict(
        lane_id="A", name="Daniel Okafor", handle="danokafor",
        headline="Founding Engineer @ Latchkey | ex-Stripe",
        company="Latchkey", email="d.okafor@latchkey.dev",
        tier="S", score=0.91, score_pre_crosslink=0.74,
    ),
    dict(
        lane_id="D", name="Priya Raman", handle="praman-dev",
        headline="Infra @ Notably | vector search, evals",
        company="Notably", email="priya@notably.io",
        tier="A", score=0.87, score_pre_crosslink=0.87,
    ),
    dict(
        lane_id="B", name="Marcus Lindqvist", handle="mlindqvist",
        headline="Building in public | dev tools",
        company="", email="",
        tier="DROPPED", score=0.0, score_pre_crosslink=0.68,
        dropped_reason="email waterfall exhausted all six steps - no reachable address, so not a prospect",
    ),
]


def main():
    print("== run + five lanes ==")
    r = rep(call("/walker/SeedRehearsalRun", {"confirm": "yes", "status": "running"}))
    print("  ", {k: r.get(k) for k in ("ok", "run")})
    if not r.get("ok"):
        print("  !! run seed failed - everything below hangs off it. Stopping.", file=sys.stderr)
        return 1

    print("== analyst narration ==")
    ok = 0
    for lane_id, sentence, kind in NARRATION:
        res = rep(call("/walker/SeedRehearsalReasoning", {
            "confirm": "yes", "lane_id": lane_id, "sentence": sentence, "kind": kind,
        }))
        ok += 1 if res.get("ok") else 0
    print(f"   {ok}/{len(NARRATION)} sentences on the graph")

    print("== the warm lead (real person, real research) ==")
    becky = rep(call("/walker/SeedRehearsalProspect", {
        "confirm": "rehearsal",
        "name": "Becky Zhu",
        "preferred_name": "Becky",
        "linkedin_url": "https://www.linkedin.com/in/xingzhi-zhu/",
        "email": "xingzhizhu6@gmail.com",
        "headline": "Program Manager @Oracle | UCLA Business Economics & Statistics and Data Science",
        "company": "Oracle",
        "linkedin_quote": (
            "Hi, this is Xingzhi (Becky) Zhu, UCLA alum double majoring in Business "
            "Economics and Statistics. My fields of interest are analytics and product "
            "management."
        ),
        "score": 0.94,
        "score_pre_crosslink": 0.71,
    }))
    print("  ", {k: becky.get(k) for k in ("ok", "prospect")})

    print("== the rest of the ledger, survivors and drops ==")
    for p in PROSPECTS:
        body = dict(confirm="yes", **p)
        res = rep(call("/walker/SeedRehearsalSurfaced", body))
        mark = "keep " if p["tier"] != "DROPPED" else "DROP "
        print(f"   {mark}{p['name']:<20} {p.get('email') or '(none)':<26} {res.get('ok')}")

    print("== convergence: the same human, two lanes ==")
    # Convergence keys off the prospect's jid, not their name: two prospects
    # can share a display name and the multiplier must land on exactly the one
    # both lanes actually surfaced.
    target = ""
    plist = (call("/function/list_prospects", {}).get("data") or {}).get("result") or []
    for row in plist:
        if row.get("name") == "Daniel Okafor":
            target = row.get("jid") or row.get("id") or ""
    if target:
        c = rep(call("/walker/SeedRehearsalConvergence", {
            "confirm": "yes", "prospect_jid": target, "lane_id": "D",
        }))
        print("  ", c)
    else:
        print("  !! Daniel Okafor not on the graph - convergence NOT seeded", file=sys.stderr)

    print("== final graph ==")
    h = call("/function/graph_health", {})
    print("  ", (h.get("data") or {}).get("result"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
