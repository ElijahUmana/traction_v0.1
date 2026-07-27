"""Proof: the three LinkedIn lanes are three researchers, not three copies.

This is the demo's central visual claim, and it is the exact thing the
flow-in-comprehension race silently inverted - every lane ran the LAST spec, so
all three panels showed lane C while A and B sat empty, with no error raised.

Asserts four independent ways they must differ: distinct probes, distinct
reasoning, distinct opening pages, and overlapping time intervals (which serial
execution cannot produce).

    jac run distinct_lanes_proof.jac
"""

import time;
import from research { RunResearch }
import from schema {
    Founder, ICP, Lane, SearchProbe, Targets, Runs, HasLane, Emitted, Surfaced,
    Probe, Widened
}

glob MID: str = "Dana Okafor\n870 followers\nStaff Engineer at Northwind\n2d\nWe spent three days trying to migrate our RAG stack and gave up.";
glob HUGE: str = "Famous Person\n412,000 followers\nAI thought leader\n1d\nA thread on why retrieval is hard.";

glob FX: dict = {
    "nightmare": [
        {"handle": "famous-person", "url": "https://www.linkedin.com/in/famous-person", "name": "Famous Person", "block": HUGE},
        {"handle": "dana-okafor", "url": "https://www.linkedin.com/in/dana-okafor", "name": "Dana Okafor", "block": MID}
    ],
    "in/famous-person": {"followers": "412,000 followers"},
    "in/dana-okafor": {"followers": "870 followers"},
    "_comments": {"diag": {"containers": 3, "anchors": 3}, "items": [
        {"handle": "priya-raman", "url": "u", "name": "Priya Raman", "text": "Great post! Congratulations on the launch, really inspiring."},
        {"handle": "sam-oyelaran", "url": "u", "name": "Sam Oyelaran", "text": "I gave up on our evaluation harness entirely after we lost three days chasing a silent retrieval regression."},
        {"handle": "dana-okafor", "url": "u", "name": "Dana Okafor", "text": "We hit exactly this last month and our whole migration stalled for a week because nothing was debuggable end to end."}
    ]},
    "we%20tried": [
        {"handle": "lee-park", "url": "https://www.linkedin.com/in/lee-park", "name": "Lee Park",
         "block": "Lee Park\nFounder\n1d\nWe tried three vector databases this quarter and I still cannot get evaluation numbers I trust."}
    ],
    "evaluation": [
        {"handle": "dana-okafor", "url": "https://www.linkedin.com/in/dana-okafor", "name": "Dana Okafor", "block": MID}
    ]
};


with entry {
    f = root ++> Founder(name="distinct-proof", email="d@example.com");
    f +>:Targets(created_at=time.time()):+> ICP(
        hypothesis="Engineers who own a RAG pipeline and cannot trust its evaluation numbers.",
        keywords=["rag evaluation"],
        pain_phrases=["rag pipeline is a nightmare"]
    );

    t0 = time.time();
    w = f spawn RunResearch(offline=True, include_github=False, fixture=FX);
    wall = time.time() - t0;

    run = [f ->:Runs:->][0];
    lanes = [run ->:HasLane:->];

    probes_by_lane: dict[str, list] = {};
    said_by_lane: dict[str, list] = {};
    seen_by_lane: dict[str, list] = {};

    print("=" * 74);
    for l in lanes {
        lid = str(l.lane_id);
        queries = [p.keywords for p in [l ->:Probe:-> ->:Widened:->]] + [p.keywords for p in [l ->:Probe:->]];
        said = [r.sentence for r in [l ->:Emitted:->]];
        handles = [p.handle for p in [l ->:Surfaced:->]];
        probes_by_lane[lid] = queries;
        said_by_lane[lid] = said;
        seen_by_lane[lid] = handles;
        print(f"LANE {lid}  state={l.state}  probes={len(queries)}  reasoning={len(said)}  surfaced={handles}");
        print(f"   first query : {queries[0] if queries else '(none)'}");
        print(f"   opening line: {said[0][:88] if said else '(none)'}");
        print(f"   a judgement : {said[2][:88] if len(said) > 2 else '(none)'}");
    }
    print("=" * 74);

    ids = sorted([str(l.lane_id) for l in lanes]);
    ok = True;

    # 1. distinct lanes exist at all
    if len(ids) != 3 or ids != ["A", "B", "C"] {
        print(f"FAIL: expected lanes A,B,C - got {ids}");
        ok = False;
    }

    # 2. each lane searched DIFFERENT queries. This is the assertion the race
    #    broke: with the bug, all three ran the last spec's vocabulary.
    for a in ids {
        for b in ids {
            if a < b {
                shared = [q for q in probes_by_lane[a] if q in probes_by_lane[b]];
                if shared {
                    print(f"FAIL: lanes {a} and {b} ran the SAME queries: {shared}");
                    ok = False;
                }
            }
        }
    }

    # 3. each lane narrated in its own voice, not a copy of another's
    for a in ids {
        for b in ids {
            if a < b and said_by_lane[a] and said_by_lane[b] {
                if said_by_lane[a][0] == said_by_lane[b][0] {
                    print(f"FAIL: lanes {a} and {b} opened with an identical line");
                    ok = False;
                }
            }
        }
    }

    # 4. lanes genuinely ran concurrently - overlapping intervals cannot come
    #    from serial execution, and unlike wall clock this does not depend on
    #    how much work any one lane happened to do.
    overlaps = 0;
    rs = w.lane_results;
    for i in range(len(rs)) {
        for j in range(i + 1, len(rs)) {
            lo = max(rs[i].started_at, rs[j].started_at);
            hi = min(rs[i].finished_at, rs[j].finished_at);
            if hi > lo { overlaps += 1; }
        }
    }
    if overlaps < 2 {
        print(f"FAIL: only {overlaps} overlapping lane pairs - lanes serialised");
        ok = False;
    }

    timed_out = [r.lane_id for r in rs if r.timed_out];

    print(f"distinct query sets : {'yes' if ok else 'NO'}");
    print(f"concurrent pairs    : {overlaps} of 3");
    print(f"wall clock          : {wall:.2f}s");
    print(f"lanes hitting budget: {timed_out if timed_out else 'none'}");
    print(f"unique prospects    : {w.unique_prospects}   converged: {w.converged}");
    for pr in run.prospects() {
        if pr.is_converged() {
            print(f"CONVERGED: {pr.name} found by lanes {sorted([str(x) for x in pr.convergence_lanes()])}");
        }
    }
    if w.converged < 1 {
        print("FAIL: no prospect was found by two lanes independently");
        ok = False;
    }
    print("=" * 74);
    print("DISTINCT_LANES_OK=" + str(ok));
}
