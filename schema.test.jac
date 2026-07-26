"""Round-trip proof for the TRACTION graph schema.

Runs with no API keys. Builds the entire chain the product walks at demo time -
Founder → ICP → ResearchRun → Lane → Reasoning → Prospect → Evidence →
Identity → EmailThread → ReplyEvent → CallSession → Insight → Booking - then
reads it back through the typed traversals, including the convergence query
that is the closing demo shot.

VERIFIED: `jac test` gives each test its OWN isolated root - a test does NOT
see nodes created by an earlier test in the same file. So every test calls
seed_demo_graph() for itself rather than relying on shared state.
"""

# Builds the entire demo chain and returns the Founder anchor.
# Each test gets its own isolated root, so every test seeds for itself.
def seed_demo_graph -> Founder {

    founder = root ++> Founder(
        name="Ada Umana",
        email="ada@traction.dev",
        product_summary="A prospect graph that finds one human from four directions.",
        github_repo="ElijahUmana/traction_v0.1",
        one_liner="Find the human, not the market.",
        meet_link="https://meet.google.com/abc-defg-hij"
    );

    icp = ICP(hypothesis="Solo founders shipping RAG apps who cannot find beta testers.");
    icp.keywords = ["vector db", "retrieval"];
    icp.pain_phrases = ["my retrieval quality is garbage"];
    founder +>:Targets(created_at=1.0):+> icp;

    run = ResearchRun(started_at=1000.0, status=RunStatus.RUNNING);
    founder +>:Runs(created_at=1000.0):+> run;

    lane_a = Lane(lane_id=LaneId.A, doctrine="comment mining", state=LaneState.SEARCHING);
    lane_d = Lane(lane_id=LaneId.D, doctrine="github first", state=LaneState.SEARCHING);
    run +>:HasLane(launched_at=1001.0):+> lane_a;
    run +>:HasLane(launched_at=1009.0):+> lane_d;

    lane_a.narrate("Mid-tier practitioners only; skipping the clout accounts.", ReasoningKind.PLAN, 1002.0);
    lane_a.narrate("This angle is dry - switching to variant 2.", ReasoningKind.PIVOT, 1004.0);

    prospect = Prospect(name="Sarah Chen", handle="sarah-chen-rag");
    prospect.headline = "ML engineer, retrieval systems";
    prospect.company = "Northwind";
    prospect.score_pre_crosslink = 0.71;

    # The convergence setup: two lanes that never spoke to each other, same human.
    lane_a +>:Surfaced(at_rank=3, found_at=1005.0, query="retrieval quality"):+> prospect;
    lane_d +>:Surfaced(at_rank=1, found_at=1011.0, query="lang:python rag"):+> prospect;

    prospect +>:HasEvidence(lane=LaneId.A, confidence=0.91):+> Evidence(
        source=EvidenceSource.LINKEDIN,
        quote="our retrieval quality falls apart past 50k docs",
        kind=EvidenceKind.COMMENT,
        url="https://linkedin.com/feed/x",
        recency_days=3
    );
    prospect +>:HasEvidence(lane=LaneId.D, confidence=0.84):+> Evidence(
        source=EvidenceSource.GITHUB,
        quote="issue #1247: chunk overlap tuning is guesswork",
        kind=EvidenceKind.ISSUE,
        url="https://github.com/x/y/issues/1247",
        recency_days=9
    );
    prospect +>:HasEvidence(lane=LaneId.A, confidence=0.22):+> Evidence(
        source=EvidenceSource.LINKEDIN,
        quote="great post!",
        kind=EvidenceKind.COMMENT
    );

    prospect +>:Identity(tier=IdentityTier.VERIFIED, basis="same commit email", confidence=0.97):+> GithubProfile(
        url="https://github.com/schen",
        login="schen",
        name="Sarah Chen",
        public_email="sarah@northwind.io",
        top_repo="schen/rag-eval"
    );
    prospect +>:Identity(tier=IdentityTier.PROBABLE, basis="name + company", confidence=0.8):+> LinkedinProfile(
        url="https://linkedin.com/in/sarah-chen-rag",
        handle="sarah-chen-rag",
        name="Sarah Chen",
        headline="ML engineer, retrieval systems",
        company="Northwind"
    );

    prospect.email = "sarah@northwind.io";
    prospect.email_source = EmailSource.GITHUB_COMMIT;
    prospect.tier = CompletenessTier.S;
    prospect.score = 0.94;

    thread = EmailThread(thread_id="thr_1", subject="your 50k-doc retrieval note", sent_at=2000.0);
    prospect +>:Outreach(sent_at=2000.0):+> thread;

    reply = ReplyEvent(raw="call me now, +14155550142", intent=ReplyIntent.WANTS_CALL, phone_number="+14155550142");
    thread +>:GotReply(received_at=2100.0):+> reply;

    call = CallSession(vapi_call_id="call_1", outcome=CallOutcome.COMPLETED, phone_number="+14155550142");
    prospect +>:Called(initiated_at=2200.0):+> call;
    call +>:Learned(confidence=0.9):+> Insight(claim="Evaluates on a 50k-doc corpus weekly.", evidence="we re-run evals every Friday");

    prospect +>:Booked(booked_at=2400.0):+> Booking(
        event_id="evt_1",
        meet_link="https://meet.google.com/abc-defg-hij",
        start="2026-07-26T19:00:00-07:00",
        attendees=["ada@traction.dev", "sarah@northwind.io"]
    );

    return founder;
}

test "full chain builds and every typed edge traverses" {
    founder = seed_demo_graph();
    run = [founder ->:Runs:->][0];
    lane_a = run.lane(LaneId.A);
    assert lane_a is not None, "lane A missing";
    prospect = [founder ->:Runs:-> ->:HasLane:-> ->:Surfaced:->][0];

    assert len([founder ->:Targets:->]) == 1, "Targets did not traverse";
    assert [founder ->:Runs:->][0].status == RunStatus.RUNNING, "Runs did not traverse";
    assert len([run ->:HasLane:->]) == 2, "HasLane did not traverse";
    assert len([lane_a ->:Emitted:->]) == 2, "Emitted did not traverse";
    assert len([prospect ->:Outreach:-> ->:GotReply:->]) == 1, "Outreach->GotReply multi-hop failed";
    assert len([prospect ->:Called:-> ->:Learned:->]) == 1, "Called->Learned multi-hop failed";
    assert [prospect ->:Booked:->][0].event_id == "evt_1", "Booked did not traverse";
}

test "convergence query returns two distinct lanes - the closing demo shot" {
    founder = seed_demo_graph();
    targets = [founder ->:Runs:-> ->:HasLane:-> ->:Surfaced:->];
    assert len(targets) >= 1, "no prospect reachable from founder in three hops";

    prospect = targets[0];
    lanes = prospect.convergence_lanes();
    assert len(lanes) == 2, f"expected 2 converging lanes, got {len(lanes)}";
    assert LaneId.A in lanes, "lane A missing from convergence";
    assert LaneId.D in lanes, "lane D missing from convergence";
    assert prospect.is_converged(), "is_converged() disagrees with convergence_lanes()";
}

test "edge-field predicate gates evidence by confidence" {
    founder = seed_demo_graph();
    target = [founder ->:Runs:-> ->:HasLane:-> ->:Surfaced:->][0];
    strong = target.strong_evidence(0.7);
    assert len(strong) == 2, f"expected 2 strong evidence, got {len(strong)}";
    quotes = [e.quote for e in strong];
    assert "great post!" not in quotes, "low-confidence evidence leaked through the gate";
}

test "polymorphic Identity edge narrows to each profile subtype" {
    founder = seed_demo_graph();
    target = [founder ->:Runs:-> ->:HasLane:-> ->:Surfaced:->][0];

    profiles = [target ->:Identity:->];
    assert len(profiles) == 2, "Identity should reach both profiles";

    gh = target.github();
    li = target.linkedin();
    assert gh is not None, "github() returned None";
    assert li is not None, "linkedin() returned None";
    assert gh.login == "schen", "GithubProfile fields did not round-trip";
    assert li.headline == "ML engineer, retrieval systems", "LinkedinProfile fields did not round-trip";
}

test "str-backed enums round-trip through the persistent graph" {
    founder = seed_demo_graph();
    target = [founder ->:Runs:-> ->:HasLane:-> ->:Surfaced:->][0];

    assert target.tier == CompletenessTier.S, "CompletenessTier did not round-trip";
    assert target.tier == "S", "str-backed enum should compare equal to a plain string";
    assert isinstance(target.tier, str), "enum member is not a str instance";
    assert target.email_source == EmailSource.GITHUB_COMMIT, "EmailSource did not round-trip";

    edges = [edge target ->:Identity:->];
    tiers = [e.tier for e in edges];
    assert IdentityTier.VERIFIED in tiers, "edge-borne enum did not round-trip";
}

test "to_view projects the prospect flat for the wire" {
    founder = seed_demo_graph();
    target = [founder ->:Runs:-> ->:HasLane:-> ->:Surfaced:->][0];
    view = target.to_view();

    assert view.name == "Sarah Chen", "name missing from view";
    assert view.tier == CompletenessTier.S, "tier missing from view";
    assert view.score == 0.94, "score missing from view";
    assert view.score_pre_crosslink == 0.71, "pre-crosslink score missing - the demo shows this delta";
    assert len(view.convergence_lanes) == 2, "view lost the convergence";
    assert "50k docs" in view.linkedin_quote, "view lost the LinkedIn quote";
    assert "1247" in view.github_artifact, "view lost the GitHub artifact";
    assert view.jid != "", "view has no stable id";
}

test "ResearchRun.prospects walks two hops and dedupes" {
    founder = seed_demo_graph();
    run = [founder ->:Runs:->][0];
    people = run.prospects();
    assert len(people) == 1, f"two lanes surfaced ONE human; expected 1 after dedupe, got {len(people)}";
    assert run.lane(LaneId.A) is not None, "lane(A) lookup failed";
    assert run.lane(LaneId.C) is None, "lane(C) should not exist in this run";
}

test "warm lead is a first-class prospect on Lane W, exempt from the email gate" {
    founder = seed_demo_graph();

    warm = Prospect(name="Marek K", handle="marek-k");
    warm.linkedin_url = "https://linkedin.com/in/marek-k";
    warm.email = "marek@teammate.dev";
    warm.email_source = EmailSource.PROVIDED;
    warm.email_confidence = 1.0;
    warm.tier = CompletenessTier.S;
    founder +>:HasWarmLead(note="on stage with us"):+> warm;

    run = [founder ->:Runs:->][0];
    lane_w = Lane(lane_id=LaneId.W, doctrine="deep research one known human");
    run +>:HasLane(launched_at=1000.0):+> lane_w;
    lane_w +>:Surfaced(lane=LaneId.W, at_rank=1, found_at=1012.0):+> warm;

    assert len([founder ->:HasWarmLead:->]) == 1, "HasWarmLead did not traverse";
    fetched = [founder ->:HasWarmLead:->][0];
    assert fetched.is_warm_lead(), "warm lead must be derived from the HasWarmLead edge";
    assert fetched.email_source == EmailSource.PROVIDED, "warm lead email must short-circuit the waterfall";
    assert run.lane(LaneId.W) is not None, "Lane W is not a first-class lane";
    assert LaneId.W in warm.convergence_lanes(), "Lane W did not register as a surfacing lane";
    assert warm.to_view().is_warm_lead, "view lost the warm-lead flag";
    cold = [founder ->:Runs:-> ->:HasLane:-> ->:Surfaced:->][0];
    assert not cold.is_warm_lead(), "a lane-surfaced prospect must NOT read as a warm lead";
}

test "dry probe widens into a child and the search tree stays inspectable" {
    founder = seed_demo_graph();
    run = [founder ->:Runs:->][0];
    lane_a = run.lane(LaneId.A);
    assert lane_a is not None, "lane A missing";

    p0 = lane_a.open_probe("retrieval quality", "retrieval", "past-24h");
    assert p0.state == ProbeState.PENDING, "new probe should be pending";
    assert p0.depth == 0, "root probe should be depth 0";

    # zero yield -> widen the date filter rather than giving up
    p1 = p0.widen("retrieval quality", "retrieval", "past-week");
    assert p0.state == ProbeState.DRY, "widening must mark the parent dry";
    assert p1.depth == 1, "child probe should be one rung deeper";
    assert p1.widened_from == "retrieval quality", "child lost its provenance";

    p2 = p1.widen("chunking strategy", "chunking", "past-month");
    assert p2.depth == 2, "ladder should keep deepening";

    # the dead branch is still reachable - that is the point
    chain = [p0 ->:Widened:-> ->:Widened:->];
    assert len(chain) == 1, "the widening chain is not traversable end to end";
    assert chain[0].query == "chunking strategy", "wrong node at the end of the ladder";

    p2.state = ProbeState.YIELDED;
    p2.yield_count = 4;
    assert len(lane_a.probes()) == 1, "open_probe should attach exactly one root probe to the lane";

    dot = printgraph(root);
    assert "SearchProbe" in dot, "search tree is not rendered by printgraph";
}

test "email confidence is separable from email source" {
    founder = seed_demo_graph();
    target = [founder ->:Runs:-> ->:HasLane:-> ->:Surfaced:->][0];

    # A bare noreply@github.com from a forked repo manifest: right format, wrong human.
    target.email = "noreply@github.com";
    target.email_source = EmailSource.GITHUB_README;
    target.email_confidence = 0.11;
    assert target.email_confidence < 0.5, "low-trust attribution must survive as a number, not a boolean";

    view = target.to_view();
    assert view.email_confidence == 0.11, "view lost the attribution confidence";
    assert view.email_source == EmailSource.GITHUB_README, "view lost the waterfall step";
}
