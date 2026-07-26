"""Unit test for the connectUrl parser — the bug that eats Browserbase sessions.

Run:  jac run traction/browser/ws_url_test.jac
"""

import from ws { parse_ws_url }

with entry {
    cases = [
        # (url, expect_secure, expect_host, expect_port, expect_path)
        # THE ONE THAT MATTERS: Browserbase — query string, no path at all.
        (
            "wss://connect.browserbase.com?apiKey=bb_live_abc&sessionId=1f2e",
            True, "connect.browserbase.com", 443, "/?apiKey=bb_live_abc&sessionId=1f2e"
        ),
        # Path AND query together.
        (
            "wss://connect.browserbase.com/devtools/page/AB12?apiKey=k",
            True, "connect.browserbase.com", 443, "/devtools/page/AB12?apiKey=k"
        ),
        # Bare host, no trailing slash.
        ("wss://echo.websocket.org", True, "echo.websocket.org", 443, "/"),
        # Trailing slash only.
        ("wss://echo.websocket.org/", True, "echo.websocket.org", 443, "/"),
        # Plaintext with explicit port — the shape jaclang's own engine uses.
        ("ws://127.0.0.1:9222/devtools/browser/xyz", False, "127.0.0.1", 9222,
         "/devtools/browser/xyz"),
        # IPv6 literal with a port.
        ("ws://[::1]:9222/devtools/browser/xyz", False, "::1", 9222,
         "/devtools/browser/xyz"),
        # A slash living inside the query must not be mistaken for a path start.
        ("wss://h.example?redirect=/a/b", True, "h.example", 443, "/?redirect=/a/b"),
    ];

    failures = 0;
    for (url, want_secure, want_host, want_port, want_path) in cases {
        (secure, host, port, path) = parse_ws_url(url);
        ok = (secure == want_secure and host == want_host
              and port == want_port and path == want_path);
        if not ok {
            failures += 1;
            print(f"  FAIL {url}");
            print(f"       want secure={want_secure} host={want_host} port={want_port} path={want_path}");
            print(f"       got  secure={secure} host={host} port={port} path={path}");
        } else {
            print(f"  ok   {url}  ->  host={host} port={port} path={path}");
        }
    }

    # Malformed input must raise, not limp along with a bogus host.
    rejected = 0;
    for bad in ["http://example.com", "connect.browserbase.com", "wss://", "wss://?a=1"] {
        try {
            parse_ws_url(bad);
            failures += 1;
            print(f"  FAIL {bad!r} should have raised");
        } except ValueError as e {
            rejected += 1;
            print(f"  ok   rejected {bad!r}: {e}");
        }
    }

    print(f"[url] {len(cases)} parses, {rejected} rejections, {failures} failures");
    print(f"[url] URL_PARSER_OK={failures == 0}");
}
