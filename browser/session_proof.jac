"""LIVE PROOF — the BrowserSession facade, including 3 CONCURRENT lanes.

Part A: one session against authenticated LinkedIn, extracting via eval_json.
Part B: three sessions in `flow` threads at once. This is the failure mode that
        only appears under concurrency: if any socket, message-id counter or
        pending-reply map were module-global, the lanes would steal each
        other's CDP responses and deadlock. Nothing shared => all three pass.

    jac run browser/session_proof.jac
"""

import os;
import time;
import from browser.session { new_session }
import from browser.env { env }

"""Open a lane, land on a LinkedIn surface, extract, and report what happened."""
def lane_probe(name: str, url: str, context_id: str) -> dict {
    started = time.monotonic();
    sess = new_session(context_id=context_id, persist=False, proxies=True);
    try {
        ok = sess.goto(url, settle=2.5);
        where = sess.where();
        # ONE round trip: an in-page loop returning a structured array, rather
        # than a CDP round trip per element.
        harvest = sess.eval_json("""
            (function(){
              const out = [];
              document.querySelectorAll('a[href*="/in/"]').forEach(a => {
                const t = (a.innerText || '').trim();
                if (t) out.push({name: t.split('\\n')[0], href: a.href.split('?')[0]});
              });
              return {profiles: out.slice(0, 8), total: out.length,
                      title: document.title, path: location.pathname};
            })()
        """) or {};
        return {
            "lane": name,
            "ok": ok,
            "session_id": sess.session_id,
            "live_url": bool(sess.live_url),
            "cdp_ids": sess.cdp._id,
            "title": where.get("title", ""),
            "path": harvest.get("path", ""),
            "profiles": harvest.get("total", 0),
            "sample": [p["name"] for p in harvest.get("profiles", [])[:3]],
            "secs": round(time.monotonic() - started, 1)
        };
    } finally {
        sess.close();
    }
}

with entry {
    context_id = env("BROWSERBASE_LINKEDIN_CONTEXT_ID", required=True);
    print("=" * 72);
    print("BrowserSession — live, authenticated, and concurrent");
    print("=" * 72);

    # ---- Part A: one lane, the full facade ------------------------------
    print("\n--- A. single session, full surface ---");
    sess = new_session(context_id=context_id, persist=False, proxies=True);
    a_ok = False;
    try {
        print(f"  session_id  {sess.session_id}");
        print(f"  live_url    {'CAPTURED at open' if sess.live_url else 'MISSING'}");
        moved = sess.goto("https://www.linkedin.com/feed/", settle=2.5);
        title_now = sess.where().get("title", "");
        print(f"  goto        -> {moved}   title={title_now!r}");


        found = sess.wait_for("a[href*='/in/']", timeout=10.0);
        print(f"  wait_for    -> {found}");

        n = sess.eval_json("document.querySelectorAll('a[href*=\"/in/\"]').length");
        raw = sess.eval_js("({ok: true, n: document.title.length})");
        print(f"  eval_json   -> {n} profile links");
        print(f"  eval_js     -> {raw}  ({type(raw).__name__})");
        print(f"  text        -> {len(sess.text())} chars of visible text");

        # LAST, deliberately: a failed navigation leaves the tab sitting on an
        # error page, so anything asserted after it would be measuring that
        # error page rather than the feed.
        bad = sess.goto("https://this-host-does-not-exist-jaccdp.invalid/");
        print(f"  goto(bad)   -> {bad}  (returned False, did not raise)");
        a_ok = moved and (not bad) and (n is not None) and found;
    } finally {
        sess.close();
        print("  close       -> socket closed + session released");
    }

    # ---- Part B: three lanes at once -------------------------------------
    print("\n--- B. THREE concurrent lanes (flow) ---");
    targets = [
        ("A", "https://www.linkedin.com/search/results/people/?keywords=founder"),
        ("B", "https://www.linkedin.com/feed/"),
        ("C", "https://www.linkedin.com/mynetwork/")
    ];
    t0 = time.monotonic();
    jobs = [flow lane_probe(n, u, context_id) for (n, u) in targets];
    results = [wait j for j in jobs];
    wall = round(time.monotonic() - t0, 1);

    ids = [];
    for r in results {
        print(f"  lane {r['lane']}  {r['secs']:>5}s  auth={'Y' if 'LinkedIn' in r['title'] else 'N'}  "
              f"path={r['path'][:22]:<22} links={r['profiles']:>3}  cdp_msgs={r['cdp_ids']}");
        sample_txt = str(r["sample"]);
        if r["sample"] {
            print(f"           sample: {sample_txt[:66]}");
        }
        ids.append(r["session_id"]);
    }

    distinct = len(set(ids)) == len(ids);
    all_auth = all(["LinkedIn" in r["title"] for r in results]);
    all_live = all([r["live_url"] for r in results]);
    no_wall = all(["login" not in r["path"] and "authwall" not in r["path"] for r in results]);

    print(f"\n  wall clock for 3 lanes      {wall}s");
    print(f"  distinct sessions           {distinct}");
    print(f"  all authenticated           {all_auth}");
    print(f"  all captured live_url       {all_live}");
    print(f"  none bounced to a wall      {no_wall}");

    print("\n" + "=" * 72);
    print(f"SESSION_FACADE_OK={a_ok}");
    print(f"CONCURRENT_LANES_OK={distinct and all_auth and all_live and no_wall}");
    print("=" * 72);
}
