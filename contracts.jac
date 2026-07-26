"""TRACTION shared vocabulary.

Every enum and every LLM-visible `obj` the whole team codes against lives here.
This module has ZERO graph dependencies on purpose - `schema.jac` imports it,
every feature module imports it, and nothing imports back. Keep it that way.

byLLM rule: LLM return types are always `obj`, never `node`. An LLM fills an
`obj`; a walker copies the fields onto a `node`. The prompt schema and the
storage schema are allowed to evolve independently.

Every enum here is str-backed (`enum X: str`), which means the members ARE
strings: they compare equal to plain strings, JSON-serialize to bare strings
over the wire, and round-trip through the persistent graph. Never write
`.value` on one.
"""

# ---------------------------------------------------------------------------
# Research lanes
# ---------------------------------------------------------------------------

enum LaneId: str {
    A = "A",
    B = "B",
    C = "C",
    D = "D"
}
sem LaneId = "Which of the four parallel research lanes a thing belongs to.";
sem LaneId.A = "Lane A - comment mining under mid-tier practitioner posts.";
sem LaneId.B = "Lane B - post authorship; first-person problem statements.";
sem LaneId.C = "Lane C - synonym sweep across adjacent phrasings.";
sem LaneId.D = "Lane D - GitHub-first, programmatic, never a visible browser.";

enum LaneState: str {
    IDLE = "idle",
    LAUNCHING = "launching",
    SEARCHING = "searching",
    READING = "reading",
    CROSSLINKING = "crosslinking",
    DRY = "dry",
    DONE = "done",
    FAILED = "failed"
}
sem LaneState = "What a single research lane is doing right now.";
sem LaneState.DRY = "This angle yielded nothing; the lane is reformulating its query.";

enum RunStatus: str {
    PLANNING = "planning",
    RUNNING = "running",
    CROSSLINKING = "crosslinking",
    GATING = "gating",
    RANKED = "ranked",
    COMPLETE = "complete",
    FAILED = "failed"
}
sem RunStatus = "Overall stage of one end-to-end research run.";

enum ReasoningKind: str {
    PLAN = "plan",
    OBSERVE = "observe",
    PIVOT = "pivot",
    HIT = "hit",
    MISS = "miss",
    CROSSLINK = "crosslink",
    GATE = "gate",
    RANK = "rank"
}
sem ReasoningKind = "The rhetorical move a line in the analyst sidebar is making.";
sem ReasoningKind.PIVOT = "Announcing that the current angle is dry and naming the next one.";
sem ReasoningKind.HIT = "Reporting a genuine find worth surfacing.";

# ---------------------------------------------------------------------------
# Evidence and identity
# ---------------------------------------------------------------------------

enum EvidenceSource: str {
    LINKEDIN = "linkedin",
    GITHUB = "github"
}
sem EvidenceSource = "Which platform a piece of evidence was read from.";

enum EvidenceKind: str {
    COMMENT = "comment",
    POST = "post",
    ABOUT = "about",
    HEADLINE = "headline",
    REPO = "repo",
    ISSUE = "issue",
    COMMIT = "commit",
    README = "readme"
}
sem EvidenceKind = "What kind of artifact the evidence quote was taken from.";
sem EvidenceKind.COMMENT = "A comment this person wrote under someone else's post.";
sem EvidenceKind.ISSUE = "A GitHub issue this person opened or commented on.";

enum IdentityTier: str {
    VERIFIED = "verified",
    PROBABLE = "probable",
    POSSIBLE = "possible",
    NOT_FOUND = "not_found"
}
sem IdentityTier = "How confident the cross-link is that two profiles are the same human.";
sem IdentityTier.VERIFIED = "A hard identifier matched on both sides, e.g. the same email or an explicit link.";
sem IdentityTier.PROBABLE = "Strong circumstantial match: same full name plus same company or same distinctive handle.";
sem IdentityTier.POSSIBLE = "Weak match on name alone; could be a different person.";
sem IdentityTier.NOT_FOUND = "No counterpart profile could be located at all.";

enum EmailSource: str {
    GITHUB_COMMIT = "github_commit",
    GITHUB_PROFILE = "github_profile",
    GITHUB_README = "github_readme",
    LINKEDIN_CONTACT_INFO = "linkedin_contact_info",
    VERIFIED_GUESS = "verified_guess",
    PROVIDED = "provided",
    NONE = "none"
}
sem EmailSource = "Which step of the six-step waterfall actually produced the email address.";
sem EmailSource.NONE = "No email was found; this prospect is dropped at the gate.";

enum CompletenessTier: str {
    S = "S",
    A = "A",
    DROPPED = "DROPPED"
}
sem CompletenessTier = "Result of the hard email gate plus content completeness.";
sem CompletenessTier.S = "Email AND LinkedIn content AND GitHub content - fully cross-linked.";
sem CompletenessTier.A = "Email plus content from exactly one of LinkedIn or GitHub.";
sem CompletenessTier.DROPPED = "No email address could be resolved; eliminated, but shown on the ledger.";

# ---------------------------------------------------------------------------
# Outreach, voice, booking
# ---------------------------------------------------------------------------

enum ReplyIntent: str {
    WANTS_CALL = "wants_call",
    WANTS_INFO = "wants_info",
    NOT_INTERESTED = "not_interested",
    UNCLEAR = "unclear"
}
sem ReplyIntent = "What the prospect's email reply is actually asking for.";
sem ReplyIntent.WANTS_CALL = "The sender agreed to talk on the phone.";

enum CallOutcome: str {
    SCHEDULED = "scheduled",
    RINGING = "ringing",
    IN_PROGRESS = "in_progress",
    COMPLETED = "completed",
    NO_ANSWER = "no_answer",
    FAILED = "failed"
}
sem CallOutcome = "Lifecycle state of one outbound voice call.";

# ---------------------------------------------------------------------------
# LLM-visible objects
# ---------------------------------------------------------------------------

obj LaneDoctrine {
    has lane_id: LaneId;
    has doctrine: str;
    has keywords: list[str] = [];
    has rationale: str = "";
}
sem LaneDoctrine = "A hunting doctrine assigned to one parallel research lane. Four of these run at once and must NOT be four views of the same search - each is a different researcher with a different angle.";
sem LaneDoctrine.lane_id = "Which lane this doctrine belongs to: A, B, C or D.";
sem LaneDoctrine.doctrine = "One sentence describing how this lane hunts, in the voice of a research analyst.";
sem LaneDoctrine.keywords = "The concrete search phrases this lane will type, ordered best-first.";
sem LaneDoctrine.rationale = "Why this angle should surface people the other three lanes will miss.";

obj CampaignPlan {
    has icp_hypothesis: str;
    has keywords: list[str] = [];
    has negative_keywords: list[str] = [];
    has pain_phrases: list[str] = [];
    has lane_doctrines: list[LaneDoctrine] = [];
}
sem CampaignPlan = "The full research plan derived from a founder's product description: who to look for, and four distinct ways to look.";
sem CampaignPlan.icp_hypothesis = "One sentence naming the specific kind of person who would want this product this week.";
sem CampaignPlan.keywords = "Phrases these people actually type when describing their own work.";
sem CampaignPlan.negative_keywords = "Phrases that indicate a false positive and should exclude a result.";
sem CampaignPlan.pain_phrases = "First-person complaints this person would plausibly post, verbatim in their voice.";
sem CampaignPlan.lane_doctrines = "Exactly four doctrines, one per lane A/B/C/D, each hunting a different way.";

obj ProspectCandidate {
    has name: str;
    has handle: str;
    has headline: str = "";
    has company: str = "";
    has quote: str = "";
    has source_url: str = "";
    has evidence_kind: EvidenceKind = EvidenceKind.POST;
    has relevance: float = 0.0;
}
sem ProspectCandidate = "One human a lane surfaced, with the exact words that made them worth surfacing.";
sem ProspectCandidate.name = "The person's display name as shown on the platform.";
sem ProspectCandidate.handle = "Their platform handle or profile slug - the stable identifier, not the URL.";
sem ProspectCandidate.headline = "Their profile headline or bio line, verbatim.";
sem ProspectCandidate.company = "Where they work, if stated.";
sem ProspectCandidate.quote = "The exact sentence they wrote that signals the pain this product solves. Verbatim, never paraphrased.";
sem ProspectCandidate.source_url = "Direct link to the artifact the quote came from.";
sem ProspectCandidate.evidence_kind = "What kind of artifact the quote was taken from.";
sem ProspectCandidate.relevance = "0.0 to 1.0 - how directly this person's own words match the ICP hypothesis.";

obj PivotDecision {
    has should_pivot: bool;
    has narration: str;
    has next_query: str = "";
}
sem PivotDecision = "Decides whether a lane that returned nothing should reformulate, and narrates the pivot for the live sidebar. An agent that says 'this angle is dry, switching to variant 2' reads as smarter than one that got lucky.";
sem PivotDecision.should_pivot = "True if the current angle is exhausted and a new query should be tried.";
sem PivotDecision.narration = "One sentence in analyst voice explaining what was tried, why it was dry, and what is next.";
sem PivotDecision.next_query = "The reformulated search phrase to try next. Empty if not pivoting.";

obj CrossLinkVerdict {
    has matched: bool;
    has tier: IdentityTier;
    has basis: str;
    has confidence: float = 0.0;
    has matched_url: str = "";
}
sem CrossLinkVerdict = "Adjudicates whether a LinkedIn person and a GitHub person are the same human. Be conservative: a wrong match poisons the outreach with details about a stranger.";
sem CrossLinkVerdict.matched = "True only if you would stake the outreach email on these being the same person.";
sem CrossLinkVerdict.tier = "How strong the match is.";
sem CrossLinkVerdict.basis = "The specific evidence that decided it, e.g. 'same commit email' or 'same full name and both list Acme Corp'.";
sem CrossLinkVerdict.confidence = "0.0 to 1.0.";
sem CrossLinkVerdict.matched_url = "URL of the counterpart profile, if matched.";

obj OutreachDraft {
    has subject: str;
    has body: str;
    has linkedin_quote_used: str = "";
    has github_artifact_used: str = "";
}
sem OutreachDraft = "A cold email that proves it was written for exactly one person. It must cite their own words and their own code. Short, specific, no flattery, no 'I came across your profile'.";
sem OutreachDraft.subject = "Under nine words. Concrete. Never a question, never clickbait.";
sem OutreachDraft.body = "Under 120 words. Open with the specific thing they said or built. State what the product does in one line. Ask for one short call. Sign as the founder.";
sem OutreachDraft.linkedin_quote_used = "The exact LinkedIn sentence quoted in the body, so the UI can highlight it.";
sem OutreachDraft.github_artifact_used = "The exact GitHub artifact referenced in the body, so the UI can highlight it.";

obj AvailabilityIntent {
    has intent: ReplyIntent;
    has wants_call: bool;
    has proposed_times: list[str] = [];
    has phone_number: str = "";
    has sentiment: str = "neutral";
}
sem AvailabilityIntent = "Everything actionable extracted from a prospect's email reply.";
sem AvailabilityIntent.intent = "What the reply is asking for.";
sem AvailabilityIntent.wants_call = "True if the sender agreed to a phone call.";
sem AvailabilityIntent.proposed_times = "Any times the sender offered, verbatim as written.";
sem AvailabilityIntent.phone_number = "Phone number in E.164 form if one was given, otherwise empty.";
sem AvailabilityIntent.sentiment = "positive, neutral, or negative.";

obj KbAnswer {
    has answer: str;
    has cited_evidence: list[str] = [];
}
sem KbAnswer = "Answers the prospect's mid-call question using ONLY facts already in the graph about this specific person. Never invent a benefit. If the graph does not support an answer, say so plainly.";
sem KbAnswer.answer = "Two sentences maximum, spoken aloud on a live phone call, so plain conversational English with no markup and no lists.";
sem KbAnswer.cited_evidence = "The exact evidence quotes leaned on, so the dashboard can show the call was grounded.";

obj CallInsight {
    has claim: str;
    has evidence: str;
}
sem CallInsight = "One durable fact learned about the prospect during a call - something that should still be true next week and that would change how we approach them next time.";
sem CallInsight.claim = "The fact, stated in one sentence.";
sem CallInsight.evidence = "The verbatim line from the transcript that supports it.";

obj ProspectView {
    has jid: str;
    has name: str;
    has handle: str;
    has headline: str = "";
    has company: str = "";
    has email: str = "";
    has email_source: EmailSource = EmailSource.NONE;
    has tier: CompletenessTier = CompletenessTier.DROPPED;
    has score: float = 0.0;
    has score_pre_crosslink: float = 0.0;
    has dropped_reason: str = "";
    has convergence_lanes: list[LaneId] = [];
    has linkedin_quote: str = "";
    has github_artifact: str = "";
}
sem ProspectView = "Flat projection of one prospect for the dashboard and the wire. Assembled from the graph by to_view; never constructed by an LLM.";
