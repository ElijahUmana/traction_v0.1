"""TRACTION persistent graph schema.

This is the product. The closing demo shot - "this human was found
independently from two directions" - is not a feature built on top of the data
model, it IS the data model: a convergence traversal back up the `Surfaced`
edges from one Prospect to the distinct Lanes that found them. In a relational
store that is a join plus a GROUP BY; here it is one reference expression, and
the score multiplier falls out of it.

Shape (everything hangs off `root` so it survives process restarts - the voice
agent at 3pm reads what the browsers wrote at 11am):

    root
     └── Founder
          ├─:Targets:→      ICP
          ├─:HasWarmLead:→  Prospect          (Lane W deep-researches this one)
          └─:Runs:→         ResearchRun
               └─:HasLane:→ Lane
                    ├─:Emitted:→  Reasoning
                    ├─:Probe:→    SearchProbe
                    │               └─:Widened:→ SearchProbe   (the dry-branch ladder)
                    └─:Surfaced:→ Prospect        ← convergence reads back up this

The widening ladder is graph structure, not an if-chain: when a probe returns
nothing it spawns a widened child and the walker visits it, so the traversal
deepens exactly where the search struggled and `printgraph` renders the dead
branches beside the live ones.

    Prospect
     ├─:HasEvidence:→ Evidence          edge has {lane, confidence}
     ├─:Identity:→    IdentityProfile   edge has {tier, basis}
     │                  ├── GithubProfile
     │                  └── LinkedinProfile
     ├─:Outreach:→    EmailThread
     │                  └─:GotReply:→ ReplyEvent
     ├─:Called:→      CallSession
     │                  └─:Learned:→ Insight
     └─:Booked:→      Booking

Every edge declares its endpoint types, so every traversal infers a real node
type instead of Unknown - `[p ->:Identity:->]` is a list[IdentityProfile], not
a list of anything.
"""

import from contracts {
    LaneId, LaneState, RunStatus, ReasoningKind,
    EvidenceSource, EvidenceKind, IdentityTier, EmailSource,
    CompletenessTier, ReplyIntent, CallOutcome, ProbeState,
    ProspectView
}

# ===========================================================================
# NODES
# ===========================================================================

node Founder {
    has name: str;
    has email: str;
    has product_summary: str = "";
    has github_repo: str = "";
    has one_liner: str = "";
    has meet_link: str = "";
}

node ICP {
    has hypothesis: str;
    has keywords: list[str] = [];
    has negative_keywords: list[str] = [];
    has pain_phrases: list[str] = [];
}

node ResearchRun {
    has started_at: float;
    has status: RunStatus = RunStatus.PLANNING;
    has finished_at: float = 0.0;

    def prospects -> list[Prospect];
    def lane(which: LaneId) -> Lane | None;
}

node Lane {
    has lane_id: LaneId;
    has doctrine: str = "";
    has bb_session_id: str = "";
    has live_url: str = "";
    has state: LaneState = LaneState.IDLE;
    has keywords: list[str] = [];
    has current_query: str = "";
    has query_index: int = 0;

    def narrate(sentence: str, kind: ReasoningKind, t: float) -> Reasoning;
    def open_probe(query: str, keywords: str, date_posted: str) -> SearchProbe;
    def probes -> list[SearchProbe];
}

node SearchProbe {
    has query: str;
    has keywords: str = "";
    has date_posted: str = "";
    has variant: int = 0;
    has depth: int = 0;
    has state: ProbeState = ProbeState.PENDING;
    has yield_count: int = 0;
    has widened_from: str = "";

    def widen(query: str, keywords: str, date_posted: str) -> SearchProbe;
}

node Reasoning {
    has t: float;
    has sentence: str;
    has kind: ReasoningKind = ReasoningKind.OBSERVE;
}

node Prospect {
    has name: str;
    has handle: str;
    has headline: str = "";
    has company: str = "";
    has linkedin_url: str = "";
    has email: str = "";
    has email_source: EmailSource = EmailSource.NONE;
    has email_confidence: float = 0.0;
    has tier: CompletenessTier = CompletenessTier.DROPPED;
    has score: float = 0.0;
    has score_pre_crosslink: float = 0.0;
    has dropped_reason: str = "";
    has is_warm_lead: bool = False;

    def convergence_lanes -> list[LaneId];
    def is_converged -> bool;
    def strong_evidence(min_confidence: float) -> list[Evidence];
    def github -> GithubProfile | None;
    def linkedin -> LinkedinProfile | None;
    def to_view -> ProspectView;
}

node Evidence {
    has source: EvidenceSource;
    has quote: str;
    has url: str = "";
    has kind: EvidenceKind = EvidenceKind.POST;
    has recency_days: int = -1;
}

node IdentityProfile {
    has url: str = "";
}

node GithubProfile(IdentityProfile) {
    has login: str = "";
    has name: str = "";
    has company: str = "";
    has public_email: str = "";
    has bio: str = "";
    has top_repo: str = "";
    has followers: int = 0;
}

node LinkedinProfile(IdentityProfile) {
    has handle: str = "";
    has name: str = "";
    has headline: str = "";
    has company: str = "";
    has about: str = "";
}

node EmailThread {
    has thread_id: str;
    has subject: str = "";
    has body: str = "";
    has sent_at: float = 0.0;
    has inbox_id: str = "";
}

node ReplyEvent {
    has raw: str;
    has intent_json: str = "";
    has intent: ReplyIntent = ReplyIntent.UNCLEAR;
    has phone_number: str = "";
    has received_at: float = 0.0;
}

node CallSession {
    has vapi_call_id: str;
    has scheduled_at: str = "";
    has transcript: str = "";
    has outcome: CallOutcome = CallOutcome.SCHEDULED;
    has phone_number: str = "";
    has kb_blob: str = "";
}

node Insight {
    has claim: str;
    has evidence: str = "";
    has learned_at: float = 0.0;
}

node Booking {
    has event_id: str;
    has meet_link: str = "";
    has start: str = "";
    has attendees: list[str] = [];
    has html_link: str = "";
}

# ===========================================================================
# EDGES - every one declares its endpoint types
# ===========================================================================

edge Targets: Founder --> ICP {
    has created_at: float = 0.0;
}

edge HasWarmLead: Founder --> Prospect {
    has note: str = "";
}

edge Runs: Founder --> ResearchRun {
    has created_at: float = 0.0;
}

edge HasLane: ResearchRun --> Lane {
    has launched_at: float = 0.0;
}

edge Emitted: Lane --> Reasoning {
    has seq: int = 0;
}

edge Surfaced: Lane --> Prospect {
    has lane: LaneId = LaneId.A;
    has at_rank: int = 0;
    has found_at: float = 0.0;
    has query: str = "";
}

edge Probe: Lane --> SearchProbe {
    has opened_at: float = 0.0;
}

edge Widened: SearchProbe --> SearchProbe {
    has reason: str = "";
}

edge HasEvidence: Prospect --> Evidence {
    has lane: LaneId = LaneId.A;
    has confidence: float = 0.0;
}

edge Identity: Prospect --> IdentityProfile {
    has tier: IdentityTier = IdentityTier.NOT_FOUND;
    has basis: str = "";
    has confidence: float = 0.0;
}

edge Outreach: Prospect --> EmailThread {
    has sent_at: float = 0.0;
}

edge GotReply: EmailThread --> ReplyEvent {
    has received_at: float = 0.0;
}

edge Called: Prospect --> CallSession {
    has initiated_at: float = 0.0;
}

edge Learned: CallSession --> Insight {
    has confidence: float = 0.0;
}

edge Booked: Prospect --> Booking {
    has booked_at: float = 0.0;
}

# ===========================================================================
# IMPLEMENTATIONS
# ===========================================================================

# Distinct lanes that independently surfaced this human. The whole thesis.
impl Prospect.convergence_lanes -> list[LaneId] {
    lanes: list[LaneId] = [];
    for lane in [self <-:Surfaced:<-] {
        if lane.lane_id not in lanes {
            lanes.append(lane.lane_id);
        }
    }
    return lanes;
}

# True when two or more lanes found this person without knowing about each other.
impl Prospect.is_converged -> bool {
    return len(self.convergence_lanes()) >= 2;
}

# Evidence above a confidence floor, read through the typed edge predicate.
impl Prospect.strong_evidence(min_confidence: float) -> list[Evidence] {
    return [self ->:HasEvidence:confidence > min_confidence:->];
}

impl Prospect.github -> GithubProfile | None {
    for prof in [self ->:Identity:->[?:GithubProfile]] {
        return prof;
    }
    return None;
}

impl Prospect.linkedin -> LinkedinProfile | None {
    for prof in [self ->:Identity:->[?:LinkedinProfile]] {
        return prof;
    }
    return None;
}

# Flat projection for the dashboard and the wire.
impl Prospect.to_view -> ProspectView {
    li_quote: str = "";
    gh_artifact: str = "";
    for ev in [self ->:HasEvidence:->] {
        if ev.source == EvidenceSource.LINKEDIN and li_quote == "" {
            li_quote = ev.quote;
        }
        if ev.source == EvidenceSource.GITHUB and gh_artifact == "" {
            gh_artifact = ev.quote;
        }
    }
    return ProspectView(
        jid=jid(self),
        name=self.name,
        handle=self.handle,
        headline=self.headline,
        company=self.company,
        linkedin_url=self.linkedin_url,
        email=self.email,
        email_source=self.email_source,
        email_confidence=self.email_confidence,
        tier=self.tier,
        score=self.score,
        score_pre_crosslink=self.score_pre_crosslink,
        dropped_reason=self.dropped_reason,
        is_warm_lead=self.is_warm_lead,
        convergence_lanes=self.convergence_lanes(),
        linkedin_quote=li_quote,
        github_artifact=gh_artifact
    );
}

# Two hops: every prospect any of this run's lanes surfaced, deduplicated.
impl ResearchRun.prospects -> list[Prospect] {
    return [self ->:HasLane:-> ->:Surfaced:->];
}

impl ResearchRun.lane(which: LaneId) -> Lane | None {
    for lane in [self ->:HasLane:->] {
        if lane.lane_id == which {
            return lane;
        }
    }
    return None;
}

# Append one line to this lane's analyst sidebar and return it.
impl Lane.narrate(sentence: str, kind: ReasoningKind, t: float) -> Reasoning {
    seq = len([self ->:Emitted:->]);
    note = Reasoning(t=t, sentence=sentence, kind=kind);
    self +>:Emitted(seq=seq):+> note;
    return note;
}

# Open a fresh probe on this lane's widening ladder.
impl Lane.open_probe(query: str, keywords: str, date_posted: str) -> SearchProbe {
    variant = len([self ->:Probe:->]);
    probe = SearchProbe(
        query=query,
        keywords=keywords,
        date_posted=date_posted,
        variant=variant,
        depth=0,
        state=ProbeState.PENDING
    );
    self +>:Probe:+> probe;
    return probe;
}

impl Lane.probes -> list[SearchProbe] {
    return [self ->:Probe:->];
}

# A dry probe spawns a widened child. The traversal literally deepens where the
# search struggled, and printgraph renders the dead branches alongside the live
# ones - the search tree is the graph, not a log line.
impl SearchProbe.widen(query: str, keywords: str, date_posted: str) -> SearchProbe {
    self.state = ProbeState.DRY;
    child = SearchProbe(
        query=query,
        keywords=keywords,
        date_posted=date_posted,
        variant=self.variant,
        depth=self.depth + 1,
        state=ProbeState.PENDING,
        widened_from=self.query
    );
    self +>:Widened(reason="zero yield"):+> child;
    return child;
}
