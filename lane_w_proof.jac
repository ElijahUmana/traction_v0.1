"""LIVE PROOF — Lane W deep-reads a real LinkedIn profile and writes a dossier.

Discovers a reachable profile from the authenticated session itself, then runs
the real LaneW walker against it and reads back what landed in the graph.

    jac run lane_w_proof.jac
"""

import time;
import from contracts { LaneId, LaneState, RunStatus }
import from schema {
    Founder, ResearchRun, Lane, Prospect, Reasoning,
    Runs, HasLane, Emitted, Surfaced, HasEvidence
}
import from lane_w { LaneW }
import from browser.session { new_session }
import from browser.env { env }

with entry {
    context_id = env("BROWSERBASE_LINKEDIN_CONTEXT_ID", required=True);
    print("=" * 70);
    print("Lane W — deep research on one warm lead");
    print("=" * 70);

    # --- find a real profile the authenticated session can actually reach ---
    print("\n[0] discovering a reachable profile from the live session...");
    scout = new_session(context_id=context_id, persist=False, proxies=True);
    warm_url = "";
    try {
        if scout.goto("https://www.linkedin.com/feed/", settle=2.5) {
            found: dict = scout.eval_json("""
                (function(){
                  const me = document.querySelector('a[href*="/in/"][data-control-name], a.profile-card-profile-picture-container, nav a[href*="/in/"]');
                  if (me) return {url: me.href.split('?')[0]};
                  const any = document.querySelector('a[href*="/in/"]');
                  return any ? {url: any.href.split('?')[0]} : {};
                })()
            """) or {};
            warm_url = str(found.get("url") or "");
        }
    } finally {
        scout.close();
    }
    if not warm_url {
        raise RuntimeError("could not discover any profile URL from the live feed");
    }
    print(f"[0] target: {warm_url}");

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

    # --- run the real walker ------------------------------------------------
    print("\n[1] spawning LaneW on the Lane node...");
    t0 = time.monotonic();
    w = LaneW(
        context_id=context_id,
        warm_url=warm_url,
        warm_name=env("TEAMMATE_NAME", fallback=""),
        warm_email=env("TEAMMATE_EMAIL", fallback=""),
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
        print(f"    name        {p.name}");
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

    print("\n" + "=" * 70);
    print(f"LANE_W_OK={ok and lane.state == LaneState.DONE}");
    print("=" * 70);
}
