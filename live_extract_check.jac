"""Live check: does EXTRACT_JS actually work on LinkedIn's real DOM?

Everything else about the research engine is proven offline. This is the one
claim that fixtures cannot support - that the in-page extractor written against
my understanding of LinkedIn's markup survives contact with the real page.

Deliberately minimal: ONE session, ONE search, read, close. Three concurrent
authenticated sessions is the fingerprint we are avoiding, and a verification
script has no business adding load to the account we demo on.

    jac run live_extract_check.jac
"""

import time;
import json;
import from browser.session { new_session }
import from browser.env { env }
import from lanes { content_search_url }
import from research { EXTRACT_JS, AUTHOR_STATS_JS, parse_followers, parse_recency_days, parse_actor }


with entry {
    ctx = env("BROWSERBASE_LINKEDIN_CONTEXT_ID", "", True);
    print(f"context {ctx[:8]}... persist=False (read-only use of the auth)");

    s = new_session(context_id=ctx, persist=False, proxies=True);
    print(f"session {s.session_id}");
    print(f"live view: {s.live_url[:80] if s.live_url else '(none)'}");

    ok = False;
    rows = [];
    try {
        url = content_search_url("rag pipeline", "past-week");
        print(f"\nnavigating: {url}");
        ok = s.goto(url, settle=3.0);
        print(f"navigated: {ok}");

        where = s.where();
        title = where.get("title", "");
        print(f"landed on: {title}");
        if "Sign" in title or "Login" in title or "login" in where.get("url", "") {
            print("!! NOT AUTHENTICATED - the context has gone stale.");
            print("   Recovery: re-run the login recipe in plan section 14, or");
            print("   re-inject .linkedin_cookies_cloud.json.");
        }

        raw = s.eval_json(EXTRACT_JS);
        # The extractor ends in JSON.stringify, so this comes back as a string.
        rows = json.loads(raw) if isinstance(raw, str) and raw.strip() else (raw if raw else []);
        print(f"\nEXTRACT_JS returned {len(rows)} rows");

        for r in rows[:5] {
            block = str(r.get("block", ""));
            name = str(r.get("name", ""));
            print("-" * 68);
            print(f"  handle    : {r.get('handle', '')}");
            print(f"  name      : {name}");
            print(f"  followers : {parse_followers(block)}   (-1 = not shown on card)");
            print(f"  recency   : {parse_recency_days(block)} days");
            act = parse_actor(block, name);
            print(f"  clean name: {act.name}");
            print(f"  headline  : {act.headline[:70]}");
            print(f"  block[:90]: {' '.join(block.split())[:90]}");
        }
    } except Exception as e {
        print(f"FAILED: {type(e).__name__}: {e}");
    } finally {
        s.close();
        print("\nsession released.");
    }

    print("=" * 68);
    if rows {
        named = len([r for r in rows if str(r.get("name", "")).strip()]);
        withblock = len([r for r in rows if len(str(r.get("block", ""))) > 80]);
        print(f"VERDICT: extractor works. {len(rows)} people, {named} with names, "
              + f"{withblock} with a readable block.");
    } else {
        print("VERDICT: extractor returned NOTHING. Either the page did not "
              + "render, the session is unauthenticated, or LinkedIn changed "
              + "the markup. Do not claim the lanes work until this prints rows.");
    }
}
