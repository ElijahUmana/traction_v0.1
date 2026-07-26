"""Voice - schedule the call, answer from the graph mid-call, book, and learn.

This is the closing 90 seconds of the demo. A real phone rings, the agent opens
with evidence this system gathered, the human pushes back, the agent answers
from the graph, names a time, and a Google Meet invite lands on their phone
before the call ends.

Three separate Vapi callbacks land back here as walkers - a mid-call question,
a mid-call booking, and the end-of-call report - and not one of them needed a
route defined. The base URL they call is read from the environment at schedule
time, never baked in, because the tunnel hostname changes on every run.

Latency note: KbQuery is the only endpoint on this system with a hard real-time
budget. It runs on a live phone call, so anything above ~50ms is audible as a
stutter. It therefore performs NO network call and NO LLM inference - the whole
dossier is flattened into a string at schedule time and read back verbatim.
"""

import time;
import from datetime { datetime, timedelta, timezone }

import from contracts { CallOutcome, LaneId }
import from schema {
    Prospect, Evidence, EmailThread, ReplyEvent,
    CallSession, Insight, Booking, Called, Learned, Booked
}
import from outreach {
    ProspectLookup, best_linkedin_quote, best_github_artifact,
    founder_context, address_as
}
import from svc { vapi_base, vapi_headers, http_json, cfg, cfg_required, public_url_for, founder_email }
import from gcal { create_meeting }

import from jaclang.byllm.lib { Model }

# The [byllm.model] block in jac.toml does NOT configure the ambient `llm`
# builtin - `by llm()` then returns None silently and the failure surfaces
# much later as an unrelated attribute error. An explicit model glob is what
# actually binds the model. Verified: without this, every call here returns null.
glob llm: Model = Model(model_name=cfg("BYLLM_MODEL", "claude-sonnet-4-6"));
# cfg() above runs load_dotenv(), which also scrubs a loopback ANTHROPIC_BASE_URL -
# so this glob is what guarantees the model is configured before any call.



# ===========================================================================
# THE MID-CALL DOSSIER
# ===========================================================================
# Built once, at schedule time. Read on the hot path. The in-process cache
# makes the common case an O(1) dict hit; the graph is the durable fallback so
# a server restart mid-demo still answers correctly.

glob KB_CACHE: dict[str, str] = {};


"""Flatten everything the graph knows about one human into speakable prose.

Written for a text-to-speech engine, so no markup, no bullet characters and no
abbreviations that would be read aloud as letters.
"""
def build_dossier(prospect: Prospect) -> str {
    founder = founder_context();
    quote = best_linkedin_quote(prospect);
    artifact = best_github_artifact(prospect);
    lanes = prospect.convergence_lanes();
    lane_names = [str(l) for l in lanes];

    lines: list[str] = [];
    called = address_as(prospect);
    lines.append(f"The person on this call is {called}. Address them as {called}, never by any other form of their name.");
    if prospect.headline {
        lines.append(f"Their headline reads: {prospect.headline}.");
    }
    if prospect.company {
        lines.append(f"They work at {prospect.company}.");
    }
    if quote {
        lines.append(f"In public they wrote, quote: {quote}. End quote.");
    }
    if artifact {
        lines.append(f"On GitHub they built or filed: {artifact}.");
    }
    if len(lane_names) > 1 {
        lines.append(
            "This person was found independently by "
            + f"{len(lane_names)} separate research lanes, which is why they were ranked first."
        );
    }
    if prospect.score_pre_crosslink > 0.0 {
        lines.append(
            f"Their match score rose from {prospect.score_pre_crosslink} to {prospect.score} "
            + "once the two profiles were cross-linked."
        );
    }
    if founder["one_liner"] {
        lines.append(f"The product being offered: {founder['one_liner']}.");
    }
    if founder["needs"] {
        lines.append(f"What the founder is asking for: {founder['needs']}.");
    }
    lines.append(
        "If asked how this helps them specifically, connect the product to the exact "
        + "problem they described in their own words above. Never invent a benefit "
        + "that is not grounded in what is written here."
    );
    return " ".join(lines);
}


"""Score a stored dossier against the caller's question with plain keyword overlap.

Deliberately not an embedding lookup and deliberately not an LLM call: this
runs while a human is waiting for the agent to speak.
"""
def relevance(question: str, text: str) -> float {
    words = [w for w in question.lower().split() if len(w) > 3];
    if not words {
        return 0.5;
    }
    lowered = text.lower();
    hits = 0;
    for w in words {
        if w in lowered {
            hits += 1;
        }
    }
    return float(hits) / float(len(words));
}


# ===========================================================================
# VAPI RESOURCE RESOLUTION
# ===========================================================================
# Ids are looked up rather than hardcoded, so a rotated phone number or a
# renamed assistant does not silently break the demo.

async def resolve_phone_number_id -> str {
    configured = cfg("VAPI_PHONE_NUMBER_ID", "");
    if configured {
        return configured;
    }
    wanted = cfg("VAPI_PHONE_NUMBER", "");
    listing = await http_json(
        "GET", f"{vapi_base()}/phone-number", vapi_headers(), None, 20.0, "vapi-phone-list"
    );
    numbers = listing.get("data", []) as list;
    for entry in numbers {
        item: dict = entry as dict;
        if (not wanted) or (str(item.get("number", "")) == wanted) {
            return str(item.get("id", ""));
        }
    }
    raise RuntimeError(
        f"vapi: no phone number matching '{wanted}' on this account. "
        + "Set VAPI_PHONE_NUMBER_ID in .env to pin one explicitly."
    );
}


async def resolve_assistant_id -> str {
    configured = cfg("VAPI_ASSISTANT_ID", "");
    if configured {
        return configured;
    }
    listing = await http_json(
        "GET", f"{vapi_base()}/assistant", vapi_headers(), None, 20.0, "vapi-assistant-list"
    );
    assistants = listing.get("data", []) as list;
    if not assistants {
        raise RuntimeError(
            "vapi: this account has no assistant. Create one in the Vapi dashboard "
            + "or set VAPI_ASSISTANT_ID in .env."
        );
    }
    first: dict = assistants[0] as dict;
    return str(first.get("id", ""));
}


"""The two tools the agent may call while the human is still on the line.

Each carries its own spoken messages. That is deliberate: the words the
prospect hears are fixed here rather than depending on how the model chooses to
narrate a JSON response, so the booking beat sounds the same on stage every
time even though the work behind it is genuinely live.
"""
def midcall_tools -> list[dict] {
    return [
        {
            "type": "function",
            "async": False,
            "function": {
                "name": "book_interview",
                "description": (
                    "Book the call with this person and email them a calendar invite "
                    + "containing a Google Meet link. Call this the moment they name a "
                    + "time that works, without asking them to confirm again."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "start_time": {
                            "type": "string",
                            "description": (
                                "When the meeting should start, as an ISO 8601 datetime "
                                + "with a timezone offset. Resolve relative phrasing like "
                                + "'tomorrow at 2' against the current date before calling. "
                                + "Leave empty only if they said as soon as possible."
                            )
                        },
                        "duration_minutes": {
                            "type": "number",
                            "description": "Meeting length in minutes. Default 30."
                        }
                    },
                    "required": ["start_time"]
                }
            },
            "messages": [
                {"type": "request-start", "content": "Booking that now."},
                {
                    "type": "request-complete",
                    "content": (
                        "Done. I have just sent the calendar invite to your email with a "
                        + "Google Meet link, it should be on your phone already."
                    )
                },
                {
                    "type": "request-failed",
                    "content": "I could not get that booked just now, I will follow up by email."
                }
            ],
            "server": {"url": public_url_for("/walker/BookInterview"), "timeoutSeconds": 25}
        },
        {
            "type": "function",
            "async": False,
            "function": {
                "name": "answer_from_graph",
                "description": (
                    "Look up what our research actually found about THIS person and use it "
                    + "to answer any question about why this is relevant to them. Call this "
                    + "whenever they ask how it helps them, why you are calling, or what you "
                    + "know about them."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "question": {
                            "type": "string",
                            "description": "The question they just asked, in their own words."
                        }
                    },
                    "required": ["question"]
                }
            },
            "server": {"url": public_url_for("/walker/KbQuery"), "timeoutSeconds": 10}
        }
    ];
}


# ===========================================================================
# WALKERS
# ===========================================================================

"""Place the outbound call and pre-cache everything it will need mid-flight.

earliestAt defaults to a few seconds out so the phone rings inside the demo
window rather than whenever Vapi's scheduler next wakes up.
"""
async walker:pub ScheduleCall(ProspectLookup) {
    has phone_number: str = "";
    has delay_seconds: int = 5;
    has dry_run: bool = False;
    has reports: list[dict] = [];

    async can place with Prospect entry {
        number: str = self.phone_number.strip();
        if not number {
            for thread in [here --> [?:EmailThread]] {
                for reply in [thread --> [?:ReplyEvent]] {
                    if reply.phone_number.strip() {
                        number = reply.phone_number.strip();
                    }
                }
            }
        }
        if not number {
            number = cfg("TEAMMATE_PHONE", "");
        }
        if not number {
            raise ValueError(
                f"no phone number for {here.name}: none supplied, none present in any "
                + "reply on the graph, and TEAMMATE_PHONE is unset"
            );
        }

        dossier = build_dossier(here);
        founder = founder_context();

        phone_id = await resolve_phone_number_id();
        assistant_id = await resolve_assistant_id();
        earliest = (
            datetime.now(timezone.utc) + timedelta(seconds=self.delay_seconds)
        ).isoformat().replace("+00:00", "Z");

        payload = {
            "phoneNumberId": phone_id,
            "assistantId": assistant_id,
            "customer": {"number": number, "name": here.name},
            "schedulePlan": {"earliestAt": earliest},
            "assistantOverrides": {
                "variableValues": {
                    "prospect_name": address_as(here),
                    "prospect_profile_name": here.name,
                    "prospect_headline": here.headline,
                    "prospect_company": here.company,
                    "linkedin_quote": best_linkedin_quote(here),
                    "github_artifact": best_github_artifact(here),
                    "founder_name": founder["name"],
                    "product_one_liner": founder["one_liner"],
                    "dossier": dossier
                },
                "firstMessage": (
                    f"Hi {address_as(here)}, this is an AI assistant calling on behalf of "
                    + f"{founder['name']}. You replied to our email a moment ago - is now "
                    + "still a good time?"
                ),
                "tools:append": midcall_tools(),
                "server": {"url": public_url_for("/walker/OnCallEnd"), "timeoutSeconds": 20},
                "serverMessages": ["end-of-call-report"]
            }
        };

        if self.dry_run {
            # Everything above is real - ids resolved from the live Vapi account,
            # dossier built from the graph, tool URLs resolved from the tunnel -
            # but no phone rings. Lets the payload be inspected during rehearsal.
            report {
                "ok": True,
                "dry_run": True,
                "prospect": here.name,
                "prospect_id": jid(here),
                "would_call": number,
                "phone_number_id": phone_id,
                "assistant_id": assistant_id,
                "earliest_at": earliest,
                "dossier_chars": len(dossier),
                "tool_urls": [
                    public_url_for("/walker/KbQuery"),
                    public_url_for("/walker/BookInterview")
                ],
                "server_url": public_url_for("/walker/OnCallEnd"),
                "payload": payload
            };
            disengage;
        }

        created = await http_json(
            "POST", f"{vapi_base()}/call", vapi_headers(), payload, 30.0, "vapi-create-call"
        );
        call_id = str(created.get("id", ""));
        if not call_id {
            raise RuntimeError(f"vapi-create-call: response carried no call id :: {created}");
        }

        session = here +>:Called(initiated_at=time.time()):+> CallSession(
            vapi_call_id=call_id,
            scheduled_at=earliest,
            phone_number=number,
            outcome=CallOutcome.SCHEDULED
        );
        session.kb_blob = dossier;
        KB_CACHE[call_id] = dossier;

        report {
            "ok": True,
            "prospect": here.name,
            "prospect_id": jid(here),
            "vapi_call_id": call_id,
            "to": number,
            "earliest_at": earliest,
            "call_session_jid": jid(session),
            "dossier_chars": len(dossier),
            "kb_endpoint": public_url_for("/walker/KbQuery"),
            "book_endpoint": public_url_for("/walker/BookInterview")
        };
        disengage;
    }
}


"""Locate a CallSession by its Vapi call id.

Checks both the production shape (hung off a Prospect by the Called edge) and a
session attached straight to root, so a rehearsal or a partially-built graph
still resolves rather than silently answering "no research on file".
"""
def find_call_session(vapi_call_id: str) -> CallSession | None {
    if not vapi_call_id {
        return None;
    }
    for prospect in [root --> [?:Prospect]] {
        for session in [prospect --> [?:CallSession]] {
            if session.vapi_call_id == vapi_call_id {
                return session;
            }
        }
    }
    for session in [root --> [?:CallSession]] {
        if session.vapi_call_id == vapi_call_id {
            return session;
        }
    }
    return None;
}


"""Pull the Vapi call id out of whichever callback shape arrived."""
def call_id_from(message: dict, fallback: str) -> str {
    call: dict = message.get("call", {}) as dict;
    found = str(call.get("id", ""));
    if found {
        return found;
    }
    return fallback;
}


"""Answer a mid-call question straight from the graph. No network, no LLM.

Responds in both the tool shape (`results`) and the custom-knowledge-base shape
(`documents`) so it is correct whichever way Vapi is wired to it.
"""
walker:pub KbQuery {
    has message: dict = {};
    has question: str = "";
    has call_id: str = "";
    has reports: list[dict] = [];

    can answer with Root entry {
        started = time.time();

        asked = self.question;
        tool_call_id = "";
        vapi_call = self.call_id;

        if self.message {
            vapi_call = call_id_from(self.message, self.call_id);
            tool_calls: list = self.message.get("toolCallList", []) as list;
            if tool_calls {
                first: dict = tool_calls[0] as dict;
                tool_call_id = str(first.get("id", ""));
                fn: dict = first.get("function", {}) as dict;
                args: dict = fn.get("arguments", {}) as dict;
                if not asked {
                    asked = str(args.get("question", ""));
                }
            }
            history: list = self.message.get("messages", []) as list;
            if (not asked) and history {
                last: dict = history[-1] as dict;
                asked = str(last.get("content", ""));
            }
        }

        # Hot path: the dossier was flattened at schedule time.
        blob = KB_CACHE.get(vapi_call, "");
        if not blob {
            found = find_call_session(vapi_call);
            if found is not None {
                blob = found.kb_blob;
                KB_CACHE[vapi_call] = blob;
            }
        }
        if not blob {
            blob = (
                "No research is on file for this call, so nothing specific can be claimed "
                + "about this person."
            );
        }

        elapsed_ms = (time.time() - started) * 1000.0;
        report {
            "results": [{"toolCallId": tool_call_id, "name": "answer_from_graph", "result": blob}],
            "documents": [{"content": blob, "similarity": relevance(asked, blob)}],
            "ok": True,
            "call_id": vapi_call,
            "question": asked,
            "elapsed_ms": elapsed_ms
        };
        disengage;
    }
}


"""Book the meeting mid-call: real event, real Meet link, invite to both parties.

Accepts the Vapi tool-call envelope and also plain fields, so the same walker
is callable from the dashboard and from a curl during rehearsal.
"""
async walker:pub BookInterview {
    has message: dict = {};
    has call_id: str = "";
    has prospect_id: str = "";
    has start_time: str = "";
    has duration_minutes: int = 0;
    has reports: list[dict] = [];

    async can book with Root entry {
        start = self.start_time;
        minutes = self.duration_minutes;
        tool_call_id = "";
        vapi_call = self.call_id;

        if self.message {
            vapi_call = call_id_from(self.message, self.call_id);
            tool_calls: list = self.message.get("toolCallList", []) as list;
            if tool_calls {
                first: dict = tool_calls[0] as dict;
                tool_call_id = str(first.get("id", ""));
                fn: dict = first.get("function", {}) as dict;
                args: dict = fn.get("arguments", {}) as dict;
                if not start {
                    start = str(args.get("start_time", ""));
                }
                if minutes <= 0 {
                    minutes = int(float(args.get("duration_minutes", 0) or 0));
                }
            }
        }

        target: Prospect | None = None;
        if self.prospect_id {
            candidate = jobj(self.prospect_id);
            if isinstance(candidate, Prospect) {
                target = candidate;
            }
        }
        if (target is None) and vapi_call {
            session = find_call_session(vapi_call);
            if session is not None {
                owner = [session <-- [?:Prospect]];
                if owner {
                    target = owner[0];
                }
            }
        }
        if target is None {
            raise ValueError(
                f"BookInterview: could not resolve who to book. call_id='{vapi_call}' "
                + f"prospect_id='{self.prospect_id}'"
            );
        }

        guest = target.email if target.email else cfg("TEAMMATE_EMAIL", "");
        if not guest {
            raise ValueError(
                f"BookInterview: {target.name} has no email address, so no invite could be sent"
            );
        }

        founder = founder_context();
        booked = await create_meeting(
            f"{founder['name']} and {target.name}",
            (
                "Booked live during a phone call by TRACTION.\n\n"
                + f"What we found: {best_linkedin_quote(target)}\n"
                + f"What they built: {best_github_artifact(target)}"
            ),
            start,
            [founder_email(), guest],
            minutes,
            30
        );

        record = target +>:Booked(booked_at=time.time()):+> Booking(
            event_id=str(booked["event_id"]),
            meet_link=str(booked["meet_link"]),
            start=str(booked["start"]),
            attendees=booked["attendees"],
            html_link=str(booked["html_link"])
        );

        spoken = (
            f"Booked for {booked['start']}. The invite is on its way to {guest} "
            + "with a Google Meet link."
        );
        report {
            "results": [{"toolCallId": tool_call_id, "name": "book_interview", "result": spoken}],
            "ok": True,
            "prospect": target.name,
            "prospect_id": jid(target),
            "event_id": booked["event_id"],
            "meet_link": booked["meet_link"],
            "html_link": booked["html_link"],
            "start": booked["start"],
            "attendees": booked["attendees"],
            "booking_jid": jid(record)
        };
        disengage;
    }
}



# Local LLM-facing mirror of contracts.CallInsight. An obj imported from another
# module cannot be a `by llm()` return type in Jac 0.34.7 - the annotation
# degrades to a string and byLLM's schema builder raises `'str' object has no
# attribute "fields"`. Fields are copied straight onto Insight nodes below.
obj LearnedFact {
    has claim: str;
    has evidence: str;
}
sem LearnedFact = "One durable fact learned about the prospect during a call - something that should still be true next week and that would change how we approach them next time.";
sem LearnedFact.claim = "The fact, stated in one sentence.";
sem LearnedFact.evidence = "The verbatim line from the transcript that supports it.";


def extract_insights(transcript: str, prospect_name: str) -> list[LearnedFact] by llm();

sem extract_insights = "Read a phone call transcript and pull out only durable facts about the person that would still be true next week and would change how someone approaches them next time. Skip pleasantries, scheduling chatter and anything about the call itself. Quote the transcript line that supports each fact. Return an empty list rather than padding with weak observations.";
sem extract_insights.transcript = "The full transcript of the call.";
sem extract_insights.prospect_name = "The person who was called.";


"""End-of-call report: store the transcript and distil it into Insight nodes.

This is the compounding-memory beat - what the system learns on one call is
hung off the graph and is there for the next one.
"""
walker:pub OnCallEnd {
    has message: dict = {};
    has call_id: str = "";
    has transcript: str = "";
    has reports: list[dict] = [];

    can absorb with Root entry {
        text = self.transcript;
        vapi_call = self.call_id;

        if self.message {
            vapi_call = call_id_from(self.message, self.call_id);
            if not text {
                artifact: dict = self.message.get("artifact", {}) as dict;
                text = str(artifact.get("transcript", ""));
            }
            if not text {
                text = str(self.message.get("transcript", ""));
            }
        }

        if not vapi_call {
            raise ValueError("OnCallEnd: no call id present in the payload");
        }

        self.transcript = text;
        found = find_call_session(vapi_call);
        if found is None {
            raise ValueError(
                f"OnCallEnd: no CallSession on the graph for vapi_call_id '{vapi_call}' - "
                + "the call was never scheduled through ScheduleCall, so there is nothing "
                + "to attach the transcript to"
            );
        }
        visit [found];
    }

    can record with CallSession entry {
        here.transcript = self.transcript;
        here.outcome = CallOutcome.COMPLETED;

        owner = [here <-- [?:Prospect]];
        who = owner[0].name if owner else "the prospect";

        learned: list[dict] = [];
        if self.transcript.strip() {
            for insight in extract_insights(self.transcript, who) {
                made = here +>:Learned(confidence=0.8):+> Insight(
                    claim=insight.claim,
                    evidence=insight.evidence,
                    learned_at=time.time()
                );
                learned.append({"claim": made.claim, "evidence": made.evidence});
            }
        }

        report {
            "ok": True,
            "prospect": who,
            "vapi_call_id": here.vapi_call_id,
            "transcript_chars": len(self.transcript),
            "insights": learned
        };
        disengage;
    }
}
