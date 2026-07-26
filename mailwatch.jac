"""AgentMail reply listener - turns an inbound email into an OnEmailReply spawn.

Runs as its own process next to the server:

    set -a && . ./.env && set +a
    jac run mailwatch.jac

Why polling rather than a webhook: a webhook would need a public callback URL,
and on venue wifi the only public URL we have is a cloudflared tunnel that is
already carrying the three Vapi callbacks. Polling needs no inbound path at
all, so reply detection cannot be broken by the tunnel dropping. At a 1.5s
interval the added latency is invisible next to how long a human takes to
finish typing a reply.

Two rules keep it honest on stage:
  - only messages that arrive AFTER startup are acted on, so the backlog in a
    shared demo inbox never fires a call
  - every message id is remembered, so a reconnect or an overlapping poll can
    never spawn the same reply twice
"""

import time;
import json;
import httpx;

import from svc { agentmail_base, agentmail_inbox, agentmail_headers, cfg, http_json }


glob SEEN: dict[str, bool] = {};


def local_server -> str {
    return cfg("TRACTION_SERVER", "http://localhost:8000").rstrip("/");
}


def poll_seconds -> float {
    return float(cfg("MAILWATCH_INTERVAL", "1.5"));
}


"""Pull the bare address out of a From header like `Traction <a@b.to>`."""
def bare_email(raw: str) -> str {
    text = raw.strip();
    if "<" in text and ">" in text {
        start = text.index("<") + 1;
        end = text.index(">");
        if end > start {
            return text[start:end].strip().lower();
        }
    }
    return text.lower();
}


"""True when this message is one WE sent rather than one that arrived."""
def is_outbound(message: dict) -> bool {
    labels: list = message.get("labels", []) as list;
    for label in labels {
        if str(label).lower() == "sent" {
            return True;
        }
    }
    return bare_email(str(message.get("from", ""))) == agentmail_inbox().lower();
}


"""Best available body text, fetching the full message when the list view is thin."""
async def message_text(message_id: str, fallback: str) -> str {
    url = f"{agentmail_base()}/inboxes/{agentmail_inbox()}/messages/{message_id}";
    try {
        full = await http_json("GET", url, agentmail_headers(), None, 15.0, "agentmail-message");
    } except Exception as e {
        print(f"  ! could not fetch full body ({str(e)[:80]}), using preview");
        return fallback;
    }
    for key in ["text", "plain", "body"] {
        value = str(full.get(key, ""));
        if value and value != "None" {
            return value;
        }
    }
    return fallback;
}


"""Hand one inbound reply to the OnEmailReply walker."""
async def deliver(thread_id: str, from_email: str, text: str) -> None {
    payload = {"thread_id": thread_id, "from_email": from_email, "text": text};
    url = f"{local_server()}/walker/OnEmailReply";
    client = httpx.AsyncClient(timeout=90.0);
    body = "";
    status = 0;
    try {
        resp = await client.post(url, json=payload);
        status = resp.status_code;
        body = resp.text;
    } finally {
        await client.aclose();
    }
    if status != 200 {
        print(f"  ! OnEmailReply returned HTTP {status}: {body[:220]}");
        return;
    }
    parsed = json.loads(body);
    data = parsed.get("data", {}) as dict;
    reports: list = data.get("reports", []) as list;
    if not reports {
        print(f"  ! OnEmailReply reported nothing: {body[:220]}");
        return;
    }
    first: dict = reports[0] as dict;
    print(
        "  -> intent=" + str(first.get("intent", "?"))
        + "  wants_call=" + str(first.get("wants_call", "?"))
        + "  phone=" + str(first.get("phone_number", ""))
        + "  sentiment=" + str(first.get("sentiment", ""))
    );
    times: list = first.get("proposed_times", []) as list;
    if times {
        print("     times offered: " + str(times));
    }
    if first.get("wants_call", False) {
        print("     READY TO CALL - spawn ScheduleCall with prospect_id="
              + str(first.get("prospect_id", "")));
    }
}


"""One pass over the inbox. Returns how many new inbound messages were handled."""
async def sweep(prime_only: bool) -> int {
    url = f"{agentmail_base()}/inboxes/{agentmail_inbox()}/messages?limit=15";
    listing = await http_json("GET", url, agentmail_headers(), None, 20.0, "agentmail-list");
    messages: list = listing.get("messages", []) as list;
    handled = 0;

    for raw in messages {
        message: dict = raw as dict;
        mid = str(message.get("message_id", ""));
        if (not mid) or SEEN.get(mid, False) {
            continue;
        }
        SEEN[mid] = True;
        if prime_only or is_outbound(message) {
            continue;
        }
        sender = bare_email(str(message.get("from", "")));
        subject = str(message.get("subject", ""));
        print(f"[{time.strftime('%H:%M:%S')}] reply from {sender}: {subject}");
        text = await message_text(mid, str(message.get("preview", "")));
        await deliver(str(message.get("thread_id", "")), sender, text);
        handled += 1;
    }
    return handled;
}


async def watch -> None {
    print("mailwatch: inbox   " + agentmail_inbox());
    print("mailwatch: server  " + local_server());
    print("mailwatch: every   " + str(poll_seconds()) + "s");

    primed = await sweep(True);
    print(f"mailwatch: primed with {len(SEEN)} existing message(s) - only NEW replies will fire");
    print("mailwatch: watching. Ctrl-C to stop.");
    _ = primed;

    failures = 0;
    while True {
        try {
            _ = await sweep(False);
            failures = 0;
        } except Exception as e {
            failures += 1;
            print(f"mailwatch: poll failed ({failures}): {str(e)[:160]}");
            if failures >= 20 {
                raise RuntimeError(
                    "mailwatch: 20 consecutive polling failures - stopping rather than "
                    + "pretending to watch an inbox it cannot reach"
                );
            }
        }
        time.sleep(poll_seconds());
    }
}


with entry:__main__ {
    import asyncio;
    asyncio.run(watch());
}
