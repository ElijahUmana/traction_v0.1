"""Browserbase control plane — the REST half of driving a remote stealth Chrome.

Sessions and contexts are ordinary JSON over HTTPS; the interesting part is
what comes back. `create_session()` returns a `connectUrl` whose query string
carries the credentials, which is precisely the URL shape that breaks a naive
websocket parser — see parse_ws_url in ws.impl.jac.

Contexts are how authentication survives between runs: log in once with
persist=true, then every later research session mounts the same profile with
persist=false so a lane can read the auth but never clobber it.
"""

import json;
import urllib.request;
import urllib.error;
import from env { env }

glob BB_API: str = "https://api.browserbase.com/v1";


obj Browserbase {
    """Typed client for the Browserbase v1 REST API."""

    has api_key: str = "",
        project_id: str = "",
        timeout: float = 30.0;

    def postinit;

    def _request(path: str, data: (dict | None) = None, method: (str | None) = None) -> any;

    """Create a fresh browser profile container and return its id."""
    def create_context -> str;

    """Start a browser session.

    `context_id` mounts an existing profile. `persist` must be True only for
    the one login session that is meant to write cookies back — research lanes
    pass False so they can read the auth without being able to damage it.
    """
    def create_session(
        proxies: bool = False,
        context_id: (str | None) = None,
        persist: bool = False,
        session_timeout: int = 1800,
        width: int = 1440,
        height: int = 900
    ) -> dict;

    """Live debug endpoints: debuggerFullscreenUrl (the embeddable view) and pages[]."""
    def session_debug(session_id: str) -> dict;

    """Ask Browserbase to end a keepAlive session and flush its context."""
    def release(session_id: str) -> dict;
}
