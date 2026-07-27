"""THE END-TO-END ARTIFACT — the full chain in one process, with graph counts.

Every stage prints what it moved in the graph, because the failure we have hit
repeatedly is a stage returning success without writing anything. A count that
does not change is a failed stage no matter what it reported.

Stops before SendOutreach. No email is sent, no call is placed.

    env -u REDIS_URL jac run e2e_chain.jac
"""

import asyncio;
import time;

import from contracts { LaneId, RunStatus }
import from schema {
    Founder, ICP, ResearchRun, Lane, Prospect, Evidence, Reasoning,
    EmailThread, GithubProfile, LinkedinProfile,
    Targets, Runs, HasLane, HasWarmLead, Surfaced, HasEvidence, Emitted, Identity
}
import from plan { PlanCampaign }
import from research { RunResearch }
import from lane_w { LaneW }
import from identity { ResolveEmail, RankAndSelect, CrossLinkToGithub, CrossLinkToLinkedIn }
import from outreach { ComposeOutreach }
import from browser.env { env }

def first(rows: list) -> dict {
    return rows[0] if rows else {};
}

"""Every count that matters, read straight off the graph."""
def census -> dict[str, int] {
    founders: list = [root --> [?:Founder]];
    prospects: list = [];
    lanes: list = [];
    runs: list = [];
    for f in founders {
        for r in [f ->:Runs:->] {
            runs.append(r);
            for ln in [r ->:HasLane:->] {
                lanes.append(ln);
                for p in [ln ->:Surfaced:->] {
                    if p not in prospects {
                        prospects.append(p);
                    }
                }
            }
        }
    }
    evidence = 0;
    reasoning = 0;
    emails = 0;
    identities = 0;
    with_email = 0;
    for p in prospects {
        evidence += len([p ->:HasEvidence:->]);
        emails += len([p ->:Outreach:->]);
        identities += len([p ->:Identity:->]);
        if p.email {
            with_email += 1;
        }
    }
    for ln in lanes {
        reasoning += len([ln ->:Emitted:->]);
    }
    return {
        "founders": len(founders), "runs": len(runs), "lanes": len(lanes),
        "prospects": len(prospects), "evidence": evidence,
        "reasoning": reasoning, "identities": identities,
        "with_email": with_email, "threads": emails
    };
}

glob PREV: dict[str, int] = {};

def stage(label: str) {
    now = census();
    parts: list[str] = [];
    for k in ["prospects", "evidence", "reasoning", "identities", "with_email", "threads"] {
        was = PREV.get(k, 0);
        delta = now.get(k, 0) - was;
        mark = f" (+{delta})" if delta > 0 else "";
        parts.append(f"{k}={now.get(k)}{mark}");
    }
    print(f"    GRAPH  {'  '.join(parts)}");
    for k in now.keys() {
        PREV[k] = now[k];
    }
}

async def main -> None {
    warm_url = env("TEAMMATE_LINKEDIN_URL", required=True);
    warm_name = env("TEAMMATE_NAME", required=True);
    preferred = env("TEAMMATE_PREFERRED_NAME", fallback="");
    warm_email = env("TEAMMATE_EMAIL", fallback="");
    ctx = env("BROWSERBASE_LINKEDIN_CONTEXT_ID", required=True);
    t_start = time.monotonic();

    print("=" * 76);
    print("TRACTION — the full chain, one process, real services");
    print("=" * 76);

    # ---- 0. intake ------------------------------------------------------
    print("\n[0] INTAKE — founder, ICP, and the warm lead named at intake");
    founder = root ++> Founder(
        name="Elijah Umana",
        email=env("FOUNDER_EMAIL", fallback="founder@example.com"),
        product_summary="Pure-Jac browser automation that researches founder-led sales prospects.",
        one_liner="Find the human, not the market.",
        github_repo="ElijahUmana/traction_v0.1"
    );
    founder +>:Targets(created_at=time.time()):+> ICP(
        hypothesis="founders and operators doing manual prospect research",
        keywords=["prospect research", "sales research", "lead generation"],
        pain_phrases=["manual research", "wasting hours prospecting"]
    );
    founder +>:HasWarmLead(note="named at intake"):+> Prospect(
        name=warm_name, handle="", preferred_name=preferred
    );
    print(f"    founder={founder.name}  warm lead={warm_name} ({preferred})");
    stage("intake");

    # ---- 1. PlanCampaign ------------------------------------------------
    print("\n[1] PlanCampaign");
    try {
        planned = first((root spawn PlanCampaign()).reports);
        print(f"    {str(planned)[:200]}");
    } except Exception as e {
        print(f"    FAILED: {e}");
    }
    stage("plan");

    # ---- 2. RunResearch — lanes A/B/C/D in flow -------------------------
    print("\n[2] RunResearch — lanes fan out with flow/wait");
    try {
        # RunResearch declares `can start with Founder entry` -- NOT Root. Spawned
        # on root it does nothing at all and reports []. That is also what
        # POST /walker/RunResearch does, since the HTTP route spawns on root.
        rr = RunResearch(context_id=ctx) spawn founder;
        print(f"    reports: {str(rr.reports)[:300] if hasattr(rr, 'reports') else '(none)'}");
    } except Exception as e {
        print(f"    FAILED: {e}");
    }
    stage("research");

    # ---- 3. Lane W — the warm lead --------------------------------------
    # NOT spawned by RunResearch: Lane W lives in its own module and the
    # orchestrator does not reference it. Spawned explicitly here, which is
    # itself a finding about the joined-up chain.
    print("\n[3] Lane W — deep read on the warm lead (spawned explicitly)");
    runs: list = [founder ->:Runs:->];
    if runs {
        wlane = Lane(lane_id=LaneId.W);
        runs[0] +>:HasLane(launched_at=time.time()):+> wlane;
        try {
            LaneW(context_id=ctx, warm_url=warm_url, warm_name=warm_name,
                  preferred_name=preferred, warm_email=warm_email) spawn wlane;
            print(f"    lane state={wlane.state}  live_url={'yes' if wlane.live_url else 'MISSING'}");
        } except Exception as e {
            print(f"    FAILED: {e}");
        }
    } else {
        print("    no ResearchRun on the graph - RunResearch never created one");
    }
    stage("lane W");

    # ---- 4. identity + email -------------------------------------------
    print("\n[4] CrossLink + ResolveEmail + RankAndSelect");
    for (label, w) in [("CrossLinkToGithub", CrossLinkToGithub()),
                       ("CrossLinkToLinkedIn", CrossLinkToLinkedIn()),
                       ("ResolveEmail", ResolveEmail()),
                       ("RankAndSelect", RankAndSelect())] {
        try {
            res = w spawn root;
            n = len(res.reports) if hasattr(res, "reports") else 0;
            print(f"    {label:<22} {n} report(s)");
        } except Exception as e {
            print(f"    {label:<22} FAILED: {str(e)[:90]}");
        }
    }
    stage("identity");

    # ---- 5. ComposeOutreach on the warm lead ----------------------------
    print("\n[5] ComposeOutreach — the warm lead only, and NOTHING is sent");
    warm: list = [founder ->:HasWarmLead:->];
    composed: dict = {};
    if warm {
        p = warm[0];
        print(f"    target {p.name!r} preferred={p.preferred_name!r} email={p.email or '(none)'}");
        evk: list = [];
        for ev in [p ->:HasEvidence:->] {
            evk.append(str(ev.kind));
        }
        print(f"    evidence {evk}");
        try {
            composed = first((await (root spawn ComposeOutreach(prospect_id=jid(p)))).reports);
        } except Exception as e {
            print(f"    FAILED: {e}");
        }
        if composed.get("refused") {
            print(f"    REFUSED: {str(composed.get('reason'))[:220]}");
        } else {
            print(f"    subject: {composed.get('subject')}");
        }
        body = str(composed.get("body", ""));
        if body {
            print("    ---- body ----");
            for ln in body.splitlines() {
                print(f"    {ln}");
            }
            print("    --------------");
        }
    } else {
        print("    no warm lead on the graph");
    }
    stage("compose");

    print("\n[--] STOPPING BEFORE SendOutreach. No email sent, no call placed.");
    final = census();
    print("\n" + "=" * 76);
    print(f"  wall clock            {round(time.monotonic() - t_start, 1)}s");
    for k in ["founders", "runs", "lanes", "prospects", "evidence", "reasoning",
              "identities", "with_email", "threads"] {
        print(f"  {k:<22} {final.get(k)}");
    }
    chain_ok = (
        final.get("prospects", 0) > 0 and final.get("evidence", 0) > 0
        and final.get("reasoning", 0) > 0 and final.get("with_email", 0) > 0
    );
    email_ok = bool(composed) and (not composed.get("refused", True));
    print(f"\nCHAIN_OK={chain_ok}");
    print(f"EMAIL_COMPOSED_OK={email_ok}");
    print("=" * 76);
}

with entry:__main__ {
    asyncio.run(main());
}
