"""LIVE PROOF — Lane W deep-reads a real LinkedIn profile and writes a dossier.

Discovers a reachable profile from the authenticated session itself, then runs
the real LaneW walker against it and reads back what landed in the graph.

    jac run lane_w_proof.jac
"""

import time;
import from contracts { LaneId, LaneState, RunStatus }
import from schema {
    Founder, ResearchRun, Lane, Prospect, Reasoning,
    Runs, HasLane, Emitted, Surfaced, HasEvidence, HasWarmLead
}
import from lane_w { LaneW }
import from browser.session { new_session }
import from browser.env { env }

with entry {
    context_id = env("BROWSERBASE_LINKEDIN_CONTEXT_ID", required=True);
    print("=" * 70);
    print("Lane W — deep research on one warm lead");
    print("=" * 70);

    warm_url = env("TEAMMATE_LINKEDIN_URL", required=True);
    warm_name = env("TEAMMATE_NAME", required=True);
    preferred = env("TEAMMATE_PREFERRED_NAME", fallback="");
    warm_email = env("TEAMMATE_EMAIL", fallback="");
    print(f"\n[0] warm lead: {warm_name} ({preferred or 'no preferred name'})");
    print(f"[0] profile:   {warm_url}");

    # --- build the minimal graph Lane W expects ----------------------------
    founder = root ++> Founder(
        name="Elijah Umana",
        email=env("FOUNDER_EMAIL", fallback="founder@example.com"),
        one_liner="Pure-Jac browser automation for founder-led sales research."
    );
    run = founder +>:Runs(created_at=time.time()):+> ResearchRun(
        started_at=time.time(), status=RunStatus.RUNNING
    );
    lane = run +>:HasLane(launched_at=time.time()):+> Lane(lane_id=LaneId.W);

    # Intake attaches her BEFORE any lane runs. Lane W must find and reuse this
    # node, not build a second one for the same human.
    intake = founder +>:HasWarmLead(note="named at intake"):+> Prospect(
        name=warm_name, handle="", preferred_name=preferred
    );
    before = len([founder ->:HasWarmLead:->]);
    print(f"[0] prospects attached at intake: {before}");

    # --- run the real walker ------------------------------------------------
    print("\n[1] spawning LaneW on the Lane node...");
    t0 = time.monotonic();
    w = LaneW(
        context_id=context_id,
        warm_url=warm_url,
        warm_name=warm_name,
        preferred_name=preferred,
        warm_email=warm_email,
        hypothesis="founders doing manual sales research"
    ) spawn lane;
    elapsed = round(time.monotonic() - t0, 1);

    # --- read back what actually landed in the graph -----------------------
    print(f"\n[2] lane state       {lane.state}   ({elapsed}s)");
    print(f"[2] bb_session_id    {lane.bb_session_id or 'MISSING'}");
    print(f"[2] live_url         {'CAPTURED' if lane.live_url else 'MISSING'}");

    reasonings: list = [lane ->:Emitted:->];
    print(f"\n[3] analyst narration — {len(reasonings)} emissions");
    for r in reasonings {
        if isinstance(r, Reasoning) {
            print(f"    [{r.kind}] {r.sentence[:92]}");
        }
    }

    prospects = [lane ->:Surfaced:->];
    print(f"\n[4] prospects written  {len(prospects)}");
    ok = False;
    for p in prospects {
        print(f"    name        {p.name}   preferred={p.preferred_name!r}");
        print(f"    headline    {p.headline[:70]}");
        print(f"    company     {p.company or '(none read)'}");
        print(f"    linkedin    {p.linkedin_url}");
        print(f"    email       {p.email or '(none supplied)'} [{p.email_source}]");
        print(f"    tier        {p.tier}");
        print(f"    warm lead   {p.is_warm_lead()}");
        evidence = [p ->:HasEvidence:->];
        print(f"    evidence    {len(evidence)} pieces");
        for e in evidence {
            age = f"{e.recency_days}d" if e.recency_days >= 0 else "undated";
            print(f"      - [{e.kind}, {age}] {e.quote[:64].replace(chr(10), ' ')}");
        }
        ok = bool(p.name) and len(evidence) > 0 and bool(p.is_warm_lead());
    }

    after = len([founder ->:HasWarmLead:->]);
    one_node = (after == before) and len(prospects) == 1;
    print(f"\n[5] warm-lead prospects before={before} after={after}  "
          + f"(no duplicate created: {after == before})");
    print(f"[5] harvested for cross-link:");
    print(f"      about_text        {len(w.about_text)} chars");
    print(f"      posts_text        {len(w.posts_text)} chars");
    print(f"      contact_info_text {len(w.contact_info_text)} chars");
    print(f"      linkedin_company  {w.linkedin_company!r}");

    print("\n" + "=" * 70);
    print(f"LANE_W_OK={ok and lane.state == LaneState.DONE and one_node}");
    print("=" * 70);
}
