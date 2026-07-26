"""Live end-to-end proof for Lane D + the email gate + ranking.

Runs the real chain against the real GitHub API - no mocks, no fixtures:

    GithubLane  -> surfaces real people from real repositories and issues
    ResolveEmail-> runs the six-step waterfall and the two-part gate
    RankAndSelect -> tiers, scores, applies convergence, and prints the ledger

    export GITHUB_TOKEN=$(gh auth token)
    jac run proof_laned.jac

Every address printed below was resolved from live data at runtime. Every drop
printed below carries the reason it was dropped. Nothing here is fabricated.
"""

import os;
import from time { time }

import from contracts { LaneId, LaneState, CompletenessTier }
import from schema { Founder, ICP, ResearchRun, Lane, Prospect, Runs, HasLane, Targets }
import from githublane { GithubLane }
import from identity { ResolveEmail, RankAndSelect, CrossLinkToGithub, CrossLinkToLinkedIn }
import from gh { gh }


with entry:__main__ {
    print("=" * 78);
    print("TRACTION - LANE D LIVE PROOF");
    print("=" * 78);
    if not gh.has_token() {
        print("FATAL: no GITHUB_TOKEN / GH_TOKEN in the environment.");
        print("  export GITHUB_TOKEN=$(gh auth token)");
    } else {
        founders: list[Founder] = [root --> [?:Founder]];
        f: Founder = founders[0] if founders else (root ++> Founder(
            name="Demo Founder",
            email="founder@example.com",
            product_summary="A tool that finds your first beta testers.",
            one_liner="We find the ten people who already have the problem."
        )) as Founder;

        run: ResearchRun = (f +>:Runs(created_at=time()):+> ResearchRun(started_at=time())) as ResearchRun;
        lane: Lane = (run +>:HasLane(launched_at=time()):+> Lane(
            lane_id=LaneId.D,
            doctrine="GitHub-first, programmatic. Find people shipping code against "
                     + "the problem, not people talking about it."
        )) as Lane;

        print("\n--- LANE D: candidate generation ------------------------------------");
        lane_res = lane spawn GithubLane(
            keywords=["ai", "agent", "framework"],
            pain_phrases=["hard to evaluate agents", "no way to test my agent"],
            negative_keywords=["awesome-list", "tutorial", "course", "roadmap"],
            max_candidates=14,
            star_ceiling=400
        );
        lr = lane_res.reports[0] if lane_res.reports else {};
        print(f"  surfaced      : {lr.get('surfaced')}");
        print(f"  api calls     : {lr.get('api')}");
        print("\n  sidebar narration (analyst voice):");
        for n in (lr.get("narration", []) as list[dict[str, any]]) {
            print(f"    [{n.get('kind')}] {n.get('sentence')}");
        }

        print("\n--- THE HARD GATE: six-step waterfall -------------------------------");
        gate_res = root spawn ResolveEmail();
        gr = gate_res.reports[0] if gate_res.reports else {};
        print(f"  resolved: {gr.get('resolved')}   dropped: {gr.get('dropped')}");
        print(f"  api     : {gr.get('api')}");
        print("");
        for row in (gr.get("ledger", []) as list[dict[str, any]]) {
            mark: str = "KEEP" if (row.get("kept", False) as bool) else "DROP";
            handle: str = row.get("handle", "") as str;
            print(f"  [{mark}] {handle:<22} {(row.get('email','') as str):<34} {row.get('why','')}");
        }

        print("\n--- CROSS-LINK: LinkedIn -> GitHub (the HEAVY direction) ------------");
        # Simulates what Lanes A/B/C hand over: raw text already scraped from a
        # LinkedIn profile. No browser is driven here on purpose - the lanes own
        # the Browserbase session, so this walker takes text and stays testable.
        xl_target: Prospect = (root ++> Prospect(
            name="Simon Willison", handle="simonw-linkedin",
            linkedin_url="https://linkedin.com/in/simonw"
        )) as Prospect;
        xl = xl_target spawn CrossLinkToGithub(
            contact_info_text="Websites: simonwillison.net · GitHub: https://github.com/simonw",
            about_text="I build open source tools for data journalism.",
            posts_text="",
            linkedin_company="Datasette"
        );
        for v in xl.reports {
            print(f"  matched={v.get('matched')}  login={v.get('login')}  tier={v.get('tier')}");
            print(f"  basis : {v.get('basis')}");
        }

        print("\n  negative control - a github link that is NOT this person:");
        xl_bad: Prospect = (root ++> Prospect(
            name="Jane Unrelated", handle="jane-unrelated"
        )) as Prospect;
        xl2 = xl_bad spawn CrossLinkToGithub(
            posts_text="Great work by github.com/torvalds on this release!",
            linkedin_company=""
        );
        for v in xl2.reports {
            print(f"  matched={v.get('matched')}  basis: {v.get('basis')}");
        }

        print("\n--- RANK AND SELECT -------------------------------------------------");
        rank_res = root spawn RankAndSelect(top_n=3);
        rr = rank_res.reports[0] if rank_res.reports else {};
        print(f"  selected {rr.get('n_selected')}  /  dropped {rr.get('n_dropped')}\n");
        for s in (rr.get("selected", []) as list[dict[str, any]]) {
            print(f"  {s.get('tier')}-tier  {(s.get('name','') as str):<26} {s.get('email')}");
            print(f"      score {s.get('score_pre_crosslink')} pre-crosslink -> {s.get('score')} "
                  + f"(lanes: {s.get('convergence_lanes')}, x{s.get('multiplier')})");
            print(f"      email confidence {s.get('email_confidence')}");
        }
        print("\n  DROP LEDGER (shown on stage - visible elimination is the point):");
        for d in (rr.get("dropped", []) as list[dict[str, any]]) {
            print(f"    {(d.get('handle','') as str):<22} {d.get('reason')}");
        }

        if gh.errors {
            print("\n--- API ERRORS (surfaced, never swallowed) --------------------------");
            for e in gh.errors {
                print(f"    {e}");
            }
        }
        print("\n" + "=" * 78);
    }
}
