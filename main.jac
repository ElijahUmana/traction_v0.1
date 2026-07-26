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
    Founder, ICP, ResearchRun, Lane, Reasoning,
    Prospect, Evidence,
    IdentityProfile, GithubProfile, LinkedinProfile,
    EmailThread, ReplyEvent, CallSession, Insight, Booking,
    Targets, HasWarmLead, Runs, HasLane, Emitted, Surfaced,
    HasEvidence, Identity, Outreach, GotReply, Called, Learned, Booked
}

# --- teammate endpoint modules are imported here as they land ---------------
# import from research { RunResearch, LinkedInLane, GithubLane, PlanCampaign }
# import from identity { CrossLinkToGithub, CrossLinkToLinkedIn, ResolveEmail, RankAndSelect }
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


# Node counts by archetype - the fastest way to prove the graph survived a restart.
def:pub graph_health -> dict[str, int] {
    prospects = [root --> [?:Prospect]];
    converged: int = 0;
    for p in prospects {
        if p.is_converged() {
            converged += 1;
        }
    }
    return {
        "founders": len([root --> [?:Founder]]),
        "runs": len([root --> [?:ResearchRun]]),
        "lanes": len([root --> [?:Lane]]),
        "prospects": len(prospects),
        "converged_prospects": converged
    };
}


with entry:__main__ {
    stats = graph_health();
    print("TRACTION graph online.");
    print("  founders           :", stats["founders"]);
    print("  research runs      :", stats["runs"]);
    print("  lanes              :", stats["lanes"]);
    print("  prospects          :", stats["prospects"]);
    print("  converged prospects:", stats["converged_prospects"]);
}
