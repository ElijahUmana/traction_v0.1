"""BrowserSession — the surface the research lanes actually code against.

Composes Browserbase + CDP + Page into one object per lane. Everything that
could be shared between lanes is deliberately per-instance: each session owns
its own JacWS, its own CDP message-id counter and its own pending-reply map.
Three lanes running in `flow` threads therefore cannot see, block on, or steal
each other's responses. There is no module-level socket and no global counter
anywhere in this package — that is a hard invariant, not an accident.

`live_url` is captured the moment the session opens, not at the end of the run,
because the dashboard iframes need it while the lane is still working.
"""

import json;
import time;
import from browser.browserbase { Browserbase }
import from browser.cdp { CDP }
import from browser.page { Page, ACTIONABILITY_JS }


obj BrowserSession {
    """One isolated remote browser: REST handle, socket, protocol and actions."""

    has session_id: str = "",
        live_url: str = "",
        connect_url: str = "",
        context_id: str = "",
        persist: bool = False,
        proxies: bool = True,
        bb: Browserbase postinit,
        cdp: CDP postinit,
        page: Page postinit,
        closed: bool = False;

    def postinit;

    # ---- navigation -------------------------------------------------------

    """Navigate. Returns False instead of raising, so a dead page cannot kill a lane.

    The failure is still printed in full — this is an explicit error-returning
    variant, not a swallowed exception. Use `page.navigate` when you want the raise.
    """
    def goto(url: str, settle: float = 0.0) -> bool;

    """Current {url, title} after redirects."""
    def where -> dict;

    # ---- extraction (the hot path) ----------------------------------------

    """Evaluate an expression in the page and return the result as a JSON string.

    ONE round trip. This is the primitive LinkedIn extraction is built on: run a
    querySelectorAll loop in-page and return a structured array, rather than
    paying a CDP round trip per element and re-breaking every time a class name
    changes.
    """
    def eval_js(expr: str) -> str;

    """Same single round trip, but hands back the parsed value."""
    def eval_json(expr: str) -> any;

    """Visible text of the document — the cheap dry-run check."""
    def text -> str;

    # ---- interaction ------------------------------------------------------

    """Click the first element matching a CSS selector, with a real actionability
    check and real mouse events. False if it is missing or unclickable."""
    def click(selector: str) -> bool;

    """Focus a selector and type into it. `human` types at ~40ms with jitter."""
    def type_text(selector: str, text: str, human: bool = True) -> bool;

    def press(key: str);
    def scroll(px: int);
    def wait_ms(ms: int);

    """Wait for a CSS selector to appear."""
    def wait_for_selector(selector: str, timeout: float = 15.0) -> bool;

    """Wait for a JavaScript expression to become truthy."""
    def wait_for_js(expr: str, timeout: float = 15.0) -> bool;

    """Wait for a selector or a JS predicate — detected by shape. Returns False on timeout.

    Anything containing JS syntax (parentheses, `=>`, comparisons, `document.`,
    `window.`) is treated as an expression; everything else as a CSS selector.
    Call wait_for_selector / wait_for_js directly when you want no guessing.
    """
    def wait_for(what: str, timeout: float = 15.0) -> bool;

    # ---- agent-legible page state -----------------------------------------

    def snapshot_ax(max_lines: int = 0) -> str;
    def click_ref(ref: str) -> str;
    def screenshot(path: str, full_page: bool = False) -> str;

    """Close the socket and release the Browserbase session. Idempotent."""
    def close;
}


"""Open an isolated browser session, already attached to its default page target.

`persist` must stay False for research lanes: they read the shared auth context
but can never write to it. Only the one login session persists.
"""
def new_session(
    context_id: str = "", persist: bool = False, proxies: bool = True
) -> BrowserSession;
