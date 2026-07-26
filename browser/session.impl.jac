"""Implementation of the per-lane browser session facade."""

impl BrowserSession.postinit {
    self.bb = Browserbase();
    sess = self.bb.create_session(
        proxies=self.proxies,
        context_id=self.context_id if self.context_id else None,
        persist=self.persist
    );
    self.session_id = sess["id"];
    self.connect_url = sess["connectUrl"];

    # Captured NOW, while the lane is still opening — the dashboard iframes
    # need it during the run, not after it.
    debug = self.bb.session_debug(self.session_id);
    self.live_url = debug.get("debuggerFullscreenUrl", "");
    if not self.live_url {
        print(f"[session] WARNING {self.session_id}: no debuggerFullscreenUrl "
              f"returned; the live panel for this lane will be blank");
    }

    # Own socket, own id counter, own pending map. Nothing shared.
    self.cdp = CDP(ws_url=self.connect_url);
    # DEFAULT tab, flattened. Never Target.createTarget: a second tab is what
    # silently zeroed the context cookie sync during auth bring-up.
    self.page = Page(cdp=self.cdp, session_id=self.cdp.attach_page());
}


impl BrowserSession.goto(url: str, settle: float = 0.0) -> bool {
    try {
        self.page.navigate(url, settle=settle);
        return True;
    } except Exception as e {
        # Reported in full, then handed back as False so the lane's own
        # retry/widening logic decides what to do. Not a swallowed error.
        print(f"[session] {self.session_id[:8]} goto({url}) FAILED: {e}");
        return False;
    }
}


impl BrowserSession.where -> dict {
    return self.page.location();
}


impl BrowserSession.eval_json(expr: str) -> any {
    return self.page.extract(expr);
}


impl BrowserSession.eval_js(expr: str) -> str {
    # One round trip: CDP already returns the value by value, so serialising
    # here costs nothing extra on the wire.
    return json.dumps(self.page.extract(expr));
}


impl BrowserSession.text -> str {
    return self.page.extract("document.body ? document.body.innerText : ''") or "";
}


impl BrowserSession.click(selector: str) -> bool {
    # Reuses the exact same vetted actionability routine as click_ref, just
    # bound to a querySelector hit instead of an accessibility ref.
    probe = (
        "(function(){ const el = document.querySelector(" + json.dumps(selector) + ");"
        " if (!el) { return {ok:false, reason:'selector matched nothing'}; }"
        " return (" + ACTIONABILITY_JS + ").call(el); })()"
    );
    try {
        info = self.page.extract(probe) or {};
    } except Exception as e {
        print(f"[session] {self.session_id[:8]} click({selector!r}) probe failed: {e}");
        return False;
    }
    if not info.get("ok") {
        print(f"[session] {self.session_id[:8]} click({selector!r}) skipped: "
              f"{info.get('reason', 'unknown reason')}");
        return False;
    }
    self.page.click_point(info["x"], info["y"]);
    return True;
}


impl BrowserSession.type_text(selector: str, text: str, human: bool = True) -> bool {
    if not self.click(selector) {
        return False;
    }
    if human {
        self.page.type_human(text);
    } else {
        self.cdp.call(
            "Input.insertText", {"text": text}, session_id=self.page.session_id
        );
    }
    return True;
}


impl BrowserSession.press(key: str) {
    self.page.press(key);
}


impl BrowserSession.scroll(px: int) {
    self.page.extract(f"(window.scrollBy(0, {px}), true)");
}


impl BrowserSession.wait_ms(ms: int) {
    time.sleep(ms / 1000.0);
}


impl BrowserSession.wait_for_selector(selector: str, timeout: float = 15.0) -> bool {
    return self.wait_for_js(
        "!!document.querySelector(" + json.dumps(selector) + ")", timeout=timeout
    );
}


impl BrowserSession.wait_for_js(expr: str, timeout: float = 15.0) -> bool {
    deadline = time.monotonic() + timeout;
    while time.monotonic() < deadline {
        try {
            if self.page.extract(f"!!({expr})") {
                return True;
            }
        } except Exception as e {
            # A predicate that throws mid-navigation is normal; keep polling
            # but say so, so a permanently broken predicate is visible.
            print(f"[session] {self.session_id[:8]} wait predicate threw: {e}");
        }
        time.sleep(0.2);
    }
    print(f"[session] {self.session_id[:8]} wait_for timed out after {timeout}s: {expr[:80]}");
    return False;
}


impl BrowserSession.wait_for(what: str, timeout: float = 15.0) -> bool {
    looks_like_js = any([
        token in what
        for token in ["(", "=>", "===", "!==", ">=", "<=", "document.", "window."]
    ]);
    if looks_like_js {
        return self.wait_for_js(what, timeout=timeout);
    }
    return self.wait_for_selector(what, timeout=timeout);
}


impl BrowserSession.snapshot_ax(max_lines: int = 0) -> str {
    return self.page.snapshot_ax(max_lines=max_lines);
}


impl BrowserSession.click_ref(ref: str) -> str {
    return self.page.click_ref(ref);
}


impl BrowserSession.screenshot(path: str, full_page: bool = False) -> str {
    return self.page.screenshot(path, full_page=full_page);
}


impl BrowserSession.close {
    if self.closed {
        return;
    }
    self.closed = True;
    # Both halves run even if the first complains — a leaked Browserbase
    # session burns concurrency we need for the other lanes.
    try {
        self.cdp.close();
    } except Exception as e {
        print(f"[session] {self.session_id[:8]} socket close: {e}");
    }
    try {
        self.bb.release(self.session_id);
    } except Exception as e {
        print(f"[session] {self.session_id[:8]} release FAILED: {e}");
    }
}


impl new_session(
    context_id: str = "", persist: bool = False, proxies: bool = True
) -> BrowserSession {
    return BrowserSession(context_id=context_id, persist=persist, proxies=proxies);
}
