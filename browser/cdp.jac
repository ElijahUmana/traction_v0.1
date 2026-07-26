"""Chrome DevTools Protocol client, spoken directly over the Jac WebSocket.

No CDP library sits under this. `call()` writes a JSON envelope into a masked
WebSocket frame built by ws.impl.jac and correlates the reply by integer id.

Two behaviours here are deliberate upgrades over the naive reference client:

1. Unmatched replies are BUFFERED, not dropped. A read loop that skips any
   message whose id it does not recognise will happily discard the answer to
   another in-flight call, then block forever waiting for it. `_pending` keeps
   those answers; `events` keeps the unsolicited ones.
2. `attach_page()` attaches the DEFAULT tab and never creates one. Creating a
   second target is what silently produced a zero-cookie context during auth
   bring-up — the browser profile syncs the original tab, not the new one.
"""

import json;
import time;
import from browser.ws { JacWS }


obj CDP {
    """A DevTools Protocol session multiplexed over one WebSocket."""

    has ws_url: str,
        timeout: float = 40.0,
        ws: JacWS postinit,
        _id: int = 0,
        _pending: dict[int, dict] postinit,
        events: list[dict] postinit,
        max_events: int = 2000,
        events_dropped: int = 0;

    def postinit;

    """Issue one CDP command and block for its reply.

    `session_id` routes the command to a flattened target session; omit it to
    address the browser itself.
    """
    def call(
        method: str,
        params: (dict | None) = None,
        session_id: (str | None) = None,
        timeout: (float | None) = None
    ) -> dict;

    def _await_reply(mid: int, method: str, timeout: float) -> dict;
    def _unwrap(msg: dict, method: str) -> dict;
    def _absorb(msg: dict);

    """Write a command WITHOUT blocking for its reply; returns the message id.

    CDP processes commands in order per session, so a burst can be pipelined
    into consecutive WebSocket frames instead of paying a round-trip each. That
    is only possible because this stack owns its own transport — the point of
    writing the frame layer in Jac rather than importing one.

    Every id handed out here MUST later be passed to `await_ids`, or a protocol
    error on that command would go unnoticed.
    """
    def send_async(
        method: str, params: (dict | None) = None, session_id: (str | None) = None
    ) -> int;

    """Reconcile pipelined commands. Raises on the first CDP error found."""
    def await_ids(ids: list[int], label: str, timeout: float = 30.0) -> int;

    """Pull the next matching CDP event, checking already-buffered ones first."""
    def wait_for_event(method: str, timeout: float = 30.0) -> dict;

    """Drain whatever events have already arrived without blocking on new ones."""
    def take_events(method: (str | None) = None) -> list;

    """Attach to the browser's existing default page target, flattened.

    Returns the sessionId every page-scoped command must carry.
    """
    def attach_page -> str;

    def close;
}
