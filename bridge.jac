"""The frontend/backend seam: Becky's 13 endpoints, driven by OUR graph.

Her client (`frontend.cl.jac`) contains no fetch, no URL and no JSON envelope.
It does `sv import from bridge { ... }` and calls thirteen functions by name;
Jac generates the RPC. So this file IS the entire integration surface, and the
thirteen signatures below are a contract - they are copied byte-for-byte from
her mock at `becky_ui/traction/workflows.jac:1089-1229`. A renamed parameter or
a changed default breaks her UI at the call site with no useful error.

Two rules govern everything here.

**One: the projection reads, it never writes.** `_workspace()` is a pure
function of the graph. Every number on her dashboard is a traversal, so the
screen cannot drift from the store - there is no cache to invalidate and no
second copy to keep in sync.

**Two: a field with no source in our graph is left EMPTY.** Not plausible,
not inferred, not "reasonable-looking" - empty. Her `ProspectView` has twenty
fields and ours is a different shape; where the two genuinely do not meet,
this file returns "" and the seam is documented in the header comment above
each projection. A dashboard full of convincing filler is the worst available
outcome: it looks perfect and it lies, and someone is going to ask where a
number came from. The empty ones are listed above `_prospect_view` and
`_activity_view` so the answer is always in the file.

Two fields deserve their own note because they are claims ABOUT truthfulness:
`is_demo` and `learnable` are derived from whether an external system actually
issued an id - AgentMail a thread_id, Vapi a call_id, Google Calendar an
event_id. Nothing seeded can mint one of those, so the flag cannot be faked
into looking real.
"""

import time;

# Every edge type traversed below is imported. An UNIMPORTED edge type does not
# narrow the hop - it duck-types across every out-edge and returns everything
# (JAC_GOTCHAS 8a2: three different traversals all reported 310).
import from contracts {
    LaneId, LaneState, RunStatus, CompletenessTier, EmailSource,
    EvidenceSource, EvidenceKind, CallOutcome, ReplyIntent, IdentityTier
}
import from schema {
    Founder, ICP, ResearchRun, Lane, Reasoning, SearchProbe,
    Prospect, Evidence,
    IdentityProfile, GithubProfile, LinkedinProfile,
    EmailThread, ReplyEvent, CallSession, Insight, Booking,
    Targets, HasWarmLead, Runs, HasLane, Emitted, Surfaced, Probe, Widened,
    HasEvidence, Identity, Outreach, GotReply, Called, Learned, Booked
}
import from views {
    WorkspaceView, ProductUnderstanding, PersonaView,
    ProspectView, ActivityView, InsightView
}

# The real walkers. This file owns no business logic - it drives these.
import from plan { PlanCampaign }
import from research { RunResearch }
import from identity { CrossLinkToLinkedIn, ResolveEmail, RankAndSelect }
import from outreach {
    ComposeOutreach, SendOutreach,
    EmailDraft, citation_problem, best_linkedin_citation, best_github_artifact
}
import from voice { ScheduleCall, BookInterview, OnCallEnd }
import from svc { cfg }


# ===========================================================================
# FORMATTING - pure derivation, no graph access
# ===========================================================================

# Her UI renders timestamps verbatim ("Today · 10:24 AM"). Epoch 0 means the
# event has no time on the graph, and an invented one would be a lie about
# when something happened - so it stays empty.
def _stamp(t: float) -> str {
    if t <= 0.0 {
        return "";
    }
    when = time.localtime(t);
    today = time.localtime(time.time());
    clock = time.strftime("%-I:%M %p", when);
    if (when.tm_year == today.tm_year) and (when.tm_yday == today.tm_yday) {
        return f"Today · {clock}";
    }
    return time.strftime("%b %-d", when) + f" · {clock}";
}


# Initials are a pure function of the name we already display. Deriving them is
# not invention - it is the same fact, shorter.
def _initials(name: str) -> str {
    parts = [p for p in name.strip().split(" ") if p];
    if not parts {
        return "";
    }
    if len(parts) == 1 {
        return parts[0][0:2].upper();
    }
    return (parts[0][0] + parts[-1][0]).upper();
}


# What a human actually calls this person. The schema is explicit that
# `preferred_name` is what every human-facing surface must use: "Hi Xingzhi"
# from a system claiming deep personalisation, addressed to someone everyone
# calls Becky, undercuts the whole thesis.
def _display_name(p: Prospect) -> str {
    if p.preferred_name {
        return p.preferred_name;
    }
    return p.name;
}


# Lane -> the platform it actually hunts on. A/B/C drive a real browser through
# CDP; D is programmatic GitHub; W is the one named warm lead.
def _lane_source(which: LaneId) -> str {
    if which == LaneId.D {
        return "GitHub";
    }
    if which == LaneId.W {
        return "LinkedIn (named warm lead)";
    }
    return "LinkedIn";
}


def _lane_title(which: LaneId) -> str {
    if which == LaneId.A {
        return "Lane A · comment mining";
    }
    if which == LaneId.B {
        return "Lane B · first-person posts";
    }
    if which == LaneId.C {
        return "Lane C · synonym sweep";
    }
    if which == LaneId.D {
        return "Lane D · GitHub artifacts";
    }
    return "Lane W · the warm lead";
}


# ===========================================================================
# GRAPH READERS
# ===========================================================================
# Runs hang off Founder and lanes off ResearchRun, so every count here has to
# TRAVERSE. `[root --> [?:ResearchRun]]` returns 0 in this project even with a
# live run on the graph (JAC_GOTCHAS 8b) - which is how a health check once
# reported "runs: 0" while another endpoint reported four live lanes.

# ===========================================================================
# FIXTURES - telling seeded rows apart from researched ones
# ===========================================================================
# `.invalid` is reserved by RFC 2606 and can never resolve, so an address in
# it is not "a prospect we failed to verify" - it is definitionally not a real
# human. `rehearsal.jac` and `feedseed.jac` are the only things that mint them.
#
# This is a SAFETY NET, not the fix. `repair_demo_graph()` below deletes these
# rows outright, which is the right answer: a projection that hides rows the
# graph still holds would let `graph_health` keep counting them and disagree
# with the screen. The guard exists so a demo cannot show a fixture next to a
# researched human if nobody remembered to run the repair first.
def _is_fixture(name: str, email: str) -> bool {
    if email and email.lower().endswith(".invalid") {
        return True;
    }
    if name and name.lower().startswith("rehearsal") {
        return True;
    }
    return False;
}


def _founder -> Founder | None {
    founders = [root --> [?:Founder]];
    if not founders {
        return None;
    }
    # A seeded Founder sitting at index 0 in front of the real one would put
    # "rehearsal founder" on the founder card and sign every email with it.
    for f in founders {
        if not _is_fixture(f.name, f.email) {
            return f;
        }
    }
    return founders[0];
}


def _icp(who: Founder) -> ICP | None {
    targets = [who ->:Targets:->];
    return targets[0] if targets else None;
}


def _runs(who: Founder) -> list[ResearchRun] {
    return [who ->:Runs:->];
}


def _latest_run(who: Founder) -> ResearchRun | None {
    runs = _runs(who);
    if not runs {
        return None;
    }
    newest = runs[0];
    for r in runs {
        if r.started_at > newest.started_at {
            newest = r;
        }
    }
    return newest;
}


# Every prospect reachable by any route, deduplicated by jid. A prospect can be
# reachable several ways at once - surfaced by two lanes AND named as the warm
# lead - so a naive concatenation double-counts the exact people the
# convergence thesis is about.
def _all_prospects(who: Founder | None) -> list[Prospect] {
    pool: list[Prospect] = [root --> [?:Prospect]];
    if who is not None {
        runs = _runs(who);
        lanes = [runs ->:HasLane:->];
        pool = pool + [who ->:HasWarmLead:->] + [lanes ->:Surfaced:->];
    }
    seen: list[str] = [];
    out: list[Prospect] = [];
    for p in pool {
        key = jid(p);
        if key not in seen {
            seen.append(key);
            if not _is_fixture(p.name, p.email) {
                out.append(p);
            }
        }
    }
    by_score = lambda (x: Prospect) -> float { return x.score; };
    out.sort(key=by_score, reverse=True);
    return out;
}


def _resolve_prospect(prospect_id: str) -> Prospect | None {
    if not prospect_id {
        return None;
    }
    found = jobj(prospect_id);
    if isinstance(found, Prospect) {
        return found;
    }
    return None;
}


# The sent thread, if there is one. ComposeOutreach writes a draft with
# sent_at=0.0; only SendOutreach stamps it. So "has a draft" and "has actually
# emailed this person" are different questions and this answers the second.
def _threads(p: Prospect) -> list[EmailThread] {
    return [p ->:Outreach:->];
}


def _latest_thread(p: Prospect) -> EmailThread | None {
    threads = _threads(p);
    return threads[-1] if threads else None;
}


def _sessions(p: Prospect) -> list[CallSession] {
    return [p ->:Called:->];
}


def _bookings(p: Prospect) -> list[Booking] {
    return [p ->:Booked:->];
}


# ===========================================================================
# STATUS - the four-state ladder her UI gates on
# ===========================================================================
# Her client compares `status` against exactly "Found" / "Sent" /
# "Call scheduled" / "Booked" in 26 places. Each of the four is a real graph
# fact, and the highest reached state wins. Nothing here is stored: delete the
# Booking and the prospect truthfully drops back to "Call scheduled".

def _status(p: Prospect) -> str {
    if _bookings(p) {
        return "Booked";
    }
    if _sessions(p) {
        return "Call scheduled";
    }
    for t in _threads(p) {
        if t.sent_at > 0.0 {
            return "Sent";
        }
    }
    return "Found";
}


# ===========================================================================
# PROJECTION: Prospect -> her ProspectView
# ===========================================================================
# 20 fields. Sourced from our graph: id, name, initials, role, organization,
# email, phone, source, profile_url, evidence_url, evidence, evidence_date,
# why_useful, confidence, status, draft_subject, draft_body.
#
# LEFT EMPTY - our graph holds no such fact, and inventing one would put an
# unfalsifiable sentence on a judged screen:
#   location              - we never collect geography for anyone.
#   research_question     - we generate no per-prospect interview question.
#   assumption_challenged - we track no per-prospect hypothesis linkage.

def _prospect_view(p: Prospect) -> ProspectView {
    li_quote = "";
    li_url = "";
    gh_artifact = "";
    gh_url = "";
    recency = -1;
    for ev in [p ->:HasEvidence:->] {
        if (ev.source == EvidenceSource.LINKEDIN) and (not li_quote) {
            li_quote = ev.quote;
            li_url = ev.url;
            recency = ev.recency_days;
        }
        if (ev.source == EvidenceSource.GITHUB) and (not gh_artifact) {
            gh_artifact = ev.quote;
            gh_url = ev.url;
            if recency < 0 {
                recency = ev.recency_days;
            }
        }
    }

    # A phone number exists only if a human gave us one - in a reply, or on the
    # call record. It is never guessed from anything.
    phone = "";
    for t in _threads(p) {
        for reply in [t ->:GotReply:->] {
            if reply.phone_number and (not phone) {
                phone = reply.phone_number;
            }
        }
    }
    if not phone {
        for s in _sessions(p) {
            if s.phone_number and (not phone) {
                phone = s.phone_number;
            }
        }
    }

    # The lanes that independently surfaced this human. This is the product
    # thesis rendered as a field: two lanes that never saw each other agreeing
    # on one person.
    lanes = p.convergence_lanes();
    lane_names: list[str] = [];
    for l in lanes {
        lane_names.append(_lane_source(l));
    }
    origins: list[str] = [];
    for n in lane_names {
        if n not in origins {
            origins.append(n);
        }
    }
    source = " + ".join(origins);
    if p.is_warm_lead() and (not source) {
        source = "Named at intake";
    }

    profile_url = p.linkedin_url;
    if not profile_url {
        gh = p.github();
        if gh is not None {
            profile_url = gh.url;
        }
    }

    # `why_useful` is ASSEMBLED FROM GRAPH FACTS, never written by a model.
    # Every clause is checkable against the store: which lanes found them, what
    # the completeness gate decided, whether the email survived the waterfall.
    # If none of those facts exist the string stays empty rather than becoming
    # a generic compliment.
    reasons: list[str] = [];
    if len(lanes) >= 2 {
        joined = ", ".join([str(x) for x in lanes]);
        reasons.append(
            f"Surfaced independently by {len(lanes)} lanes ({joined}) - "
            + "separate searches that never saw each other converged on this person"
        );
    } elif len(lanes) == 1 {
        reasons.append(f"Surfaced by lane {str(lanes[0])}");
    }
    if p.is_warm_lead() {
        reasons.append("Named as a warm lead at intake");
    }
    if p.tier == CompletenessTier.S {
        reasons.append("Tier S: deliverable email plus both LinkedIn and GitHub content");
    } elif p.tier == CompletenessTier.A {
        reasons.append("Tier A: deliverable email plus content from one platform");
    } elif p.dropped_reason {
        reasons.append(f"Dropped at the gate: {p.dropped_reason}");
    }
    why_useful = ". ".join(reasons);

    # Recency is stored as an integer number of days, not a date. Rendering it
    # as a date would manufacture a precision the scrape never had.
    evidence_date = "";
    if recency == 0 {
        evidence_date = "today";
    } elif recency == 1 {
        evidence_date = "1 day ago";
    } elif recency > 1 {
        evidence_date = f"{recency} days ago";
    }

    thread = _latest_thread(p);

    return ProspectView(
        id=jid(p),
        name=_display_name(p),
        # Initials come from the FULL name even though the label shows the
        # preferred one: the avatar for "Ada Lovelace, who goes by Ada" is AL.
        initials=_initials(p.name if p.name else _display_name(p)),
        role=p.headline,
        organization=p.company,
        email=p.email,
        phone=phone,
        location="",
        source=source,
        profile_url=profile_url,
        evidence_url=li_url if li_url else gh_url,
        evidence=li_quote if li_quote else gh_artifact,
        evidence_date=evidence_date,
        why_useful=why_useful,
        research_question="",
        assumption_challenged="",
        confidence=p.score,
        status=_status(p),
        draft_subject=thread.subject if thread is not None else "",
        draft_body=thread.body if thread is not None else ""
    );
}


# ===========================================================================
# PROJECTION: activity nodes -> her ActivityView
# ===========================================================================
# An activity is REAL when an external system issued an id for it. AgentMail
# returns a thread_id, Vapi returns a call id (ScheduleCall raises without
# one), Google Calendar returns an event_id. Nothing seeded can mint those, so
# `is_demo` is a fact about the outside world rather than a label we chose.
#
# `learnable` means "this artifact can still teach us something" - which for us
# means a stored transcript that OnCallEnd can mine into Insight nodes. A call
# with no transcript is not learnable, and saying otherwise would promise the
# UI a button that does nothing.
#
# LEFT EMPTY on some rows:
#   external_url - only bookings carry one (Google's htmlLink / Meet link).
#                  An AgentMail send has no user-visible URL, so email rows
#                  get "" rather than a fabricated link.
#   hypothesis   - filled from the ICP the run was actually targeting when we
#                  have one; empty before PlanCampaign has run.

def _email_activities(p: Prospect, hypothesis: str) -> list[ActivityView] {
    out: list[ActivityView] = [];
    who = _display_name(p);
    for t in _threads(p) {
        if t.sent_at <= 0.0 {
            # Composed but never sent. Not an activity - it has not happened.
            continue;
        }
        real = t.thread_id != "";
        out.append(ActivityView(
            id=jid(t),
            timestamp=_stamp(t.sent_at),
            channel="AgentMail",
            activity_type="email",
            identity=t.inbox_id,
            state="Sent",
            label=t.subject,
            link_label="",
            external_url="",
            prospect_name=who,
            hypothesis=hypothesis,
            transcript_title="",
            transcript="",
            learnable=False,
            is_demo=not real
        ));
        for reply in [t ->:GotReply:->] {
            out.append(ActivityView(
                id=jid(reply),
                timestamp=_stamp(reply.received_at),
                channel="AgentMail",
                activity_type="email",
                identity=who,
                state="Replied",
                label=f"Reply received - {str(reply.intent)}",
                link_label="",
                external_url="",
                prospect_name=who,
                hypothesis=hypothesis,
                transcript_title="Reply text",
                transcript=reply.raw,
                learnable=reply.raw.strip() != "",
                is_demo=not real
            ));
        }
    }
    return out;
}


def _call_activities(p: Prospect, hypothesis: str) -> list[ActivityView] {
    out: list[ActivityView] = [];
    who = _display_name(p);
    for s in _sessions(p) {
        real = s.vapi_call_id != "";
        transcript = s.transcript;
        out.append(ActivityView(
            id=jid(s),
            timestamp=_stamp(0.0),
            channel="Phone",
            activity_type="call",
            identity=s.phone_number,
            state=str(s.outcome),
            label=f"Voice call - {str(s.outcome)}",
            link_label="Read transcript" if transcript.strip() else "",
            external_url="",
            prospect_name=who,
            hypothesis=hypothesis,
            transcript_title="Call transcript" if transcript.strip() else "",
            transcript=transcript,
            learnable=transcript.strip() != "",
            is_demo=not real
        ));
    }
    return out;
}


def _booking_activities(p: Prospect, hypothesis: str) -> list[ActivityView] {
    out: list[ActivityView] = [];
    who = _display_name(p);
    for b in _bookings(p) {
        real = b.event_id != "";
        link = b.html_link if b.html_link else b.meet_link;
        out.append(ActivityView(
            id=jid(b),
            timestamp=b.start,
            channel="Google Calendar",
            activity_type="meeting",
            identity=", ".join(b.attendees),
            state="Booked",
            label=f"Interview booked for {b.start}" if b.start else "Interview booked",
            link_label="Open invite" if link else "",
            external_url=link,
            prospect_name=who,
            hypothesis=hypothesis,
            transcript_title="",
            transcript="",
            learnable=False,
            is_demo=not real
        ));
    }
    return out;
}


def _insight_view(i: Insight) -> InsightView {
    return InsightView(
        id=jid(i),
        label=i.claim,
        detail=i.claim,
        evidence=i.evidence,
        # `impact` would be a judgement about what this insight CHANGES, and we
        # store no such judgement. Empty rather than editorialised.
        impact=""
    );
}


# ===========================================================================
# PROJECTION: Lane -> her PersonaView
# ===========================================================================
# Her model has founder-approved personas; ours has lanes, each a distinct
# hunting doctrine written by the `by llm()` planner. A lane IS "a kind of
# person and how to find them", so the mapping is real - but two of her fields
# have no counterpart:
#   research_goal - we store no per-lane learning objective.
#   approved      - we have nowhere to record founder approval (see
#                   save_persona_feedback, which cannot persist and says so).
#                   Reported True because every lane on the graph is a lane
#                   that actually ran - it is a statement about the lane
#                   existing, not about a founder having blessed it.
# `pain` is the ICP's pain phrases, which are campaign-level: the same string
# appears on every lane, because every lane hunts the same ICP.

def _persona_view(lane: Lane, pain: str) -> PersonaView {
    return PersonaView(
        id=jid(lane),
        title=_lane_title(lane.lane_id),
        description=lane.doctrine,
        pain=pain,
        signal=lane.current_query,
        research_goal="",
        source_plan=_lane_source(lane.lane_id),
        approved=lane.approved
    );
}


# ===========================================================================
# THE PROJECTION
# ===========================================================================
# Pure read. Never raises: bootstrap_workspace() is the first call the UI makes
# and a 500 here is a blank application, so an empty graph must project to an
# empty workspace rather than an error.
#
# WorkspaceView fields with no source in our graph:
#   company             - our Founder node has no company field.
#   understanding_note  - we store no founder commentary on the understanding.
#   understanding_note  - the confirm step's note has no home; ICP.founder_note
#                         carries the PERSONA note, and one field cannot hold two.
#   zoom_connected      - always False, and true: we book Google Meet, never Zoom.

def _workspace() -> WorkspaceView {
    who = _founder();
    icp: ICP | None = None;
    if who is not None {
        icp = _icp(who);
    }

    hypothesis = icp.hypothesis if icp is not None else "";
    pain = "; ".join(icp.pain_phrases) if icp is not None else "";
    # The founder's note from the persona-review step, read back from where
    # save_persona_feedback stored it.
    note = icp.founder_note if icp is not None else "";

    understanding: ProductUnderstanding | None = None;
    if who is not None {
        understanding = ProductUnderstanding(
            product=who.product_summary,
            job=who.one_liner,
            audience=hypothesis,
            # No source in our graph for the four below. The ICP the planner
            # produces is a targeting hypothesis - who to look for and what
            # they say - not a product-positioning worksheet.
            moment="",
            alternative="",
            difference="",
            learning_goal="",
            concepts=icp.keywords if icp is not None else []
        );
    }

    # The founder's own artifacts, as supplied at intake. Only the repo is
    # actually stored, so it is the only one listed.
    artifact_names: list[str] = [];
    if who is not None {
        owner: Founder = who as Founder;
        repo = owner.github_repo;
        if repo {
            artifact_names.append(repo);
        }
    }

    personas: list[PersonaView] = [];
    run: ResearchRun | None = None;
    if who is not None {
        run = _latest_run(who);
    }
    if run is not None {
        lanes: list[Lane] = [run ->:HasLane:->];
        by_lane = lambda (x: Lane) -> str { return str(x.lane_id); };
        lanes.sort(key=by_lane);
        for lane in lanes {
            personas.append(_persona_view(lane, pain));
        }
    }

    prospects: list[ProspectView] = [];
    activities: list[ActivityView] = [];
    insights: list[InsightView] = [];
    for p in _all_prospects(who) {
        prospects.append(_prospect_view(p));
        activities = (
            activities
            + _email_activities(p, hypothesis)
            + _call_activities(p, hypothesis)
            + _booking_activities(p, hypothesis)
        );
        for s in _sessions(p) {
            for i in [s ->:Learned:->] {
                insights.append(_insight_view(i));
            }
        }
    }

    # Each completed research run is one iteration of the targeting hypothesis.
    # Version 1 before any run, so her UI never renders "version 0".
    version = 1;
    if who is not None {
        version = len(_runs(who)) + 1;
    }

    return WorkspaceView(
        founder_name=who.name if who is not None else "",
        founder_email=who.email if who is not None else "",
        company="",
        # These are claims about wiring, so each is read from the credential
        # that actually has to be present for the integration to work.
        gmail_connected=cfg("AGENTMAIL_API_KEY", "") != "",
        calendar_connected=cfg("GOOGLE_CLIENT_ID", "") != "",
        zoom_connected=False,
        product_description=who.product_summary if who is not None else "",
        understanding=understanding,
        # An ICP on the graph means PlanCampaign ran and the targeting is
        # settled. That is the closest real fact to "confirmed".
        understanding_confirmed=icp is not None,
        understanding_note="",
        artifact_names=artifact_names,
        personas=personas,
        persona_note=note,
        prospects=prospects,
        activities=activities,
        insights=insights,
        hypothesis_version=version
    );
}


# ===========================================================================
# THE 13 ENDPOINTS
# ===========================================================================
# Signatures copied byte-for-byte from becky_ui/traction/workflows.jac:1089.
# Four are `async def:pub` because their bodies await an async walker - the
# client already `await`s all thirteen, so this is invisible to her UI
# (JAC_GOTCHAS 7.4: mark an endpoint async when its body uses await).


def:pub bootstrap_workspace() -> WorkspaceView {
    return _workspace();
}


# Deletes the founder and everything hanging off them. Prospects seeded
# directly onto root are reached separately, because rehearsal seeds attach
# there rather than under the founder.
def:pub reset_workspace() -> WorkspaceView {
    for entity in [root --> [?:Founder]] {
        del entity;
    }
    for stray in [root --> [?:Prospect]] {
        del stray;
    }
    return _workspace();
}


# One-shot demo-graph repair, run over HTTP against the LIVE server because a
# second `jac` process on the same anchor store corrupts the guest root
# (JAC_GOTCHAS 8e). Two jobs, both idempotent:
#
#   1. Rewrite the EXISTING Founder's name and email from `.env`. The node on
#      the graph was minted by the rehearsal seeder and carries
#      "rehearsal founder" / rehearsal@example.invalid, which is what the
#      founder card renders and what `outreach.founder_context()` signs with.
#      It updates in place and never creates a second Founder - a second one
#      splits the graph and every run, lane and warm-lead edge hanging off the
#      first becomes unreachable.
#
#   2. Delete the seeded prospects outright rather than filtering them, so the
#      graph and `graph_health` agree with the screen. Only `.invalid`
#      addresses and `rehearsal*` names match, so a researched human is never
#      in scope.
#
# The two parameters default to `.env` and exist so the caller can override
# them: `cfg()` reads the .env the SERVER process loaded, and if that process
# was started before `FOUNDER_NAME` was added, reading it again returns the
# stale value. Passing the name explicitly cannot go stale.
def:pub repair_demo_graph(
    founder_name: str = "", founder_email: str = ""
) -> WorkspaceView {
    real_name = founder_name if founder_name else cfg("FOUNDER_NAME", "");
    real_email = founder_email if founder_email else cfg("FOUNDER_EMAIL", "");

    for f in [root --> [?:Founder]] {
        if _is_fixture(f.name, f.email) {
            if real_name {
                f.name = real_name;
            }
            if real_email {
                f.email = real_email;
            }
            print(f"[bridge] repair: Founder renamed to {f.name} <{f.email}>");
        }
    }

    dropped: list[str] = [];
    for p in [root --> [?:Prospect]] {
        if _is_fixture(p.name, p.email) {
            dropped.append(p.name);
            del p;
        }
    }
    who = _founder();
    if who is not None {
        owner: Founder = who as Founder;
        for p in [owner ->:HasWarmLead:->] {
            if _is_fixture(p.name, p.email) {
                dropped.append(p.name);
                del p;
            }
        }
    }
    print(f"[bridge] repair: dropped {len(dropped)} seeded prospect(s)");
    return _workspace();
}


# Intake. Records the product description on the Founder, then runs the real
# `by llm()` ICP planner over it. PlanCampaign keeps an existing ICP unless
# told to replace, so re-describing the product genuinely re-plans.
def:pub begin_product(description: str) -> WorkspaceView {
    who = _founder();
    if who is None {
        who = root ++> Founder(
            name=cfg("FOUNDER_NAME", ""),
            email=cfg("FOUNDER_EMAIL", "")
        );
    }
    who.product_summary = description;
    if not who.one_liner {
        who.one_liner = description;
    }
    root spawn PlanCampaign(replace=True);
    return _workspace();
}


# Her form collects six positioning answers. Our graph stores exactly two of
# them - the one-liner and the product summary - and the ICP hypothesis. The
# other four (moment, alternative, difference, learning_goal) have nowhere to
# live, so they are accepted and NOT persisted; `_workspace` reports them
# empty on the way back rather than echoing them and implying storage.
def:pub confirm_understanding(
    job: str,
    audience: str,
    moment: str,
    alternative: str,
    difference: str,
    learning_goal: str,
    founder_note: str = ""
) -> WorkspaceView {
    who = _founder();
    if who is None {
        return _workspace();
    }
    if job {
        who.one_liner = job;
    }
    icp = _icp(who);
    if (icp is not None) and audience {
        icp.hypothesis = audience;
    }
    return _workspace();
}


# The only artifact our graph can hold is the GitHub repo, which the ICP
# planner genuinely reads. Anything else is accepted and dropped, and does not
# come back in artifact_names - so the UI shows what was actually stored.
def:pub add_artifact(
    artifact_type: str, name: str, external_url: str
) -> WorkspaceView {
    who = _founder();
    if who is None {
        return _workspace();
    }
    if artifact_type.lower() == "github" {
        who.github_repo = name if name else external_url;
    }
    return _workspace();
}


# Personas are lane doctrines, and the planner writes them. Re-planning against
# the current description regenerates the doctrines the lanes will hunt with.
def:pub build_personas() -> WorkspaceView {
    root spawn PlanCampaign(replace=True);
    return _workspace();
}


# Real, as of ARCHITECT adding `ICP.founder_note` and `Lane.approved` to
# schema.jac. This was an honest no-op until those two fields existed - it
# returned an empty `persona_note` rather than echoing the founder's note back
# as though it had been stored, because a UI that reflects your note is a UI
# claiming a persistence it does not have.
#
# A deselected lane is marked `approved=False`, never deleted, so the run it
# belongs to still shows what the founder rejected and why the ledger is
# shorter than the fan-out.
def:pub save_persona_feedback(
    note: str, selected_ids: list[str] | None = None
) -> WorkspaceView {
    who = _founder();
    if who is None {
        return _workspace();
    }
    owner: Founder = who as Founder;
    icp = _icp(owner);
    if icp is not None {
        target: ICP = icp as ICP;
        target.founder_note = note;
    }
    run = _latest_run(owner);
    if run is not None {
        current: ResearchRun = run as ResearchRun;
        lanes: list[Lane] = [current ->:HasLane:->];
        # An absent or empty selection means "keep all", matching her mock:
        # her client already substitutes the full id list when the founder
        # deselects nothing (frontend.impl.jac:280), so an empty list here is
        # the founder having approved everything, never having rejected it.
        if selected_ids {
            picked: list[str] = selected_ids as list[str];
            for lane in lanes {
                lane.approved = jid(lane) in picked;
            }
        } else {
            for lane in lanes {
                lane.approved = True;
            }
        }
    }
    return _workspace();
}


# The centrepiece. RunResearch fans five lanes out with `flow` and collects
# them with `wait` - A/B/C drive real browsers through our pure-Jac CDP client,
# D is programmatic GitHub, W deep-reads the named warm lead - then merges on
# convergence. Cross-link, the email gate and ranking run after, in that order,
# because ranking multiplies by convergence and gates on a deliverable address.
def:pub run_signal_search() -> WorkspaceView {
    who = _founder();
    if who is None {
        return _workspace();
    }
    if _icp(who) is None {
        root spawn PlanCampaign();
    }

    # DEMO MODE. `TRACTION_DEMO=1` in .env makes this return whatever research
    # is already on the graph instead of launching the live fan-out.
    #
    # This is not a stub and it fabricates nothing: `_workspace()` reads the
    # same lanes, the same analyst narration, the same prospects and the same
    # convergence the live run would have written. The only thing that changes
    # is WHO wrote them - a prior run rather than this request.
    #
    # It exists because the live path drives five real browser sessions against
    # LinkedIn and GitHub and takes six to fifteen minutes. A UI that sits at
    # 97% with a lane reading "SEARCHING" for a quarter of an hour is not a
    # demo, and on a recording it is indistinguishable from a hang.
    #
    # Unset the flag and the real fan-out runs, unchanged, below.
    if cfg("TRACTION_DEMO", "") {
        # Say so. Demo mode returns 200 in milliseconds having launched
        # nothing, which on the wire is indistinguishable from the live path
        # silently failing to fire - the exact shape of the bug that costs a
        # demo (§0.15). One line in the log tells the two apart.
        print(
            "[bridge] run_signal_search: TRACTION_DEMO is set - returning the "
            + "research already on the graph, live fan-out NOT launched."
        );
        return _workspace();
    }

    researched = root spawn RunResearch();
    run_reports = researched.reports;
    print(f"[bridge] run_signal_search: RunResearch -> {run_reports}");
    if not run_reports {
        # A walker that reports nothing did not run. Spawning on root is a
        # silent no-op when the entry ability triggers on a node type, and it
        # returns 200 with an untouched graph (§0.15).
        print(
            "[bridge] run_signal_search: RunResearch reported NOTHING - it did "
            + "not run. Check that its Root entry ability fired."
        );
    }
    linked = root spawn CrossLinkToLinkedIn();
    gated = root spawn ResolveEmail();
    print(
        f"[bridge] run_signal_search: crosslinked={linked.linked} "
        + f"emails_resolved={gated.resolved} dropped={gated.dropped}"
    );
    ranked = root spawn RankAndSelect();
    rank_reports = ranked.reports;
    print(f"[bridge] run_signal_search: RankAndSelect -> {rank_reports}");
    return _workspace();
}


# ComposeOutreach refuses to draft unless the graph holds something this person
# actually wrote or built, and refuses again if the drafted body does not quote
# it verbatim. Both refusals are load-bearing and neither is caught here: a
# prospect that fails the gate simply ends up with no draft, which is the
# correct outcome and is visible as an empty draft_body in her UI.
async def:pub draft_outreach() -> WorkspaceView {
    for p in _all_prospects(_founder()) {
        if not p.email {
            continue;
        }
        if _threads(p) {
            continue;
        }
        _ = await (root spawn ComposeOutreach(prospect_id=jid(p)));
    }
    return _workspace();
}


# The founder may edit the draft before sending, and an edit can destroy the
# grounding ComposeOutreach proved. So the revised body is re-checked against
# the SAME evidence, with the SAME function, before it is allowed onto the
# thread. If the edit removed the quote, the send is refused and the stored
# draft is left exactly as it was - the gate is not weakened by giving a human
# a text box.
async def:pub send_outreach(prospect_id: str, revised_body: str) -> WorkspaceView {
    p = _resolve_prospect(prospect_id);
    if p is None {
        return _workspace();
    }
    thread = _latest_thread(p);
    if thread is None {
        return _workspace();
    }
    if revised_body and (revised_body != thread.body) {
        citation = best_linkedin_citation(p);
        artifact = best_github_artifact(p);
        edited = EmailDraft(subject=thread.subject, body=revised_body);
        problem = citation_problem(edited, citation.quote, artifact);
        if problem {
            print(
                f"[bridge] send_outreach REFUSED for {p.name}: the edited body is no "
                + f"longer grounded - {problem}. The stored draft is unchanged."
            );
            return _workspace();
        }
        thread.body = revised_body;
    }
    _ = await (root spawn SendOutreach(prospect_id=prospect_id));
    return _workspace();
}


# Vapi outbound. ScheduleCall resolves the number from the graph and raises if
# Vapi returns no call id, so a CallSession on the graph always corresponds to
# a call Vapi accepted.
async def:pub schedule_demo_call(prospect_id: str) -> WorkspaceView {
    p = _resolve_prospect(prospect_id);
    if p is None {
        return _workspace();
    }
    _ = await (root spawn ScheduleCall(prospect_id=prospect_id));
    return _workspace();
}


# Google Calendar + Meet, both parties invited.
#
# Her signature carries NO time, and BookInterview refuses to invent a slot -
# deliberately, after a wrong invite reached a real calendar. Nothing in our
# graph records a time this prospect proposed (ReplyEvent stores intent and
# sentiment, not proposed times), so the phrase below is a BRIDGE DEFAULT, not
# something anyone asked for. It is resolved against the real clock by the same
# server-side parser the voice agent uses, availability is checked, and the
# activity row shows the slot Google actually stored - so the screen shows the
# real booking, and this comment is where the time came from.
async def:pub schedule_demo_meeting(prospect_id: str) -> WorkspaceView {
    p = _resolve_prospect(prospect_id);
    if p is None {
        return _workspace();
    }
    _ = await (root spawn BookInterview(
        prospect_id=prospect_id,
        spoken_time="tomorrow at 10am"
    ));
    return _workspace();
}


# OnCallEnd stores the transcript first, then mines it into Insight nodes. If
# the model is unreachable the transcript is still saved and the insights are
# skipped - never the other way round.
def:pub synthesize_demo_interview(prospect_id: str) -> WorkspaceView {
    p = _resolve_prospect(prospect_id);
    if p is None {
        return _workspace();
    }
    for s in _sessions(p) {
        if s.transcript.strip() {
            root spawn OnCallEnd(
                call_id=s.vapi_call_id,
                transcript=s.transcript
            );
        }
    }
    return _workspace();
}
