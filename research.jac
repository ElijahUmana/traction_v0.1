"""TRACTION research engine - four lanes, genuinely parallel.

`RunResearch` fans out four lanes with `flow` and collects them with `wait`.
The three LinkedIn lanes are three *researchers*: A mines comment sections under
mid-tier practitioner posts, B reads post bodies for first-person problem
statements, C sweeps adjacent vocabulary. They share no results and search
different phrases on purpose - so when two of them land on the same human, that
convergence means something.

Two design decisions worth naming:

**The dry-branch ladder is graph structure.** Each Lane grows `SearchProbe`
children as it goes dry. Rung 0 dry -> create rung 1, `visit` it -> dry -> rung
2. The traversal deepens exactly when an angle fails, so the search tree - dead
branches included - is a graph fact you can read back with `printgraph`, not a
log line. It also makes these walkers genuine traversal rather than RPC in
walker costume.

**Lanes write only under themselves.** Every Reasoning, Prospect and Evidence a
lane creates hangs off that lane's own node, so four threads touch four disjoint
edge lists. The merge, dedupe and convergence pass runs serially in the
orchestrator after `wait`. (Concurrent writes to a shared parent were measured
safe - 200/200 with no losses - but disjoint parents cost nothing and remove the
question entirely.)
"""

import time;
import json;
import re;

import from lane_w { LaneW }
import from browser.env { env as _env_unused }
import from schema {
    Founder, ICP, ResearchRun, Lane, Reasoning, Prospect, Evidence,
    SearchProbe,
    Targets, Runs, HasLane, Emitted, Surfaced, HasEvidence, Probe, Widened
}
import from contracts {
    LaneId, LaneState, RunStatus, ReasoningKind,
    EvidenceSource, EvidenceKind, ProspectCandidate
}
import from lanes {
    LaneTactics, ProbeSpec, tactics_for, build_ladder, probe_url, opening_url,
    human_window, phrases_for_lane, is_midtier, midtier_verdict,
    ladder_was_capped,
    content_search_url
}
import from narration {
    say_opening, say_next_query, say_results, say_vendor_split,
    say_comment_scan, say_post_body, say_midtier_reject, say_midtier_accept,
    say_recruiter_drop, say_stale, say_duplicate_source, say_dry, say_pivot,
    say_exhausted, say_yield, say_lane_summary, say_convergence, say_merge,
    truncate_quote, sentence_case, numword, count_phrase
}

import from browser.session { BrowserSession, new_session }
import from browser.env { env }
import from githublane { GithubLane }


# The search ladder lives in schema.jac like every other archetype. Declaring it
# here as well created a SECOND SearchProbe/Probe/Widened: distinct types, but
# edge traversal matches by NAME at runtime, so [lane ->:Probe:->] returned a
# mixture of both and any read of a field only one of them had would raise.
# jac check passed on both files because each resolved its own declaration.


# ===========================================================================
# LLM classification - the one genuinely-LLM job inside a lane
# ===========================================================================

obj CommentVerdict {
    has index: int;
    has is_pain: bool = False;
    has is_vendor: bool = False;
    has summary: str = "";
    has relevance: float = 0.0;
}
sem CommentVerdict = "A judgement about one thing a person wrote: is this someone describing a problem they actually have, or is it noise?";
sem CommentVerdict.index = "Zero-based position of the text in the list that was handed to you.";
sem CommentVerdict.is_pain = "True only if the author is describing a difficulty they themselves are experiencing, in the first person. Congratulation, agreement, and abstract commentary are all False.";
sem CommentVerdict.is_vendor = "True if the author is pitching a product or service that solves the problem rather than having the problem.";
sem CommentVerdict.summary = "Two or three words naming the specific problem, e.g. 'migration failure' or 'billing surprise'. Empty when is_pain is False.";
sem CommentVerdict.relevance = "0.0 to 1.0 - how directly this text matches the ICP hypothesis.";

def classify_texts(
    hypothesis: str, texts: list[str]
) -> list[CommentVerdict] by llm();
sem classify_texts = "Sort things people wrote into genuine first-person problem statements versus noise. Return exactly one verdict per input text, with matching indexes. Be strict: 'Great post!', 'so true', and agreement without a personal example are NOT pain signals.";
sem classify_texts.hypothesis = "Description of the kind of person we are looking for and the problem they have.";
sem classify_texts.texts = "The texts to classify, in order.";


# ===========================================================================
# Browser access
#
# `BrowserSession` (browser/session.jac) is the real client - per-instance
# socket, per-instance CDP id counter, so three lanes in `flow` threads cannot
# steal each other's replies. `LaneBrowser` is a thin seam over it that adds
# exactly one thing: an offline mode so the whole pipeline can be tested with
# no network and no API keys.
# ===========================================================================

# One in-page pass that keys off profile links rather than class names.
# LinkedIn re-keys its CSS constantly; `a[href*="/in/"]` is structural and has
# to exist for the page to function at all. One round-trip, not N.
glob EXTRACT_JS: str = """
(() => {
  const seen = new Set(); const out = [];
  const anchors = document.querySelectorAll('a[href*="/in/"]');
  for (const a of anchors) {
    const href = (a.href || '').split('?')[0];
    const m = href.match(/\\/in\\/([^\\/]+)/);
    if (!m) continue;
    const handle = m[1];
    if (!handle || seen.has(handle)) continue;
    seen.add(handle);
    let el = a, hops = 0;
    while (el && hops < 9 && (el.innerText || '').length < 140) {
      el = el.parentElement; hops++;
    }
    const block = el ? (el.innerText || '') : '';
    let name = (a.innerText || '').trim().split('\\n')[0].trim();
    if (!name) {
      const img = a.querySelector('img[alt]');
      if (img) name = (img.getAttribute('alt') || '').trim();
    }
    out.push({handle: handle, url: href, name: name, block: block.slice(0, 1500)});
    if (out.length >= 25) break;
  }
  return JSON.stringify(out);
})()
""";

# Comment sections are lazy-rendered; this expands them before reading.
glob EXPAND_COMMENTS_JS: str = """
(() => {
  let clicked = 0;
  const sels = [
    'button.comments-comments-list__load-more-comments-button',
    'button[aria-label*="more comment"]',
    'button.comments-comments-list__show-previous-button'
  ];
  for (const s of sels) {
    document.querySelectorAll(s).forEach(b => { try { b.click(); clicked++; } catch (e) {} });
  }
  return JSON.stringify({clicked: clicked});
})()
""";

# Follower counts are NOT rendered on search result cards - verified against
# live LinkedIn. They ARE on the post page. Lane A's mid-tier gate would be a
# hollow claim if it only ever saw "unknown", so the gate runs here instead.
glob AUTHOR_STATS_JS: str = """
(() => {
  const t = document.body ? document.body.innerText : '';
  const m = t.match(/([0-9][0-9,\\.]*)\\s*([KkMm]?)\\s*followers/);
  return JSON.stringify({followers: m ? m[0] : ''});
})()
""";

glob READ_COMMENTS_JS: str = """
(() => {
  const SEL = 'article.comments-comment-entity, article.comments-comment-item, div.comments-comment-item';
  const BODY_SEL = '.comments-comment-item__main-content, .update-components-text, .comments-comment-entity__content';
  const out = [];
  const seen = new Set();
  const add = (el, via) => {
    const who = el.querySelector('a[href*="/in/"]');
    if (!who) return;
    const href = (who.href || '').split('?')[0];
    const m = href.match(/\\/in\\/([^\\/]+)/);
    const handle = m ? m[1] : '';
    if (!handle || seen.has(handle)) return;
    const body = el.querySelector(BODY_SEL);
    const text = (body ? body.innerText : el.innerText || '').trim();
    // A comment is prose attached to one person. Anything shorter is chrome.
    if (text.length < 25) return;
    seen.add(handle);
    out.push({handle: handle, url: href,
              name: (who.innerText || '').trim().split('\\n')[0],
              text: text.slice(0, 700), via: via});
  };

  let items = document.querySelectorAll(SEL);
  const containers = items.length;
  for (const it of items) { add(it, 'class'); if (out.length >= 60) break; }

  // Class names rotate - .pv-top-card did, and this extractor is Lane A's core.
  // If the known selectors match nothing, fall back to structure: any element
  // holding exactly one profile link and enough prose to be a comment. The
  // gates are the same either way so the fallback cannot lower the bar.
  let via2 = 0;
  if (!out.length) {
    const cands = document.querySelectorAll('[class*="comments-comment"], article, li[data-id], div[data-id]');
    for (const el of cands) {
      if (el.querySelectorAll('a[href*="/in/"]').length !== 1) continue;
      add(el, 'structure');
      via2++;
      if (out.length >= 60) break;
    }
  }

  return JSON.stringify({
    items: out,
    diag: {
      containers: containers,
      wildcard: document.querySelectorAll('[class*="comments-comment"]').length,
      anchors: document.querySelectorAll('a[href*="/in/"]').length,
      fallback_scanned: via2,
      body_len: (document.body ? document.body.innerText : '').length
    }
  });
})()
""";





obj LaneBrowser {
    """One lane's browser. Each lane owns its own session, its own CDP socket
    and its own message-id counter - three concurrent lanes must never share a
    reply stream.
    """

    has lane_id: str;
    has session_id: str = "";
    has live_url: str = "";
    has page_sess: str = "";
    has session: any = None;
    has offline: bool = False;
    # Canned page results, keyed by a substring of the URL. ONLY consulted when
    # `offline` is True, which only the test suite sets - there is no path from
    # a real run into this dict. It exists so the whole pipeline (ladder, dry
    # branch, harvest, merge, convergence) can be exercised with no network and
    # no API keys.
    has fixture: dict = {};
    has last_url: str = "";
    has last_error: str = "";

    def open(context_id: str) -> bool;
    def goto(url: str) -> bool;
    def eval_json(expr: str) -> any;
    def close_session;
}


impl LaneBrowser.open(context_id: str) -> bool {
    # persist=False is load-bearing: a research lane reads the canonical login
    # but can never write back to it, so no lane can damage the auth mid-demo.
    if self.offline {
        return True;
    }
    try {
        self.session = new_session(
            context_id=context_id, persist=False, proxies=True
        );
        self.session_id = self.session.session_id;
        self.live_url = self.session.live_url;
        if not self.session_id {
            self.last_error = "Browserbase returned no session id";
            return False;
        }
        return True;
    } except Exception as e {
        # Surfaced, never swallowed - the lane narrates this and stops.
        self.last_error = f"{type(e).__name__}: {e}";
        return False;
    }
}


impl LaneBrowser.goto(url: str) -> bool {
    self.last_url = url;
    if self.offline {
        return True;
    }
    if self.session is None {
        self.last_error = "goto before open";
        return False;
    }
    ok = self.session.goto(url, settle=1.2);
    if not ok {
        self.last_error = f"navigation failed for {url}";
    }
    return ok;
}


impl LaneBrowser.eval_json(expr: str) -> any {
    if self.offline {
        # Test mode only. Keys are URL substrings; the comment reader is
        # detected by its selector so one fixture can serve both passes.
        which = "_comments" if "comments-comment" in expr else self.last_url;
        for (key, val) in self.fixture.items() {
            if key in which {
                return val;
            }
        }
        return [];
    }
    if self.session is None {
        return None;
    }
    try {
        raw = self.session.eval_json(expr);
        # The extractors end in `JSON.stringify(...)`, so CDP hands back a
        # STRING and `eval_json` faithfully returns it. Decoding here rather
        # than returning the array straight from the page is deliberate:
        # returnByValue marshalling of a live object graph is the flakier path,
        # and a string round-trip is predictable. Verified against real
        # LinkedIn - without this the lane iterates the JSON text character by
        # character and every "row" is a one-character string.
        if isinstance(raw, str) {
            if not raw.strip() {
                return [];
            }
            return json.loads(raw);
        }
        return raw;
    } except Exception as e {
        self.last_error = f"evaluate failed: {type(e).__name__}: {e}";
        return None;
    }
}


impl LaneBrowser.close_session {
    if self.session is not None {
        try {
            self.session.close();
        } except Exception as e {
            self.last_error = f"close: {e}";
        }
    }
}


# ===========================================================================
# Parsing helpers - pure, so they are testable without a browser
# ===========================================================================

def parse_followers(block: str) -> int {
    """Follower count from a result card, or -1 when the page did not show one.

    -1 means *unknown*, and callers must treat it as unknown rather than as
    zero. Inventing a number here would silently corrupt Lane A's whole gate.
    """;
    m = re.search(r"([\d,\.]+)\s*([KkMm]?)\s*followers", block);
    if not m {
        return -1;
    }
    raw = m.group(1).replace(",", "");
    suffix = m.group(2).lower();
    try {
        val = float(raw);
    } except ValueError {
        return -1;
    }
    if suffix == "k" {
        val *= 1000;
    } elif suffix == "m" {
        val *= 1000000;
    }
    return int(val);
}


def parse_recency_days(block: str) -> int {
    """LinkedIn's relative timestamps ('3d', '2 weeks ago') as whole days.""";
    m = re.search(r"\b(\d+)\s*(m|h|d|w|mo|y)\b", block);
    if not m {
        return -1;
    }
    n = int(m.group(1));
    unit = m.group(2);
    if unit == "m" or unit == "h" { return 0; }
    if unit == "d" { return n; }
    if unit == "w" { return n * 7; }
    if unit == "mo" { return n * 30; }
    return n * 365;
}



# LinkedIn wraps the profile link's text in chrome - verified live: names came
# back as "View Neel Mahyavanshi's profile, open to work" and the first content
# line was "Feed post". Both are parsed off rather than shown to a judge.
glob NAME_CHROME_PREFIX: list[str] = ["view ", "voir ", "ver "];
glob BLOCK_CHROME: list[str] = [
    "feed post", "suggested", "promoted", "follow", "featured", "status is"
];
# Longest-first: matching "3rd" before "3rd+" leaves a stray "+" on the headline.
glob DEGREE_TOKENS: list[str] = ["3rd+", "2nd+", "1st+", "3rd", "2nd", "1st"];


obj Actor {
    """A post author's display name and headline, cleaned of LinkedIn chrome."""
    has name: str = "";
    has headline: str = "";
}


def clean_name(raw: str) -> str {
    """Strip the "View X's profile, open to work" wrapper off anchor text.""";
    s = " ".join(raw.split()).strip();
    if not s {
        return "";
    }
    low = s.lower();
    for pre in NAME_CHROME_PREFIX {
        if low.startswith(pre) {
            s = s[len(pre):];
            break;
        }
    }
    for marker in ["\u2019s profile", "'s profile", "s profile"] {
        idx = s.lower().find(marker);
        if idx > 0 {
            s = s[:idx];
            break;
        }
    }
    return s.strip().strip(",").strip();
}


def clean_headline(raw: str) -> str {
    """Drop the timestamp and follow-button text LinkedIn appends to the line.

    A headline reads "AI Engineer 25m Follow" straight off the card; the two
    trailing tokens are chrome and would show up in the demo UI.
    """;
    s = " ".join(raw.split()).strip();
    cut = re.search(r"\s\d+\s*(mo|[mhdwy])\b", s);
    if cut {
        s = s[:cut.start()];
    }
    for tail in ["Follow", "\u2022", "Connect", "Message"] {
        while s.strip().endswith(tail) {
            s = s.strip()[: -len(tail)].strip();
        }
    }
    return s.strip(" \u2022-|").strip();
}


def parse_actor(block: str, anchor_name: str) -> Actor {
    """Pull the author and headline out of a result card's text block.

    The first content line looks like "Jay P. \u2022 3rd+ Staff AI Engineer @ Apple",
    sometimes preceded by chrome such as "Feed post". Splitting on the bullet
    beats trusting the anchor, which carries accessibility text.
    """;
    for line in block.split("\n") {
        s = line.strip();
        if not s {
            continue;
        }
        low = s.lower();
        # `skip` is a reserved traversal keyword in Jac - hence is_chrome.
        is_chrome = False;
        for c in BLOCK_CHROME {
            if low == c or low.startswith(c + " ") {
                s = s[len(c):].strip() if low.startswith(c + " ") else "";
                low = s.lower();
                if not s {
                    is_chrome = True;
                }
                break;
            }
        }
        if is_chrome or not s {
            continue;
        }
        parts = [x.strip() for x in s.split("\u2022")];
        nm = parts[0].strip();
        head = "";
        if len(parts) > 1 {
            rest = " ".join(parts[1:]).strip();
            for d in DEGREE_TOKENS {
                if rest.startswith(d) {
                    rest = rest[len(d):].strip();
                    break;
                }
            }
            head = clean_headline(rest);
        }
        if nm {
            return Actor(name=nm, headline=head[:220]);
        }
    }
    return Actor(name=clean_name(anchor_name), headline="");
}


glob RECRUITER_MARKERS: list[str] = [
    "recruiter", "talent acquisition", "hiring for", "we are hiring",
    "staffing", "headhunter", "talent partner"
];

glob VENDOR_MARKERS: list[str] = [
    "we built", "our platform", "check out our", "try our", "book a demo",
    "we just launched", "our product", "founder of", "ceo at"
];


def looks_recruiter(text: str) -> bool {
    low = text.lower();
    for m in RECRUITER_MARKERS {
        if m in low { return True; }
    }
    return False;
}


def looks_vendor(text: str) -> bool {
    low = text.lower();
    for m in VENDOR_MARKERS {
        if m in low { return True; }
    }
    return False;
}


glob FIRST_PERSON_MARKERS: list[str] = [
    "i ", "i'm", "im ", "we ", "we're", "our ", "my ", "us ", "i've", "we've"
];


def looks_first_person(text: str) -> bool {
    low = " " + text.lower().strip();
    for m in FIRST_PERSON_MARKERS {
        if m in low { return True; }
    }
    return False;
}


def heuristic_verdicts(texts: list[str]) -> list[CommentVerdict] {
    """Keyword fallback used only when the LLM classifier is unreachable.

    Deliberately cruder than the model. The lane says out loud that it dropped
    to this, so a degraded run is never mistaken for a clean one.
    """;
    out = [];
    for (i, t) in enumerate(texts) {
        vendor = looks_vendor(t);
        pain = looks_first_person(t) and not vendor and len(t.split()) >= 8;
        out.append(
            CommentVerdict(
                index=i,
                is_pain=pain,
                is_vendor=vendor,
                summary="stated problem" if pain else "",
                relevance=0.5 if pain else 0.0
            )
        );
    }
    return out;
}


# ===========================================================================
# LinkedInLane - the shared traversal, ladder and narration
#
# Subclasses override `harvest` only. Everything about *how a lane moves* is
# here exactly once; everything about *what a lane is looking for* is in the
# subclass. That is the whole point of three lanes instead of one with flags.
# ===========================================================================

walker LinkedInLane {
    """Base lane: walks its probe ladder, narrating as it goes."""

    has lane_id: LaneId = LaneId.A;
    has context_id: str = "";
    has hypothesis: str = "";
    has phrases: list[str] = [];
    has offline: bool = False;
    has fixture: dict = {};
    # Wall-clock budget. A lane that overruns disengages CLEANLY and reports
    # what it has: `wait` on a hung lane blocks all four and freezes the
    # dashboard, which is an unrecoverable failure on a 4-minute stage.
    #
    # 90s, not longer, and the reason is presentational rather than technical:
    # a lane that stops at 90s having narrated a clean handover reads as
    # deliberate, while one still grinding at minute three reads as broken even
    # though it is working correctly.
    has deadline_s: float = 90.0;
    has started_at: float = 0.0;
    has timed_out: bool = False;

    has tactics: any = None;
    # The Lane this walker was spawned on. Captured once at entry rather than
    # rediscovered by walking Probe/Widened edges backwards from each probe:
    # reverse-edge reads race against the sibling lanes writing concurrently,
    # and the walker already knows the answer.
    has lane_node: any = None;
    has ladder: list[ProbeSpec] = [];
    has browser: any = None;

    has probes_run: int = 0;
    has found: int = 0;
    has seq: int = 0;
    has seen_handles: list[str] = [];
    has candidates: list[ProspectCandidate] = [];
    has llm_degraded: bool = False;
    has failure: str = "";

    def pace(seconds: float);
    def out_of_time -> bool;
    def narrate(here: Lane, sentence: str, kind: ReasoningKind);
    def classify(texts: list[str]) -> list[CommentVerdict];
    def search(here: Lane, probe: SearchProbe) -> list;
    def harvest(here: Lane, probe: SearchProbe, results: list) -> int;
    def record(here: Lane, probe: SearchProbe, cand: ProspectCandidate,
               kind: EvidenceKind, recency: int) -> bool;

    can begin with Lane entry {
        self.tactics = tactics_for(str(self.lane_id));
        t = self.tactics;

        self.lane_node = here;
        self.started_at = time.time();
        here.doctrine = t.doctrine;
        here.state = LaneState.LAUNCHING;
        here.keywords = self.phrases;

        # Staggered launch: 0 / 9 / 18s. Three authenticated sessions opening in the
        # same second is a textbook automation fingerprint.
        if t.stagger > 0.0 and not self.offline {
            time.sleep(t.stagger);
        }

        self.narrate(here, f"Lane {t.lane_id}. {t.doctrine}", ReasoningKind.PLAN);

        self.browser = LaneBrowser(
        lane_id=t.lane_id, offline=self.offline, fixture=self.fixture
    );
        if not self.browser.open(self.context_id) {
            here.state = LaneState.FAILED;
            self.failure = self.browser.last_error;
            self.narrate(
                here,
                f"Could not open a browser session: {self.browser.last_error}. "
                + "This lane is down - reporting that rather than pretending it ran.",
                ReasoningKind.MISS
            );
            disengage;
        }
        here.bb_session_id = self.browser.session_id;
        here.live_url = self.browser.live_url;

        # Differentiated opening move. A lands on content search, B on the feed, C
        # on the network page - so no two lanes are ever loading the same page type
        # at the same instant.
        self.browser.goto(opening_url(t));
        self.pace(t.action_delay);

        self.ladder = build_ladder(t, self.phrases);
        dropped = ladder_was_capped(t, self.phrases);
        if dropped > 0 {
            self.narrate(
                here,
                f"The plan gives me {count_phrase(len(self.phrases), 'phrasing', 'phrasings')} "
                + f"to work through. I am taking the strongest {numword(len(self.ladder))} "
                + f"and dropping {numword(dropped)} - better to search a few "
                + "angles properly than to still be typing when the demo ends.",
                ReasoningKind.PLAN
            );
        }
        if not self.ladder {
            here.state = LaneState.DRY;
            self.narrate(
                here,
                "No phrases were assigned to this lane, so there is nothing to run.",
                ReasoningKind.MISS
            );
            disengage;
        }

        first = self.ladder[0];
        here.state = LaneState.SEARCHING;
        self.narrate(
            here,
            say_opening(t.name, first.keywords, human_window(first.date_posted)),
            ReasoningKind.PLAN
        );

        seed = here +>:Probe(created_at=time.time()):+> SearchProbe(
            keywords=first.keywords,
            date_posted=first.date_posted,
            rung=first.rung,
            move=first.move,
            reason=first.reason,
            url=probe_url(first)
        );
        visit seed;
    }

    can at_probe with SearchProbe entry {
        t = self.tactics;

        if self.out_of_time() {
            self.timed_out = True;
            here.state = "abandoned";
            lane_stop = self.lane_node;
            lane_stop.state = LaneState.DONE if self.found > 0 else LaneState.DRY;
            self.narrate(
                lane_stop,
                f"I am out of time on this angle - {count_phrase(self.probes_run, 'query', 'queries')} "
                + f"run, {count_phrase(self.found, 'name', 'names')} kept. Stopping "
                + "here and handing over what I have rather than leaving the "
                + "panel spinning.",
                ReasoningKind.MISS
            );
            disengage;
        }

        self.probes_run += 1;
        here.state = "running";

        if self.probes_run > 1 {
            self.narrate(
                self.lane_node,
                say_next_query(here.keywords, human_window(here.date_posted)),
                ReasoningKind.PLAN
            );
        }

        lane_node = self.lane_node;
        results = self.search(lane_node, here);
        here.result_count = len(results);

        if results {
            lane_node.state = LaneState.READING;
            self.narrate(
                lane_node, say_results(len(results), here.keywords),
                ReasoningKind.OBSERVE
            );
            got = self.harvest(lane_node, here, results);
            here.yield_count = got;
            self.found += got;
        } else {
            here.yield_count = 0;
            self.narrate(
                lane_node,
                say_results(0, here.keywords) + " "
                + say_dry(here.keywords, human_window(here.date_posted)),
                ReasoningKind.OBSERVE
            );
        }

        if self.found >= t.target_yield {
            here.state = "yielded";
            lane_node.state = LaneState.DONE;
            self.narrate(
                lane_node, say_lane_summary(t.lane_id, self.found, self.probes_run),
                ReasoningKind.HIT
            );
            disengage;
        }

        # Dry (or thin) - grow the next rung and walk into it. The pivot is a real
        # edge in the graph, not a branch in a loop.
        here.state = "dry" if here.yield_count == 0 else "thin";
        nxt_index = here.rung + 1;
        if nxt_index >= len(self.ladder) {
            lane_node.state = LaneState.DRY if self.found == 0 else LaneState.DONE;
            self.narrate(
                lane_node, say_exhausted(t.name, self.probes_run, self.found),
                ReasoningKind.MISS if self.found == 0 else ReasoningKind.HIT
            );
            disengage;
        }

        nxt = self.ladder[nxt_index];
        lane_node.state = LaneState.DRY;
        lane_node.query_index = nxt_index;
        self.narrate(
            lane_node,
            say_pivot(nxt.move, nxt.reason, nxt.keywords, human_window(nxt.date_posted)),
            ReasoningKind.PIVOT
        );

        child = here +>:Widened(because=here.state):+> SearchProbe(
            keywords=nxt.keywords,
            date_posted=nxt.date_posted,
            rung=nxt.rung,
            move=nxt.move,
            reason=nxt.reason,
            url=probe_url(nxt)
        );
        visit child;
    }
}


# --- narration -------------------------------------------------------------

impl LinkedInLane.out_of_time -> bool {
    """True once this lane has spent its wall-clock budget.

    Checked before every probe and between results inside a harvest, so the
    lane can stop at a coherent point rather than being killed mid-write.
    """;
    if self.started_at <= 0.0 {
        return False;
    }
    return (time.time() - self.started_at) >= self.deadline_s;
}


impl LinkedInLane.pace(seconds: float) {
    """Inter-action delay.

    Online this is the real anti-detection pacing - fixed per lane rather than
    random, so a morning rehearsal predicts the evening demo. Offline it drops
    to a short beat: the test suite still overlaps in time (which is what proves
    the lanes are concurrent) without waiting on production timings.
    """;
    time.sleep(0.15 if self.offline else seconds);
}


impl LinkedInLane.narrate(here: Lane, sentence: str, kind: ReasoningKind) {
    self.seq += 1;
    r = Reasoning(t=time.time(), sentence=sentence, kind=kind);
    here +>:Emitted(seq=self.seq):+> r;
}


impl LinkedInLane.classify(texts: list[str]) -> list[CommentVerdict] {
    if not texts {
        return [];
    }
    if self.offline {
        # Declared test mode - use the deterministic classifier so a run with no
        # API key is reproducible rather than merely degraded.
        return heuristic_verdicts(texts);
    }
    try {
        verdicts = classify_texts(self.hypothesis, texts);
        if len(verdicts) == len(texts) {
            return verdicts;
        }
        # A short or misaligned list would silently mis-attribute quotes to the
        # wrong people, so we refuse it rather than trusting the indexes.
        self.llm_degraded = True;
        return heuristic_verdicts(texts);
    } except Exception as e {
        self.llm_degraded = True;
        self.failure = f"classifier unavailable: {type(e).__name__}: {e}";
        return heuristic_verdicts(texts);
    }
}








# --- search: navigate and extract ------------------------------------------

impl LinkedInLane.search(here: Lane, probe: SearchProbe) -> list {
    t = self.tactics;
    ok = self.browser.goto(probe.url);
    if not ok {
        self.narrate(
            here,
            f"That page would not load ({self.browser.last_error}). "
            + "Treating it as dry and moving down the ladder rather than retrying "
            + "into a rate limit.",
            ReasoningKind.MISS
        );
        return [];
    }
    self.pace(t.action_delay);
    raw = self.browser.eval_json(EXTRACT_JS);
    if raw is None {
        return [];
    }
    return raw[: t.results_per_probe];
}


# --- recording a find ------------------------------------------------------

impl LinkedInLane.record(
    here: Lane, probe: SearchProbe, cand: ProspectCandidate,
    kind: EvidenceKind, recency: int
) -> bool {
    if cand.handle in self.seen_handles {
        return False;
    }
    self.seen_handles.append(cand.handle);

    p = here +>:Surfaced(
        at_rank=len(self.candidates) + 1,
        found_at=time.time(),
        query=probe.keywords
    ):+> Prospect(
        name=cand.name,
        handle=cand.handle,
        headline=cand.headline,
        company=cand.company
    );

    ev = p +>:HasEvidence(
        lane=self.lane_id, confidence=cand.relevance
    ):+> Evidence(
        source=EvidenceSource.LINKEDIN,
        quote=cand.quote,
        url=cand.source_url,
        kind=kind,
        recency_days=recency
    );

    self.candidates.append(cand);
    self.narrate(here, say_yield(cand.name, cand.quote, recency), ReasoningKind.HIT);
    return True;
}


impl LinkedInLane.harvest(here: Lane, probe: SearchProbe, results: list) -> int {
    # The base lane has no doctrine of its own - every concrete lane overrides
    # this. Failing loudly beats silently harvesting nothing.
    raise NotImplementedError(
        "LinkedInLane is abstract; spawn LaneA, LaneB or LaneC."
    );
}




# ===========================================================================
# Lane A - comment mining under mid-tier practitioner posts
# ===========================================================================

walker LaneA(LinkedInLane) {
    """Reads the comments, not the post.

    The post is the author's opinion. The comments are other people
    volunteering that they have the same problem - which is a much better
    signal, but only under accounts small enough that the section is not
    applause.
    """
    has rejected_big: int = 0;

    def harvest(here: Lane, probe: SearchProbe, results: list) -> int;
}


impl LaneA.harvest(here: Lane, probe: SearchProbe, results: list) -> int {
    t = self.tactics;
    got = 0;

    for r in results {
        # Lane A navigates once PER RESULT, so the budget has to be checked
        # here too - a single probe can otherwise outlast the whole deadline.
        if self.out_of_time() {
            self.timed_out = True;
            return got;
        }
        block = str(r.get("block", ""));
        actor = parse_actor(block, str(r.get("name", "")));
        author = actor.name if actor.name else str(r.get("handle", ""));
        post_url = str(r.get("url", ""));

        # Follower counts are not on the search card (verified live), so the
        # gate cannot run until we are on the post. Open it, then judge.
        if not self.browser.goto(post_url) {
            continue;
        }
        self.pace(t.action_delay);

        stats = self.browser.eval_json(AUTHOR_STATS_JS);
        followers = -1;
        if stats is not None and isinstance(stats, dict) {
            followers = parse_followers(str(stats.get("followers", "")));
        }

        # The defining move: reject loudly, on the record.
        if followers >= 0 {
            verdict = midtier_verdict(followers);
            if verdict != "mid" {
                self.rejected_big += 1;
                self.narrate(
                    here, say_midtier_reject(author, followers, verdict),
                    ReasoningKind.MISS
                );
                continue;
            }
            self.narrate(
                here, say_midtier_accept(author, followers), ReasoningKind.OBSERVE
            );
        } else {
            self.narrate(
                here,
                f"{author} does not publish a follower count, so I cannot size "
                + "the audience. Reading the comments anyway, but weighting "
                + "anything I find here lower.",
                ReasoningKind.OBSERVE
            );
        }

        self.browser.eval_json(EXPAND_COMMENTS_JS);
        self.pace(0.8);
        # NOT named `harvest` - that is this walker's own method, and the local
        # would shadow it.
        raw_comments = self.browser.eval_json(READ_COMMENTS_JS) or [];
        # Accept both shapes. The live extractor returns {items, diag}; the
        # offline fixtures return a bare list, and a fixture should not have to
        # be rewritten every time the diagnostics around it change.
        comments: list = [];
        diag: dict = {};
        if isinstance(raw_comments, dict) {
            comments = raw_comments.get("items") or [];
            diag = raw_comments.get("diag") or {};
        } else {
            comments = raw_comments as list;
        }

        if not comments {
            # "Comments are closed" is a claim about LinkedIn. A selector that
            # matched nothing is a claim about us. Saying the first when the
            # second is true is how a lane reports zero comments on a post with
            # forty-one and sounds confident doing it.
            containers = int(diag.get("containers") or 0);
            anchors = int(diag.get("anchors") or 0);
            if containers == 0 and anchors > 2 {
                self.narrate(
                    here,
                    f"My comment selector matched nothing on a page still showing "
                    + f"{anchors} profile links, and the structural fallback found "
                    + "no comment-shaped elements either. That is a scraper problem, "
                    + "not an empty comment section - I am not going to call this post quiet.",
                    ReasoningKind.MISS
                );
            } else {
                self.narrate(
                    here, "Comments are closed on this one. Nothing to mine.",
                    ReasoningKind.MISS
                );
            }
            continue;
        }
        if comments and str(comments[0].get("via", "")) == "structure" {
            self.narrate(
                here,
                f"LinkedIn has rotated the comment class names, so I read these "
                + f"{len(comments)} by structure instead. Same quality gates.",
                ReasoningKind.OBSERVE
            );
        }

        texts = [str(c.get("text", "")) for c in comments];
        verdicts = self.classify(texts);
        if self.llm_degraded {
            self.narrate(
                here,
                "The language model is not answering, so I am falling back to a "
                + "cruder keyword filter. Treat this lane's picks as weaker until "
                + "it recovers.",
                ReasoningKind.MISS
            );
            self.llm_degraded = False;
        }

        pain = [v for v in verdicts if v.is_pain];
        noise = len(verdicts) - len(pain);
        desc = pain[0].summary if pain and pain[0].summary else "problem";

        self.narrate(
            here, say_comment_scan(len(comments), noise, len(pain), desc),
            ReasoningKind.OBSERVE
        );

        for v in pain {
            if v.index >= len(comments) { continue; }
            c = comments[v.index];
            handle = str(c.get("handle", ""));
            if not handle { continue; }
            conf = v.relevance if followers >= 0 else v.relevance * 0.8;
            cand = ProspectCandidate(
                name=clean_name(str(c.get("name", ""))) or handle,
                handle=handle,
                headline="",
                company="",
                quote=str(c.get("text", "")),
                source_url=post_url,
                evidence_kind=EvidenceKind.COMMENT,
                relevance=conf
            );
            if self.record(
                here, probe, cand, EvidenceKind.COMMENT, parse_recency_days(block)
            ) {
                got += 1;
            }
            if self.found + got >= t.target_yield { return got; }
        }
    }
    return got;
}


# ===========================================================================
# Lane B - post authorship, first-person problem statements
# ===========================================================================

walker LaneB(LinkedInLane) {
    """Wants the complaint itself, written by the person who has the problem.

    Ignores comment sections entirely. Someone who cared enough to write the
    post is closer to buying than someone who typed a reply under it.
    """
    has skipped_abstract: int = 0;

    def harvest(here: Lane, probe: SearchProbe, results: list) -> int;
}


impl LaneB.harvest(here: Lane, probe: SearchProbe, results: list) -> int {
    got = 0;
    blocks = [str(r.get("block", "")) for r in results];

    vendors = 0;
    practitioners = 0;
    for b in blocks {
        if looks_vendor(b) { vendors += 1; } else { practitioners += 1; }
    }
    self.narrate(
        here, say_vendor_split(len(blocks), vendors, practitioners),
        ReasoningKind.OBSERVE
    );

    recruiters = len([b for b in blocks if looks_recruiter(b)]);
    if recruiters > 0 {
        self.narrate(here, say_recruiter_drop(recruiters), ReasoningKind.MISS);
    }

    keep = [];
    for r in results {
        b = str(r.get("block", ""));
        if looks_vendor(b) or looks_recruiter(b) { continue; }
        keep.append(r);
    }
    if not keep {
        return 0;
    }

    verdicts = self.classify([str(r.get("block", "")) for r in keep]);
    if self.llm_degraded {
        self.narrate(
            here,
            "The classifier is unreachable; falling back to a keyword filter and "
            + "flagging these picks as lower confidence.",
            ReasoningKind.MISS
        );
        self.llm_degraded = False;
    }

    for v in verdicts {
        if v.index >= len(keep) { continue; }
        r = keep[v.index];
        block = str(r.get("block", ""));
        actor = parse_actor(block, str(r.get("name", "")));
        author = actor.name if actor.name else str(r.get("handle", ""));

        if not v.is_pain {
            self.skipped_abstract += 1;
            self.narrate(here, say_post_body(author, False), ReasoningKind.MISS);
            continue;
        }

        days = parse_recency_days(block);
        if days > 21 {
            self.narrate(here, say_stale(author, days), ReasoningKind.MISS);
            continue;
        }

        self.narrate(here, say_post_body(author, True), ReasoningKind.OBSERVE);
        cand = ProspectCandidate(
            name=author,
            handle=str(r.get("handle", "")),
            headline=actor.headline,
            company="",
            quote=first_meaningful_line(block),
            source_url=str(r.get("url", "")),
            evidence_kind=EvidenceKind.POST,
            relevance=v.relevance
        );
        if cand.handle and self.record(here, probe, cand, EvidenceKind.POST, days) {
            got += 1;
        }
        if self.found + got >= self.tactics.target_yield { return got; }
    }
    return got;
}


def first_meaningful_line(block: str) -> str {
    """The longest line in a card - in practice the post body, not the chrome.""";
    best = "";
    for line in block.split("\n") {
        s = line.strip();
        if len(s) > len(best) {
            best = s;
        }
    }
    return truncate_quote(best, 400);
}


# ===========================================================================
# Lane C - synonym sweep across adjacent vocabulary
# ===========================================================================

walker LaneC(LinkedInLane) {
    """A breadth instrument: many phrasings, few results each.

    Whatever words we happened to pick are the ones we will over-find. C runs
    the phrasings the other two lanes will never type, looking for the
    vocabulary nobody on the team thought of.
    """
    has vocabulary_hits: list[str] = [];

    def harvest(here: Lane, probe: SearchProbe, results: list) -> int;
}


impl LaneC.harvest(here: Lane, probe: SearchProbe, results: list) -> int {
    got = 0;
    keep = [r for r in results if not looks_vendor(str(r.get("block", "")))];
    if not keep {
        self.narrate(
            here,
            "Everything on this page is someone selling a fix rather than "
            + "someone who has the problem. That is a vendor keyword, not a "
            + "customer one - noting it and moving on.",
            ReasoningKind.MISS
        );
        return 0;
    }

    verdicts = self.classify([str(r.get("block", "")) for r in keep]);
    if self.llm_degraded {
        self.narrate(
            here,
            "Classifier unreachable; dropping to keyword matching for this sweep "
            + "and marking the results lower confidence.",
            ReasoningKind.MISS
        );
        self.llm_degraded = False;
    }

    for v in verdicts {
        if v.index >= len(keep) or not v.is_pain { continue; }
        r = keep[v.index];
        block = str(r.get("block", ""));
        actor = parse_actor(block, str(r.get("name", "")));
        author = actor.name if actor.name else str(r.get("handle", ""));
        handle = str(r.get("handle", ""));
        if not handle { continue; }

        if v.summary and v.summary not in self.vocabulary_hits {
            self.vocabulary_hits.append(v.summary);
            self.narrate(
                here,
                f"\"{probe.keywords}\" surfaced someone describing it as "
                + f"{v.summary} - that is a phrasing the other lanes are not "
                + "searching. Worth adding to the vocabulary.",
                ReasoningKind.OBSERVE
            );
        }

        cand = ProspectCandidate(
            name=author,
            handle=handle,
            headline=actor.headline,
            company="",
            quote=first_meaningful_line(block),
            source_url=str(r.get("url", "")),
            evidence_kind=EvidenceKind.POST,
            relevance=v.relevance
        );
        if self.record(here, probe, cand, EvidenceKind.POST, parse_recency_days(block)) {
            got += 1;
        }
        if self.found + got >= self.tactics.target_yield { return got; }
    }
    return got;
}


# ===========================================================================
# The fan-out
# ===========================================================================

obj LaneResult {
    has lane_id: str;
    has found: int = 0;
    has probes_run: int = 0;
    has failure: str = "";
    has live_url: str = "";
    # Wall-clock bounds of this lane's run. Two lanes whose intervals overlap
    # were genuinely running at the same time - that is the assertion that
    # proves `flow` is doing real work and not quietly serializing.
    has started_at: float = 0.0;
    has finished_at: float = 0.0;
    # True when the lane hit its wall-clock bound. A partial result must never
    # be presentable as a complete one.
    has timed_out: bool = False;
}


obj LaneSpec {
    """A lane node plus the vocabulary it was handed - what `flow` carries.

    Everything a lane thread needs is bundled here for a concrete reason: a bare
    local `list` is not sendable across a concurrency boundary (E1308), while a
    field read off this object is. One object per lane, read once at launch.
    """
    has node: Lane;
    has lane_id: str;
    has phrases: list[str] = [];
    has pains: list[str] = [];
    has negatives: list[str] = [];
    # Pre-encoded at construction: only scalars and strings cross a `flow`
    # boundary cleanly (E1308), and decoding per-thread also guarantees no two
    # lanes share one mutable list.
    has lane_jid: str = "";
    has phrases_json: str = "";
    has pains_json: str = "";
    has negatives_json: str = "";
}


def run_lane(
    lane_node: Lane, lane_id: str, context_id: str, hypothesis: str,
    phrases_json: str, offline: bool, fixture_json: str, deadline_s: float
) -> LaneResult {
    """One lane, start to finish, inside its own thread.

    Runs on the thread `flow` hands it. Everything it touches hangs off
    `lane_node`, so the three LinkedIn lanes never write to the same edge list.

    `fixture_json` crosses as a string rather than a dict on purpose: a mutable
    container is not sendable across a concurrency boundary (E1308), and
    decoding per-thread guarantees no lane can mutate another lane's copy.
    """;
    fixture: dict = json.loads(fixture_json) if fixture_json else {};
    phrases: list[str] = json.loads(phrases_json) if phrases_json else [];
    w: LinkedInLane = LaneC(
        lane_id=LaneId.C, context_id=context_id, hypothesis=hypothesis,
        phrases=phrases, offline=offline, fixture=fixture,
        deadline_s=deadline_s
    );
    if lane_id == "A" {
        w = LaneA(lane_id=LaneId.A, context_id=context_id, hypothesis=hypothesis,
                  phrases=phrases, offline=offline, fixture=fixture,
                  deadline_s=deadline_s);
    } elif lane_id == "B" {
        w = LaneB(lane_id=LaneId.B, context_id=context_id, hypothesis=hypothesis,
                  phrases=phrases, offline=offline, fixture=fixture,
                  deadline_s=deadline_s);
    }
    t0 = time.time();
    try {
        lane_node spawn w;
    } except Exception as e {
        lane_node.state = LaneState.FAILED;
        return LaneResult(
            lane_id=lane_id, found=0, probes_run=w.probes_run,
            failure=f"{type(e).__name__}: {e}",
            started_at=t0, finished_at=time.time()
        );
    } finally {
        if w.browser is not None {
            w.browser.close_session();
        }
    }
    return LaneResult(
        lane_id=lane_id,
        found=w.found,
        probes_run=w.probes_run,
        failure=w.failure,
        live_url=lane_node.live_url,
        started_at=t0,
        finished_at=time.time(),
        timed_out=w.timed_out
    );
}


def launch_lane(
    lane_node: Lane, lane_id: str, phrases_json: str,
    ctx: str, hyp: str, off: bool, fx: str, deadline_s: float
) -> any {
    """Start one lane and hand back its future.

    Launching through a function rather than writing `flow run_lane(s.node, ...)`
    inline in the comprehension is NOT stylistic. In Jac 0.34.7 a `flow` call
    whose arguments reference the comprehension's loop variable is racy: the
    thread can read that variable AFTER the loop has advanced, so every lane
    ends up running the LAST spec. Observed live - all three panels became lane
    C, writing 3x the narration onto one Lane node while A and B sat empty.
    A function call gives each invocation its own parameter binding, so there is
    no shared variable left for a thread to re-read.
    """;
    return flow run_lane(
        lane_node, lane_id, ctx, hyp, phrases_json, off, fx, deadline_s
    );
}


def run_lane_w(
    lane_jid: str, warm_url: str, warm_name: str, preferred: str,
    warm_email: str, ctx: str
) -> dict {
    """Body of Lane W, run inside its own thread.

    Takes a jid rather than a node for the same reason the other lanes do: a
    container is not sendable across a concurrency boundary, and re-resolving
    with jobj() inside the thread makes this thread's writes visible.
    """;
    lane = jobj(lane_jid);
    w: LaneW = LaneW(
        context_id=ctx, warm_url=warm_url, warm_name=warm_name,
        preferred_name=preferred, warm_email=warm_email
    );
    w spawn lane;
    return {"lane": "W", "evidence": w.evidence_written, "failure": w.failure};
}


def launch_lane_w(
    lane_jid: str, warm_url: str, warm_name: str, preferred: str,
    warm_email: str, ctx: str
) -> any {
    """Same eager-binding rule as launch_lane - see the note there.""";
    return flow run_lane_w(lane_jid, warm_url, warm_name, preferred, warm_email, ctx);
}


def launch_github(
    lane_node: Lane, keywords_json: str, pains_json: str, negatives_json: str
) -> any {
    """Same eager-binding rule as launch_lane - see the note there.""";
    return flow run_github_lane(
        lane_node, keywords_json, pains_json, negatives_json
    );
}


walker:pub RunResearch {
    """Fans four lanes out with `flow`, collects with `wait`, then merges.

    The launch and the collect are two separate passes on purpose. A `wait`
    inside the launch loop would serialize the whole thing silently - the lanes
    would still work, they would just take four times as long and the
    parallelism would be a lie.
    """

    has context_id: str = "";
    has offline: bool = False;
    # Offline page fixtures, test-suite only - see LaneBrowser.fixture.
    has fixture: dict = {};
    # Per-lane wall-clock budget. The orchestrator must never be able to hang:
    # every lane disengages cleanly at this bound and reports partials.
    # Default lives here rather than at the call site - the call site is the
    # thing most likely to be typed wrong under pressure.
    has lane_deadline_s: float = 90.0;
    has include_github: bool = True;
    has run: any = None;
    has lane_results: list[LaneResult] = [];
    has converged: int = 0;
    has unique_prospects: int = 0;
    has reports: list[dict] = [];

    def merge(run: ResearchRun);
    def narrate_run(lane: Lane, sentence: str, kind: ReasoningKind);

    # POST /walker/<name> spawns on ROOT. Without this the HTTP route -- the
    # dashboard's Go button -- returned 200, reported [], and touched nothing:
    # no run, no lane, no browser, in 0.0 seconds. Silent success is the worst
    # possible answer on the demo's critical path.
    can from_root with Root entry {
        founders = [-->[?:Founder]];
        if not founders {
            report {
                "ok": False,
                "error": "no Founder on the graph - run PlanCampaign (or intake) first"
            };
            disengage;
        }
        visit founders;
    }

    can start with Founder entry;
    can finish with Founder exit;
}



impl RunResearch.start with Founder entry {
    icps = [here ->:Targets:->];
    if not icps {
        raise ValueError(
            "Founder has no ICP - run PlanCampaign before RunResearch. "
            + "Without an ICP there are no phrases to search and the lanes would "
            + "spin on empty queries."
        );
    }
    icp = icps[0];

    ctx: str = self.context_id if self.context_id else env(
        "BROWSERBASE_LINKEDIN_CONTEXT_ID", "", False
    );

    run = here +>:Runs(created_at=time.time()):+> ResearchRun(
        started_at=time.time(), status=RunStatus.RUNNING
    );
    self.run = run;

    # Build the lane nodes up front so the dashboard has something to bind to
    # before any of them has produced a single line.
    specs: list[LaneSpec] = [];
    for lid in ["A", "B", "C"] {
        t = tactics_for(lid);
        phrases: list[str] = phrases_for_lane(
            lid, icp.pain_phrases, icp.keywords
        );
        lane_node = run +>:HasLane(launched_at=time.time()):+> Lane(
            lane_id=LaneId(lid), doctrine=t.doctrine, keywords=phrases
        );
        specs.append(
            LaneSpec(
                node=lane_node, lane_id=lid, phrases=phrases,
                lane_jid=jid(lane_node), phrases_json=json.dumps(phrases)
            )
        );
    }

    # ---- launch: every lane starts NOW ------------------------------------
    # Two passes, deliberately. A `wait` inside this comprehension would
    # serialize all three lanes and the parallelism would be a lie.
    hypothesis: str = icp.hypothesis;
    offline: bool = self.offline;
    fixture_json: str = json.dumps(self.fixture) if self.fixture else "";
    deadline: float = self.lane_deadline_s;
    # Attribute reads happen here, at the call site, BEFORE the thread starts -
    # that is what removes the race. Lists cross as JSON (E1308: a container is
    # not sendable across a concurrency boundary) and are decoded per-thread.
    # ONE DISTINCTLY-NAMED VARIABLE PER LANE. This shape is load-bearing and
    # was arrived at by fixing the same bug from two opposite directions:
    #
    #   `[flow run_lane(s.node, ...) for s in specs]`  -> RACES. The worker can
    #   read the loop variable after the loop advanced, so all three lanes ran
    #   the LAST spec: three identical panels, no error.
    #
    #   passing `jid(node)` and calling `jobj()` in the worker -> fixed the race
    #   but 500s over HTTP. In a server request the walker is bound to the GUEST
    #   root and the `flow` thread does not inherit that binding, so `jobj()`
    #   cannot see a Lane created microseconds earlier. It resolved fine under
    #   `jac run` only because the local root is ambient in that process.
    #
    # Separate names solve both: nothing is shared to race on, and the real node
    # crosses so no root lookup is needed. Three lanes is fixed by the demo.
    futures = [];
    if len(specs) > 0 {
        sa = specs[0];
        futures.append(
            launch_lane(
                sa.node, sa.lane_id, sa.phrases_json,
                ctx, hypothesis, offline, fixture_json, deadline
            )
        );
    }
    if len(specs) > 1 {
        sb = specs[1];
        futures.append(
            launch_lane(
                sb.node, sb.lane_id, sb.phrases_json,
                ctx, hypothesis, offline, fixture_json, deadline
            )
        );
    }
    if len(specs) > 2 {
        sc = specs[2];
        futures.append(
            launch_lane(
                sc.node, sc.lane_id, sc.phrases_json,
                ctx, hypothesis, offline, fixture_json, deadline
            )
        );
    }
    if len(specs) > 3 {
        # No silent cap: say what was dropped rather than quietly running three.
        print(
            f"RunResearch: {len(specs) - 3} LinkedIn lane(s) beyond the third "
            + "were not launched - the fan-out is unrolled to three by design."
        );
    }

    # Lane D is GitHub-first and programmatic - it never opens a browser, which
    # is exactly the visual contrast the demo wants. Owned by the identity
    # track; launched here so all four are genuinely in flight together.
    gh_specs: list[LaneSpec] = [];
    if self.include_github and not self.offline {
        gh_node = run +>:HasLane(launched_at=time.time()):+> Lane(
            lane_id=LaneId.D,
            doctrine="GitHub-first. I never open a browser - I read code, "
                     + "issues and commit history through the API, and I "
                     + "generate my own candidates instead of inheriting "
                     + "theirs.",
            keywords=icp.keywords
        );
        gh_specs.append(
            LaneSpec(
                node=gh_node,
                lane_id="D",
                phrases=icp.keywords,
                pains=icp.pain_phrases,
                negatives=icp.negative_keywords,
                lane_jid=jid(gh_node),
                phrases_json=json.dumps(icp.keywords),
                pains_json=json.dumps(icp.pain_phrases),
                negatives_json=json.dumps(icp.negative_keywords)
            )
        );
    }
    gh_futures = [];
    for gs in gh_specs {
        gh_futures.append(
            launch_github(
                gs.node, gs.phrases_json, gs.pains_json, gs.negatives_json
            )
        );
    }

    # ---- collect: only now do we block ------------------------------------
    # ---- Lane W: the warm lead, in the same fan-out --------------------
    # Previously RunResearch never referenced LaneW at all, so a working Go
    # button still produced no Becky - and a button that looks like it worked
    # while skipping the one prospect we email, call and book is worse than a
    # dead one. Launched here so all five lanes are genuinely in flight together.
    w_futures: list = [];
    warm_url: str = env("TEAMMATE_LINKEDIN_URL", "", False);
    if warm_url and not self.offline {
        w_node = run +>:HasLane(launched_at=time.time()):+> Lane(
            lane_id=LaneId.W,
            doctrine="One named warm lead, already trusted. Not searching - "
                     + "reading them properly, so the first email can quote "
                     + "what they actually said."
        );
        w_futures.append(
            launch_lane_w(
                jid(w_node), warm_url,
                env("TEAMMATE_NAME", "", False),
                env("TEAMMATE_PREFERRED_NAME", "", False),
                env("TEAMMATE_EMAIL", "", False),
                ctx
            )
        );
    }

    self.lane_results = (
        [wait f for f in futures]
        + [wait g for g in gh_futures]
        + [wait w for w in w_futures]
    );

    run.status = RunStatus.CROSSLINKING;
    self.merge(run);
}


# --- Lane D ----------------------------------------------------------------

def run_github_lane(
    lane_node: Lane, keywords_json: str, pains_json: str, negatives_json: str
) -> LaneResult {
    """Lane D, in its own thread alongside the three browser lanes.

    GitHub-first and programmatic - it never opens a browser, which is exactly
    the visual contrast the demo wants: three panels of live LinkedIn beside one
    terminal. Owned by the identity track; launched here so all four lanes are
    genuinely in flight at the same time rather than run one after another.
    """;
    t0 = time.time();
    w = GithubLane(
        keywords=json.loads(keywords_json) if keywords_json else [],
        pain_phrases=json.loads(pains_json) if pains_json else [],
        negative_keywords=json.loads(negatives_json) if negatives_json else []
    );
    try {
        lane_node spawn w;
    } except Exception as e {
        lane_node.state = LaneState.FAILED;
        return LaneResult(
            lane_id="D", found=0, failure=f"{type(e).__name__}: {e}",
            started_at=t0, finished_at=time.time()
        );
    }
    return LaneResult(
        lane_id="D", found=w.surfaced, probes_run=len(w.narration),
        started_at=t0, finished_at=time.time()
    );
}





# --- merge, dedupe, convergence -------------------------------------------

impl RunResearch.merge(run: ResearchRun) {
    """Serial pass. Two lanes finding the same person is the product thesis, so
    the dedupe is where the score gets made, not a cleanup step.""";

    lanes = [run ->:HasLane:->];
    canon: dict[str, Prospect] = {};
    dupes: dict[str, list[Prospect]] = {};
    finders: dict[str, list[Lane]] = {};
    order: list[str] = [];
    total_raw = 0;

    for lane in lanes {
        for p in [lane ->:Surfaced:->] {
            total_raw += 1;
            key = p.handle.strip().lower();
            if not key { continue; }
            if key not in canon {
                canon[key] = p;
                dupes[key] = [];
                finders[key] = [lane];
                order.append(key);
            } else {
                dupes[key].append(p);
                finders[key].append(lane);
            }
        }
    }

    converged = 0;
    for key in order {
        canonical: Prospect = canon[key];

        # Fold duplicates into the first sighting: carry the evidence across,
        # add a Surfaced edge from every lane that found them, drop the husk.
        for p in dupes[key] {
            for ev in [p ->:HasEvidence:->] {
                edges = [edge p ->:HasEvidence:-> ev];
                conf: float = edges[0].confidence if edges else 0.0;
                ln: LaneId = edges[0].lane if edges else LaneId.A;
                canonical +>:HasEvidence(lane=ln, confidence=conf):+> ev;
            }
            if not canonical.headline and p.headline {
                canonical.headline = p.headline;
            }
            if not canonical.company and p.company {
                canonical.company = p.company;
            }
            del p;
        }
        for lane in finders[key] {
            if canonical not in [lane ->:Surfaced:->] {
                lane +>:Surfaced(found_at=time.time()):+> canonical;
            }
        }

        # NOTE: no `run +>:Surfaced:+> canonical` here. `Surfaced` is declared
        # Lane --> Prospect, and Prospect.convergence_lanes() reads every
        # incoming Surfaced source as a Lane - hanging one off the ResearchRun
        # too would make the run itself count as a "lane" and corrupt the
        # convergence score. The run reaches its prospects with the two-hop
        # ResearchRun.prospects() (HasLane -> Surfaced), which is already exact.
        lane_ids = [str(l) for l in canonical.convergence_lanes()];
        if len(lane_ids) >= 2 {
            converged += 1;
            self.narrate_run(
                finders[key][0], say_convergence(canonical.name, lane_ids),
                ReasoningKind.CROSSLINK
            );
        }
    }

    self.unique_prospects = len(order);
    self.converged = converged;

    if lanes {
        self.narrate_run(
            lanes[0], say_merge(total_raw, len(order), converged),
            ReasoningKind.RANK
        );
    }
    run.status = RunStatus.RANKED;
    run.finished_at = time.time();
}


impl RunResearch.narrate_run(lane: Lane, sentence: str, kind: ReasoningKind) {
    r = Reasoning(t=time.time(), sentence=sentence, kind=kind);
    lane +>:Emitted(seq=0):+> r;
}


impl RunResearch.finish with Founder exit {
    report {
        "run": jid(self.run) if self.run is not None else "",
        "lanes": [
            {
                "lane": r.lane_id,
                "found": r.found,
                "probes_run": r.probes_run,
                "failure": r.failure,
                "live_url": r.live_url,
                "timed_out": r.timed_out
            }
            for r in self.lane_results
        ],
        "unique_prospects": self.unique_prospects,
        "converged": self.converged
    };
}
