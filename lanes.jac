"""Lane doctrines, LinkedIn URL composition, and the widening ladder.

Three lanes are three *researchers*, not three views of one action. Lane A mines
comment sections under mid-tier practitioner posts; Lane B reads post bodies for
first-person problem statements; Lane C sweeps synonyms broadly and shallowly.

This module is pure logic - no graph, no browser, no network. It is fully
testable standalone and carries zero dependency on the schema or the CDP client.
"""

import from urllib.parse { quote }


# ---------------------------------------------------------------------------
# Date windows. LinkedIn's content-search filter takes these three literal
# values, quoted. Anything else is silently ignored by their UI.
# ---------------------------------------------------------------------------
glob DATE_TIGHT: str = "past-24h";
glob DATE_WIDE: str = "past-week";
glob DATE_WIDEST: str = "past-month";

glob LINKEDIN_BASE: str = "https://www.linkedin.com";

# Mid-tier practitioner band for Lane A. Below the floor there is no comment
# section worth mining; above the ceiling the section is applause, not signal.
glob MIDTIER_FLOOR: int = 200;
glob MIDTIER_CEIL: int = 3000;

# Words that carry no search weight - stripped when reformulating a dry phrase.
glob STOPWORDS: list[str] = [
    "a", "an", "the", "is", "are", "was", "were", "be", "been", "being",
    "of", "to", "in", "on", "at", "for", "with", "and", "or", "but",
    "my", "our", "we", "i", "it", "its", "this", "that", "these", "those",
    "so", "just", "really", "actually", "still", "even", "very", "quite"
];


obj LaneTactics {
    """One researcher's standing orders."""

    has lane_id: str;
    has name: str;
    # Prose shown in the UI under the lane's panel. First person - this is the
    # researcher describing their own method.
    has doctrine: str;
    # Where this lane's browser lands first. Deliberately different per lane so
    # no two lanes ever load the same page type at the same instant.
    has opening_path: str;
    # Whether the first query is typed visibly (demo drama) or navigated.
    has types_first_query: bool = False;
    # Does this lane open comment sections, or read post bodies only?
    has mines_comments: bool = False;
    # Does this lane enforce the mid-tier follower band?
    has enforce_midtier: bool = False;
    # Date windows tried per keyword, in order. Lane C starts wide on purpose.
    has date_ladder: list[str] = [];
    # How many results this lane inspects per probe. C is a breadth instrument:
    # many probes, few results each. A is the opposite.
    has results_per_probe: int = 8;
    # How many prospects this lane is trying to surface before it stops.
    has target_yield: int = 3;
    # Fixed (not random) inter-action delay in seconds. Differentiated per lane
    # so concurrent activity never looks synchronized - and reproducible, so a
    # morning rehearsal predicts the evening demo.
    has action_delay: float = 1.4;
    # Seconds after launch before this lane starts. 8-12s apart, per plan S14.
    has stagger: float = 0.0;
}


obj ProbeSpec {
    """One rung on the widening ladder: a query this lane will actually run."""

    has keywords: str;
    has date_posted: str;
    has rung: int = 0;
    # Why this rung exists. Feeds the pivot sentence verbatim, so it is written
    # as a fragment an analyst would say, not as a status code.
    has reason: str = "";
    # Which move produced this rung: seed | widen_date | reformulate | next_phrase
    has move: str = "seed";
}


# ---------------------------------------------------------------------------
# URL composition
#
# We compose search URLs directly rather than hunting filter buttons in the UI.
# LinkedIn's filter chips are React-rendered, re-keyed between deploys, and
# require 3-4 clicks each; the query string is stable and one navigation.
# ---------------------------------------------------------------------------

def content_search_url(keywords: str, date_posted: str) -> str {
    """Compose a LinkedIn content-search URL sorted newest-first.

    `datePosted` and `sortBy` take *quoted* values - the literal double quotes
    are part of the value and must survive encoding as %22.
    """;
    parts = [f"keywords={quote(keywords)}"];
    if date_posted {
        parts.append(f"datePosted={quote(f'\"{date_posted}\"')}");
    }
    parts.append(f"sortBy={quote('\"date_posted\"')}");
    return f"{LINKEDIN_BASE}/search/results/content/?" + "&".join(parts);
}


def people_search_url(keywords: str) -> str {
    """Compose a LinkedIn people-search URL. Used by the light cross-link pass.""";
    return f"{LINKEDIN_BASE}/search/results/people/?keywords={quote(keywords)}";
}


def probe_url(p: ProbeSpec) -> str {
    return content_search_url(p.keywords, p.date_posted);
}


def opening_url(d: LaneTactics) -> str {
    """The first page this lane loads. Different per lane, by design.""";
    return f"{LINKEDIN_BASE}{d.opening_path}";
}


# ---------------------------------------------------------------------------
# Phrase reformulation
#
# When a phrase is dry, the cheapest real move is to require fewer terms.
# LinkedIn ANDs the keywords, so dropping qualifiers strictly widens the match
# set. We keep the content words and drop the connective tissue.
# ---------------------------------------------------------------------------

def content_words(phrase: str) -> list[str] {
    out = [];
    for w in phrase.lower().split() {
        cleaned = w.strip(".,!?;:\"'()[]");
        if cleaned and cleaned not in STOPWORDS {
            out.append(cleaned);
        }
    }
    return out;
}


def reformulate(phrase: str) -> str | None {
    """Narrow a phrase to its load-bearing core, which *widens* the result set.

    Returns None when the phrase is already at its core - there is nothing left
    to strip, and pretending otherwise would re-run an identical query.
    """;
    words = content_words(phrase);
    if len(words) <= 2 {
        return None;
    }
    core = " ".join(words[:2]);
    if core.lower() == phrase.strip().lower() {
        return None;
    }
    return core;
}


# ---------------------------------------------------------------------------
# The widening ladder
#
# Built up front from the doctrine so every rung is inspectable and the whole
# search plan is deterministic. The walker materializes rungs lazily as it goes
# dry - so the graph records exactly how far down the ladder each lane had to
# climb, and a rung that was never needed leaves no node behind.
# ---------------------------------------------------------------------------

def build_ladder(d: LaneTactics, phrases: list[str]) -> list[ProbeSpec] {
    """Expand a doctrine plus the ICP's phrases into the full ordered ladder.

    Per phrase: try each date window in the doctrine's ladder, then try the
    reformulated core at the widest window. Then move to the next phrase.
    """;
    ladder = [];
    rung = 0;
    dates = d.date_ladder if d.date_ladder else [DATE_TIGHT, DATE_WIDE];

    for (pi, phrase) in enumerate(phrases) {
        for (di, dw) in enumerate(dates) {
            if di == 0 {
                reason = (
                    f"opening on \"{phrase}\""
                    if pi == 0
                    else f"moving to \"{phrase}\""
                );
                move = "seed" if pi == 0 else "next_phrase";
            } else {
                reason = f"widening \"{phrase}\" to {human_window(dw)}";
                move = "widen_date";
            }
            ladder.append(
                ProbeSpec(
                    keywords=phrase,
                    date_posted=dw,
                    rung=rung,
                    reason=reason,
                    move=move
                )
            );
            rung += 1;
        }

        core = reformulate(phrase);
        if core is not None {
            ladder.append(
                ProbeSpec(
                    keywords=core,
                    date_posted=dates[-1],
                    rung=rung,
                    reason=f"stripping \"{phrase}\" back to \"{core}\"",
                    move="reformulate"
                )
            );
            rung += 1;
        }
    }
    return ladder;
}


def next_rung(ladder: list[ProbeSpec], cur_rung: int) -> ProbeSpec | None {
    """The next probe to try after `cur_rung` came back dry. None = exhausted.""";
    nxt = cur_rung + 1;
    if nxt >= len(ladder) {
        return None;
    }
    return ladder[nxt];
}


def human_window(date_posted: str) -> str {
    """Date filter rendered the way a person would say it out loud.""";
    if date_posted == DATE_TIGHT { return "the last 24 hours"; }
    if date_posted == DATE_WIDE { return "the last week"; }
    if date_posted == DATE_WIDEST { return "the last month"; }
    return "any time";
}


# ---------------------------------------------------------------------------
# Mid-tier gate (Lane A)
# ---------------------------------------------------------------------------

def is_midtier(followers: int) -> bool {
    """Is this author a practitioner whose comment section is worth mining?

    Below the floor there is no comment section. Above the ceiling the section
    is roughly 90% congratulation - the signal density does not justify the
    click, and every click is detection surface.
    """;
    return followers >= MIDTIER_FLOOR and followers <= MIDTIER_CEIL;
}


def midtier_verdict(followers: int) -> str {
    """Which side of the band this author falls on: below | mid | above.""";
    if (followers < MIDTIER_FLOOR) {
        return "below";
    } elif (followers > MIDTIER_CEIL) {
        return "above";
    }
    return "mid";
}


# ---------------------------------------------------------------------------
# The three doctrines
# ---------------------------------------------------------------------------

def tactics_a() -> LaneTactics {
    return LaneTactics(
        lane_id="A",
        name="comment mining",
        doctrine=(
            "I search the phrase people actually type when they are annoyed, "
            "then I read the comments underneath - not the post. The post is "
            "the author's opinion; the comments are other people volunteering "
            "that they have the same problem. I stay under mid-sized "
            "practitioner accounts, because the comment section under a "
            "hundred-thousand-follower post is applause, not evidence."
        ),
        opening_path="/search/results/content/",
        types_first_query=True,
        mines_comments=True,
        enforce_midtier=True,
        date_ladder=[DATE_TIGHT, DATE_WIDE],
        results_per_probe=6,
        target_yield=3,
        action_delay=1.4,
        stagger=0.0
    );
}


def tactics_b() -> LaneTactics {
    return LaneTactics(
        lane_id="B",
        name="post authorship",
        doctrine=(
            "I want people who wrote the problem down themselves, in the first "
            "person, with a date on it. Not commentary about the problem - the "
            "complaint itself. I read post bodies and ignore comment sections "
            "entirely; if someone cared enough to write the post, they are "
            "closer to buying than someone who typed a reply."
        ),
        opening_path="/feed/",
        types_first_query=False,
        mines_comments=False,
        enforce_midtier=False,
        date_ladder=[DATE_TIGHT, DATE_WIDE],
        results_per_probe=10,
        target_yield=3,
        action_delay=1.9,
        stagger=9.0
    );
}


def tactics_c() -> LaneTactics {
    return LaneTactics(
        lane_id="C",
        name="synonym sweep",
        doctrine=(
            "Everyone describing the same pain uses different words for it, and "
            "whichever words we happened to pick are the ones we will over-find. "
            "So I run the adjacent phrasings - the ones the first two lanes will "
            "never type. I go wide and shallow on purpose: many phrasings, a few "
            "results each, looking for the vocabulary we did not think of."
        ),
        opening_path="/mynetwork/",
        types_first_query=False,
        mines_comments=False,
        enforce_midtier=False,
        date_ladder=[DATE_WIDE, DATE_WIDEST],
        results_per_probe=5,
        target_yield=3,
        action_delay=1.1,
        stagger=18.0
    );
}


def all_linkedin_tactics() -> list[LaneTactics] {
    return [tactics_a(), tactics_b(), tactics_c()];
}


def tactics_for(lane_id: str) -> LaneTactics {
    if lane_id == "A" { return tactics_a(); }
    if lane_id == "B" { return tactics_b(); }
    if lane_id == "C" { return tactics_c(); }
    raise ValueError(
        f"No LinkedIn tactics for lane '{lane_id}'. "
        + "Valid LinkedIn lanes are A, B, C; lane D is the GitHub lane and is "
        + "owned by the identity track, not this module."
    );
}


# ---------------------------------------------------------------------------
# Phrase selection per lane
#
# The ICP carries pain_phrases and keywords. Each lane draws a DIFFERENT slice,
# so three lanes genuinely search three things rather than racing on one list.
# ---------------------------------------------------------------------------

def phrases_for_lane(
    lane_id: str, pain_phrases: list[str], keywords: list[str]
) -> list[str] {
    """Give each lane its own vocabulary. Overlap is failure, not redundancy.""";
    pains = [p for p in pain_phrases if p.strip()];
    keys = [k for k in keywords if k.strip()];

    if lane_id == "A" {
        # Comment mining rides the raw pain phrases - the emotional wording is
        # exactly what draws me-too replies.
        return pains if pains else keys;
    }
    if lane_id == "B" {
        # Authorship wants first-person framing. We build it around the phrase's
        # content core rather than the whole sentence - "we tried rag pipeline"
        # finds someone describing their own attempt; "we tried rag pipeline is
        # a nightmare" is a sentence nobody wrote.
        seeds = pains if pains else keys;
        out = [];
        for s in seeds {
            core = " ".join(content_words(s)[:2]);
            if not core { continue; }
            out.append(f"we tried {core}");
            out.append(f"gave up on {core}");
        }
        return out if out else seeds;
    }
    # Lane C sweeps the adjacent vocabulary: the topical keywords rather than
    # the pain wording, which is where the phrasings we did not guess live.
    return keys if keys else pains;
}
