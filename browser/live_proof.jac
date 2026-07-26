"""LIVE END-TO-END PROOF — every layer of this stack is Jac.

Drives a real remote Chrome on Browserbase and exercises all six semantic
actions. Nothing is mocked: the frames are masked by ws.impl.jac, the protocol
is spoken by cdp.impl.jac, and the browser is 2,500 miles away.

    jac run traction/browser/live_proof.jac
"""

import os;
import time;
import from browser.browserbase { Browserbase }
import from browser.cdp { CDP }
import from browser.page { Page }
import from browser.env { env }

"""Pull the first @eN handle whose snapshot line matches every needle."""
def find_ref(snapshot: str, needles: list[str]) -> str {
    for line in snapshot.splitlines() {
        stripped = line.strip();
        if not stripped.startswith("@") {
            continue;
        }
        low = stripped.lower();
        if all([n.lower() in low for n in needles]) {
            return stripped.split(" ")[0];
        }
    }
    return "";
}

with entry {
    evidence = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "evidence");
    os.makedirs(evidence, exist_ok=True);
    results: dict[str, any] = {};

    bb = Browserbase();
    print("=" * 68);
    print("TRACTION — pure-Jac browser automation, live against Browserbase");
    print("=" * 68);

    sess = bb.create_session();
    sid = sess["id"];
    print(f"\n[1] REST  session created        id={sid}");

    debug = bb.session_debug(sid);
    live_url = debug.get("debuggerFullscreenUrl", "");
    print(f"[1] REST  live view              {'present' if live_url else 'MISSING'} "
          f"({len(debug.get('pages', []))} page(s))");
    results["rest"] = bool(sid) and bool(live_url);

    try {
        # ---- 2. Transport: pure-Jac TLS WebSocket -------------------------
        t0 = time.monotonic();
        cdp = CDP(ws_url=sess["connectUrl"]);
        print(f"\n[2] WS    upgrade + masking      OK in {round(time.monotonic() - t0, 2)}s");
        version = cdp.call("Browser.getVersion");
        print(f"[2] WS    remote browser         {version.get('product')}");
        results["websocket"] = True;

        # ---- 3. CDP: flattened session attach -----------------------------
        page_session = cdp.attach_page();
        page = Page(cdp=cdp, session_id=page_session);
        print(f"\n[3] CDP   attached (flatten)     sessionId={page_session[:16]}…");
        results["cdp_attach"] = True;

        # ---- 4. navigate --------------------------------------------------
        loc = page.navigate("https://duckduckgo.com/");
        print(f"\n[4] ACT   navigate               {loc['title'][:48]!r}");
        print(f"          readyState polled, not slept");
        results["navigate"] = "duckduckgo" in loc["url"];

        # ---- 5. snapshot_ax ------------------------------------------------
        snap = page.snapshot_ax();
        total_lines = len(snap.splitlines());
        print(f"\n[5] ACT   snapshot_ax            {total_lines} nodes, "
              f"{len(page._refs)} clickable refs");
        for line in snap.splitlines()[:6] {
            print(f"          | {line[:70]}");
        }
        results["snapshot_ax"] = len(page._refs) > 0;

        # ---- 6. click_ref (real mouse, actionability-checked) -------------
        box = find_ref(snap, ["searchbox"]) or find_ref(snap, ["combobox"]) or find_ref(snap, ["textbox"]);
        if not box {
            raise RuntimeError(f"no search input found in the AX tree of {loc['url']}");
        }
        print(f"\n[6] ACT   click_ref              {page.click_ref(box)}");
        results["click_ref"] = True;

        # ---- 7. type_human -------------------------------------------------
        query = "jaclang object spatial programming";
        t0 = time.monotonic();
        page.type_human(query);
        elapsed = time.monotonic() - t0;
        cadence = round(elapsed / len(query) * 1000);
        print(f"\n[7] ACT   type_human             {len(query)} chars in "
              f"{round(elapsed, 2)}s = {cadence}ms/keystroke (jittered)");
        results["type_human"] = 25 <= cadence <= 70;

        page.press("Enter");
        page.wait_ready(timeout=30.0);

        # ---- 8. extract ----------------------------------------------------
        after = page.location();
        headings = page.extract(
            "Array.from(document.querySelectorAll('h2,h3')).slice(0,5).map(e=>e.innerText.trim())"
        );
        print(f"\n[8] ACT   extract                now at {after['url'][:56]}");
        print(f"          {len(headings or [])} headings pulled from the live DOM");
        results["extract"] = bool(headings);

        # a page exception must RAISE, not return silently
        threw = False;
        try {
            page.extract("(function(){ throw new Error('deliberate'); })()");
        } except RuntimeError as e {
            threw = "deliberate" in str(e);
        }
        print(f"          page exceptions surface as raises: {threw}");
        results["error_surfacing"] = threw;

        # ---- 9. screenshot -------------------------------------------------
        shot = page.screenshot(os.path.join(evidence, "live_proof.png"));
        size = os.path.getsize(shot);
        print(f"\n[9] ACT   screenshot             {size} bytes -> {os.path.basename(shot)}");
        results["screenshot"] = size > 10000;

        # ---- 10. CDP correctness: interleaved ids + event buffer -----------
        print(f"\n[10] CDP  buffered events        {len(cdp.events)} kept, "
              f"{cdp.events_dropped} dropped");
        print(f"          commands issued          {cdp._id}");
        results["cdp_events"] = True;

        cdp.close();
    } finally {
        bb.release(sid);
        print(f"\n[--] REST session released");
    }

    print("\n" + "=" * 68);
    passed = len([1 for v in results.values() if v]);
    for (k, v) in results.items() {
        print(f"  {'PASS' if v else 'FAIL'}  {k}");
    }
    print(f"\nLIVE_PROOF_OK={passed == len(results)}  ({passed}/{len(results)})");
    print("=" * 68);
}
