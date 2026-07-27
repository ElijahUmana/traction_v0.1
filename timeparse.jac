"""Turn a spoken time into an exact calendar slot - deterministically.

WHY THIS EXISTS
---------------
The booking path used to trust the voice model to emit ISO-8601. That is a
single point of silent failure in three separate ways:

  1. The model has no grounded "today". Asked to resolve "Thursday at 2" it
     answers against its training cutoff and confidently returns a date in
     the wrong year. Nothing in the response looks wrong.
  2. If the model emits prose instead of ISO, `gcal.parse_iso` returns None
     and the old `create_meeting` silently booked `now + 30 minutes` while
     the agent said "invite sent". The human hears success and gets a slot
     nobody asked for.
  3. A bare hour is genuinely ambiguous. "Two" is 14:00 in every business
     conversation ever held, and 02:00 to a naive parser.

So the server, not the model, is the authority on what time was spoken. The
model's ISO attempt is treated as a HINT that must survive validation; the
raw phrase the human actually said is parsed here against the real clock.
Anything that cannot be resolved raises - it never guesses a slot.

TIMEZONE DOCTRINE
-----------------
Every returned moment is tz-aware and expressed in the founder's calendar
timezone (DEMO_TIMEZONE, America/Los_Angeles). A spoken time is interpreted
in `speaker_tz`, which is the founder's zone unless the human named a zone
("three thirty Eastern") or said "my time" and we know the prospect's zone.
The interpretation is returned in `basis` so it can be spoken back and
audited. An implicit timezone is the one that produces a three-hour error
nobody notices until the meeting is missed.
"""

import re;
import from datetime { datetime, timedelta }
import from zoneinfo { ZoneInfo }


# --------------------------------------------------------------------------
# Vocabulary
# --------------------------------------------------------------------------

glob WEEKDAYS: dict[str, int] = {
    "monday": 0, "mon": 0, "tuesday": 1, "tues": 1, "tue": 1,
    "wednesday": 2, "weds": 2, "wed": 2, "thursday": 3, "thurs": 3, "thur": 3,
    "thu": 3, "friday": 4, "fri": 4, "saturday": 5, "sat": 5,
    "sunday": 6, "sun": 6
};

glob MONTHS: dict[str, int] = {
    "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3,
    "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7,
    "august": 8, "aug": 8, "september": 9, "sept": 9, "sep": 9,
    "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12
};

# Spoken numerals. Voice transcripts carry "two thirty" as often as "2:30".
glob NUMWORDS: dict[str, int] = {
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
    "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
    "thirty": 30, "forty": 40, "forty-five": 45, "fortyfive": 45, "fifty": 50
};

# Named parts of the day, and the hour a business meeting actually lands on.
glob DAYPARTS: dict[str, int] = {
    "morning": 10, "afternoon": 14, "evening": 17, "tonight": 17,
    "noon": 12, "midday": 12, "midnight": 0, "lunch": 12,
    "lunchtime": 12, "breakfast": 9
};

# Zone words a human says out loud -> IANA zone.
glob ZONEWORDS: dict[str, str] = {
    "eastern": "America/New_York", "eest": "America/New_York",
    "est": "America/New_York", "edt": "America/New_York",
    "et": "America/New_York", "east coast": "America/New_York",
    "new york": "America/New_York",
    "central": "America/Chicago", "cst": "America/Chicago",
    "cdt": "America/Chicago", "ct": "America/Chicago",
    "chicago": "America/Chicago",
    "mountain": "America/Denver", "mst": "America/Denver",
    "mdt": "America/Denver", "mt": "America/Denver",
    "denver": "America/Denver",
    "pacific": "America/Los_Angeles", "pst": "America/Los_Angeles",
    "pdt": "America/Los_Angeles", "pt": "America/Los_Angeles",
    "west coast": "America/Los_Angeles", "california": "America/Los_Angeles",
    "los angeles": "America/Los_Angeles",
    "utc": "UTC", "gmt": "UTC",
    "uk": "Europe/London", "london": "Europe/London", "bst": "Europe/London",
    "ist": "Asia/Kolkata", "india": "Asia/Kolkata"
};

# Filler that survives transcription and would otherwise confuse the matcher.
glob FILLER: list[str] = [
    "how about", "what about", "can we do", "could we do", "let's do",
    "lets do", "let's say", "lets say", "does", "work for you", "work",
    "sounds good", "maybe", "perhaps", "i think", "um", "uh", "like",
    "sure", "yeah", "yes", "okay", "ok", "please", "would", "could",
    "is fine", "fine", "great", "perfect", "book me for", "book for",
    "put me down for", "pencil me in for", "schedule me for", "how's", "hows"
];

glob MAX_HORIZON_DAYS: int = 180;


# --------------------------------------------------------------------------
# Normalisation
# --------------------------------------------------------------------------

"""Lower-case, strip punctuation and conversational filler.

Runs longest-filler-first so "how about" is removed before the bare "about"
inside it can strand a fragment.
"""
def normalise(raw: str) -> str {
    text: str = raw.lower().strip();
    text = text.replace("o'clock", "").replace("oclock", "");
    text = re.sub(r"[,!?\"]", " ", text);
    text = text.replace(".", " ");
    ordered: list[str] = sorted(FILLER, key=len, reverse=True);
    for word in ordered {
        text = re.sub(r"\b" + re.escape(word) + r"\b", " ", text);
    }
    text = re.sub(r"\s+", " ", text).strip();
    return text;
}


"""Rewrite spoken numerals into digits so one regex handles both spellings.

"two thirty" -> "2:30", "half past two" -> "2:30", "quarter past three"
-> "3:15", "quarter to four" -> "3:45", bare "two" -> "2".
"""
def digitise(text: str) -> str {
    out: str = text;

    # "half past two" / "quarter past three" / "quarter to four"
    for (word, num) in NUMWORDS.items() {
        if num >= 1 and num <= 12 {
            out = re.sub(
                r"\bhalf past " + word + r"\b", f"{num}:30", out
            );
            out = re.sub(
                r"\bquarter past " + word + r"\b", f"{num}:15", out
            );
            prev = num - 1;
            if prev < 1 {
                prev = 12;
            }
            out = re.sub(
                r"\bquarter to " + word + r"\b", f"{prev}:45", out
            );
        }
    }
    out = re.sub(r"\bhalf past (\d{1,2})\b", r"\1:30", out);
    out = re.sub(r"\bquarter past (\d{1,2})\b", r"\1:15", out);

    # "two thirty" / "three fifteen" -> "2:30" / "3:15"
    for (hword, hnum) in NUMWORDS.items() {
        if hnum < 1 or hnum > 12 {
            continue;
        }
        for (mword, mnum) in NUMWORDS.items() {
            if mnum < 10 or mnum > 59 {
                continue;
            }
            out = re.sub(
                r"\b" + hword + r" " + mword + r"\b", f"{hnum}:{mnum:02d}", out
            );
        }
    }

    # bare numerals last, so the pair-rules above get first refusal
    for (word, num) in NUMWORDS.items() {
        if num >= 1 and num <= 12 {
            out = re.sub(r"\b" + word + r"\b", str(num), out);
        }
    }
    return out;
}


# --------------------------------------------------------------------------
# Timezone
# --------------------------------------------------------------------------

"""Find a spoken timezone in the phrase.

Returns (iana_zone, matched_words). Empty zone means the human named none,
in which case the caller's default applies. Multi-word zone names are tried
before single tokens so "east coast" beats a stray "ct".
"""
def detect_zone(text: str) -> tuple[str, str] {
    ordered: list[str] = sorted(ZONEWORDS.keys(), key=len, reverse=True);
    for word in ordered {
        if re.search(r"\b" + re.escape(word) + r"\b", text) {
            return (ZONEWORDS[word] as str, word);
        }
    }
    return ("", "");
}


# --------------------------------------------------------------------------
# Time of day
# --------------------------------------------------------------------------

"""Resolve a bare hour to 24h using business-meeting convention.

This is the single most consequential heuristic in the file. Nobody offering
a slot on a sales call means 02:00, so 1-7 read as afternoon and 8-11 as
morning. An explicit am/pm, or a daypart word in the same breath, always
overrides the convention.
"""
def disambiguate_hour(hour: int, meridiem: str, daypart: str) -> int {
    if meridiem == "am" {
        if hour == 12 {
            return 0;
        }
        return hour;
    }
    if meridiem == "pm" {
        if hour == 12 {
            return 12;
        }
        return hour + 12;
    }
    if hour == 0 or hour > 12 {
        return hour;
    }
    if daypart == "morning" or daypart == "breakfast" {
        if hour == 12 {
            return 0;
        }
        return hour;
    }
    if daypart == "afternoon" or daypart == "evening" or daypart == "tonight" {
        if hour == 12 {
            return 12;
        }
        return hour + 12;
    }
    if hour == 12 {
        return 12;
    }
    if hour >= 1 and hour <= 7 {
        return hour + 12;
    }
    return hour;
}


"""Extract (hour, minute, explicit) from a digitised phrase.

`explicit` is False when no clock time was spoken at all, which lets the
caller fall back to a daypart default and mark the result as coarse.
"""
def extract_time(text: str, daypart: str) -> tuple[int, int, bool] {
    # 14:00 / 2:30 pm / 2 pm / 2p
    m = re.search(r"\b(\d{1,2}):(\d{2})\s*(am|pm|a m|p m|a|p)?\b", text);
    if m {
        hour = int(m.group(1));
        minute = int(m.group(2));
        mer = normalise_meridiem(m.group(3));
        return (disambiguate_hour(hour, mer, daypart), minute, True);
    }
    m = re.search(r"\b(\d{1,2})\s*(am|pm|a m|p m)\b", text);
    if m {
        hour = int(m.group(1));
        mer = normalise_meridiem(m.group(2));
        return (disambiguate_hour(hour, mer, daypart), 0, True);
    }
    # a bare hour, but only after date digits are masked out
    masked: str = mask_date_digits(text);
    m = re.search(r"\b(\d{1,2})\b(?!\s*[:/-])", masked);
    if m {
        hour = int(m.group(1));
        if hour >= 0 and hour <= 23 {
            return (disambiguate_hour(hour, "", daypart), 0, True);
        }
    }
    if daypart {
        return (DAYPARTS[daypart] as int, 0, False);
    }
    return (-1, 0, False);
}


def normalise_meridiem(raw: any) -> str {
    if raw is None {
        return "";
    }
    token: str = str(raw).replace(" ", "").strip();
    if token.startswith("a") {
        return "am";
    }
    if token.startswith("p") {
        return "pm";
    }
    return "";
}


"""Blank out digits that belong to a DATE before hunting for a bare hour.

Without this, "August 5 at 4" finds the 5 first and books 5pm on some other
day, and "8/5 at 11" books at 5. The date digits are masked, never the
clock digits, so the bare-hour fallback can only ever see an hour.
"""
def mask_date_digits(text: str) -> str {
    out: str = re.sub(r"\b\d{1,2}/\d{1,2}(?:/\d{2,4})?\b", " ", text);
    out = re.sub(r"\b\d{1,2}(?:st|nd|rd|th)\b", " ", out);
    for mword in MONTHS.keys() {
        out = re.sub(
            r"\b" + mword + r"\.?\s+\d{1,2}\b", " " + mword + " ", out
        );
        out = re.sub(
            r"\b\d{1,2}\s+(?:of\s+)?" + mword + r"\b", " " + mword + " ", out
        );
    }
    return out;
}


"""Find a named part of the day, if one was spoken."""
def extract_daypart(text: str) -> str {
    parts: list[str] = sorted(DAYPARTS.keys(), key=len, reverse=True);
    for word in parts {
        if re.search(r"\b" + word + r"\b", text) {
            return word;
        }
    }
    return "";
}


# --------------------------------------------------------------------------
# Date
# --------------------------------------------------------------------------

"""Advance `base` to the next occurrence of `weekday`.

`inclusive` keeps today when today already is that weekday - the caller only
sets it when the spoken time is still ahead on the clock.
"""
def next_weekday(base: datetime, weekday: int, inclusive: bool) -> datetime {
    delta = (weekday - base.weekday()) % 7;
    if delta == 0 and not inclusive {
        delta = 7;
    }
    return base + timedelta(days=delta);
}


"""Resolve the calendar date the human meant.

Returns (date_anchor, basis, ambiguous). `ambiguous` marks readings that a
reasonable English speaker could disagree with - "next Tuesday" being the
canonical example - so the caller can insist the agent speaks the full date
back and lets the human catch it.
"""
def extract_date(text: str, now: datetime, hour: int, minute: int) -> tuple[datetime, str, bool] {
    today: datetime = now.replace(hour=0, minute=0, second=0, microsecond=0);

    # relative day words
    if re.search(r"\bday after tomorrow\b", text) {
        return (today + timedelta(days=2), "day after tomorrow", False);
    }
    if re.search(r"\btomorrow\b", text) {
        return (today + timedelta(days=1), "tomorrow", False);
    }
    if re.search(r"\btoday\b", text) or re.search(r"\btonight\b", text) {
        return (today, "today", False);
    }
    rel_days = re.search(r"\bin (\d{1,3}) days?\b", text);
    if rel_days is not None {
        return (today + timedelta(days=int(rel_days.group(1))), "relative days", False);
    }

    # explicit calendar date: "july 30", "30 july", "7/30"
    m = re.search(r"\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b", text);
    if m {
        month = int(m.group(1));
        day = int(m.group(2));
        year = now.year;
        if m.group(3) {
            year = int(m.group(3));
            if year < 100 {
                year = 2000 + year;
            }
        }
        anchor = today.replace(year=year, month=month, day=day);
        if anchor < today and not m.group(3) {
            anchor = anchor.replace(year=year + 1);
        }
        return (anchor, "explicit date", False);
    }
    for (mword, mnum) in MONTHS.items() {
        pattern = r"\b" + mword + r"\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b";
        m = re.search(pattern, text);
        if not m {
            pattern = r"\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?" + mword + r"\b";
            m = re.search(pattern, text);
        }
        if m {
            day = int(m.group(1));
            anchor = today.replace(month=mnum as int, day=day);
            if anchor < today {
                anchor = anchor.replace(year=today.year + 1);
            }
            return (anchor, "explicit date", False);
        }
    }

    # weekday, with this/next qualifiers
    for (dword, dnum) in WEEKDAYS.items() {
        if not re.search(r"\b" + dword + r"\b", text) {
            continue;
        }
        is_next = bool(re.search(r"\bnext\s+" + dword + r"\b", text));
        is_this = bool(re.search(r"\b(?:this|coming)\s+" + dword + r"\b", text));

        # today counts only when the clock time has not already passed
        inclusive = False;
        if hour >= 0 {
            candidate = now.replace(
                hour=hour, minute=minute, second=0, microsecond=0
            );
            inclusive = candidate > now;
        }
        anchor = next_weekday(today, dnum as int, inclusive);
        if is_next {
            # Deliberate, documented reading: "next Thursday" is the Thursday
            # of the following week, not the one three days away. English
            # speakers split on this, so it is flagged ambiguous and the
            # agent is required to speak the full date back.
            anchor = anchor + timedelta(days=7);
            return (anchor, "next-week weekday", True);
        }
        if is_this {
            return (anchor, "this-week weekday", False);
        }
        return (anchor, "upcoming weekday", False);
    }

    if re.search(r"\bnext week\b", text) {
        return (today + timedelta(days=7), "next week", True);
    }

    # no date spoken: today if the time is still ahead, else tomorrow
    if hour >= 0 {
        candidate = now.replace(hour=hour, minute=minute, second=0, microsecond=0);
        if candidate > now + timedelta(minutes=2) {
            return (today, "implicit today", False);
        }
        return (today + timedelta(days=1), "implicit tomorrow", False);
    }
    return (today, "implicit today", False);
}


# --------------------------------------------------------------------------
# The resolver
# --------------------------------------------------------------------------

"""Resolve a spoken phrase into an exact slot, or raise.

Returns a dict:
  start        aware datetime in `calendar_tz`
  iso          ISO-8601 with offset - what goes on the wire to Google
  spoken_back  human phrasing the agent must read out, with the zone named
  basis        how the date and time were arrived at, for the audit trail
  ambiguous    True when a reasonable person could read the phrase otherwise
  speaker_tz   the zone the phrase was interpreted in
  source_tz    "spoken" if the human named a zone, else "default"

Raises ValueError when the phrase carries no usable time, resolves into the
past, or lands beyond the booking horizon. Raising is the point: a booking
walker that cannot tell what time was meant must fail loudly, not guess.
"""
def resolve_spoken_time(
    phrase: str,
    now: datetime,
    calendar_tz: str,
    default_speaker_tz: str = ""
) -> dict[str, any] {
    raw: str = phrase.strip();
    if not raw {
        raise ValueError(
            "timeparse: no time was spoken - refusing to invent one. "
            + "The caller must ask the human to name a time."
        );
    }

    text: str = normalise(raw);

    # "in an hour" / "in 45 minutes" - relative to the real clock, no date logic
    rel = re.search(r"\bin (?:an?|(\d{1,3})|(\w+)) (hour|hours|minute|minutes|min|mins)\b", text);
    if rel {
        amount: int = 1;
        if rel.group(1) {
            amount = int(rel.group(1));
        } elif rel.group(2) {
            amount = int(NUMWORDS.get(rel.group(2), 1));
        }
        unit: str = str(rel.group(3));
        if unit.startswith("hour") {
            relstart: datetime = now + timedelta(hours=amount);
        } else {
            relstart: datetime = now + timedelta(minutes=amount);
        }
        relstart = relstart.replace(second=0, microsecond=0).astimezone(ZoneInfo(calendar_tz));
        return build_result(relstart, calendar_tz, calendar_tz, "default", "relative offset", False, raw);
    }

    text = digitise(text);

    (zone, zone_word) = detect_zone(text);
    speaker_tz: str = default_speaker_tz if default_speaker_tz else calendar_tz;
    source: str = "default";
    if zone {
        speaker_tz = zone;
        source = "spoken";
    } elif re.search(r"\bmy time\b", text) and default_speaker_tz {
        speaker_tz = default_speaker_tz;
        source = "their-zone";
    } elif re.search(r"\byour time\b", text) {
        speaker_tz = calendar_tz;
        source = "our-zone";
    }

    daypart: str = extract_daypart(text);
    (hour, minute, explicit) = extract_time(text, daypart);
    if hour < 0 {
        raise ValueError(
            f"timeparse: could not find a time in '{raw}'. Refusing to guess a "
            + "slot - the caller must ask the human to say a time."
        );
    }

    # The date is resolved in the SPEAKER's zone: "tomorrow at 9 Eastern" means
    # tomorrow where they are, which can be a different calendar day from ours.
    now_speaker: datetime = now.astimezone(ZoneInfo(speaker_tz));
    (anchor, date_basis, ambiguous) = extract_date(text, now_speaker, hour, minute);

    local: datetime = anchor.replace(hour=hour, minute=minute, second=0, microsecond=0);
    local = local.replace(tzinfo=ZoneInfo(speaker_tz));
    start: datetime = local.astimezone(ZoneInfo(calendar_tz));

    if start <= now {
        raise ValueError(
            f"timeparse: '{raw}' resolves to {start.isoformat()}, which is in the "
            + "past. Refusing to book backwards - the caller must re-ask."
        );
    }
    if start > now + timedelta(days=MAX_HORIZON_DAYS) {
        raise ValueError(
            f"timeparse: '{raw}' resolves to {start.isoformat()}, beyond the "
            + f"{MAX_HORIZON_DAYS}-day booking horizon. Treating as a parse failure."
        );
    }

    basis: str = date_basis;
    if not explicit {
        basis = f"{date_basis} + {daypart} default";
        ambiguous = True;
    }
    return build_result(start, calendar_tz, speaker_tz, source, basis, ambiguous, raw);
}


"""Assemble the result dict and the sentence the agent will actually say."""
def build_result(
    start: datetime,
    calendar_tz: str,
    speaker_tz: str,
    source: str,
    basis: str,
    ambiguous: bool,
    raw: str
) -> dict[str, any] {
    return {
        "start": start,
        "iso": start.isoformat(),
        "spoken_back": speak_datetime(start, calendar_tz),
        "basis": basis,
        "ambiguous": ambiguous,
        "speaker_tz": speaker_tz,
        "calendar_tz": calendar_tz,
        "source_tz": source,
        "heard": raw
    };
}


"""Render a slot the way a person says it, with the zone named out loud.

Naming the zone is not decoration. It is the control that lets the human on
the phone catch a three-hour error while the call is still live.
"""
def speak_datetime(moment: datetime, calendar_tz: str) -> str {
    local: datetime = moment.astimezone(ZoneInfo(calendar_tz));
    weekday: str = local.strftime("%A");
    month: str = local.strftime("%B");
    day: int = local.day;
    hour24: int = local.hour;
    minute: int = local.minute;

    hour12: int = hour24 % 12;
    if hour12 == 0 {
        hour12 = 12;
    }
    meridiem: str = "AM" if hour24 < 12 else "PM";
    clock: str = f"{hour12}:{minute:02d} {meridiem}";
    if minute == 0 {
        clock = f"{hour12} {meridiem}";
    }
    if hour24 == 12 and minute == 0 {
        clock = "noon";
    }
    return f"{weekday}, {month} {day}{ordinal_suffix(day)} at {clock} {zone_label(local, calendar_tz)}";
}


def ordinal_suffix(day: int) -> str {
    if day >= 11 and day <= 13 {
        return "th";
    }
    last: int = day % 10;
    if last == 1 {
        return "st";
    }
    if last == 2 {
        return "nd";
    }
    if last == 3 {
        return "rd";
    }
    return "th";
}


"""Say "Pacific", not "PDT" - a TTS voice reading four letters is unusable."""
def zone_label(moment: datetime, calendar_tz: str) -> str {
    friendly: dict[str, str] = {
        "America/Los_Angeles": "Pacific",
        "America/New_York": "Eastern",
        "America/Chicago": "Central",
        "America/Denver": "Mountain",
        "Europe/London": "UK time",
        "Asia/Kolkata": "India time",
        "UTC": "UTC"
    };
    return friendly.get(calendar_tz, moment.strftime("%Z")) as str;
}


"""Validate the model's ISO attempt, or fall through to parsing the phrase.

The model's ISO is a hint, never the authority. It is accepted only when it
parses AND lands in the future AND inside the horizon - the exact conditions
under which a hallucinated year or a stale "today" would be caught.
Returns None when the hint fails any of those, so the caller can parse the
spoken phrase instead.
"""
def validate_iso_hint(raw: str, now: datetime, calendar_tz: str) -> dict[str, any] | None {
    text: str = raw.strip();
    if not text {
        return None;
    }
    if text.endswith("Z") {
        text = text[:-1] + "+00:00";
    }
    parsed: datetime | None = None;
    try {
        parsed = datetime.fromisoformat(text);
    } except ValueError {
        return None;
    }
    if parsed is None {
        return None;
    }
    aware: datetime = parsed;
    if aware.tzinfo is None {
        aware = aware.replace(tzinfo=ZoneInfo(calendar_tz));
    }
    start: datetime = aware.astimezone(ZoneInfo(calendar_tz));
    if start <= now {
        return None;
    }
    if start > now + timedelta(days=MAX_HORIZON_DAYS) {
        return None;
    }
    return build_result(start, calendar_tz, calendar_tz, "iso-hint", "model ISO", False, raw);
}
