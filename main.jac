"""TRACTION - entry module.

Five external services - Browserbase, AgentMail, Vapi, Google Calendar and
GitHub - talk to this system, and there is not one line of routing glue. Each
one is a walker on a persistent graph. The language generated the endpoints.

    jac check .                 # typecheck the whole project
    jac start main.jac --no-client   # serve the API on :8000
    jac run main.jac            # bootstrap banner + graph stats

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
import from research {
    RunResearch, LinkedInLane, LaneA, LaneB, LaneC,
    LaneResult, LaneSpec, CommentVerdict
}
import from githublane { GithubLane }
import from identity { CrossLinkToGithub, CrossLinkToLinkedIn, ResolveEmail, RankAndSelect }
import from outreach { ComposeOutreach, SendOutreach, OnEmailReply }
import from voice    { ScheduleCall, KbQuery, BookInterview, OnCallEnd }
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
            if p.tier == CompletenessTier.DROPPED {
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
