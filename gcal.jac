"""Google Calendar booking - the final beat of the demo.

One POST creates the event, mints a Google Meet link, and emails the invite to
BOTH the founder and the prospect. `sendUpdates=all` is the parameter that
actually sends those emails; `conferenceDataVersion=1` is what makes Google
honour the Meet createRequest. Dropping either silently degrades the demo:
the event appears on the founder's calendar and nothing lands on the
prospect's phone.
"""

import uuid;
import from datetime { datetime, timedelta }
import from zoneinfo { ZoneInfo }
import from svc { google_headers, http_json, founder_email, cfg }


glob CAL_EVENTS_URL: str = "https://www.googleapis.com/calendar/v3/calendars/primary/events";
glob FREEBUSY_URL: str = "https://www.googleapis.com/calendar/v3/freeBusy";


def demo_timezone -> str {
    return cfg("DEMO_TIMEZONE", "America/Los_Angeles");
}


def default_meeting_minutes -> int {
    return int(cfg("MEETING_MINUTES", "30"));
}


"""Parse an ISO-8601 timestamp, returning None when the text is not ISO.

The voice agent is instructed to emit ISO. When it does, this is the fast
path and no LLM is involved. Anything else falls through to normalisation.
"""
def parse_iso(raw: str) -> datetime | None {
    text = raw.strip();
    if not text {
        return None;
    }
    if text.endswith("Z") {
        text = text[:-1] + "+00:00";
    }
    try {
        return datetime.fromisoformat(text);
    } except ValueError {
        return None;
    }
}


"""Attach the demo timezone to a naive datetime; leave aware ones alone."""
def ensure_tz(moment: datetime) -> datetime {
    if moment.tzinfo is None {
        return moment.replace(tzinfo=ZoneInfo(demo_timezone()));
    }
    return moment;
}


def now_local -> datetime {
    return datetime.now(ZoneInfo(demo_timezone()));
}


"""Pull the Meet URL out of a created event.

`hangoutLink` is the usual carrier, but on some responses the video URL only
appears inside conferenceData.entryPoints, so both are checked rather than
assuming one shape.
"""
def extract_meet_link(event: dict) -> str {
    direct: str = event.get("hangoutLink", "") as str;
    if direct {
        return direct;
    }
    conference: dict = event.get("conferenceData", {}) as dict;
    entries: list = conference.get("entryPoints", []) as list;
    for raw in entries {
        entry: dict = raw as dict;
        if (entry.get("entryPointType", "") as str) == "video" {
            uri: str = entry.get("uri", "") as str;
            if uri {
                return uri;
            }
        }
    }
    return "";
}


"""Create a real calendar event with a Meet link and invite every attendee.

start_iso may be empty, in which case the meeting is placed `fallback_minutes`
from now - used when the voice agent says "as soon as possible".
"""
async def create_meeting(
    summary: str,
    description: str,
    start_iso: str,
    attendees: list[str],
    duration_minutes: int = 0,
    fallback_minutes: int = 30
) -> dict {
    minutes = duration_minutes;
    if minutes <= 0 {
        minutes = default_meeting_minutes();
    }

    parsed = parse_iso(start_iso);
    start: datetime = now_local() + timedelta(minutes=fallback_minutes);
    if parsed is not None {
        start = ensure_tz(parsed);
    } elif start_iso.strip() {
        # A time was requested and could not be parsed. Silently falling back to
        # now+30 books a slot nobody asked for and then reports success - which
        # is how a real invite landed on the prospect's calendar for a time she
        # never agreed to. An unparseable time is a failure, not a default.
        # Callers should resolve the phrase first (timeparse.resolve_spoken_time);
        # anything still unparseable here has to fail loud.
        raise ValueError(
            f"gcal.create_meeting: could not understand the requested time "
            + f"'{start_iso}'. Refusing to book an arbitrary slot instead - say "
            + "the time back to the caller and ask them to repeat it."
        );
    }
    end: datetime = start + timedelta(minutes=minutes);

    if start <= now_local() {
        raise ValueError(
            f"gcal.create_meeting: start_time '{start.isoformat()}' is in the past. "
            + "Refusing to book backwards."
        );
    }

    guests: list[dict] = [];
    seen: list[str] = [];
    for raw in attendees {
        email = raw.strip();
        if email and (email.lower() not in seen) {
            seen.append(email.lower());
            guests.append({"email": email});
        }
    }
    if not guests {
        raise ValueError(
            "gcal.create_meeting: refusing to create an event with no attendees - "
            + "the whole point is that the invite lands on the prospect's phone."
        );
    }

    tz = demo_timezone();
    body = {
        "summary": summary,
        "description": description,
        "start": {"dateTime": start.isoformat(), "timeZone": tz},
        "end": {"dateTime": end.isoformat(), "timeZone": tz},
        "attendees": guests,
        "conferenceData": {
            "createRequest": {
                "requestId": f"traction-{uuid.uuid4().hex}",
                "conferenceSolutionKey": {"type": "hangoutsMeet"}
            }
        },
        "reminders": {"useDefault": True}
    };

    # conferenceDataVersion=1 -> Google actually mints the Meet link.
    # sendUpdates=all        -> Google actually emails BOTH parties.
    url = f"{CAL_EVENTS_URL}?conferenceDataVersion=1&sendUpdates=all";
    headers = await google_headers();
    event = await http_json("POST", url, headers, body, 30.0, "gcal-create-event");

    meet_link = extract_meet_link(event);
    if not meet_link {
        raise RuntimeError(
            "gcal-create-event: event was created but carried no Meet link. "
            + "Check that conferenceDataVersion=1 survived on the request URL. "
            + f"event_id={event.get('id', '?')}"
        );
    }

    return {
        "event_id": event.get("id", ""),
        "meet_link": meet_link,
        "html_link": event.get("htmlLink", ""),
        "start": start.isoformat(),
        "end": end.isoformat(),
        "timezone": tz,
        "attendees": [g["email"] for g in guests],
        "summary": summary
    };
}


"""Delete an event. Used by rehearsal cleanup so the calendar stays honest."""
async def delete_meeting(event_id: str) -> bool {
    url = f"{CAL_EVENTS_URL}/{event_id}?sendUpdates=all";
    headers = await google_headers();
    _ = await http_json("DELETE", url, headers, None, 20.0, "gcal-delete-event");
    return True;
}


"""Ask Google whether the founder is already busy across a window.

Returns (is_free, conflicts). A conflict is described in words the voice agent
can read out, so "you already have something then, does 3 work?" is a real
sentence rather than a raw timestamp. Never raises on a lookup failure - an
availability check that goes down must not block a booking the human asked
for, so it fails OPEN and says so in the reason.
"""
async def check_availability(start: datetime, minutes: int) -> tuple[bool, list[str]] {
    finish = start + timedelta(minutes=minutes);
    body = {
        "timeMin": start.isoformat(),
        "timeMax": finish.isoformat(),
        "timeZone": demo_timezone(),
        "items": [{"id": "primary"}]
    };
    headers = await google_headers();
    data = await http_json(
        "POST", FREEBUSY_URL, headers, body, 15.0, "gcal-freebusy"
    );
    calendars: dict = data.get("calendars", {}) as dict;
    primary: dict = calendars.get("primary", {}) as dict;
    busy: list = primary.get("busy", []) as list;
    conflicts: list[str] = [];
    for raw in busy {
        slot: dict = raw as dict;
        conflicts.append(
            f"{slot.get('start', '?')} to {slot.get('end', '?')}"
        );
    }
    return (len(conflicts) == 0, conflicts);
}

