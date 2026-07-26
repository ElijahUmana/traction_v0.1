"""Analyst-voice reasoning.

Judges read the sidebar and infer judgment from it. "41 comments, most
congratulatory, three describe an actual migration failure - opening those
three" reads as a researcher thinking. "[14:23:04] parsed 41 comments" reads as
a script running. Same underlying event; completely different inference about
whether anything intelligent is happening.

Every sentence here is built from counts the lane actually observed. Nothing is
decorative and nothing is invented - if the sentence says three, three comments
came back classified as first-person pain. That constraint is the whole point:
the prose is a *rendering* of real state, so it cannot drift from what the lane
did.

Pure logic - no graph, no browser, no network, no LLM.
"""


# Reasoning *kinds* live in contracts.ReasoningKind - this module produces the
# words, the walker chooses the kind. Keeping them apart means the sidebar's
# vocabulary can change without touching the enum on the wire.

glob NUMWORDS: list[str] = [
    "no", "one", "two", "three", "four", "five", "six",
    "seven", "eight", "nine", "ten", "eleven", "twelve"
];


def numword(n: int) -> str {
    """Small counts as words. Writing 'three' instead of '3' is most of the
    difference between prose and a log line.""";
    if n >= 0 and n < len(NUMWORDS) {
        return NUMWORDS[n];
    }
    return str(n);
}


def plural(n: int, one: str, many: str) -> str {
    return one if n == 1 else many;
}


def count_phrase(n: int, one: str, many: str) -> str {
    """e.g. (1,'comment','comments') -> 'one comment'; (41,..) -> '41 comments'.""";
    return f"{numword(n)} {plural(n, one, many)}";
}


def sentence_case(s: str) -> str {
    """Uppercase the first letter only - `.capitalize()` would lowercase the
    rest, which mangles names and acronyms mid-sentence.""";
    if not s {
        return s;
    }
    return s[0].upper() + s[1:];
}


def truncate_quote(q: str, limit: int = 120) -> str {
    """Trim a quote at a word boundary. A quote cut mid-word looks like a bug.""";
    clean = " ".join(q.split());
    if len(clean) <= limit {
        return clean;
    }
    cut = clean[:limit];
    sp = cut.rfind(" ");
    if sp > 40 {
        cut = cut[:sp];
    }
    return cut + "...";
}


# ---------------------------------------------------------------------------
# plan - stating intent before acting
# ---------------------------------------------------------------------------

def say_opening(lane_name: str, keywords: str, window_human: str) -> str {
    return (
        f"Starting where the complaint would actually be typed: \"{keywords}\", "
        + f"{window_human}. I want people who are annoyed right now, not people "
        + "who were annoyed in March."
    );
}


def say_doctrine(lane_id: str, doctrine: str) -> str {
    return f"Lane {lane_id}. {doctrine}";
}


def say_next_query(keywords: str, window_human: str) -> str {
    return f"Running \"{keywords}\" over {window_human}.";
}


# ---------------------------------------------------------------------------
# observe - reporting what came back
# ---------------------------------------------------------------------------

def say_results(n: int, keywords: str) -> str {
    """First look at a result page.""";
    if n == 0 {
        return f"Nothing at all for \"{keywords}\".";
    }
    if n == 1 {
        return f"A single hit for \"{keywords}\". Thin, but worth reading.";
    }
    return f"{numword(n).capitalize()} {plural(n, 'post', 'posts')} back for \"{keywords}\".";
}


def say_vendor_split(total: int, vendors: int, practitioners: int) -> str {
    """The most common real shape of a LinkedIn result page: vendors pitching a
    fix, mixed with people describing the problem. Only one of those is the
    customer, and saying so out loud is the judgment call.""";
    if vendors == 0 {
        return (
            f"All {numword(total)} are practitioners describing the problem "
            + "rather than vendors pitching at it. Unusually clean page."
        );
    }
    if practitioners == 0 {
        return (
            f"All {numword(total)} are vendors pitching a solution. Nobody here "
            + "has the problem - they are all selling the fix. Moving on."
        );
    }
    return (
        f"Of {numword(total)}, {numword(vendors)} {plural(vendors, 'is a vendor', 'are vendors')} "
        + f"pitching a solution and {numword(practitioners)} "
        + f"{plural(practitioners, 'is a practitioner', 'are practitioners')} describing the "
        + f"problem. The vendors are not the customer - reading the other "
        + f"{numword(practitioners)}."
    );
}


def say_comment_scan(
    total: int, noise: int, signal: int, signal_desc: str
) -> str {
    """The Lane A money sentence. This is the exact shape from the brief.""";
    if total == 0 {
        return "Comments are closed on this one. Nothing to mine.";
    }
    if signal == 0 {
        return (
            f"{sentence_case(count_phrase(total, 'comment', 'comments'))}, and all of them are "
            + "congratulation. No one here is describing a problem. Backing out."
        );
    }
    lead = sentence_case(count_phrase(total, "comment", "comments"));
    if noise > signal {
        lead += ", most congratulatory";
    }
    if signal == 1 {
        return f"{lead}, one describes an actual {signal_desc} - opening that one.";
    }
    return (
        f"{lead}, {numword(signal)} describe an actual {signal_desc} - "
        + f"opening those {numword(signal)}."
    );
}


def say_post_body(author: str, has_first_person: bool) -> str {
    if has_first_person {
        return f"{author} wrote this in the first person, which is what I want - not commentary about the problem, the complaint itself.";
    }
    return f"{author} is describing the problem in the abstract. That is an opinion, not a symptom. Skipping.";
}


# ---------------------------------------------------------------------------
# judge - accepting or rejecting a source, with the reason
# ---------------------------------------------------------------------------

def say_midtier_reject(author: str, followers: int, verdict: str) -> str {
    """Lane A's defining move. Rejecting a big account *on the record* is what
    makes the lane look like it has a method rather than a scraper.""";
    if verdict == "above" {
        return (
            f"{author} has {followers:,} followers. Comment sections that big are "
            + "mostly applause - the signal is not worth the click. Skipping to a "
            + "smaller account."
        );
    }
    return (
        f"{author} has {followers} followers, so there is no comment section to "
        + "speak of. Nothing to mine here."
    );
}


def say_midtier_accept(author: str, followers: int) -> str {
    return (
        f"{author}, {followers} followers - a working practitioner, not an "
        + "influencer. This is exactly the size where the comments are people "
        + "with the same problem."
    );
}


def say_duplicate_source(author: str, n_seen: int) -> str {
    return (
        f"{author} again - {ordinal(n_seen)} time this lane has landed on them. "
        + "One person's opinion does not become {n} data points. Skipping."
    ).replace("{n}", numword(n_seen));
}


def say_recruiter_drop(n: int) -> str {
    if n == 1 {
        return "One of these is a recruiter account. Recruiters are not the buyer here; dropping it.";
    }
    tail = "dropping both" if n == 2 else f"dropping all {numword(n)}";
    return (
        f"{sentence_case(numword(n))} of these are recruiter accounts posting the same "
        + f"template. Recruiters are not the buyer here; {tail}."
    );
}


def say_stale(author: str, days: int) -> str {
    return (
        f"{author}'s post is {days} days old. The problem may well be solved by "
        + "now - a cold email referencing it would land badly. Passing."
    );
}


# ---------------------------------------------------------------------------
# pivot - the dry-branch narration
#
# An agent that says "this angle is dry, switching to variant 2" looks smarter
# than one that succeeds first try. These sentences are the reason the dry
# branch is worth building at all.
# ---------------------------------------------------------------------------

def say_dry(keywords: str, window_human: str) -> str {
    return f"\"{keywords}\" is dry over {window_human}.";
}


def say_pivot(move: str, reason: str, keywords: str, window_human: str) -> str {
    """`move` and `reason` come straight off the ProbeSpec, so the narration
    cannot disagree with the query that actually runs next.""";
    if move == "widen_date" {
        return (
            f"Dry at the tighter window. Widening to {window_human} before I give "
            + "up on this phrasing - the pain does not stop existing just because "
            + "nobody posted today."
        );
    }
    if move == "reformulate" {
        return (
            f"That phrasing is too specific; every extra word is another thing the "
            + f"post has to contain. Stripping it back to \"{keywords}\"."
        );
    }
    if move == "next_phrase" {
        return (
            f"This angle is spent. Trying \"{keywords}\" - same pain, different "
            + "vocabulary."
        );
    }
    return f"Pivoting: {reason}.";
}


def say_exhausted(lane_name: str, tried: int, found: int) -> str {
    """Honest terminal state. A lane that found nothing and says so is more
    credible than one that pads the ledger.""";
    if found == 0 {
        return (
            f"I have run {count_phrase(tried, 'phrasing', 'phrasings')} and every one "
            + "came back dry. This vocabulary is not where these people are talking. "
            + "Reporting empty rather than padding the list."
        );
    }
    return (
        f"Ladder exhausted after {count_phrase(tried, 'phrasing', 'phrasings')}. "
        + f"{sentence_case(count_phrase(found, 'name', 'names'))} worth keeping."
    );
}


# ---------------------------------------------------------------------------
# yield - a prospect surfaced
# ---------------------------------------------------------------------------

def say_yield(name: str, quote: str, days_old: int) -> str {
    when = recency_phrase(days_old);
    return (
        f"{name}: \"{truncate_quote(quote)}\" - {when}. That is a first-person "
        + "problem statement with a date on it. Keeping."
    );
}


def say_lane_summary(lane_id: str, found: int, probes_run: int) -> str {
    if found == 0 {
        return (
            f"Lane {lane_id} closing with nothing after "
            + f"{count_phrase(probes_run, 'query', 'queries')}."
        );
    }
    return (
        f"Lane {lane_id} closing: {count_phrase(found, 'name', 'names')} from "
        + f"{count_phrase(probes_run, 'query', 'queries')}."
    );
}


# ---------------------------------------------------------------------------
# convergence - the thesis sentence, emitted by the orchestrator after merge
# ---------------------------------------------------------------------------

def say_convergence(name: str, lane_ids: list[str]) -> str {
    """The closing shot. Two lanes with different methods landing on the same
    human is the product thesis, so this sentence gets to be the loud one.""";
    ids = sorted(lane_ids);
    if len(ids) < 2 {
        return f"{name} surfaced by lane {ids[0] if ids else '?'} only.";
    }
    joined = (
        f"{', '.join(ids[:-1])} and {ids[-1]}" if len(ids) > 2
        else f"{ids[0]} and {ids[1]}"
    );
    roads = "Two roads" if len(ids) == 2 else f"{sentence_case(numword(len(ids)))} roads";
    return (
        f"{name} was found independently by {count_phrase(len(ids), 'lane', 'lanes')} "
        + f"- {joined} - searching different vocabularies and never sharing results. "
        + f"{roads} to the same person is the strongest signal we have."
    );
}


def say_merge(total_raw: int, unique: int, converged: int) -> str {
    dropped = total_raw - unique;
    if dropped == 0 {
        return (
            f"{sentence_case(count_phrase(total_raw, 'candidate', 'candidates'))} across all "
            + "lanes and no overlap between them - every lane was looking somewhere "
            + "different."
        );
    }
    base = (
        f"{sentence_case(count_phrase(total_raw, 'candidate', 'candidates'))} across all "
        + f"lanes, {numword(unique)} unique after merging "
        + f"{count_phrase(dropped, 'duplicate', 'duplicates')}"
    );
    if converged == 0 {
        return base + ". No one was found by two lanes independently, though.";
    }
    return (
        base
        + f". {sentence_case(count_phrase(converged, 'name', 'names'))} came from more than one lane."
    );
}


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def recency_phrase(days: int) -> str {
    if days <= 0 { return "posted today"; }
    if days == 1 { return "posted yesterday"; }
    if days < 7 { return f"posted {numword(days)} days ago"; }
    if days < 14 { return "posted last week"; }
    if days < 31 { return f"posted about {numword(max(1, days // 7))} weeks ago"; }
    return f"posted {numword(max(1, days // 30))} {plural(max(1, days // 30), 'month', 'months')} ago";
}


def ordinal(n: int) -> str {
    words = ["zeroth", "first", "second", "third", "fourth", "fifth", "sixth"];
    if n >= 0 and n < len(words) {
        return words[n];
    }
    return f"{n}th";
}
