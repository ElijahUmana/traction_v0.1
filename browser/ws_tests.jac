"""Standalone tests for the pure-Jac WebSocket layer.

Pure functions only — no sockets, no network, no graph. Runs anywhere,
including with no API keys set.

    jac test browser/ws.jac
"""

import struct;
# Explicit imports because this is a STANDALONE test module, not a `.test.jac`
# annex. As an annex, its 12 tests were attributed to EVERY module that
# transitively imports ws - page, session, session_proof, live_proof, cdp - and
# pytest-xdist workers disagreed about which, which aborted collection for the
# entire repo ("no tests ran", exit 3).
import from browser.ws {
    parse_ws_url, mask_payload, build_frame, JacWS,
    OP_CONT, OP_TEXT, OP_BINARY, OP_CLOSE, OP_PING, OP_PONG, WS_GUID
}

test "connectUrl with a query string and no path keeps the query out of the host" {
    # THE regression. A Browserbase connectUrl is 'wss://host?apiKey=...' with
    # no path at all. Splitting on '/' before '?' puts the whole query inside
    # the hostname and DNS fails on a name that is not a name.
    (secure, host, port, path) = parse_ws_url(
        "wss://connect.browserbase.com?apiKey=bb_test_key&sessionId=1f2e"
    );
    assert secure == True;
    assert host == "connect.browserbase.com";
    assert port == 443;
    assert path == "/?apiKey=bb_test_key&sessionId=1f2e";
}

test "the live connectUrl shape Browserbase actually returns" {
    # Observed live: a trailing slash AND a query.
    (secure, host, port, path) = parse_ws_url(
        "wss://connect.usw2.browserbase.com/?apiKey=bb_test_key"
    );
    assert host == "connect.usw2.browserbase.com";
    assert path == "/?apiKey=bb_test_key";
}

test "path and query together survive intact" {
    (secure, host, port, path) = parse_ws_url(
        "wss://connect.browserbase.com/devtools/page/AB12?apiKey=k"
    );
    assert host == "connect.browserbase.com";
    assert path == "/devtools/page/AB12?apiKey=k";
}

test "a slash inside the query is not mistaken for the start of a path" {
    (secure, host, port, path) = parse_ws_url("wss://h.example?redirect=/a/b");
    assert host == "h.example";
    assert path == "/?redirect=/a/b";
}

test "bare host and trailing-slash host both normalise to /" {
    (s1, h1, p1, path1) = parse_ws_url("wss://echo.websocket.org");
    (s2, h2, p2, path2) = parse_ws_url("wss://echo.websocket.org/");
    assert path1 == "/";
    assert path2 == "/";
    assert h1 == h2;
}

test "ws:// defaults to port 80 and honours an explicit port" {
    (secure, host, port, path) = parse_ws_url("ws://127.0.0.1:9222/devtools/browser/xyz");
    assert secure == False;
    assert host == "127.0.0.1";
    assert port == 9222;
    (s2, h2, p2, path2) = parse_ws_url("ws://localhost/socket");
    assert p2 == 80;
}

test "IPv6 literals keep their brackets out of the hostname" {
    (secure, host, port, path) = parse_ws_url("ws://[::1]:9222/devtools/browser/xyz");
    assert host == "::1";
    assert port == 9222;
}

test "malformed urls raise instead of limping along with a bogus host" {
    for bad in ["http://example.com", "connect.browserbase.com", "wss://", "wss://?a=1"] {
        raised = False;
        try {
            parse_ws_url(bad);
        } except ValueError {
            raised = True;
        }
        assert raised == True;
    }
}

test "RFC 6455 5.7 masked Hello vector matches byte for byte" {
    # The specification gives this frame explicitly:
    #   0x81 0x85 0x37 0xfa 0x21 0x3d 0x7f 0x9f 0x4d 0x51 0x58
    expected = bytes([0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d,
                      0x7f, 0x9f, 0x4d, 0x51, 0x58]);
    assert build_frame("Hello".encode(), OP_TEXT, bytes([0x37, 0xfa, 0x21, 0x3d])) == expected;
}

test "masking is involutive and rejects a wrong-sized key" {
    key = bytes([0xDE, 0xAD, 0xBE, 0xEF]);
    body = "the quick brown fox".encode();
    assert mask_payload(mask_payload(body, key), key) == body;
    raised = False;
    try {
        mask_payload(body, bytes([1, 2, 3]));
    } except ValueError {
        raised = True;
    }
    assert raised == True;
}

test "length ladder picks 7-bit, 16-bit and 64-bit headers at the right boundaries" {
    key = bytes([1, 2, 3, 4]);
    # (payload size, expected length marker, expected total header bytes)
    for (size, marker, header) in [
        (0, 0, 6), (125, 125, 6),          # 7-bit
        (126, 126, 8), (65535, 126, 8),    # 16-bit extension
        (65536, 127, 14)                   # 64-bit extension
    ] {
        frame = build_frame(bytes(size), OP_BINARY, key);
        assert (frame[1] & 0x7F) == marker;
        assert len(frame) == header + size;
        # Every client frame must set the MASK bit or Chrome drops the socket.
        assert (frame[1] & 0x80) != 0;
        # FIN set, opcode preserved.
        assert (frame[0] & 0x80) != 0;
        assert (frame[0] & 0x0F) == OP_BINARY;
    }
}

test "frames round-trip through the masker including multibyte text" {
    key = bytes([0x5A, 0x11, 0xC3, 0x07]);
    for text in ["", "a", "Hello, World!", "héllo wörld — em dash & 你好"] {
        payload = text.encode();
        frame = build_frame(payload, OP_TEXT, key);
        # Header is 2 bytes + 4 mask bytes for these sizes.
        assert mask_payload(frame[6:], key).decode() == text;
    }
}
