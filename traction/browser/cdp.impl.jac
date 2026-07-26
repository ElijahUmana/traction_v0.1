"""Implementation of the CDP client."""

impl CDP.postinit {
    self.ws = JacWS(url=self.ws_url, timeout=self.timeout);
    self._pending = {};
    self.events = [];
}


impl CDP.call(
    method: str,
    params: (dict | None) = None,
    session_id: (str | None) = None,
    timeout: (float | None) = None
) -> dict {
    self._id += 1;
    mid = self._id;
    msg: dict[str, any] = {"id": mid, "method": method};
    if params {
        msg["params"] = params;
    }
    if session_id {
        # Flattened routing: the sessionId rides on the envelope rather than
        # being wrapped in Target.sendMessageToTarget.
        msg["sessionId"] = session_id;
    }
    self.ws.send(json.dumps(msg));
    return self._await_reply(mid, method, timeout if timeout is not None else self.timeout);
}


impl CDP._await_reply(mid: int, method: str, timeout: float) -> dict {
    # The answer may already have arrived while some earlier call was reading.
    if mid in self._pending {
        return self._unwrap(self._pending.pop(mid), method);
    }
    deadline = time.monotonic() + timeout;
    while time.monotonic() < deadline {
        raw = self.ws.recv();
        if isinstance(raw, bytes) {
            raw = raw.decode(errors="replace");
        }
        try {
            msg = json.loads(raw);
        } except json.JSONDecodeError as e {
            # A frame that is not JSON means the stream is desynchronised.
            # Continuing would silently corrupt every later correlation.
            raise RuntimeError(
                f"CDP stream desynchronised while awaiting {method}: {e}; "
                f"frame began {raw[:200]!r}"
            );
        }
        if msg.get("id") == mid {
            return self._unwrap(msg, method);
        }
        self._absorb(msg);
    }
    raise TimeoutError(
        f"CDP {method} (id={mid}) got no reply within {timeout}s"
    );
}


impl CDP._absorb(msg: dict) {    if "id" in msg {
        # Someone else's reply. Hold it so their call() finds it.
        self._pending[msg["id"]] = msg;
    } else {
        self.events.append(msg);
        if len(self.events) > self.max_events {
            # Bounded so a long-running lane cannot grow without limit, but the
            # drop is COUNTED and reported rather than silently swallowed.
            overflow = len(self.events) - self.max_events;
            self.events = self.events[overflow:];
            self.events_dropped += overflow;
            print(
                f"[cdp] event buffer full at {self.max_events}; dropped "
                f"{overflow} oldest ({self.events_dropped} total)"
            );
        }
    }
}


impl CDP._unwrap(msg: dict, method: str) -> dict {
    if "error" in msg {
        err: dict = msg["error"];
        raise RuntimeError(
            f"CDP {method} failed: code={err.get('code')} {err.get('message')}"
            + (f" | {err.get('data')}" if err.get("data") else "")
        );
    }
    return msg.get("result", {});
}


impl CDP.wait_for_event(method: str, timeout: float = 30.0) -> dict {
    for (i, ev) in enumerate(self.events) {
        if ev.get("method") == method {
            return self.events.pop(i);
        }
    }
    deadline = time.monotonic() + timeout;
    while time.monotonic() < deadline {
        raw = self.ws.recv();
        if isinstance(raw, bytes) {
            raw = raw.decode(errors="replace");
        }
        try {
            msg = json.loads(raw);
        } except json.JSONDecodeError as e {
            raise RuntimeError(
                f"CDP stream desynchronised while waiting for {method}: {e}; "
                f"frame began {raw[:200]!r}"
            );
        }
        if msg.get("method") == method {
            return msg;
        }
        self._absorb(msg);
    }
    raise TimeoutError(f"CDP event {method} did not arrive within {timeout}s");
}


impl CDP.take_events(method: (str | None) = None) -> list {
    if method is None {
        out = self.events;
        self.events = [];
        return out;
    }
    out = [ev for ev in self.events if ev.get("method") == method];
    self.events = [ev for ev in self.events if ev.get("method") != method];
    return out;
}


impl CDP.attach_page -> str {
    targets: list = self.call("Target.getTargets").get("targetInfos", []);
    pages = [t for t in targets if t.get("type") == "page"];
    if not pages {
        # No default tab at all. Creating one is the documented failure mode
        # for context persistence, so say so loudly rather than paper over it.
        raise RuntimeError(
            "browser exposes no page target to attach to; refusing to "
            "Target.createTarget because a second tab breaks context cookie sync"
        );
    }
    target_id = pages[0]["targetId"];
    res = self.call(
        "Target.attachToTarget",
        {"targetId": target_id, "flatten": True}
    );
    session_id = res.get("sessionId");
    if not session_id {
        raise RuntimeError(f"Target.attachToTarget returned no sessionId: {res}");
    }
    return session_id;
}


impl CDP.send_async(
    method: str, params: (dict | None) = None, session_id: (str | None) = None
) -> int {
    self._id += 1;
    mid = self._id;
    msg: dict[str, any] = {"id": mid, "method": method};
    if params {
        msg["params"] = params;
    }
    if session_id {
        msg["sessionId"] = session_id;
    }
    self.ws.send(json.dumps(msg));
    return mid;
}


impl CDP.await_ids(ids: list[int], label: str, timeout: float = 30.0) -> int {
    # _await_reply consults _pending first and buffers anything else it reads,
    # so replies arriving out of order cost nothing.
    seen = 0;
    for mid in ids {
        self._await_reply(mid, label, timeout);
        seen += 1;
    }
    return seen;
}


impl CDP.close {
    self.ws.close();
}
