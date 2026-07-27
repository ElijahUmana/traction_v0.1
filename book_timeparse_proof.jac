"""Proof that a spoken time becomes the correct absolute slot.

Runs the resolver against a FIXED anchor - Sunday 26 July 2026, 17:22 Pacific -
so every row is reproducible and the expected column can be asserted rather
than eyeballed. A drifting `now` would make this harness prove nothing.

Three sections:
  1. RESOLUTION  - phrases that must land on an exact datetime
  2. REFUSAL     - phrases that must RAISE rather than guess a slot
  3. ISO HINT    - the model's ISO attempt, accepted only when it survives
                   validation, so a hallucinated year cannot reach Google

Run:  jac run book_timeparse_proof.jac
"""

import from datetime { datetime }
import from zoneinfo { ZoneInfo }
import from timeparse { resolve_spoken_time, validate_iso_hint, speak_datetime }


glob CAL_TZ: str = "America/Los_Angeles";

# Sunday 26 July 2026, 17:22:00 Pacific.
glob ANCHOR: datetime = datetime(
    2026, 7, 26, 17, 22, 0, tzinfo=ZoneInfo("America/Los_Angeles")
);


# (phrase, prospect_default_tz, expected_iso)
glob RESOLUTION_CASES: list[tuple[str, str, str]] = [
    ("Thursday at 2",                        "", "2026-07-30T14:00:00-07:00"),
    ("tomorrow afternoon",                   "", "2026-07-27T14:00:00-07:00"),
    ("how about 3:30 my time",               "", "2026-07-27T15:30:00-07:00"),
    ("next Tuesday morning",                 "", "2026-08-04T10:00:00-07:00"),
    ("Thursday at 2pm Eastern",              "", "2026-07-30T11:00:00-07:00"),
    ("does Friday at 9 work for you",        "", "2026-07-31T09:00:00-07:00"),
    ("tomorrow at noon",                     "", "2026-07-27T12:00:00-07:00"),
    ("two thirty tomorrow",                  "", "2026-07-27T14:30:00-07:00"),
    ("half past ten on Wednesday",           "", "2026-07-29T10:30:00-07:00"),
    ("August 5th at 4",                      "", "2026-08-05T16:00:00-07:00"),
    ("8/5 at 11am",                          "", "2026-08-05T11:00:00-07:00"),
    ("this Friday at 3:30 in the afternoon", "", "2026-07-31T15:30:00-07:00"),
    ("monday at 8 in the morning",           "", "2026-07-27T08:00:00-07:00"),
    ("today at 6",                           "", "2026-07-26T18:00:00-07:00"),
    ("noon on Thursday",                     "", "2026-07-30T12:00:00-07:00"),
    ("9am Central on Tuesday",               "", "2026-07-28T07:00:00-07:00"),
    ("quarter past four on Friday",          "", "2026-07-31T16:15:00-07:00"),
    ("day after tomorrow at 1",              "", "2026-07-28T13:00:00-07:00"),
    ("in an hour",                           "", "2026-07-26T18:22:00-07:00"),
    ("in 45 minutes",                        "", "2026-07-26T18:07:00-07:00"),
    ("let's say Thursday at two thirty",     "", "2026-07-30T14:30:00-07:00"),
    ("Thursday at 2 my time",                "America/New_York", "2026-07-30T11:00:00-07:00"),
    ("4pm my time",                          "America/New_York", "2026-07-27T13:00:00-07:00"),
    ("Thursday at 2 your time",              "America/New_York", "2026-07-30T14:00:00-07:00"),
    ("wednesday at 10 UK time",              "", "2026-07-29T02:00:00-07:00")
];

# Phrases the resolver must REFUSE. Guessing here is the silent failure.
glob REFUSAL_CASES: list[tuple[str, str]] = [
    ("",                    "empty phrase"),
    ("sometime soon",       "no time in the phrase"),
    ("Thursday",            "a day with no time is not a slot"),
    ("today at 9 in the morning", "resolves into the past"),
    ("whenever suits you",  "no time in the phrase")
];

# (iso_from_model, must_be_accepted, why)
glob ISO_HINT_CASES: list[tuple[str, bool, str]] = [
    ("2026-07-30T14:00:00-07:00", True,  "well-formed and in the future"),
    ("2026-07-30T14:00:00",       True,  "naive - adopts the calendar timezone"),
    ("2026-07-30T21:00:00Z",      True,  "Z suffix normalises to +00:00"),
    ("2024-07-30T14:00:00-07:00", False, "hallucinated year - lands in the past"),
    ("2025-07-31T14:00:00-07:00", False, "stale training-cutoff year"),
    ("Thursday at 2",             False, "model emitted prose, not ISO"),
    ("",                          False, "model emitted nothing"),
    ("2027-12-01T10:00:00-08:00", False, "beyond the 180-day horizon")
];


def pad(text: str, width: int) -> str {
    if len(text) >= width {
        return text;
    }
    return text + (" " * (width - len(text)));
}


with entry:__main__ {
    print("=" * 108);
    print("  TRACTION - spoken time -> booked slot");
    print(f"  anchor now : {ANCHOR.isoformat()}  ({ANCHOR.strftime('%A')})");
    print(f"  calendar tz: {CAL_TZ}");
    print("=" * 108);

    failures: int = 0;

    print("");
    print("1. RESOLUTION - what the human says becomes an exact slot");
    print("-" * 108);
    print(
        "  " + pad("PHRASE", 38) + pad("THEIR TZ", 19)
        + pad("RESOLVED (Pacific)", 27) + "BASIS"
    );
    print("-" * 108);
    for (phrase, their_tz, expected) in RESOLUTION_CASES {
        got: str = "";
        basis: str = "";
        spoken: str = "";
        flag: str = "";
        try {
            result = resolve_spoken_time(phrase, ANCHOR, CAL_TZ, their_tz);
            got = str(result["iso"]);
            basis = str(result["basis"]);
            spoken = str(result["spoken_back"]);
            if result["ambiguous"] {
                flag = " [ambiguous - agent must read the date back]";
            }
        } except Exception as err {
            got = f"RAISED: {err}";
        }
        ok: bool = (got == expected);
        if not ok {
            failures += 1;
        }
        mark: str = "ok " if ok else "FAIL";
        shown: str = their_tz if their_tz else "-";
        print(
            f"{mark} " + pad(f'"{phrase}"', 38) + pad(shown, 19)
            + pad(got, 27) + basis + flag
        );
        if not ok {
            print(f"     expected: {expected}");
        } else {
            print(f"     says: \"{spoken}\"");
        }
    }

    print("");
    print("2. REFUSAL - an unresolvable phrase raises instead of guessing a slot");
    print("-" * 108);
    for (phrase, why) in REFUSAL_CASES {
        raised: bool = False;
        detail: str = "";
        try {
            outcome = resolve_spoken_time(phrase, ANCHOR, CAL_TZ, "");
            detail = f"booked {outcome['iso']} anyway";
        } except Exception as err {
            raised = True;
            detail = str(err).split(" - ")[0];
        }
        if not raised {
            failures += 1;
        }
        mark: str = "ok " if raised else "FAIL";
        print(f"{mark} " + pad(f'"{phrase}"', 32) + pad(why, 32) + detail[:44]);
    }

    print("");
    print("3. ISO HINT - the model's ISO is a hint, never the authority");
    print("-" * 108);
    for (raw, should_accept, why) in ISO_HINT_CASES {
        verdict = validate_iso_hint(raw, ANCHOR, CAL_TZ);
        accepted: bool = verdict is not None;
        ok: bool = (accepted == should_accept);
        if not ok {
            failures += 1;
        }
        mark: str = "ok " if ok else "FAIL";
        action: str = "ACCEPTED" if accepted else "rejected -> parse the phrase";
        print(f"{mark} " + pad(f'"{raw}"', 30) + pad(action, 30) + why);
    }

    print("");
    print("=" * 108);
    if failures == 0 {
        print(f"  PASS - {len(RESOLUTION_CASES)} resolutions, "
              + f"{len(REFUSAL_CASES)} refusals, {len(ISO_HINT_CASES)} hint checks, 0 failures");
    } else {
        print(f"  FAIL - {failures} case(s) wrong. The booking path is NOT safe to demo.");
    }
    print("=" * 108);
}
