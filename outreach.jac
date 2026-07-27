"""Outreach - compose, send, and interpret the reply.

The product thesis lives in ComposeOutreach. A cold email that could have been
sent to anyone is worth nothing; the entire research pipeline exists so that
this one email can quote a sentence this specific human wrote and name a
repository this specific human built. So this module refuses to send anything
it cannot ground in the graph, and it verifies after generation that the model
actually used the citations rather than paraphrasing them away.

Two external services, zero routing glue: byLLM writes the draft, AgentMail
carries it, and both are just walkers on the persistent graph.
"""

import time;
import re;

import from contracts { ReplyIntent, EvidenceSource, EvidenceKind }
import from schema {
    Founder, Prospect, Evidence, GithubProfile, LinkedinProfile,
    EmailThread, ReplyEvent, Outreach, GotReply
}
import from svc { agentmail_base, agentmail_inbox, agentmail_headers, http_json, cfg }
import from emailgate { check_identity }

import from jaclang.byllm.lib { Model }

# The [byllm.model] block in jac.toml does NOT configure the ambient `llm`
# builtin - `by llm()` then returns None silently and the failure surfaces
# much later as an unrelated attribute error. An explicit model glob is what
# actually binds the model. Verified: without this, every call here returns null.
glob llm: Model = Model(model_name=cfg("BYLLM_MODEL", "claude-sonnet-4-6"));
# cfg() above runs load_dotenv(), which also scrubs a loopback ANTHROPIC_BASE_URL -
# so this glob is what guarantees the model is configured before any call.



# ===========================================================================
# THE LLM SURFACE
# ===========================================================================

# ---------------------------------------------------------------------------
# LLM-facing mirrors of the contracts types.
#
# These deliberately duplicate OutreachDraft and AvailabilityIntent from
# contracts.jac. An obj IMPORTED from another module cannot be used as a
# `by llm()` return type in Jac 0.34.7: the annotation resolves to a bare
# string and byLLM's schema builder raises `'str' object has no attribute
# "fields"`. Verified against a brand-new throwaway module, so it is the import
# itself and not anything specific to contracts.jac.
#
# contracts.jac therefore remains the source of truth for the wire and graph
# shapes; these locals exist only so byLLM has a schema it can build, and every
# field is copied straight back out. Keep the two in sync by hand.
# ---------------------------------------------------------------------------

obj EmailDraft {
    has subject: str;
    has body: str;
    has linkedin_quote_used: str = "";
    has github_artifact_used: str = "";
}
sem EmailDraft = "A cold email that proves it was written for exactly one person. It must cite their own words and their own code. Short, specific, no flattery, no 'I came across your profile'.";
sem EmailDraft.subject = "Under nine words. Concrete. Never a question, never clickbait.";
sem EmailDraft.body = "Under 120 words. Open with the specific thing they said or built. State what the product does in one line. Ask for one short call. Sign as the founder.";
sem EmailDraft.linkedin_quote_used = "The exact LinkedIn sentence quoted in the body, so the UI can highlight it.";
sem EmailDraft.github_artifact_used = "The exact GitHub artifact referenced in the body, so the UI can highlight it.";

obj ReplyRead {
    has intent_label: str;
    has wants_call: bool;
    has proposed_times: list[str] = [];
    has phone_number: str = "";
    has sentiment: str = "neutral";
}
sem ReplyRead = "Everything actionable extracted from a prospect's email reply.";
sem ReplyRead.intent_label = "Exactly one of: wants_call, wants_info, not_interested, unclear.";
sem ReplyRead.wants_call = "True only if the sender agreed to a phone call.";
sem ReplyRead.proposed_times = "Any times the sender offered, verbatim as written.";
sem ReplyRead.phone_number = "Phone number in E.164 form if one was given, otherwise empty.";
sem ReplyRead.sentiment = "positive, neutral, or negative.";


"""Map the model's free-text label onto the graph's ReplyIntent enum."""
def to_reply_intent(label: str) -> ReplyIntent {
    cleaned = label.strip().lower();
    if cleaned == "wants_call" {
        return ReplyIntent.WANTS_CALL;
    }
    if cleaned == "wants_info" {
        return ReplyIntent.WANTS_INFO;
    }
    if cleaned == "not_interested" {
        return ReplyIntent.NOT_INTERESTED;
    }
    return ReplyIntent.UNCLEAR;
}


def draft_outreach_email(
    founder_name: str,
    product_one_liner: str,
    what_the_founder_needs: str,
    prospect_name: str,
    prospect_headline: str,
    linkedin_quote: str,
    linkedin_quote_source: str,
    github_artifact: str
) -> EmailDraft by llm();

sem draft_outreach_email = "Write one cold email from a founder to a named person. You are given the exact sentence this person wrote in public and the exact artifact they built. Quote the sentence verbatim in the body and name the artifact verbatim. Do not paraphrase either one - the recipient must recognise their own words. Never write 'I came across your profile', never compliment them, never describe them as impressive. Lead with their problem, not with the product. If a field you were given is empty, do not invent a replacement and do not mention it.";
sem draft_outreach_email.founder_name = "Who is sending the email; sign off with this name.";
sem draft_outreach_email.product_one_liner = "What the founder's product does, in one plain sentence.";
sem draft_outreach_email.what_the_founder_needs = "The specific ask, e.g. three beta testers this week.";
sem draft_outreach_email.prospect_name = "What the recipient is actually called. Open the email by addressing them with exactly this, never with a fuller or more formal version of it.";
sem draft_outreach_email.prospect_headline = "The recipient's professional headline, for context only - do not quote it back to them.";
sem draft_outreach_email.linkedin_quote = "The exact words the recipient wrote about themselves or their work. Quote it verbatim. Empty means they have no quotable LinkedIn evidence - then rely on the GitHub artifact alone.";
sem draft_outreach_email.linkedin_quote_source = "Where those words came from, e.g. 'in their LinkedIn About section'. Attribute the quote accurately using this. NEVER describe it as a recent post unless this says it was a post - claiming to have seen a post that does not exist is the fastest way to be caught out.";
sem draft_outreach_email.github_artifact = "The exact GitHub artifact the recipient built or filed. Name it verbatim. Empty means rely on the LinkedIn quote alone.";


def read_reply_intent(reply_text: str, prospect_name: str) -> ReplyRead by llm();

sem read_reply_intent = "Extract what this email reply is actually asking for. Be literal. Only set wants_call true if the sender genuinely agreed to talk by phone - 'sure, send me info' is not a call. Copy any times they offered exactly as written rather than normalising them. Only report a phone number that literally appears in the text.";
sem read_reply_intent.reply_text = "The full plain-text body of the reply the prospect sent.";
sem read_reply_intent.prospect_name = "Who sent it, for disambiguating pronouns.";


# ===========================================================================
# GRAPH READS - the citations that make the email non-generic
# ===========================================================================

"""What to actually call this person in a greeting.

The profile name and the name a human answers to are different things. LinkedIn
says "Xingzhi Zhu"; everyone who knows her says "Becky". An email that opens
"Hi Xingzhi", sent by a system whose entire pitch is that it read this person
carefully, quietly disproves its own thesis in the first three words. So the
preferred name wins whenever the graph carries one, and otherwise we fall back
to the first token of the profile name rather than the full legal name.
"""
def address_as(prospect: Prospect) -> str {
    preferred = prospect.preferred_name.strip();
    if preferred {
        return preferred;
    }
    parts = prospect.name.strip().split();
    if parts {
        return parts[0];
    }
    return prospect.name;
}


"""Cut LinkedIn chrome off a harvested quote.

A profile scrape swallows the "More profiles for you" sidebar, so a 156-char
About arrives 703 chars long carrying FIVE OTHER PEOPLE'S names and employers.
That text is piped into the voice dossier as "in public they wrote, quote: ..."
- so on a live call the agent can read a stranger's name and employer back to
the prospect as if it were their own words. It is the single worst thing this
system could say out loud, and the email path already refuses such quotes while
the voice path had no equivalent gate.

These markers are LinkedIn's own section boundaries, so truncating at the
earliest one keeps exactly the person's own words.
"""
def strip_profile_chrome(text: str) -> str {
    cut = len(text);
    for marker in [
        "More profiles for you", "Show all", "Explore Premium profiles",
        "People also viewed", "People you may know", "Others viewed"
    ] {
        found = text.find(marker);
        if found >= 0 and found < cut {
            cut = found;
        }
    }
    return text[:cut].strip();
}


obj Citation {
    has quote: str = "";
    has kind: str = "";
    has attribution: str = "";
}


"""How much a piece of LinkedIn evidence is worth quoting back at someone.

A HEADLINE is a job title, not something a person sat down and wrote. Quoting
"Program Manager @Oracle | UCLA Business Economics" back at someone as "you
wrote this" is precisely the tell we are trying to avoid - it reads as a mail
merge that found a field, not as a human who read them. So a headline scores
zero and is never citable, even when it is the longest string on the node.
An About section, a post and a comment are all genuinely authored, and among
those the more substantial one carries more signal.
"""
def citation_rank(kind: EvidenceKind) -> int {
    if kind == EvidenceKind.ABOUT {
        return 3;
    }
    if kind == EvidenceKind.POST {
        return 3;
    }
    if kind == EvidenceKind.COMMENT {
        return 3;
    }
    return 0;
}


"""How to introduce the quote so the attribution is literally true."""
def attribution_for(kind: EvidenceKind) -> str {
    if kind == EvidenceKind.ABOUT {
        return "in their LinkedIn About section";
    }
    if kind == EvidenceKind.POST {
        return "in a post they wrote";
    }
    if kind == EvidenceKind.COMMENT {
        return "in a comment they wrote";
    }
    return "";
}


"""Best genuinely-authored LinkedIn line for this prospect, with its provenance.

Returns an empty citation when the only LinkedIn evidence is a headline, which
correctly sends the caller to the GitHub artifact or to an outright refusal.
"""
def best_linkedin_citation(prospect: Prospect) -> Citation {
    best = Citation();
    best_score = 0;
    for ev in [prospect --> [?:Evidence]] {
        if ev.source == EvidenceSource.LINKEDIN {
            rank = citation_rank(ev.kind);
            if rank == 0 {
                continue;
            }
            quote = strip_profile_chrome(ev.quote);
            if not quote {
                continue;
            }
            score = (rank * 10000) + len(quote);
            if score > best_score {
                best_score = score;
                best = Citation(
                    quote=quote,
                    kind=str(ev.kind),
                    attribution=attribution_for(ev.kind)
                );
            }
        }
    }
    return best;
}


"""Back-compat shim: the bare quote text, for callers that only need a string."""
def best_linkedin_quote(prospect: Prospect) -> str {
    return best_linkedin_citation(prospect).quote;
}


"""Best GitHub artifact on record: a stored evidence quote, else the top repo."""
def best_github_artifact(prospect: Prospect) -> str {
    best = "";
    for ev in [prospect --> [?:Evidence]] {
        if ev.source == EvidenceSource.GITHUB {
            quote = strip_profile_chrome(ev.quote);
            if len(quote) > len(best) {
                best = quote;
            }
        }
    }
    if best {
        return best;
    }
    profile = prospect.github();
    if profile is not None {
        return profile.top_repo;
    }
    return "";
}


"""Resolve the founder identity used as the sender voice."""
def founder_context -> dict {
    founders = [root --> [?:Founder]];
    if not founders {
        return {
            "name": cfg("FOUNDER_NAME", "the founder"),
            "one_liner": "",
            "needs": ""
        };
    }
    f = founders[0];
    return {
        "name": f.name,
        "one_liner": f.one_liner if f.one_liner else f.product_summary,
        "needs": f.product_summary
    };
}


"""Reduce text to comparable word tokens: case, punctuation and quoting removed.

Collapsing case and whitespace is not enough. When the model quotes a citation
it wraps it in quotation marks - which is correct writing - and those marks fuse
onto the boundary tokens: `"my` and `management."` no longer equal `my` and
`management`. A correctly quoted nine-word sentence then measures as a
SEVEN-word run against its own source, so the effective bar becomes ten words
rather than eight, and the better the model quotes the more likely it is to be
rejected. Typographic quotes and em dashes do the same thing.

So punctuation is stripped from both sides before tokenising. This compares the
two strings on equal terms; it does not weaken the check, because the run-length
requirement is unchanged and still measured in whole words.
"""
def normalize(text: str) -> str {
    folded = (text.lower()
        .replace("\u201c", '"').replace("\u201d", '"')
        .replace("\u2018", "'").replace("\u2019", "'")
        .replace("\u2014", " ").replace("\u2013", " "));
    kept = "".join([c if (c.isalnum() or c.isspace()) else " " for c in folded]);
    return " ".join(kept.split());
}


"""The name part of a stored artifact, e.g. 'agent-runner' from 'agent-runner - a harness'.

Evidence is stored as `name - description`. The email is expected to name the
artifact, not to recite our description of it, so the identifier is what must
appear verbatim.
"""
def artifact_identifier(artifact: str) -> str {
    trimmed = artifact.strip();
    for sep in [" - ", " — ", " -- ", ": "] {
        if sep in trimmed {
            trimmed = trimmed.split(sep)[0];
            break;
        }
    }
    return trimmed.strip();
}


"""Longest run of consecutive words appearing verbatim in BOTH texts."""
def longest_verbatim_run(body_norm: str, stored_norm: str) -> int {
    body_words = body_norm.split();
    stored_words = stored_norm.split();
    best = 0;
    for i in range(len(stored_words)) {
        for j in range(len(body_words)) {
            run = 0;
            while ((i + run) < len(stored_words)
                   and (j + run) < len(body_words)
                   and stored_words[i + run] == body_words[j + run]) {
                run += 1;
            }
            if run > best {
                best = run;
            }
        }
    }
    return best;
}


"""Did the email actually quote this person's words, or only paraphrase them?

The check is a contiguous run of identical words, not a specific fragment, and
that distinction is the whole point. A stored About section runs several
sentences and opens with a self-introduction; a good email quotes the ONE
sentence that describes the person's problem and skips "Hi, this is ...".
A good email also trims a leading "I am" so the quote reads naturally inside
its own sentence. Both are correct editorial choices, and both were being
rejected by earlier versions of this check that demanded the quote begin at a
particular place.

What genuinely matters is that the words came from this human rather than from
the model's imagination. Eight consecutive identical words cannot survive
paraphrase and cannot occur by chance between unrelated prose, so that is the
bar. Short stored quotes fall back to requiring the whole thing.
"""
def quote_is_grounded(body_norm: str, stored_quote: str) -> bool {
    stored_norm = normalize(stored_quote);
    if not stored_norm {
        return False;
    }
    if stored_norm in body_norm {
        return True;
    }
    stored_words = stored_norm.split();
    needed = 8;
    if len(stored_words) < needed {
        needed = len(stored_words);
    }
    return longest_verbatim_run(body_norm, stored_norm) >= needed;
}


"""Confirm the model actually used the citations it was handed.

byLLM returns a well-formed EmailDraft even when the model quietly paraphrases
the quote into something the recipient will not recognise. A well-formed object
is not a grounded one, so the citations are re-checked against the body text
here. Returns an empty string when the draft is clean, otherwise the reason it
must not be sent.
"""
def citation_problem(draft: EmailDraft, linkedin_quote: str, github_artifact: str) -> str {
    body = normalize(draft.body);
    if linkedin_quote {
        if not quote_is_grounded(body, linkedin_quote) {
            return (
                "the LinkedIn quote from the graph does not appear verbatim in the "
                + f"drafted body (expected to find: {linkedin_quote.strip()[:60]})"
            );
        }
    }
    if github_artifact {
        identifier = normalize(artifact_identifier(github_artifact));
        if len(identifier) >= 3 and (identifier not in body) {
            return (
                "the GitHub artifact from the graph is not named in the drafted body "
                + f"(expected to find: {artifact_identifier(github_artifact)})"
            );
        }
    }
    return "";
}



# ===========================================================================
# DEGRADED PATHS - what happens when the model is unreachable
# ===========================================================================
# An LLM outage is an INFRASTRUCTURE failure. Missing evidence is a DATA
# failure. They are not the same thing and must not be handled the same way:
# the evidence gate below still refuses outright, because an email with nothing
# specific to say is worse than no email. But a rate limit or a transient 529
# is no reason to abandon a prospect whose exact words we are already holding.
#
# So the degraded email is still genuinely personal - it quotes the same
# verbatim sentence and names the same artifact the model would have been given.
# Only the prose around the citations is mechanical. Every degraded result is
# labelled `source` and carries the failure reason, so it can never be mistaken
# for a model-written one on the dashboard.

"""Build a cited email without the model. Citations are guaranteed by construction."""
def template_draft(
    called: str,
    founder_name: str,
    product_one_liner: str,
    what_is_needed: str,
    linkedin_quote: str,
    linkedin_quote_source: str,
    github_artifact: str
) -> EmailDraft {
    artifact_id = artifact_identifier(github_artifact);

    subject = "The problem you described";
    if artifact_id {
        subject = f"{artifact_id} and the problem you described";
    }

    parts: list[str] = [f"{called},", ""];
    if linkedin_quote {
        lead = "You wrote";
        if linkedin_quote_source {
            lead = f"You wrote, {linkedin_quote_source}";
        }
        parts.append(f'{lead}: "{linkedin_quote}"');
        parts.append("");
    }
    if github_artifact {
        parts.append(f"You also built {github_artifact}, so you have hit this first hand.");
        parts.append("");
    }
    if product_one_liner {
        parts.append(product_one_liner);
        parts.append("");
    }
    if what_is_needed {
        parts.append(f"I am looking for {what_is_needed}.");
    }
    parts.append("Would a 20-minute call this week work?");
    parts.append("");
    parts.append(founder_name);

    return EmailDraft(
        subject=subject,
        body="\n".join(parts),
        linkedin_quote_used=linkedin_quote,
        github_artifact_used=github_artifact
    );
}


"""Read a reply without the model: explicit phone extraction, conservative intent.

Deliberately biased toward UNCLEAR. Guessing WANTS_CALL wrongly would place a
real phone call to someone who did not agree to one, which is a far worse
failure than making a human press the button themselves.
"""
def fallback_reply_read(text: str) -> ReplyRead {
    lowered = text.lower();

    digits = re.findall(r"[+]?[0-9][0-9()\-.\s]{8,}[0-9]", text);
    phone = "";
    for candidate in digits {
        cleaned = re.sub(r"[^0-9+]", "", candidate);
        if len(re.sub(r"[^0-9]", "", cleaned)) >= 10 {
            if not cleaned.startswith("+") {
                bare = re.sub(r"[^0-9]", "", cleaned);
                cleaned = "+1" + bare if len(bare) == 10 else "+" + bare;
            }
            phone = cleaned;
            break;
        }
    }

    negative = ["not interested", "no thanks", "unsubscribe", "stop emailing", "remove me"];
    for marker in negative {
        if marker in lowered {
            return ReplyRead(
                intent_label="not_interested", wants_call=False,
                phone_number=phone, sentiment="negative"
            );
        }
    }

    call_markers = ["call me", "give me a call", "happy to talk", "let's talk",
                    "lets talk", "phone me", "ring me", "call now", "can talk"];
    for marker in call_markers {
        if marker in lowered {
            return ReplyRead(
                intent_label="wants_call", wants_call=True,
                phone_number=phone, sentiment="positive"
            );
        }
    }

    return ReplyRead(
        intent_label="unclear", wants_call=False,
        phone_number=phone, sentiment="neutral"
    );
}


# ===========================================================================
# WALKERS
# ===========================================================================

"""Shared target resolution: an explicit jid, else the highest-scoring prospect.

Every outreach walker starts by finding one specific human, so the lookup
lives in one place and each action walker adds only its own arrival ability.
"""
async walker ProspectLookup {
    has prospect_id: str = "";

    async can locate with Root entry {
        if self.prospect_id {
            target = jobj(self.prospect_id);
            if isinstance(target, Prospect) {
                visit [target];
                return;
            }
            raise ValueError(
                f"no Prospect found for jid {self.prospect_id} - pass a jid from "
                + "the ranked list, or omit prospect_id to take the top-ranked one"
            );
        }
        ranked = [root --> [?:Prospect]];
        if not ranked {
            raise ValueError(
                "the graph holds no Prospect yet - run the research pipeline before outreach"
            );
        }
        best = ranked[0];
        for p in ranked {
            if p.score > best.score {
                best = p;
            }
        }
        visit [best];
    }
}


"""Draft an email grounded in this prospect's own words and own code.

Refuses rather than degrades: with no exact citation in the graph there is
nothing to say that could not have been said to anyone, and a generic email
defeats the entire product.
"""
async walker:pub ComposeOutreach(ProspectLookup) {
    has reports: list[dict] = [];

    async can compose with Prospect entry {
        # IDENTITY INTEGRITY, checked before anything is drafted.
        #
        # An address that arrives at intake is trusted by construction and never
        # goes through the attribution floor. That trust only holds if the
        # identity the evidence came from is the identity the address belongs
        # to. If a node carries one person's quotes and another person's email,
        # the draft would quote one human's words at another - real evidence
        # about the wrong person, which reads perfectly in every log and is
        # strictly worse than sending nothing. Refuse here so no lane, present
        # or future, can route that shape to a send.
        evidence_urls: list[str] = [];
        for ev in [here --> [?:Evidence]] {
            if ev.url {
                evidence_urls.append(str(ev.url));
            }
        }
        integrity = check_identity(
            here.email, str(here.email_source), here.linkedin_url, evidence_urls
        );
        if not integrity.ok {
            report {
                "ok": False,
                "refused": True,
                "prospect": here.name,
                "prospect_id": jid(here),
                "reason": (
                    "refusing to compose: this prospect fails identity integrity - "
                    + "; ".join(integrity.reasons)
                    + ". Emailing one human words scraped from another is worse "
                    + "than sending nothing."
                )
            };
            disengage;
        }

        citation = best_linkedin_citation(here);
        linkedin_quote = citation.quote;
        github_artifact = best_github_artifact(here);

        if (not linkedin_quote) and (not github_artifact) {
            report {
                "ok": False,
                "refused": True,
                "prospect": here.name,
                "addressed_as": address_as(here),
                "prospect_id": jid(here),
                "linkedin_quote": linkedin_quote,
                "linkedin_quote_kind": citation.kind,
                "github_artifact": github_artifact,
                "reason": (
                    "refusing to compose: the graph holds nothing this person actually "
                    + "wrote and no GitHub artifact they built, so any email would be "
                    + "generic. A headline on its own does not count - it is a job title, "
                    + "not something they said."
                )
            };
            disengage;
        }

        founder = founder_context();
        called = address_as(here);
        source = "llm";
        degraded_reason = "";

        try {
            draft = draft_outreach_email(
                founder["name"],
                founder["one_liner"],
                founder["needs"],
                called,
                here.headline,
                linkedin_quote,
                citation.attribution,
                github_artifact
            );
        } except Exception as e {
            # Infrastructure failure, not a data failure - we still hold this
            # person's exact words, so we still write to them.
            source = "template";
            degraded_reason = str(e)[:300];
            print(f"[traction] ComposeOutreach: model unreachable ({degraded_reason}) - "
                  + "falling back to the cited template");
            draft = template_draft(
                called,
                founder["name"],
                founder["one_liner"],
                founder["needs"],
                linkedin_quote,
                citation.attribution,
                github_artifact
            );
        }

        problem = citation_problem(draft, linkedin_quote, github_artifact);
        if problem {
            report {
                "ok": False,
                "refused": True,
                "prospect": here.name,
                "prospect_id": jid(here),
                "reason": f"refusing to send an ungrounded draft: {problem}",
                "source": source,
                "addressed_as": called,
                "linkedin_quote": linkedin_quote,
                "linkedin_quote_kind": citation.kind,
                "github_artifact": github_artifact,
                "subject": draft.subject,
                "body": draft.body
            };
            disengage;
        }

        thread = here +>:Outreach(sent_at=0.0):+> EmailThread(
            thread_id="",
            subject=draft.subject,
            body=draft.body,
            inbox_id=agentmail_inbox()
        );

        report {
            "ok": True,
            "refused": False,
            "prospect": here.name,
            "addressed_as": address_as(here),
            "prospect_id": jid(here),
            "email": here.email,
            "thread_jid": jid(thread),
            "subject": draft.subject,
            "body": draft.body,
            "linkedin_quote": linkedin_quote,
            "linkedin_quote_kind": citation.kind,
            "github_artifact": github_artifact,
            "source": source,
            "degraded_reason": degraded_reason
        };
        disengage;
    }
}


"""Send the most recent unsent draft for this prospect through AgentMail."""
async walker:pub SendOutreach(ProspectLookup) {
    has reports: list[dict] = [];

    async can send with Prospect entry {
        if not here.email {
            raise ValueError(
                f"{here.name} has no resolved email address - the email gate should "
                + "have dropped this prospect before outreach"
            );
        }

        drafts = [here --> [?:EmailThread]];
        pending = [t for t in drafts if t.sent_at == 0.0];
        if not pending {
            raise ValueError(
                f"no unsent draft for {here.name} - run ComposeOutreach first"
            );
        }
        thread = pending[-1];

        payload = {
            "to": [here.email],
            "subject": thread.subject,
            "text": thread.body
        };
        url = f"{agentmail_base()}/inboxes/{agentmail_inbox()}/messages/send";
        result = await http_json(
            "POST", url, agentmail_headers(), payload, 30.0, "agentmail-send"
        );

        thread.thread_id = str(result.get("thread_id", ""));
        thread.sent_at = time.time();

        report {
            "ok": True,
            "prospect": here.name,
            "prospect_id": jid(here),
            "to": here.email,
            "subject": thread.subject,
            "thread_id": thread.thread_id,
            "message_id": str(result.get("message_id", "")),
            "thread_jid": jid(thread),
            "sent_at": thread.sent_at
        };
        disengage;
    }
}


"""Interpret an inbound reply and hang a ReplyEvent under its thread.

Called by the AgentMail listener the moment a reply lands. Matching is by
AgentMail thread_id when present, falling back to the sender address, because
a reply that arrives on a thread we never recorded still belongs to a prospect
we know.
"""
walker:pub OnEmailReply {
    has thread_id: str = "";
    has from_email: str = "";
    has text: str = "";
    has message_id: str = "";
    has reports: list[dict] = [];

    can route with Root entry {
        if not self.text.strip() {
            raise ValueError("OnEmailReply: `text` is empty - nothing to interpret");
        }
        sender = self.from_email.strip().lower();

        for prospect in [root --> [?:Prospect]] {
            for thread in [prospect --> [?:EmailThread]] {
                if self.thread_id and thread.thread_id == self.thread_id {
                    visit [thread];
                    return;
                }
            }
            if sender and prospect.email.strip().lower() == sender {
                threads = [prospect --> [?:EmailThread]];
                if threads {
                    visit [threads[-1]];
                    return;
                }
            }
        }
        raise ValueError(
            f"OnEmailReply: no known thread or prospect matches thread_id="
            + f"'{self.thread_id}' from='{self.from_email}'"
        );
    }

    can interpret with EmailThread entry {
        owner = [here <-- [?:Prospect]];
        who = owner[0].name if owner else "the prospect";

        source = "llm";
        degraded_reason = "";
        try {
            intent = read_reply_intent(self.text, who);
        } except Exception as e {
            source = "keyword";
            degraded_reason = str(e)[:300];
            print(f"[traction] OnEmailReply: model unreachable ({degraded_reason}) - "
                  + "falling back to keyword extraction");
            intent = fallback_reply_read(self.text);
        }
        event = here +>:GotReply(received_at=time.time()):+> ReplyEvent(
            raw=self.text,
            intent=to_reply_intent(intent.intent_label),
            phone_number=intent.phone_number,
            received_at=time.time()
        );
        event.intent_json = (
            '{"intent": "' + intent.intent_label
            + '", "wants_call": ' + ("true" if intent.wants_call else "false")
            + ', "sentiment": "' + intent.sentiment + '"}'
        );

        report {
            "ok": True,
            "prospect": who,
            "prospect_id": jid(owner[0]) if owner else "",
            "thread_id": here.thread_id,
            "intent": intent.intent_label,
            "wants_call": intent.wants_call,
            "proposed_times": intent.proposed_times,
            "phone_number": intent.phone_number,
            "sentiment": intent.sentiment,
            "reply_jid": jid(event),
            "source": source,
            "degraded_reason": degraded_reason
        };
        disengage;
    }
}
