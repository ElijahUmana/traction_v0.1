"""Tests for the research engine.

Runs with no network and no API keys. The lanes drive a fixture-backed browser
and the deterministic classifier, so the full pipeline - ladder, dry branch,
harvest, merge, convergence - is exercised offline.

The parallelism assertion is the interesting one: it does not measure total
wall clock (which would be sensitive to how much work each lane happens to do)
but checks that the lanes' [start, finish] intervals genuinely OVERLAP. Two
overlapping intervals cannot be produced by serial execution.
"""

import time;
import from lanes {
    content_search_url, build_ladder, tactics_a, tactics_b, tactics_c,
    reformulate, is_midtier, midtier_verdict, phrases_for_lane, next_rung
}
import from narration {
    say_comment_scan, say_convergence, say_pivot, say_merge, say_exhausted
}


# --- fixtures --------------------------------------------------------------
#
# Keyed by URL substring. Lane A searches the raw pain phrase, Lane C searches
# the topical keyword - and both are rigged to land on the same person, which
# is what the convergence assertion needs.

glob POST_BLOCK_MIDTIER: str =
    "Dana Okafor\n870 followers\nStaff Engineer at Northwind\n2d\n"
    + "We spent three days trying to migrate our RAG stack and gave up.";

glob POST_BLOCK_HUGE: str =
    "Famous Person\n412,000 followers\nAI thought leader\n1d\n"
    + "A thread on why retrieval is hard.";

glob FIXTURE: dict = {
    # Lane A - a mega account first (must be rejected), then a mid-tier one.
    "nightmare": [
        {"handle": "famous-person", "url": "https://www.linkedin.com/in/famous-person",
         "name": "Famous Person", "block": POST_BLOCK_HUGE},
        {"handle": "dana-okafor", "url": "https://www.linkedin.com/in/dana-okafor",
         "name": "Dana Okafor", "block": POST_BLOCK_MIDTIER}
    ],
    # Author stats read on the POST page - follower counts are not rendered on
    # search cards at all, which is why lane A's gate runs after opening the post.
    "in/famous-person": {"followers": "412,000 followers"},
    "in/dana-okafor": {"followers": "870 followers"},
    # Lane A's comment pass. The reader returns {items, diag} - diag carries the
    # container/anchor counts the lane narrates when a section looks empty.
    "_comments": {"diag": {"containers": 3, "anchors": 3}, "items": [
        {"handle": "priya-raman", "url": "https://www.linkedin.com/in/priya-raman",
         "name": "Priya Raman",
         "text": "Great post! Congratulations on the launch, really inspiring."},
        {"handle": "dana-okafor", "url": "https://www.linkedin.com/in/dana-okafor",
         "name": "Dana Okafor",
         "text": "We hit exactly this last month and our whole migration stalled "
                 + "for a week because nothing was debuggable end to end."},
        {"handle": "sam-oyelaran", "url": "https://www.linkedin.com/in/sam-oyelaran",
         "name": "Sam Oyelaran",
         "text": "I gave up on our evaluation harness entirely after we lost "
                 + "three days chasing a silent retrieval regression."}
    ]},
    # Lane B - authorship. Distinct person.
    "we%20tried": [
        {"handle": "lee-park", "url": "https://www.linkedin.com/in/lee-park",
         "name": "Lee Park",
         "block": "Lee Park\nFounder\n1d\nWe tried three vector databases this "
                  + "quarter and I still cannot get evaluation numbers I trust."}
    ],
    # Lane C - synonym sweep, rigged to re-find Dana. This is the convergence.
    "evaluation": [
        {"handle": "dana-okafor", "url": "https://www.linkedin.com/in/dana-okafor",
         "name": "Dana Okafor",
         "block": POST_BLOCK_MIDTIER}
    ]
};


def seed_founder(name: str) -> Founder {
    """A founder with an ICP whose phrases hit the fixture keys above.""";
    f = root ++> Founder(
        name=name, email=f"{name}@example.com",
        product_summary="Evaluation tooling for RAG pipelines."
    );
    f +>:Targets(created_at=time.time()):+> ICP(
        hypothesis="Engineers who own a RAG pipeline and cannot trust its "
                   + "evaluation numbers.",
        keywords=["rag evaluation"],
        pain_phrases=["rag pipeline is a nightmare"]
    );
    return f;
}


# ===========================================================================
# Pure layers - no graph, no browser
# ===========================================================================

test "search url quotes datePosted and sortBy" {
    u = content_search_url("rag pipeline", "past-24h");
    assert "keywords=rag%20pipeline" in u;
    # The literal double quotes are part of LinkedIn's filter values and must
    # survive as %22 - dropping them silently disables the filter.
    assert "datePosted=%22past-24h%22" in u;
    assert "sortBy=%22date_posted%22" in u;
}


test "reformulate widens by requiring fewer terms" {
    assert reformulate("rag pipeline is a nightmare") == "rag pipeline";
    # Already at its core - returning a value here would re-run an identical
    # query and burn a rung for nothing.
    assert reformulate("langchain") is None;
}


test "ladder escalates seed to widen to reformulate to next phrase" {
    lad = build_ladder(tactics_a(), ["rag pipeline is a nightmare", "vector db costs"]);
    moves = [p.move for p in lad];
    assert moves[0] == "seed";
    assert "widen_date" in moves;
    assert "reformulate" in moves;
    assert "next_phrase" in moves;
    # Every rung carries a reason fragment, because the pivot sentence is built
    # from it - a rung with no reason would narrate as an empty pivot.
    for p in lad {
        assert p.reason;
    }
    assert next_rung(lad, len(lad) - 1) is None;
}


test "linkedin chrome is stripped off names and headlines" {
    # Verified against live LinkedIn: the profile anchor's text is accessibility
    # chrome, and the first block line is often "Feed post".
    assert clean_name("View Neel Mahyavanshi\u2019s profile, open to work") == "Neel Mahyavanshi";
    assert clean_name("View Robin R.\u2019s profile") == "Robin R.";

    a = parse_actor(
        "Feed post Neel Mahyavanshi \u2022 2nd AI Engineer 25m \u2022 Follow",
        "View Neel Mahyavanshi\u2019s profile"
    );
    assert a.name == "Neel Mahyavanshi", a.name;
    assert "Feed post" not in a.headline;
    assert "AI Engineer" in a.headline, a.headline;

    b = parse_actor("Jay P. \u2022 3rd+ Staff AI Engineer @ Apple", "");
    assert b.name == "Jay P.", b.name;
    assert b.headline.startswith("Staff AI Engineer"), b.headline;
}


test "follower counts parse from post-page text, unknown stays unknown" {
    assert parse_followers("412,000 followers") == 412000;
    assert parse_followers("870 followers") == 870;
    assert parse_followers("12K followers") == 12000;
    # A card with no follower count must report UNKNOWN, never zero - lane A
    # gates on this and a fabricated zero would silently reject real people.
    assert parse_followers("Staff Engineer at Northwind") == -1;
}


test "mid-tier band rejects influencers and ghost accounts" {
    assert is_midtier(870);
    assert not is_midtier(412000);
    assert not is_midtier(40);
    assert midtier_verdict(412000) == "above";
    assert midtier_verdict(40) == "below";
}


test "each lane is handed different vocabulary" {
    pains = ["rag pipeline is a nightmare"];
    keys = ["rag evaluation"];
    a = phrases_for_lane("A", pains, keys);
    b = phrases_for_lane("B", pains, keys);
    c = phrases_for_lane("C", pains, keys);
    # Three lanes racing on one keyword list is three copies of one researcher.
    assert a != b and b != c and a != c;
    assert any(["we tried" in p for p in b]);
}


test "analyst voice reads as prose, not log lines" {
    s = say_comment_scan(41, 38, 3, "migration failure");
    assert s == (
        "41 comments, most congratulatory, three describe an actual "
        + "migration failure - opening those three."
    );
    # Small counts as words is most of what separates prose from a log line.
    assert "three" in say_comment_scan(7, 6, 3, "billing surprise");
    # Singular must agree.
    assert "one describes" in say_comment_scan(7, 6, 1, "billing surprise");
    assert "[" not in s and "]" not in s;
}


test "convergence sentence names the lanes that found them" {
    s = say_convergence("Dana Okafor", ["C", "A"]);
    assert "two lanes" in s;
    assert "A and C" in s;
}


# ===========================================================================
# The lanes, end to end, offline
# ===========================================================================

test "lane A rejects the mega account and mines the mid-tier one" {
    f = seed_founder("lane-a-founder");
    w = f spawn RunResearch(offline=True, include_github=False, fixture=FIXTURE);

    lanes = [[f ->:Runs:->][0] ->:HasLane:->];
    lane_a = [l for l in lanes if str(l.lane_id) == "A"][0];
    said = [r.sentence for r in [lane_a ->:Emitted:->]];
    joined = " ".join(said);

    # The defining move: reject the influencer out loud, with the reason.
    assert "412,000 followers" in joined;
    assert "applause" in joined;
    # And accept the practitioner.
    assert "870 followers" in joined;
    # Comment scan reports real counts from the fixture (3 comments, 1 clout).
    assert "comments" in joined;
}


test "lane A surfaces commenters, not the post author" {
    f = seed_founder("lane-a-yield");
    f spawn RunResearch(offline=True, include_github=False, fixture=FIXTURE);
    lanes = [[f ->:Runs:->][0] ->:HasLane:->];
    lane_a = [l for l in lanes if str(l.lane_id) == "A"][0];
    handles = [p.handle for p in [lane_a ->:Surfaced:->]];

    # Sam and Dana wrote first-person problem statements in the comments.
    assert "sam-oyelaran" in handles or "dana-okafor" in handles;
    # Priya only congratulated - clout noise must never become a prospect.
    assert "priya-raman" not in handles;
    # Evidence is tagged as a COMMENT, which is what makes lane A different.
    for p in [lane_a ->:Surfaced:->] {
        for ev in [p ->:HasEvidence:->] {
            assert ev.source == EvidenceSource.LINKEDIN;
            assert ev.quote;
        }
    }
}


test "a dry probe grows the next rung as a child and walks into it" {
    f = seed_founder("dry-branch");
    # No fixture at all: every query comes back empty, so the lane must climb
    # its whole ladder rather than stopping at the first miss.
    f spawn RunResearch(offline=True, include_github=False, fixture={});

    lanes = [[f ->:Runs:->][0] ->:HasLane:->];
    lane_b = [l for l in lanes if str(l.lane_id) == "B"][0];

    seeds = [lane_b ->:Probe:->];
    assert len(seeds) == 1, "a lane seeds exactly one rung 0";
    # The ladder is graph structure: rung 1 hangs off rung 0 via Widened.
    assert len([seeds[0] ->:Widened:->]) >= 1, "dry rung must grow a child";

    said = " ".join([r.sentence for r in [lane_b ->:Emitted:->]]);
    # An agent that narrates the pivot reads as smarter than one that got lucky.
    assert "dry" in said.lower() or "spent" in said.lower();
    assert lane_b.state == LaneState.DRY;
}


test "an exhausted lane reports empty instead of padding the ledger" {
    f = seed_founder("exhausted");
    f spawn RunResearch(offline=True, include_github=False, fixture={});
    lanes = [[f ->:Runs:->][0] ->:HasLane:->];
    for l in lanes {
        assert len([l ->:Surfaced:->]) == 0;
    }
    said = " ".join(
        [r.sentence for l in lanes for r in [l ->:Emitted:->]]
    );
    assert "padding" in said or "came back dry" in said;
}


test "two lanes finding the same human converge onto one prospect" {
    f = seed_founder("convergence");
    w = f spawn RunResearch(offline=True, include_github=False, fixture=FIXTURE);
    run = [f ->:Runs:->][0];

    # Dana appears in lane A's comment pass and lane C's synonym sweep. After
    # the merge she must be ONE node with two Surfaced edges, not two nodes.
    danas = [p for p in run.prospects() if p.handle == "dana-okafor"];
    assert len(danas) == 1, f"expected one merged Dana, got {len(danas)}";

    dana = danas[0];
    assert dana.is_converged(), "Dana was found by two lanes and must be converged";
    assert len(dana.convergence_lanes()) >= 2;
    # Evidence from both lanes survives the merge - that is the whole point of
    # folding duplicates rather than dropping them.
    assert len([dana ->:HasEvidence:->]) >= 2;
    assert w.converged >= 1;
}


test "lanes run concurrently - their time intervals overlap" {
    f = seed_founder("parallel");
    w = f spawn RunResearch(offline=True, include_github=False, fixture=FIXTURE);
    rs = w.lane_results;
    assert len(rs) == 3;
    for r in rs {
        assert r.finished_at > r.started_at, f"lane {r.lane_id} has no duration";
    }

    # Serial execution cannot produce overlapping intervals. This is a stronger
    # claim than "total wall clock was short", and it does not care how much
    # work any individual lane happened to do.
    overlaps = 0;
    for i in range(len(rs)) {
        for j in range(i + 1, len(rs)) {
            lo = max(rs[i].started_at, rs[j].started_at);
            hi = min(rs[i].finished_at, rs[j].finished_at);
            if hi > lo {
                overlaps += 1;
            }
        }
    }
    assert overlaps >= 2, (
        f"expected concurrent lanes, found {overlaps} overlapping pairs - "
        + "a `wait` inside the launch loop would serialize them silently"
    );
}


test "every lane gets a different opening page" {
    # Three authenticated sessions loading the same page type at the same
    # instant is a textbook automation fingerprint.
    opens = [
        tactics_a().opening_path,
        tactics_b().opening_path,
        tactics_c().opening_path
    ];
    assert len(set(opens)) == 3;
    staggers = [tactics_a().stagger, tactics_b().stagger, tactics_c().stagger];
    assert staggers == sorted(staggers);
    for i in range(1, len(staggers)) {
        gap = staggers[i] - staggers[i - 1];
        assert gap >= 8.0 and gap <= 12.0, f"stagger gap {gap} outside 8-12s";
    }
}


test "reasoning is emitted in order and every line is a sentence" {
    f = seed_founder("voice-check");
    f spawn RunResearch(offline=True, include_github=False, fixture=FIXTURE);
    lanes = [[f ->:Runs:->][0] ->:HasLane:->];
    total = 0;
    for l in lanes {
        for r in [l ->:Emitted:->] {
            total += 1;
            assert r.sentence.strip(), "an empty reasoning line renders as a gap";
            # Prose, not log lines: no leading timestamp brackets.
            assert not r.sentence.startswith("["), r.sentence;
            assert r.sentence.strip()[-1] in ".?\"", r.sentence;
            assert r.t > 0.0;
        }
    }
    assert total > 0;
}
