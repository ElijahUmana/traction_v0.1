"""LIVE PROOF, PART B — the real product path: authenticated LinkedIn in pure Jac.

Mounts the canonical Browserbase context read-only (persist=false, so a lane
can use the auth but never damage it), attaches to the DEFAULT tab, and proves
the session is genuinely logged in rather than looking at a signup wall.

    jac run traction/browser/linkedin_proof.jac
"""

import os;
import from browser.browserbase { Browserbase }
import from browser.cdp { CDP }
import from browser.page { Page }
import from browser.env { env }

with entry {
    evidence = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "evidence");
    os.makedirs(evidence, exist_ok=True);

    context_id = env("BROWSERBASE_LINKEDIN_CONTEXT_ID", required=True);
    bb = Browserbase();
    print("=" * 68);
    print("TRACTION — authenticated LinkedIn over pure-Jac CDP");
    print("=" * 68);

    # persist=false: read the auth, never write it back. Only the one login
    # session is ever allowed to persist.
    sess = bb.create_session(proxies=True, context_id=context_id, persist=False);
    sid = sess["id"];
    print(f"\n[1] session {sid} on context {context_id[:8]}… (persist=false, proxied)");

    authenticated = False;
    try {
        cdp = CDP(ws_url=sess["connectUrl"]);
        # The default tab, never a new one — a second target is what silently
        # produced a zero-cookie context during auth bring-up.
        page_session = cdp.attach_page();
        page = Page(cdp=cdp, session_id=page_session);
        print(f"[2] attached to the DEFAULT page target (no Target.createTarget)");

        loc = page.navigate("https://www.linkedin.com/feed/", settle=3.0);
        print(f"\n[3] url   {loc['url'][:60]}");
        print(f"[3] title {loc['title']!r}");

        # The honest test: an unauthenticated session lands on a login or
        # signup wall, and /feed/ redirects away.
        signed_in = page.extract(
            "!!document.querySelector('img.global-nav__me-photo, .global-nav__me, "
            "[data-control-name=\"identity_welcome_message\"]') "
            "|| /feed/.test(location.pathname)"
        );
        on_wall = ("authwall" in loc["url"]) or ("login" in loc["url"]) or ("signup" in loc["url"]);
        authenticated = bool(signed_in) and not on_wall;
        print(f"[3] AUTHENTICATED={authenticated}  (nav-avatar/feed={signed_in}, wall={on_wall})");

        snap = page.snapshot_ax(max_lines=25);
        print(f"\n[4] accessibility tree — {len(page._refs)} clickable refs");
        for line in snap.splitlines()[:12] {
            print(f"    | {line[:72]}");
        }

        shot = page.screenshot(os.path.join(evidence, "linkedin_proof.png"));
        print(f"\n[5] screenshot {os.path.getsize(shot)} bytes -> {os.path.basename(shot)}");

        cdp.close();
    } finally {
        bb.release(sid);
        print("[--] session released");
    }

    print("\n" + "=" * 68);
    print(f"LINKEDIN_AUTH_OK={authenticated}");
    print("=" * 68);
}
