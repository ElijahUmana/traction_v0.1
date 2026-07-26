"""Implementation of the Browserbase REST client."""

impl Browserbase.postinit {
    if not self.api_key {
        self.api_key = env("BROWSERBASE_API_KEY", required=True);
    }
    if not self.project_id {
        self.project_id = env("BROWSERBASE_PROJECT_ID");
    }
}


impl Browserbase._request(path: str, data: (dict | None) = None, method: (str | None) = None) -> any {
    body = json.dumps(data).encode() if data is not None else None;
    req = urllib.request.Request(
        BB_API + path,
        data=body,
        headers={"X-BB-API-Key": self.api_key, "Content-Type": "application/json"},
        method=method
    );
    try {
        resp = urllib.request.urlopen(req, timeout=self.timeout);
        text = resp.read().decode();
        resp.close();
    } except urllib.error.HTTPError as e {
        # Browserbase explains itself in the response body — an unread body
        # turns "context is invalid" into a bare 400 and costs an hour.
        detail = e.read().decode(errors="replace");
        raise RuntimeError(
            f"Browserbase {method or 'GET'} {path} -> HTTP {e.code} {e.reason}: {detail}"
        );
    } except urllib.error.URLError as e {
        raise RuntimeError(f"Browserbase {method or 'GET'} {path} unreachable: {e.reason}");
    }
    if not text {
        return {};
    }
    try {
        return json.loads(text);
    } except json.JSONDecodeError as e {
        raise RuntimeError(f"Browserbase {path} returned non-JSON: {e}; body {text[:300]!r}");
    }
}


impl Browserbase.create_context -> str {
    payload: dict[str, any] = {};
    if self.project_id {
        payload["projectId"] = self.project_id;
    }
    res = self._request("/contexts", payload, method="POST");
    context_id = res.get("id");
    if not context_id {
        raise RuntimeError(f"context creation returned no id: {res}");
    }
    return context_id;
}


impl Browserbase.create_session(
    proxies: bool = False,
    context_id: (str | None) = None,
    persist: bool = False,
    session_timeout: int = 1800,
    width: int = 1440,
    height: int = 900
) -> dict {
    settings: dict[str, any] = {
        "solveCaptchas": True,
        "viewport": {"width": width, "height": height}
    };
    if context_id {
        settings["context"] = {"id": context_id, "persist": persist};
    }
    body: dict[str, any] = {
        "keepAlive": True,
        "timeout": session_timeout,
        "browserSettings": settings
    };
    if proxies {
        body["proxies"] = True;
    }
    if self.project_id {
        body["projectId"] = self.project_id;
    }
    res = self._request("/sessions", body, method="POST");
    if not res.get("connectUrl") {
        raise RuntimeError(f"session created without a connectUrl: {res}");
    }
    return res;
}


impl Browserbase.session_debug(session_id: str) -> dict {
    return self._request(f"/sessions/{session_id}/debug");
}


impl Browserbase.release(session_id: str) -> dict {
    return self._request(
        f"/sessions/{session_id}",
        {"status": "REQUEST_RELEASE"},
        method="POST"
    );
}
