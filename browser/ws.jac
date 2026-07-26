"""Pure-Jac RFC 6455 WebSocket client — speaks ws:// AND wss://.

This is the transport floor of TRACTION. Every byte that reaches a remote
Chrome is framed, masked and unmasked by Jac code in this file. There is no
websocket library underneath it; `socket` and `ssl` are the only primitives.

Relationship to jaclang's own `jaclang/cli/browser_engine.jac`: that engine is
ws:// only, so it can only ever drive a Chrome on localhost. Adding TLS
(`ssl.create_default_context().wrap_socket(...)`) is what lets Jac drive a
*remote* stealth browser over the public internet.
"""

import socket;
import ssl;
import base64;
import hashlib;
import os;
import struct;

# RFC 6455 §5.2 opcodes.
glob OP_CONT: int = 0x0;
glob OP_TEXT: int = 0x1;
glob OP_BINARY: int = 0x2;
glob OP_CLOSE: int = 0x8;
glob OP_PING: int = 0x9;
glob OP_PONG: int = 0xA;

# RFC 6455 §1.3 — the magic GUID the server concatenates with our nonce.
glob WS_GUID: str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";


"""Split a ws:// or wss:// URL into (secure, host, port, path).

THE BUG THIS FUNCTION EXISTS TO KILL: a Browserbase connectUrl looks like
    wss://connect.browserbase.com?apiKey=<key>&sessionId=<id>
— a query string and NO path. The obvious parse, `rest.partition("/")`, splits
on the slash first, so the entire query string ends up inside the hostname and
DNS resolution fails on a name that is not a name. The query must be stripped
from the host BEFORE the path is taken, and the path must then be recovered
from the remainder so the apiKey survives into the HTTP request line.
"""
def parse_ws_url(url: str) -> tuple[bool, str, int, str];


"""XOR a payload against a 4-byte masking key (RFC 6455 §5.3).

Involutive: masking twice with the same key returns the original bytes, which
is why the same routine serves both directions.
"""
def mask_payload(payload: bytes, mask: bytes) -> bytes;


"""Encode one complete client->server frame: header, length ladder, mask, body.

Split out from `send` so the wire format can be checked against the RFC's own
test vectors without opening a socket.
"""
def build_frame(payload: bytes, opcode: int, mask: bytes) -> bytes;


obj JacWS {
    """A blocking WebSocket client connection."""

    has url: str,
        timeout: float = 40.0,
        sock: socket.socket postinit,
        _buf: bytearray postinit,
        host: str postinit,
        port: int postinit,
        path: str postinit,
        secure: bool postinit,
        closed: bool = False;

    def postinit;

    def _handshake;
    def _read_until(delim: bytes) -> bytes;
    def _recv_exact(n: int) -> bytes;
    def _read_frame -> tuple[bool, int, bytes];

    def send(data: (str | bytes), opcode: int = OP_TEXT);
    def recv -> (str | bytes);
    def close;
}
