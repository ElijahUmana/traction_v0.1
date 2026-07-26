"""Implementation of the pure-Jac WebSocket client."""

impl parse_ws_url(url: str) -> tuple {
    if "://" not in url {
        raise ValueError(f"not a websocket url (no scheme): {url!r}");
    }
    (scheme, _, rest) = url.partition("://");
    scheme = scheme.lower();
    if scheme != "ws" and scheme != "wss" {
        raise ValueError(f"expected ws:// or wss://, got {scheme!r}:// in {url!r}");
    }
    secure = scheme == "wss";
    if not rest {
        raise ValueError(f"websocket url has no host: {url!r}");
    }

    # --- THE FIX -----------------------------------------------------------
    # Take everything up to the first '/' *and* strip anything from the first
    # '?'. Doing '?' second means a query-only URL (Browserbase) no longer
    # smuggles "?apiKey=..." into the hostname.
    hostport = rest.split("/", 1)[0].split("?", 1)[0];
    # The remainder is whatever followed the authority — a path, a query, or
    # both. A bare query has to be prefixed with '/' to make a legal HTTP
    # request-target, which is how the apiKey reaches the server.
    tail = rest[len(hostport):];
    path = tail if tail.startswith("/") else "/" + tail;
    # -----------------------------------------------------------------------

    if hostport.startswith("[") {
        # IPv6 literal: [::1]:9222
        (raw_host, bracket, after) = hostport.partition("]");
        if not bracket {
            raise ValueError(f"unterminated IPv6 literal in {url!r}");
        }
        host = raw_host[1:];
        port = int(after[1:]) if after.startswith(":") and len(after) > 1 else (443 if secure else 80);
    } else {
        (host, colon, raw_port) = hostport.partition(":");
        port = int(raw_port) if colon and raw_port else (443 if secure else 80);
    }
    if not host {
        raise ValueError(f"websocket url has an empty host: {url!r}");
    }
    return (secure, host, port, path);
}


impl mask_payload(payload: bytes, mask: bytes) -> bytes {
    if len(mask) != 4 {
        raise ValueError(f"websocket mask must be exactly 4 bytes, got {len(mask)}");
    }
    return bytes([payload[i] ^ mask[i % 4] for i in range(len(payload))]);
}


impl build_frame(payload: bytes, opcode: int, mask: bytes) -> bytes {
    # FIN=1 plus the opcode. This client never fragments what it sends;
    # CDP commands are small and Chrome accepts them whole.
    header = bytearray([0x80 | opcode]);
    ln = len(payload);
    # The high bit of byte 1 is the MASK flag. RFC 6455 5.1 requires every
    # client->server frame to be masked, and Chrome closes the socket if not.
    if ln < 126 {
        header.append(0x80 | ln);
    } elif ln < 65536 {
        header.append(0x80 | 126);
        header.extend(struct.pack("!H", ln));
    } else {
        header.append(0x80 | 127);
        header.extend(struct.pack("!Q", ln));
    }
    header.extend(mask);
    return bytes(header) + mask_payload(payload, mask);
}


impl JacWS.postinit {
    (secure, host, port, path) = parse_ws_url(self.url);
    self.secure = secure;
    self.host = host;
    self.port = port;
    self.path = path;
    self._buf = bytearray();
    self.closed = False;

    raw = socket.create_connection((host, port), timeout=self.timeout);
    if secure {
        ctx = ssl.create_default_context();
        # server_hostname drives BOTH SNI and certificate validation. Without
        # it the handshake to a name-based vhost like connect.browserbase.com
        # gets the wrong certificate.
        self.sock = ctx.wrap_socket(raw, server_hostname=host);
    } else {
        self.sock = raw;
    }
    self.sock.settimeout(self.timeout);
    self._handshake();
}


impl JacWS._handshake {
    key = base64.b64encode(os.urandom(16)).decode();
    # Only carry the port in Host when it is non-default, per RFC 7230 §5.4.
    default_port = 443 if self.secure else 80;
    host_header = self.host if self.port == default_port else f"{self.host}:{self.port}";
    req = (
        f"GET {self.path} HTTP/1.1\r\n"
        f"Host: {host_header}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    );
    self.sock.sendall(req.encode());

    header = self._read_until("\r\n\r\n".encode());
    status = header.split("\r\n".encode(), 1)[0].decode(errors="replace");
    if "101" not in status {
        # Surface the server's own words — a 401 here means a bad API key and
        # a 404 means the sessionId is gone. Both are worth reading verbatim.
        body = header.decode(errors="replace");
        raise ConnectionError(
            f"websocket upgrade rejected by {self.host}: {status}\n--- headers ---\n{body}"
        );
    }
    # RFC 6455 §4.1: the server must echo base64(sha1(key + GUID)). Verifying
    # it is what distinguishes a real websocket peer from a proxy that merely
    # felt like saying 101.
    expected = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode();
    if expected.encode() not in header {
        raise ConnectionError(
            f"Sec-WebSocket-Accept mismatch from {self.host}: expected {expected}\n"
            f"--- headers ---\n{header.decode(errors='replace')}"
        );
    }
}


impl JacWS._read_until(delim: bytes) -> bytes {
    while delim not in self._buf {
        chunk = self.sock.recv(4096);
        if not chunk {
            raise ConnectionError(
                f"{self.host} closed the connection during the HTTP upgrade "
                f"after {len(self._buf)} bytes"
            );
        }
        self._buf.extend(chunk);
    }
    idx = self._buf.index(delim) + len(delim);
    head = bytes(self._buf[:idx]);
    # Anything past the header terminator is already-arrived frame data and
    # must be kept — Chrome pipelines its first events onto the 101 response.
    del self._buf[:idx];
    return head;
}


impl JacWS._recv_exact(n: int) -> bytes {
    while len(self._buf) < n {
        chunk = self.sock.recv(65536);
        if not chunk {
            raise ConnectionError(
                f"{self.host} closed mid-frame: wanted {n} bytes, have {len(self._buf)}"
            );
        }
        self._buf.extend(chunk);
    }
    out = bytes(self._buf[:n]);
    del self._buf[:n];
    return out;
}


impl JacWS._read_frame -> tuple {
    (b0, b1) = self._recv_exact(2);
    fin = (b0 & 0x80) != 0;
    opcode = b0 & 0x0F;
    masked = (b1 & 0x80) != 0;
    ln = b1 & 0x7F;
    # 7-bit / 16-bit / 64-bit extended length ladder, RFC 6455 §5.2.
    if ln == 126 {
        ln = struct.unpack("!H", self._recv_exact(2))[0];
    } elif ln == 127 {
        ln = struct.unpack("!Q", self._recv_exact(8))[0];
    }
    mask = self._recv_exact(4) if masked else bytes();
    payload = self._recv_exact(ln);
    if masked {
        # A conforming server never masks, but unmask rather than silently
        # hand back garbage if one does.
        payload = mask_payload(payload, mask);
    }
    return (fin, opcode, payload);
}


impl JacWS.send(data: (str | bytes), opcode: int = OP_TEXT) {
    if self.closed {
        raise ConnectionError("send on a closed JacWS");
    }
    payload = data.encode() if isinstance(data, str) else data;
    self.sock.sendall(build_frame(payload, opcode, os.urandom(4)));
}


impl JacWS.recv -> (str | bytes) {
    chunks = bytearray();
    started = 0;
    while True {
        (fin, opcode, payload) = self._read_frame();
        if opcode == OP_PING {
            # Answer it. A CDP session that goes quiet during a long research
            # lane is kept alive only by this pong.
            self.send(payload, opcode=OP_PONG);
            continue;
        }
        if opcode == OP_PONG {
            continue;
        }
        if opcode == OP_CLOSE {
            code = struct.unpack("!H", payload[:2])[0] if len(payload) >= 2 else 0;
            reason = payload[2:].decode(errors="replace") if len(payload) > 2 else "";
            self.closed = True;
            raise ConnectionError(f"{self.host} sent WebSocket close {code} {reason}");
        }
        if opcode != OP_CONT {
            started = opcode;
        }
        chunks.extend(payload);
        if fin {
            return bytes(chunks).decode() if started == OP_TEXT else bytes(chunks);
        }
    }
}


impl JacWS.close {
    # Only offer a close frame if the peer has not already closed on us —
    # and note the flag flips AFTER the send, because send() refuses to write
    # to a connection already marked closed.
    if not self.closed {
        try {
            self.send(bytes(), opcode=OP_CLOSE);
        } except OSError as e {
            # The peer hanging up first is the normal race here; anything else
            # is still worth printing rather than hiding.
            print(f"[jacws] close handshake skipped ({self.host}): {e}");
        }
        self.closed = True;
    }
    # Always release the fd, including on the recv()-saw-a-close-frame path.
    try {
        self.sock.close();
    } except OSError as e {
        print(f"[jacws] socket close ({self.host}): {e}");
    }
}
