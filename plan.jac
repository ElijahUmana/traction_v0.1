"""PlanCampaign - the walker that turns a founder into a searchable hypothesis.

Plan section 4, walker #2: Founder -> ICP. This is the first thing that runs and
everything downstream depends on it - `RunResearch` raises outright if the
Founder has no ICP, because lanes with no phrases would spin on empty queries.

It is also a visible demo beat: the planning screen shows the keywords and the
per-lane doctrine before the four browsers launch, so the audience sees the
system decide what to look for before it looks.

DESIGN RULE, non-negotiable: this walker MUST NOT be able to hard-fail. If the
LLM is slow, rate-limited, keyless or returns nonsense, we fall back to a
deterministic ICP derived from the founder's own words and carry on. A mediocre
ICP that runs beats a perfect one that raises at 19:00 on stage. Every exit path
from `at_founder` attaches a usable ICP with non-empty keywords and pain phrases.
"""

import time;
import from jaclang.byllm.lib { Model }
import from schema { Founder, ICP, Targets }

# byLLM's ambient model is NOT bound by jac.toml's [byllm.model] table - a
# module that calls `by llm()` has to declare its own `glob llm`.
glob llm: Model = Model(model_name="claude-sonnet-4-6");


# ---------------------------------------------------------------------------
# The LLM-visible draft.
#
# Declared LOCALLY on purpose. byLLM reflects over the return archetype at call
# time, and an obj IMPORTED from another module arrives as a string reference -
# the call dies with "'str' object has no attribute 'fields'". So the draft
# lives here and its fields are copied onto the persistent ICP node. This is the
# same separation byLLM already requires between LLM types (obj) and storage
# types (node): the prompt schema and the graph schema evolve independently.
# ---------------------------------------------------------------------------

obj IcpDraft {
    has hypothesis: str;
    has keywords: list[str];
    has negative_keywords: list[str];
    has pain_phrases: list[str];
}
sem IcpDraft = "A research plan for finding the specific humans who would want this product this week.";
sem IcpDraft.hypothesis = "One sentence naming the specific kind of person who would want this product THIS WEEK. Name a role and a situation, never a market segment. Good: 'Solo founders shipping RAG apps who just hit retrieval quality problems past 50k documents.' Bad: 'AI developers.'";
sem IcpDraft.keywords = "6 to 10 short search phrases these people actually type when describing their OWN work. Their vocabulary, not marketing vocabulary. No brand names, no buzzwords.";
sem IcpDraft.negative_keywords = "4 to 8 phrases that signal a false positive - recruiters, agencies, vendors selling to this person, students, and course-sellers. These EXCLUDE a result.";
sem IcpDraft.pain_phrases = "5 to 8 first-person complaints this person would plausibly post, written verbatim in THEIR voice, lowercase and informal as people actually write. Good: 'our retrieval quality falls apart past 50k docs'. Bad: 'challenges with retrieval scalability'.";

def draft_icp(
    one_liner: str, product_summary: str, github_repo: str
) -> IcpDraft by llm();
sem draft_icp = "Read a founder's description of what they built and produce a research plan for finding beta testers: who to look for, the words they use, the complaints they post, and what to exclude. Be concrete and specific. A vague plan produces vague searches and the lanes come back empty.";
sem draft_icp.one_liner = "The founder's one-line description of the product.";
sem draft_icp.product_summary = "A longer description of what the product does and who it is for.";
sem draft_icp.github_repo = "The founder's repo, as owner/name, for technical context. May be empty.";


# ---------------------------------------------------------------------------
# Deterministic fallback - no network, no keys, never raises
# ---------------------------------------------------------------------------

glob PLAN_STOPWORDS: list[str] = [
    "the", "and", "for", "that", "this", "with", "from", "into", "your", "you",
    "our", "are", "was", "were", "has", "have", "had", "not", "but", "all",
    "can", "will", "who", "what", "when", "how", "why", "its", "it's", "they",
    "them", "their", "there", "then", "than", "been", "being", "more", "most",
    "some", "such", "only", "just", "also", "very", "much", "any", "each",
    "build", "building", "built", "make", "makes", "made", "help", "helps",
    "using", "used", "use", "uses", "get", "gets", "one", "two", "new", "way"
];

# Split prose into lowercase alphanumeric words. No regex import needed and no
# dependency on punctuation being well-formed.
def _plan_words(text: str) -> list[str] {
    cleaned: str = "";
    for ch in text.lower() {
        if ch.isalnum() or ch == " " or ch == "-" {
            cleaned += ch;
        } else {
            cleaned += " ";
        }
    }
    return [w for w in cleaned.split() if len(w) > 2 and w not in PLAN_STOPWORDS];
}

# Adjacent word pairs read far better as search phrases than single tokens -
# "vector database" finds practitioners, "vector" finds noise.
def _plan_phrases(words: list[str], limit: int) -> list[str] {
    out: list[str] = [];
    i: int = 0;
    while i < len(words) - 1 {
        phrase = words[i] + " " + words[i + 1];
        if phrase not in out {
            out.append(phrase);
        }
        i += 1;
    }
    for w in words {
        if len(out) >= limit {
            break;
        }
        if w not in out {
            out.append(w);
        }
    }
    return out[:limit];
}

def fallback_draft(one_liner: str, product_summary: str) -> IcpDraft {
    # Build phrases per SENTENCE, never across a boundary. Concatenating the
    # two fields first produced junk bigrams like "human market" spanning the
    # end of the one-liner and the start of the summary.
    words: list[str] = [];
    keys: list[str] = [];
    for chunk in (one_liner + ". " + product_summary).split(".") {
        chunk_words = _plan_words(chunk);
        words += chunk_words;
        for phrase in _plan_phrases(chunk_words, 4) {
            if phrase not in keys {
                keys.append(phrase);
            }
        }
    }
    if not words {
        # Nothing usable in the founder's own text. Still must not return empty:
        # RunResearch treats empty keywords as a hard failure.
        words = ["developer", "tooling", "workflow", "shipping", "product"];
    }
    if not keys {
        keys = _plan_phrases(words, 8);
    }
    keys = keys[:8];
    pains: list[str] = [];
    for k in keys[:5] {
        pains.append("struggling with " + k);
        pains.append(k + " is a mess");
    }
    return IcpDraft(
        hypothesis="People who work on " + keys[0] + " and have said so in public in the last month.",
        keywords=keys,
        negative_keywords=[
            "hiring", "recruiter", "we are hiring", "join our team",
            "consulting services", "agency", "course", "webinar", "sponsored"
        ],
        pain_phrases=pains[:8]
    );
}

# The gate every path funnels through: a draft is only usable if it can actually
# drive a search. Anything short of that gets replaced wholesale.
def draft_is_usable(d: IcpDraft | None) -> bool {
    if d is None {
        return False;
    }
    if not d.keywords or not d.pain_phrases {
        return False;
    }
    if not d.hypothesis or len(d.hypothesis) < 10 {
        return False;
    }
    return True;
}


# ---------------------------------------------------------------------------
# The walker
# ---------------------------------------------------------------------------

# NOTE: both ability bodies are INLINE, not impl-separated. `disengage` inside
# an `impl PlanCampaign.start with Root entry { ... }` block fails with
# E2083 "'disengage' is only valid inside a walker ability" - the compiler does
# not treat an impl-separated ability as an ability for that check.
walker:pub PlanCampaign {
    has replace: bool = False;
    has offline: bool = False;
    has planned: list[str] = [];
    has source: str = "";

    can start with Root entry {
        founders = [-->[?:Founder]];
        if not founders {
            report {
                "ok": False,
                "error": "no Founder on the graph - run IntakeFounder first"
            };
            disengage;
        }
        visit founders;
    }

    can at_founder with Founder entry {
        existing = [here ->:Targets:->];
        if existing and not self.replace {
            found = existing[0];
            self.source = "existing";
            self.planned = found.keywords;
            report {
                "ok": True,
                "source": "existing",
                "hypothesis": found.hypothesis,
                "keywords": found.keywords,
                "negative_keywords": found.negative_keywords,
                "pain_phrases": found.pain_phrases
            };
            disengage;
        }

        draft: IcpDraft | None = None;
        origin: str = "llm";

        if not self.offline {
            try {
                draft = draft_icp(here.one_liner, here.product_summary, here.github_repo);
            } except Exception as e {
                # Deliberately caught and REPORTED, never re-raised. An LLM
                # outage must not be able to stop the demo - but it must stay
                # visible, so the reason travels back in the response and the
                # source flips to "fallback" where the dashboard can show it.
                origin = "fallback:" + str(e)[:120];
                draft = None;
            }
        } else {
            origin = "fallback:offline";
        }

        if not draft_is_usable(draft) {
            if origin == "llm" {
                origin = "fallback:llm-returned-unusable-draft";
            }
            draft = fallback_draft(here.one_liner, here.product_summary);
        }

        usable: IcpDraft = draft as IcpDraft;

        for old in existing {
            del old;
        }

        here +>:Targets(created_at=time.time()):+> ICP(
            hypothesis=usable.hypothesis,
            keywords=usable.keywords,
            negative_keywords=usable.negative_keywords,
            pain_phrases=usable.pain_phrases
        );

        self.source = origin;
        self.planned = usable.keywords;
        report {
            "ok": True,
            "source": origin,
            "hypothesis": usable.hypothesis,
            "keywords": usable.keywords,
            "negative_keywords": usable.negative_keywords,
            "pain_phrases": usable.pain_phrases
        };
    }
}
