"""Implementation of the semantic browser actions."""

impl Page.postinit {
    self._refs = {};
}


impl Page.enable {
    if self._enabled {
        return;
    }
    for domain in ["Page", "DOM", "Runtime", "Accessibility"] {
        self.cdp.call(f"{domain}.enable", session_id=self.session_id);
    }
    self._enabled = True;
}


impl Page.navigate(url: str, timeout: float = 45.0, settle: float = 0.0) -> dict {
    self.enable();
    res = self.cdp.call(
        "Page.navigate", {"url": url}, session_id=self.session_id, timeout=timeout
    );
    if res.get("errorText") {
        # net::ERR_NAME_NOT_RESOLVED and friends arrive as a successful CDP
        # reply carrying an error string. Silently returning it would let a
        # lane "succeed" against a page that never loaded.
        raise RuntimeError(f"navigation to {url} failed: {res['errorText']}");
    }
    self.wait_ready(timeout=timeout);
    if settle > 0 {
        # Only for pages that keep hydrating after readyState=complete.
        time.sleep(settle);
    }
    # A fresh document invalidates every ref from the previous snapshot.
    self._refs = {};
    return self.location();
}


impl Page.wait_ready(timeout: float = 30.0) -> bool {
    deadline = time.monotonic() + timeout;
    last = "";
    while time.monotonic() < deadline {
        last = self.extract("document.readyState");
        if last == "complete" {
            return True;
        }
        time.sleep(0.15);
    }
    raise TimeoutError(
        f"document never reached readyState=complete within {timeout}s (last: {last!r})"
    );
}


impl Page.extract(expression: str, timeout: float = 30.0) -> any {
    res = self.cdp.call(
        "Runtime.evaluate",
        {"expression": expression, "returnByValue": True, "awaitPromise": True},
        session_id=self.session_id,
        timeout=timeout
    );
    if "exceptionDetails" in res {
        detail = res["exceptionDetails"];
        text = (detail.get("exception") or {}).get("description") or detail.get("text");
        raise RuntimeError(f"page threw while evaluating {expression[:120]!r}: {text}");
    }
    return (res.get("result") or {}).get("value");
}


impl Page.location -> dict {
    raw = self.extract("JSON.stringify({url: location.href, title: document.title})");
    return json.loads(raw);
}


impl Page.type_human(text: str) {
    # Each character is two CDP commands. Awaiting each one would put a full
    # network round-trip (~90ms to us-west-2) between every keystroke, so the
    # observed cadence would be RTT-bound at ~220ms no matter what delay was
    # asked for. Pipelining the frames instead makes the inter-keystroke
    # interval genuinely the value below. CDP executes in order per session,
    # so ordering is preserved; every id is reconciled at the end, so a
    # protocol error still surfaces.
    pending: list[int] = [];
    for ch in text {
        # keyDown carrying `text` is what fires the input/change events React
        # listens for; insertText would skip them.
        pending.append(self.cdp.send_async(
            "Input.dispatchKeyEvent",
            {"type": "keyDown", "text": ch, "key": ch, "unmodifiedText": ch},
            session_id=self.session_id
        ));
        pending.append(self.cdp.send_async(
            "Input.dispatchKeyEvent",
            {"type": "keyUp", "key": ch},
            session_id=self.session_id
        ));
        # Human cadence: ~40ms, jittered, never negative.
        delay = self.keystroke_delay + random.uniform(-self.keystroke_jitter, self.keystroke_jitter);
        time.sleep(delay if delay > 0.005 else 0.005);
    }
    self.cdp.await_ids(pending, "Input.dispatchKeyEvent (type_human)");
}


impl Page.press(key: str, modifiers: int = 0) {
    vk = KEY_CODES.get(key, 0);
    code = key;
    down: dict[str, any] = {"type": "keyDown", "key": key, "modifiers": modifiers};
    if vk {
        down["windowsVirtualKeyCode"] = vk;
        down["nativeVirtualKeyCode"] = vk;
    } elif len(key) == 1 {
        code = ("Key" + key.upper()) if key.isalpha() else (("Digit" + key) if key.isdigit() else key);
        down["windowsVirtualKeyCode"] = ord(key.upper());
        if modifiers == 0 {
            down["text"] = key;
        }
    }
    down["code"] = code;
    self.cdp.call("Input.dispatchKeyEvent", down, session_id=self.session_id);
    self.cdp.call(
        "Input.dispatchKeyEvent",
        {"type": "keyUp", "key": key, "code": code, "modifiers": modifiers},
        session_id=self.session_id
    );
}


impl Page._walk_ax(ax: dict, by_id: dict, depth: int, lines: list, refs: dict) {
    role = (ax.get("role") or {}).get("value", "");
    name = (ax.get("name") or {}).get("value", "");
    ignored = ax.get("ignored", False);
    next_depth = depth;
    if (not ignored) and role {
        ref_str = "";
        backend = ax.get("backendDOMNodeId");
        if (role in INTERACTIVE_ROLES or name) and backend is not None {
            rid = f"e{len(refs) + 1}";
            refs[rid] = backend;
            ref_str = f"@{rid} ";
        }
        label = f' "{name}"' if name else "";
        lines.append("  " * depth + f"{ref_str}{role}{label}");
        next_depth = depth + 1;
    }
    children: list = ax.get("childIds", []) or [];
    for cid in children {
        child = by_id.get(cid);
        if child {
            self._walk_ax(child, by_id, next_depth, lines, refs);
        }
    }
}


impl Page.snapshot_ax(max_lines: int = 0) -> str {
    self.enable();
    nodes: list[dict] = self.cdp.call(
        "Accessibility.getFullAXTree", session_id=self.session_id, timeout=60.0
    ).get("nodes", []) or [];
    by_id: dict[any, dict] = {};
    for n in nodes {
        by_id[n["nodeId"]] = n;
    }
    child_ids: set[any] = set();
    for n in nodes {
        kids: list = n.get("childIds", []) or [];
        for c in kids {
            child_ids.add(c);
        }
    }
    roots: list[dict] = [n for n in nodes if n["nodeId"] not in child_ids];
    lines: list[str] = [];
    refs: dict[str, int] = {};
    for r in roots {
        self._walk_ax(r, by_id, 0, lines, refs);
    }
    self._refs = refs;
    if max_lines > 0 and len(lines) > max_lines {
        # Truncation is ANNOUNCED. A silently clipped tree reads to an agent
        # like a page that simply does not contain what it is looking for.
        dropped = len(lines) - max_lines;
        lines = lines[:max_lines];
        lines.append(f"... [{dropped} more accessibility nodes truncated of {dropped + max_lines} total]");
    }
    return "\n".join(lines);
}


impl Page.click_ref(ref: str) -> str {
    key = ref[1:] if ref.startswith("@") else ref;
    if key not in self._refs {
        raise KeyError(
            f"unknown element ref {ref!r}; call snapshot_ax() first "
            f"({len(self._refs)} refs currently known)"
        );
    }
    backend_id = self._refs[key];
    resolved = self.cdp.call(
        "DOM.resolveNode", {"backendNodeId": backend_id}, session_id=self.session_id
    );
    object_id = (resolved.get("object") or {}).get("objectId");
    if not object_id {
        raise RuntimeError(f"ref {ref} no longer resolves to a live DOM node: {resolved}");
    }
    check = self.cdp.call(
        "Runtime.callFunctionOn",
        {
            "functionDeclaration": ACTIONABILITY_JS,
            "objectId": object_id,
            "returnByValue": True,
            "awaitPromise": True
        },
        session_id=self.session_id
    );
    if "exceptionDetails" in check {
        raise RuntimeError(f"actionability check threw for {ref}: {check['exceptionDetails']}");
    }
    info = (check.get("result") or {}).get("value") or {};
    if not info.get("ok") {
        raise RuntimeError(f"cannot click {ref}: {info.get('reason', 'unknown reason')}");
    }
    self.click_point(info["x"], info["y"]);
    covered = "" if info.get("hitOk") else f" (warning: point is covered by {info.get('hit')})";
    return f"clicked {ref} at ({round(info['x'])}, {round(info['y'])}){covered}";
}


impl Page.click_point(x: float, y: float) {
    base: dict[str, any] = {"x": x, "y": y, "button": "left", "clickCount": 1};
    # Move first: many hover-gated menus never open without a mouseMoved.
    self.cdp.call(
        "Input.dispatchMouseEvent",
        {"type": "mouseMoved", "x": x, "y": y},
        session_id=self.session_id
    );
    self.cdp.call(
        "Input.dispatchMouseEvent", {"type": "mousePressed"} | base, session_id=self.session_id
    );
    self.cdp.call(
        "Input.dispatchMouseEvent", {"type": "mouseReleased"} | base, session_id=self.session_id
    );
}


impl Page.screenshot(path: str, full_page: bool = False) -> str {
    self.enable();
    params: dict[str, any] = {"format": "png"};
    if full_page {
        params["captureBeyondViewport"] = True;
    }
    res = self.cdp.call(
        "Page.captureScreenshot", params, session_id=self.session_id, timeout=60.0
    );
    data = base64.b64decode(res["data"]);
    out = Path(path);
    out.parent.mkdir(parents=True, exist_ok=True);
    out.write_bytes(data);
    return str(out);
}


impl Page.set_cookies(cookies: list) -> int {
    self.enable();
    payload: list = [];
    for c in cookies {
        entry: dict[str, any] = {
            "name": c["name"],
            "value": c["value"],
            "domain": c.get("domain", ""),
            "path": c.get("path") or "/",
            "secure": c.get("secure", True),
            "httpOnly": c.get("httpOnly", False)
        };
        if c.get("expires", 0) and c["expires"] > 0 {
            entry["expires"] = c["expires"];
        }
        if c.get("sameSite") {
            entry["sameSite"] = c["sameSite"];
        }
        payload.append(entry);
    }
    self.cdp.call("Network.enable", session_id=self.session_id);
    self.cdp.call("Network.setCookies", {"cookies": payload}, session_id=self.session_id);
    return len(payload);
}
