"""Live proof: a spoken phrase becomes the exact slot Google actually stores.

Runs against the REAL Google Calendar. Every event is created ~400 days out
with the founder as the only attendee - no prospect is ever emailed - and each
one is deleted at the end. The point is not that an event can be created; that
was already known. The point is that the slot Google STORES equals the slot the
resolver derived from the words a human said, and that the sentence the agent
would speak describes that stored slot rather than the request.

For each phrase:
  1. resolve the phrase against an anchor 400 days out
  2. create the real event at that ISO
  3. RE-READ the event back from Google independently
  4. assert stored start == resolved start
  5. render the sentence the agent would speak
  6. delete

Run from an isolated clone only:  jac run live_booking_proof.jac
"""

import asyncio;
import from datetime { datetime, timedelta }
import from zoneinfo { ZoneInfo }
import from timeparse { resolve_spoken_time, speak_datetime }
import from gcal {
    create_meeting, delete_meeting, demo_timezone, now_local, CAL_EVENTS_URL
}
import from svc { google_headers, http_json, founder_email }


glob PHRASES: list[str] = [
    "Thursday at 2",
    "tomorrow afternoon",
    "next Tuesday morning",
    "3:30 my time",
    "9am Eastern on Wednesday"
];


"""Read an event straight back from Google - the only trustworthy confirmation."""
async def reread(event_id: str) -> dict {
    headers = await google_headers();
    return await http_json(
        "GET", f"{CAL_EVENTS_URL}/{event_id}", headers, None, 20.0, "gcal-reread"
    );
}


async def main -> None {
    tz = demo_timezone();
    anchor = now_local() + timedelta(days=400);
    print("=" * 100);
    print("  LIVE: spoken phrase -> resolved slot -> what Google actually stored");
    print(f"  anchor now : {anchor.isoformat()} ({anchor.strftime('%A')})");
    print(f"  calendar tz: {tz}   attendee: {founder_email()} only");
    print("=" * 100);

    created: list[str] = [];
    failures: int = 0;

    for phrase in PHRASES {
        print("");
        print(f'PHRASE  "{phrase}"');
        slot = resolve_spoken_time(phrase, anchor, tz, "");
        resolved = str(slot["iso"]);
        print(f"  resolved      {resolved}   ({slot['basis']})");

        booked = await create_meeting(
            "TRACTION booking verification - safe to ignore",
            f"Automated check. Heard: {phrase}. Deleted immediately after.",
            resolved,
            [founder_email()],
            30,
            30
        );
        event_id = str(booked["event_id"]);
        created.append(event_id);

        fresh = await reread(event_id);
        start_block: dict = fresh.get("start", {}) as dict;
        stored = str(start_block.get("dateTime", ""));
        stored_tz = str(start_block.get("timeZone", ""));

        same = (
            datetime.fromisoformat(stored).astimezone(ZoneInfo(tz))
            == datetime.fromisoformat(resolved).astimezone(ZoneInfo(tz))
        );
        if not same {
            failures += 1;
        }
        mark = "ok  " if same else "FAIL";
        print(f"  {mark}google saw  {stored}  tz={stored_tz}");
        print(f"  event_id      {event_id}");
        print(f"  meet_link     {booked['meet_link']}");
        print(f"  agent says    \"Booked for {speak_datetime(datetime.fromisoformat(stored), tz)}.\"");
    }

    print("");
    print("-" * 100);
    for event_id in created {
        _ = await delete_meeting(event_id);
        print(f"  deleted {event_id}");
    }

    print("");
    print("=" * 100);
    if failures == 0 {
        print(f"  PASS - {len(PHRASES)} phrases booked at exactly the resolved slot, all cleaned up");
    } else {
        print(f"  FAIL - {failures} slot(s) did not match what Google stored");
    }
    print("=" * 100);
}


with entry:__main__ {
    asyncio.run(main());
}
