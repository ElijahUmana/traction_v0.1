"""TRACTION - entry module.

Five external services - Browserbase, AgentMail, Vapi, Google Calendar and
GitHub - talk to this system, and there is not one line of routing glue. Each
one is a walker on a persistent graph. The language generated the endpoints.

    jac check .                 # typecheck the whole project
    jac start main.jac          # serve the API *and* the web client on :8000
    jac run main.jac            # bootstrap banner + graph stats

`--no-client` is deliberately gone. It is exactly the flag that stops the web
client being built and served, and this program now serves both surfaces from
one process. Two processes cannot share the anchor store (JAC_GOTCHAS 8e), so
"API here, UI there" is not an option - it is one process or a corrupt graph.

-----------------------------------------------------------------------------
ENDPOINT REGISTRY - READ THIS BEFORE ADDING AN ENDPOINT
-----------------------------------------------------------------------------
Every `def:pub` and every `walker:pub` MUST have its name listed in one of the
`import from ... { ... }` blocks below, or it returns 404/405 at runtime even
though it compiles clean and even though its module is already imported here
(jaseci-labs/jac#7695 - registration tracks the exact NAME, not the module).

So: add your endpoint, then add its name here. Same commit. Import your node
and obj types alongside the functions too - a missing type is a server-side
NameError at request time, not at check time.
"""

import from contracts {
    LaneId, LaneState, RunStatus, ReasoningKind,
    EvidenceSource, EvidenceKind, IdentityTier, EmailSource,
    CompletenessTier, ReplyIntent, CallOutcome,
    LaneDoctrine, CampaignPlan, ProspectCandidate, PivotDecision,
    CrossLinkVerdict, OutreachDraft, AvailabilityIntent,
    KbAnswer, CallInsight, ProspectView
}

import from schema {
    Founder, ICP, ResearchRun, Lane, Reasoning, SearchProbe,
    Prospect, Evidence,
    IdentityProfile, GithubProfile, LinkedinProfile,
    EmailThread, ReplyEvent, CallSession, Insight, Booking,
    Targets, HasWarmLead, Runs, HasLane, Emitted, Surfaced,
    Probe, Widened,
    HasEvidence, Identity, Outreach, GotReply, Called, Learned, Booked
}

# --- teammate endpoint modules are imported here as they land ---------------
import from plan { PlanCampaign, IcpDraft }
import from research {
    RunResearch, LinkedInLane, LaneA, LaneB, LaneC,
    LaneResult, LaneSpec, CommentVerdict
}
import from githublane { GithubLane }
# ResearchWarmLead is the single-lane route for the warm lead: RunResearch fans
# out five lanes and takes minutes, this runs only the one the email and the
# call depend on, in about forty seconds. It must be imported HERE, not merely
# declared walker:pub in lane_w.jac - a walker nobody imports into the entry
# module gets no route and POST /walker/ResearchWarmLead returns 405.
import from lane_w { ResearchWarmLead }
import from identity { CrossLinkToGithub, CrossLinkToLinkedIn, ResolveEmail, RankAndSelect }
import from outreach { ComposeOutreach, SendOutreach, OnEmailReply }
# vapi_kb and vapi_book are the only two endpoints in this program that are
# functions rather than walkers, and the reason is the wire format, not the
# work. Vapi reads `results` at the TOP LEVEL of the response body; every jac
# walker and function is wrapped in {"ok":...,"data":{"result":...}}, so our
# correctly-formed results array sat at data.reports[0].results where Vapi
# never looks, and the agent was told "No result returned" on a live call.
# `@restspec(envelope=False)` sends the return value to the wire verbatim - and
# the runtime honours it on the FUNCTION path only (the walker endpoint builder
# ignores it). So these two spawn the KbQuery/BookInterview walkers to do all
# the traversal and own nothing but the wire format. They must be imported here
# or the /vapi/* routes never register and the tools 405.
import from voice    { ScheduleCall, KbQuery, BookInterview, OnCallEnd, vapi_kb, vapi_book }
import from rehearsal { SeedRehearsalProspect }
import from feedseed {
    SeedRehearsalRun, SeedRehearsalReasoning,
    SeedRehearsalSurfaced, SeedRehearsalConvergence
}
import from feed {
    LiveFeed, list_lanes, list_prospects, get_run_state,
    feed_since, feed_backlog,
    LaneView, RunStateView, ReasoningView, FeedBatch
}

# --- the web client's server contract ----------------------------------------
# Becky's client (`frontend.cl.jac`) reaches the server with `sv import`, not
# with fetch - it calls these thirteen by NAME and Jac generates the RPC. So
# these names ARE the frontend contract; changing one changes her UI. They must
# be listed here for the same reason every other endpoint is (see above).
#
# `WorkspaceView` is the single return type of all thirteen and must be imported
# alongside them or the call is a server-side NameError at request time.
#
# Only `WorkspaceView` is taken from `views` on purpose. `views.jac` also
# declares `ProspectView` and `OutreachDraft`, and so does `contracts.jac`, with
# different shapes - importing both here would silently shadow one with the
# other. `feed.jac` needs the contracts pair, so the contracts pair is what this
# module binds; the views pair stays resolved inside `views.jac` and `bridge.jac`.
import from views { WorkspaceView }
import from bridge {
    bootstrap_workspace, reset_workspace,
    begin_product, confirm_understanding, add_artifact,
    build_personas, save_persona_feedback,
    run_signal_search, draft_outreach,
    send_outreach, schedule_demo_call, schedule_demo_meeting,
    synthesize_demo_interview
}


# Node counts across the whole reachable graph - the fastest way to prove the
# graph survived a restart, and the fastest way to see a split root.
# NOTE: runs hang off Founder and lanes off ResearchRun, so this must TRAVERSE.
# Counting only `[root --> [?:X]]` silently reports 0 runs and 0 lanes while
# get_run_state happily reports a live run with four lanes.
def:pub graph_health -> dict[str, int] {
    founders = [root --> [?:Founder]];
    runs = [founders ->:Runs:->];
    lanes = [runs ->:HasLane:->];

    seen: list[str] = [];
    converged: int = 0;
    dropped: int = 0;
    for p in [root --> [?:Prospect]] + [founders ->:HasWarmLead:->] + [lanes ->:Surfaced:->] {
        key = jid(p);
        if key not in seen {
            seen.append(key);
            if p.is_converged() {
                converged += 1;
            }
            # Compare against the literal, not the enum member. CompletenessTier
            # is str-backed so these are equal - but resolving the symbol here
            # made graph_health 500 with "name 'CompletenessTier' is not defined"
            # when a new module joined main.jac's import registry and shifted
            # init order. jac check stayed green throughout; it is a runtime
            # resolution failure, not a type error. The literal cannot break.
            if p.tier == "DROPPED" {
                dropped += 1;
            }
        }
    }
    return {
        "founders": len(founders),
        "runs": len(runs),
        "lanes": len(lanes),
        "probes": len([lanes ->:Probe:->]),
        "reasoning": len([lanes ->:Emitted:->]),
        "prospects": len(seen),
        "converged_prospects": converged,
        "dropped_prospects": dropped
    };
}


# --- the web client -----------------------------------------------------------
# Becky built the whole UI as a Jac `cl` client. This block is what makes the
# ONE `jac start main.jac` serve it: `[serve] base_route_app = "app"` in
# jac.toml routes `/` at this function, and `.frontend` resolves to
# `frontend.cl.jac` in this directory.
#
# It lives in main.jac rather than a second entry point because the API and the
# UI must be the same process. Two jac processes against one `.jac/data` anchor
# store diverge the guest root and end in permanent 500s that no restart heals
# (JAC_GOTCHAS 8e / 8e-iii) - so a separate UI server is not a lighter option,
# it is the outage.
cl {
    import "./styles.global.css";
    import from .frontend { TractionApp }

    def:pub app -> JsxElement {
        return <TractionApp/>;
    }
}


with entry:__main__ {
    stats = graph_health();
    print("TRACTION graph online.");
    print("  founders           :", stats["founders"]);
    print("  research runs      :", stats["runs"]);
    print("  lanes              :", stats["lanes"]);
    print("  probes             :", stats["probes"]);
    print("  reasoning lines    :", stats["reasoning"]);
    print("  prospects          :", stats["prospects"]);
    print("  converged prospects:", stats["converged_prospects"]);
    print("  dropped prospects  :", stats["dropped_prospects"]);
}
