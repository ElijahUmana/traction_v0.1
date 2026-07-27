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
import json;
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
import from gcal {
    create_meeting, check_availability, now_local, demo_timezone, default_meeting_minutes
}
import from timeparse { resolve_spoken_time, validate_iso_hint, speak_datetime }

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


"""Spell a name so text-to-speech says it the way a human does.

The live call rendered "Elijah Umana" as "Elijah Yamana". The prospect hears
the founder's name mispronounced in the first sentence, which is a small thing
that sounds exactly like a robocall. Hyphenating the syllables fixes it without
changing anything the recipient sees in writing.
"""
def speakable_name(name: str) -> str {
    overrides = cfg("SPOKEN_NAME", "");
    if overrides {
        return overrides;
    }
    return name;
}


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
                                "Your best attempt at the start time as an ISO 8601 "
                                + "datetime with a timezone offset. If you are not "
                                + "certain of today's date, leave this empty and fill "
                                + "in spoken_time only - the server resolves it against "
                                + "the real clock."
                            )
                        },
                        "spoken_time": {
                            "type": "string",
                            "description": (
                                "REQUIRED. The time exactly as the person said it, in "
                                + "their own words - 'thursday at 2', 'tomorrow "
                                + "afternoon', '3:30 my time'. Do not reword it, do not "
                                + "convert it, do not resolve it. This is the server's "
                                + "authoritative record of what was actually asked for."
                            )
                        },
                        "duration_minutes": {
                            "type": "number",
                            "description": "Meeting length in minutes. Default 30."
                        }
                    },
                    "required": ["spoken_time"]
                }
            },
            # There is deliberately NO static request-complete message here.
            # Vapi speaks a static request-complete INSTEAD of the tool result,
            # so a fixed string makes the agent claim "invite sent" no matter
            # what actually happened - including when the tool 500s. That is
            # exactly what was heard on call 019fa100. Leaving it out forces the
            # model to narrate the returned line, which carries the real date,
            # time and timezone the human needs in order to catch an error.
            "messages": [
                {"type": "request-start", "content": "Let me get that booked."},
                {
                    "type": "request-failed",
                    "role": "system",
                    "content": (
                        "The booking did not go through. Tell them plainly that it did "
                        + "not work - never imply an invite was sent - say briefly why "
                        + "based on the error, and offer to follow up by email."
                    )
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
                    + f"{speakable_name(founder['name'])}. You replied to our email a moment "
                    + "ago - is now still a good time?"
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


"""The timezone a spoken time should be interpreted in for this prospect.

We do NOT guess. Nothing on the Prospect node records where anyone is - there
is no location field anywhere in the schema - so reasoning "Becky is at Oracle
therefore Pacific" would be a three-hour error waiting to happen. Unless
PROSPECT_TIMEZONE is set deliberately, this returns empty, meaning the spoken
time is read in the founder's calendar zone and the agent SAYS that zone out
loud. Naming the zone is what lets the human correct it while still on the
phone; an inferred zone that is never spoken is the failure we are avoiding.
"""
def prospect_timezone(target: Prospect) -> str {
    return cfg("PROSPECT_TIMEZONE", "");
}


"""Re-derive the spoken sentence from what Google stored, not what we sent.

`create_meeting` returns the start Google actually wrote. Speaking that back,
rather than echoing the request, is the control that catches a slot Google
moved or a timezone reinterpreted on the way out.
"""
def confirmed_slot(stored_iso: str) -> str {
    moment = datetime.fromisoformat(stored_iso);
    return speak_datetime(moment, demo_timezone());
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


"""Extract the tool call from whichever key Vapi actually used.

Vapi sends the invocation under `toolCallList` in some payloads and `toolCalls`
in others, and which one arrives is not ours to choose. Reading only
`toolCallList` is how a live call produced an EMPTY toolCallId and an EMPTY
question: the wire carried `toolCalls`, every field silently defaulted, and the
endpoint returned 200 with an empty answer. Nothing errored, which is the worst
kind of failure because it looks like success. The earlier envelope proof passed
for exactly this reason - it fed the shape this code expected instead of the
shape Vapi sends.
"""
def first_tool_call(message: dict) -> dict {
    for key in ["toolCallList", "toolCalls", "tool_calls"] {
        raw: list = message.get(key, []) as list;
        if raw {
            entry: dict = raw[0] as dict;
            return entry;
        }
    }
    empty: dict = {};
    return empty;
}


"""Tool arguments, whether Vapi sent them as an object or a JSON-encoded string."""
def tool_arguments(call: dict) -> dict {
    fn: dict = call.get("function", {}) as dict;
    raw = fn.get("arguments", {});
    if isinstance(raw, str) {
        text: str = raw as str;
        if not text.strip() {
            blank: dict = {};
            return blank;
        }
        try {
            parsed = json.loads(text);
        } except Exception {
            bad: dict = {};
            return bad;
        }
        if isinstance(parsed, dict) {
            ok: dict = parsed as dict;
            return ok;
        }
        other: dict = {};
        return other;
    }
    direct: dict = raw as dict;
    return direct;
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
            call: dict = first_tool_call(self.message);
            if call {
                tool_call_id = str(call.get("id", ""));
                args: dict = tool_arguments(call);
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
        resolved_by = "cache";
        blob = KB_CACHE.get(vapi_call, "");
        if not blob {
            resolved_by = "graph";
        }
        if not blob {
            found = find_call_session(vapi_call);
            if found is not None {
                blob = found.kb_blob;
                KB_CACHE[vapi_call] = blob;
            }
        }
        if not blob {
            # Vapi can report a call id we never stored (a retried or re-created
            # call). With exactly one call session on the graph there is no
            # ambiguity about who is on the phone, so answer rather than stall.
            # With several, guessing could describe the WRONG person to them -
            # so we say nothing instead.
            sessions = [root --> [?:Prospect] --> [?:CallSession]];
            if len(sessions) == 1 and sessions[0].kb_blob {
                blob = sessions[0].kb_blob;
                resolved_by = "sole-session";
            }
        }
        if not blob {
            blob = (
                "No research is on file for this call, so nothing specific can be claimed "
                + "about this person."
            );
            resolved_by = "none";
        }

        elapsed_ms = (time.time() - started) * 1000.0;
        report {
            "results": [{"toolCallId": tool_call_id, "name": "answer_from_graph", "result": blob}],
            "documents": [{"content": blob, "similarity": relevance(asked, blob)}],
            "ok": True,
            "call_id": vapi_call,
            "question": asked,
            "resolved_by": resolved_by,
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
    has spoken_time: str = "";
    has duration_minutes: int = 0;
    has reports: list[dict] = [];

    async can book with Root entry {
        start = self.start_time;
        spoken = self.spoken_time;
        minutes = self.duration_minutes;
        tool_call_id = "";
        vapi_call = self.call_id;

        if self.message {
            vapi_call = call_id_from(self.message, self.call_id);
            call: dict = first_tool_call(self.message);
            if call {
                tool_call_id = str(call.get("id", ""));
                args: dict = tool_arguments(call);
                if not start {
                    start = str(args.get("start_time", ""));
                }
                if not spoken {
                    spoken = str(args.get("spoken_time", ""));
                }
                if minutes <= 0 {
                    minutes = int(float(args.get("duration_minutes", 0) or 0));
                }
            }
        }

        # Log what ARRIVED, before anything interprets it. Without this line the
        # only way to tell a fallback from a real parse was to notice that a
        # booked start carried microseconds - which is how the 17:58:27.383985
        # event on Becky's calendar was eventually diagnosed. Never again.
        print(
            f"[BookInterview] raw start_time={start!r} spoken_time={spoken!r} "
            + f"duration={minutes} call_id={vapi_call!r} tool_call_id={tool_call_id!r}"
        );

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

        # ------------------------------------------------------------------
        # Resolve WHEN. The server is the authority, not the model.
        #
        # The model's ISO is only a hint: accepted if it parses, lands in the
        # future, and sits inside the booking horizon. A hallucinated year or a
        # "today" carried over from the training cutoff fails those tests, and
        # we fall back to parsing the phrase the human actually said against
        # the real clock. If neither yields a slot we raise rather than guess.
        # ------------------------------------------------------------------
        clock = now_local();
        slot = validate_iso_hint(start, clock, demo_timezone());
        if slot is None {
            phrase = spoken if spoken.strip() else start;
            if not phrase.strip() {
                raise ValueError(
                    "BookInterview: no usable time arrived - start_time was "
                    + f"'{start}' and spoken_time was '{spoken}'. Refusing to invent a slot."
                );
            }
            slot = resolve_spoken_time(
                phrase, clock, demo_timezone(), prospect_timezone(target)
            );
        }
        print(
            f"[BookInterview] resolved -> {slot['iso']} via {slot['basis']} "
            + f"(speaker_tz={slot['speaker_tz']}, ambiguous={slot['ambiguous']})"
        );

        if minutes <= 0 {
            minutes = default_meeting_minutes();
        }

        # Availability is advisory: a lookup failure must never block a booking
        # the human just asked for out loud, so it is reported, never enforced.
        free = True;
        conflicts: list[str] = [];
        availability_checked = True;
        try {
            (free, conflicts) = await check_availability(slot["start"], minutes);
        } except Exception as probe_err {
            availability_checked = False;
            conflicts = [f"availability lookup failed: {probe_err}"];
        }

        founder = founder_context();
        booked = await create_meeting(
            f"{founder['name']} and {target.name}",
            (
                "Booked live during a phone call by TRACTION.\n\n"
                + f"Heard on the call: \"{slot['heard']}\"\n"
                + f"Resolved to: {slot['spoken_back']} ({slot['basis']})\n\n"
                + f"What we found: {best_linkedin_quote(target)}\n"
                + f"What they built: {best_github_artifact(target)}"
            ),
            str(slot["iso"]),
            [founder_email(), guest],
            minutes,
            30
        );

        # Speak back what Google ACTUALLY stored, re-derived from its response -
        # not the string we sent and not the phrase we heard. Reading the raw
        # ISO here is what produced "Booked for 2026-07-26T17:58:27.383985-07:00"
        # over TTS: unintelligible, so nobody could catch the wrong slot.
        confirmed = confirmed_slot(str(booked["start"]));

        record = target +>:Booked(booked_at=time.time()):+> Booking(
            event_id=str(booked["event_id"]),
            meet_link=str(booked["meet_link"]),
            start=str(booked["start"]),
            attendees=booked["attendees"],
            html_link=str(booked["html_link"])
        );

        spoken_line: str = (
            f"Booked for {confirmed}. The invite is on its way to {guest} now, "
            + "with a Google Meet link."
        );
        if not free {
            spoken_line = (
                f"Booked for {confirmed}, though {founder['name']} already has "
                + "something on the calendar then, so he may need to move it. The "
                + f"invite is on its way to {guest} with a Google Meet link."
            );
        }

        report {
            "results": [
                {"toolCallId": tool_call_id, "name": "book_interview", "result": spoken_line}
            ],
            "ok": True,
            "prospect": target.name,
            "prospect_id": jid(target),
            "event_id": booked["event_id"],
            "meet_link": booked["meet_link"],
            "html_link": booked["html_link"],
            "start": booked["start"],
            "attendees": booked["attendees"],
            "booking_jid": jid(record),
            "heard": slot["heard"],
            "resolved_by": slot["basis"],
            "speaker_timezone": slot["speaker_tz"],
            "timezone_source": slot["source_tz"],
            "ambiguous": slot["ambiguous"],
            "spoken_confirmation": spoken_line,
            "calendar_free": free,
            "availability_checked": availability_checked,
            "conflicts": conflicts
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
            # Vapi posts EVERY server message to this URL - conversation-update,
            # speech-update, status-update - not only the end-of-call report.
            # The live call produced ~20 of them in 18 seconds, and each one was
            # re-running insight extraction against a partial transcript: an LLM
            # call per message, for an answer that is thrown away and rewritten
            # by the next one. Only the final report is worth acting on.
            kind = str(self.message.get("type", ""));
            if kind and kind != "end-of-call-report" {
                report {"ok": True, "ignored": kind};
                disengage;
            }
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
        insight_source = "llm";
        degraded_reason = "";
        facts: list[LearnedFact] = [];
        if self.transcript.strip() {
            try {
                facts = extract_insights(self.transcript, who);
            } except Exception as e {
                # The transcript is already safely on the graph above. Insights
                # are compounding memory for the NEXT call, so losing them costs
                # future value, not this call - never fail the callback for it.
                insight_source = "unavailable";
                degraded_reason = str(e)[:300];
                facts = [];
                print(f"[traction] OnCallEnd: insight extraction unavailable "
                      + f"({degraded_reason}) - transcript is stored, insights skipped");
            }
            for insight in facts {
                fact: LearnedFact = insight as LearnedFact;
                made = here +>:Learned(confidence=0.8):+> Insight(
                    claim=fact.claim,
                    evidence=fact.evidence,
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
            "insights": learned,
            "insight_source": insight_source,
            "degraded_reason": degraded_reason
        };
        disengage;
    }
}
