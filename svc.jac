"""Shared service layer: config, HTTP, and Google OAuth token refresh.

Every external credential and base URL used by the outreach/voice/calendar
walkers is resolved here so that nothing is hardcoded at a call site.
"""

import os;
import json;
import time;
import httpx;


# --------------------------------------------------------------------------
# .env loading
# --------------------------------------------------------------------------
# `jac start` does not populate os.environ from a .env file, so we do it once,
# walking up from the cwd. Real environment variables always win over the file.

glob _ENV_READY: bool = False;


def _dotenv_candidates -> list[str] {
    out: list[str] = [];
    here = os.path.abspath(os.getcwd());
    while True {
        out.append(os.path.join(here, ".env"));
        parent = os.path.dirname(here);
        if parent == here {
            break;
        }
        here = parent;
    }
    return out;
}


def _unquote(raw: str) -> str {
    v = raw.strip();
    if len(v) >= 2 {
        if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")) {
            return v[1:-1];
        }
    }
    return v;
}


def load_dotenv -> None {
    if _ENV_READY {
        return;
    }
    for path in _dotenv_candidates() {
        if not os.path.exists(path) {
            continue;
        }
        fh = open(path, "r", encoding="utf-8");
        raw = fh.read();
        fh.close();
        for line in raw.splitlines() {
            s = line.strip();
            if (not s) or s.startswith("#") or ("=" not in s) {
                continue;
            }
            parts = s.split("=", 1);
            key = parts[0].strip();
            if key and (key not in os.environ) {
                os.environ[key] = _unquote(parts[1]);
            }
        }
    }
    _ENV_READY = True;
    scrub_local_llm_proxy();
}


"""Drop a LOCALHOST Anthropic proxy from the environment.

Developer shells (Claude Code, some IDE agents) export
`ANTHROPIC_BASE_URL=http://127.0.0.1:...` pointing at a local relay. litellm
honours it, so every `by llm()` call inside this project is routed to that
relay and comes back `{"type":"authentication_error","message":"Missing or
invalid local proxy token"}` even though ANTHROPIC_API_KEY is perfectly valid.
The failure names the proxy, not the variable, so it reads like a bad key.

This removes the override ONLY when it points at loopback AND we hold a real
`sk-ant-` key - a deliberate, narrow rule, because a genuine remote gateway is
a legitimate deployment and must be left alone. It announces itself rather than
doing this silently.
"""
def scrub_local_llm_proxy -> bool {
    base = os.environ.get("ANTHROPIC_BASE_URL", "");
    if not base {
        return False;
    }
    is_loopback = ("127.0.0.1" in base) or ("localhost" in base) or ("::1" in base);
    has_real_key = os.environ.get("ANTHROPIC_API_KEY", "").startswith("sk-ant-");
    if not (is_loopback and has_real_key) {
        return False;
    }
    for name in ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_CUSTOM_HEADERS"] {
        if name in os.environ {
            del os.environ[name];
        }
    }
    print(
        f"[traction] ignoring loopback ANTHROPIC_BASE_URL ({base}) - a real sk-ant- key "
        + "is present, so LLM calls go to the Anthropic API directly."
    );
    return True;
}


def cfg(key: str, fallback: str = "") -> str {
    load_dotenv();
    return os.environ.get(key, fallback);
}


def cfg_required(key: str) -> str {
    value = cfg(key, "");
    if not value {
        raise ValueError(
            f"TRACTION config error: {key} is not set. "
            + "Add it to the .env at the project root before running this walker."
        );
    }
    return value;
}


# --------------------------------------------------------------------------
# Service endpoints and identities
# --------------------------------------------------------------------------

def agentmail_base -> str {
    # v0 is correct - v1 returns 404 "Route not found".
    return cfg("AGENTMAIL_BASE", "https://api.agentmail.to/v0");
}


def agentmail_inbox -> str {
    return cfg("AGENTMAIL_INBOX", "traction-outreach@agentmail.to");
}


def agentmail_headers -> dict {
    return {
        "Authorization": f"Bearer {cfg_required('AGENTMAIL_API_KEY')}",
        "Content-Type": "application/json"
    };
}


def vapi_base -> str {
    return cfg("VAPI_BASE", "https://api.vapi.ai");
}


def vapi_headers -> dict {
    return {
        "Authorization": f"Bearer {cfg_required('VAPI_API_KEY')}",
        "Content-Type": "application/json"
    };
}


"""Public HTTPS origin Vapi calls back into (cloudflared tunnel).

Never hardcoded: the tunnel hostname changes every run, so this is read
from the environment at call time rather than baked into a payload.
"""
def public_base_url -> str {
    return cfg("PUBLIC_BASE_URL", "").rstrip("/");
}


def public_url_for(path: str) -> str {
    base = public_base_url();
    if not base {
        raise ValueError(
            "TRACTION config error: PUBLIC_BASE_URL is not set. Vapi mid-call "
            + "tools need a public HTTPS origin (cloudflared). Set it in .env, "
            + "e.g. PUBLIC_BASE_URL=https://<something>.trycloudflare.com"
        );
    }
    if not path.startswith("/") {
        return f"{base}/{path}";
    }
    return f"{base}{path}";
}


def founder_email -> str {
    return cfg("FOUNDER_EMAIL", "elijah@uni.minerva.edu");
}


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------
# Every external call is awaited on an AsyncClient so a slow vendor never
# blocks the event loop - the mid-call KbQuery endpoint shares this process
# and has a hard <50ms budget.

"""Perform a JSON request. Raises loudly with the response body on failure."""
async def http_json(
    method: str,
    url: str,
    headers: dict,
    payload: any = None,
    timeout: float = 30.0,
    label: str = "http"
) -> dict {
    client = httpx.AsyncClient(timeout=timeout);
    status = 0;
    body = "";
    try {
        resp = await client.request(method, url, headers=headers, json=payload);
        status = resp.status_code;
        body = resp.text;
    } finally {
        await client.aclose();
    }
    if status < 200 or status >= 300 {
        snippet = body[:800];
        raise RuntimeError(f"{label}: HTTP {status} from {method} {url} :: {snippet}");
    }
    if not body.strip() {
        return {};
    }
    parsed = json.loads(body);
    if isinstance(parsed, dict) {
        return parsed;
    }
    return {"data": parsed};
}


"""POST application/x-www-form-urlencoded (Google token endpoint)."""
async def http_form(
    url: str,
    form: dict,
    timeout: float = 20.0,
    label: str = "http-form"
) -> dict {
    client = httpx.AsyncClient(timeout=timeout);
    status = 0;
    body = "";
    try {
        resp = await client.post(url, data=form);
        status = resp.status_code;
        body = resp.text;
    } finally {
        await client.aclose();
    }
    if status < 200 or status >= 300 {
        snippet = body[:800];
        raise RuntimeError(f"{label}: HTTP {status} from POST {url} :: {snippet}");
    }
    return json.loads(body);
}


# --------------------------------------------------------------------------
# Google OAuth - refresh-token flow
# --------------------------------------------------------------------------
# The obj must be declared above the glob that constructs it: a glob is
# evaluated before later declarations exist.

obj GoogleToken {
    has access_token: str = "";
    has expires_at: float = 0.0;
}


glob _GTOKEN: GoogleToken = GoogleToken();


"""Resolve client_id, client_secret and refresh_token as ONE matched set.

A Google refresh token is bound to the OAuth client that issued it. Mixing a
client_id from one source with a refresh_token from another is not a
misconfiguration Google tolerates - it answers 401 `unauthorized_client`.
That is a real trap here: the .env GOOGLE_CLIENT_ID (163824...) is a
different client from the one that minted the credentials-file refresh token
(116064...). So we take all three from the same origin, never interleaved:
env wins only when the caller supplies the complete triple.
"""
def _google_oauth_creds -> dict {
    env_id = cfg("GOOGLE_CLIENT_ID", "");
    env_secret = cfg("GOOGLE_CLIENT_SECRET", "");
    env_refresh = cfg("GOOGLE_REFRESH_TOKEN", "");
    if env_id and env_secret and env_refresh {
        return {
            "client_id": env_id,
            "client_secret": env_secret,
            "refresh_token": env_refresh
        };
    }

    path = cfg(
        "GOOGLE_CREDENTIALS_FILE",
        "/Users/elijahumana/.workspace-mcp/credentials/elijah@uni.minerva.edu.json"
    );
    if not os.path.exists(path) {
        raise ValueError(
            "TRACTION config error: no usable Google credentials. Either set all of "
            + "GOOGLE_CLIENT_ID + GOOGLE_CLIENT_SECRET + GOOGLE_REFRESH_TOKEN (they must "
            + "belong to the same OAuth client), or point GOOGLE_CREDENTIALS_FILE at a "
            + f"credentials json (tried: {path})"
        );
    }
    fh = open(path, "r", encoding="utf-8");
    data = json.loads(fh.read());
    fh.close();
    creds = {
        "client_id": data.get("client_id", ""),
        "client_secret": data.get("client_secret", ""),
        "refresh_token": data.get("refresh_token", "")
    };
    for key in ["client_id", "client_secret", "refresh_token"] {
        if not creds[key] {
            raise ValueError(f"TRACTION config error: {path} has no '{key}' key.");
        }
    }
    return creds;
}


"""Return a live Google access token, refreshing when within 60s of expiry."""
async def google_access_token -> str {
    now = time.time();
    if _GTOKEN.access_token and _GTOKEN.expires_at > (now + 60.0) {
        return _GTOKEN.access_token;
    }
    creds = _google_oauth_creds();
    form = {
        "client_id": creds["client_id"],
        "client_secret": creds["client_secret"],
        "refresh_token": creds["refresh_token"],
        "grant_type": "refresh_token"
    };
    data = await http_form(
        "https://oauth2.googleapis.com/token", form, 20.0, "google-oauth-refresh"
    );
    token = data.get("access_token", "");
    if not token {
        raise RuntimeError(f"google-oauth-refresh: response carried no access_token :: {data}");
    }
    _GTOKEN.access_token = token;
    _GTOKEN.expires_at = now + float(data.get("expires_in", 3600));
    return token;
}


async def google_headers -> dict {
    token = await google_access_token();
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"};
}
