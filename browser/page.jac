"""Semantic browser actions — the vocabulary an agent actually reasons in.

Everything here decomposes into CDP commands that travel as Jac-masked
WebSocket frames. `click_ref` in particular is not a JavaScript `.click()`:
it resolves an accessibility ref to a live DOM node, runs a real actionability
check (scrolled into view, visible, not covered, inside the viewport, with
iframe coordinates translated), then dispatches genuine mouse events at the
resulting page coordinates. That is what a bot-detection system cannot tell
apart from a hand.
"""

import json;
import time;
import base64;
import random;
import from pathlib { Path }
import from browser.cdp { CDP }

# Roles worth handing an agent a clickable ref for.
glob INTERACTIVE_ROLES: set[str] = {
        "button", "link", "textbox", "checkbox", "radio", "combobox",
        "menuitem", "tab", "switch", "searchbox", "slider", "option",
        "menuitemcheckbox", "menuitemradio", "listbox", "spinbutton"
    };

glob KEY_CODES: dict[str, int] = {
        "Enter": 13, "Tab": 9, "Escape": 27, "Backspace": 8, "Delete": 46,
        "ArrowLeft": 37, "ArrowUp": 38, "ArrowRight": 39, "ArrowDown": 40,
        "Home": 36, "End": 35, "PageUp": 33, "PageDown": 34
    };

# Runs in the page with `this` bound to the target element. Returns the point
# to click, or an explanation of why the element cannot be clicked.
glob ACTIONABILITY_JS: str = """
function() {
  const el = this;
  if (el.scrollIntoViewIfNeeded) { el.scrollIntoViewIfNeeded(true); }
  else { el.scrollIntoView({block: 'center', inline: 'center'}); }
  const r = el.getBoundingClientRect();
  const cs = getComputedStyle(el);
  if (!(r.width > 0 && r.height > 0)
      || cs.visibility === 'hidden' || cs.display === 'none') {
    return {ok: false, reason: 'element is not visible'};
  }
  let x = r.x + r.width / 2, y = r.y + r.height / 2;
  const hit = el.ownerDocument.elementFromPoint(x, y);
  const hitOk = !!hit && (hit === el || el.contains(hit) || hit.contains(el));
  const hitDesc = hit
    ? hit.tagName.toLowerCase() + (hit.id ? '#' + hit.id : '') : 'nothing';
  let win = el.ownerDocument.defaultView;
  try {
    while (win && win.frameElement) {
      const fr = win.frameElement.getBoundingClientRect();
      x += fr.x; y += fr.y;
      win = win.parent;
    }
  } catch (e) { /* cross-origin frame: keep best-effort coords */ }
  const vw = win.innerWidth, vh = win.innerHeight;
  if (x < 0 || y < 0 || x >= vw || y >= vh) {
    return {ok: false, reason: 'point (' + Math.round(x) + ',' + Math.round(y)
            + ') is outside the ' + vw + 'x' + vh + ' viewport'};
  }
  return {ok: true, x: x, y: y, hitOk: hitOk, hit: hitDesc};
}
""";


obj Page {
    """One attached page target, addressed by its flattened CDP sessionId."""

    has cdp: CDP,
        session_id: str,
        keystroke_delay: float = 0.040,
        keystroke_jitter: float = 0.022,
        _refs: dict[str, int] postinit,
        _enabled: bool = False;

    def postinit;

    """Turn on the CDP domains the rest of these actions rely on. Idempotent."""
    def enable;

    """Navigate and block until the document is actually ready."""
    def navigate(url: str, timeout: float = 45.0, settle: float = 0.0) -> dict;

    """Poll document.readyState rather than sleeping a guessed number of seconds."""
    def wait_ready(timeout: float = 30.0) -> bool;

    """Evaluate JavaScript and return the value. Page exceptions are raised, not returned."""
    def extract(expression: str, timeout: float = 30.0) -> any;

    """Where are we, really — after redirects, interstitials and logins."""
    def location -> dict;

    """Type character by character at ~40ms with jitter, so the cadence is not a metronome."""
    def type_human(text: str);

    def press(key: str, modifiers: int = 0);

    """Render the accessibility tree as an indented, agent-legible outline.

    Interactive and named nodes get an `@eN` handle that click_ref can act on.
    """
    def snapshot_ax(max_lines: int = 0) -> str;

    def _walk_ax(ax: dict, by_id: dict, depth: int, lines: list, refs: dict);

    """Click an `@eN` handle from the last snapshot, with a real actionability check."""
    def click_ref(ref: str) -> str;

    def click_point(x: float, y: float);

    """Capture a PNG. Returns the path written."""
    def screenshot(path: str, full_page: bool = False) -> str;

    """Inject cookies (the auth fallback path). Returns how many were set."""
    def set_cookies(cookies: list) -> int;
}
