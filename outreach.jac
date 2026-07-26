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

import from contracts { ReplyIntent, EvidenceSource }
import from schema {
    Founder, Prospect, Evidence, GithubProfile, LinkedinProfile,
    EmailThread, ReplyEvent, Outreach, GotReply
}
import from svc { agentmail_base, agentmail_inbox, agentmail_headers, http_json, cfg }

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


def draft_outreach(
    founder_name: str,
    product_one_liner: str,
    what_the_founder_needs: str,
    prospect_name: str,
    prospect_headline: str,
    linkedin_quote: str,
    github_artifact: str
) -> EmailDraft by llm();

sem draft_outreach = "Write one cold email from a founder to a named engineer. You are given the exact sentence this person wrote in public and the exact artifact they built. Quote the sentence verbatim in the body and name the artifact verbatim. Do not paraphrase either one - the recipient must recognise their own words. Never write 'I came across your profile', never compliment them, never describe them as impressive. Lead with their problem, not with the product. If a field you were given is empty, do not invent a replacement and do not mention it.";
sem draft_outreach.founder_name = "Who is sending the email; sign off with this name.";
sem draft_outreach.product_one_liner = "What the founder's product does, in one plain sentence.";
sem draft_outreach.what_the_founder_needs = "The specific ask, e.g. three beta testers this week.";
sem draft_outreach.prospect_name = "The recipient's first name; address them by it.";
sem draft_outreach.prospect_headline = "The recipient's professional headline, for context only - do not quote it back to them.";
sem draft_outreach.linkedin_quote = "The exact sentence the recipient wrote in public. Quote it verbatim. Empty means they have no LinkedIn evidence - then rely on the GitHub artifact alone.";
sem draft_outreach.github_artifact = "The exact GitHub artifact the recipient built or filed. Name it verbatim. Empty means rely on the LinkedIn quote alone.";


def read_reply_intent(reply_text: str, prospect_name: str) -> ReplyRead by llm();

sem read_reply_intent = "Extract what this email reply is actually asking for. Be literal. Only set wants_call true if the sender genuinely agreed to talk by phone - 'sure, send me info' is not a call. Copy any times they offered exactly as written rather than normalising them. Only report a phone number that literally appears in the text.";
sem read_reply_intent.reply_text = "The full plain-text body of the reply the prospect sent.";
sem read_reply_intent.prospect_name = "Who sent it, for disambiguating pronouns.";


# ===========================================================================
# GRAPH READS - the citations that make the email non-generic
# ===========================================================================

"""Best LinkedIn sentence on record for this prospect, or empty.

Longer quotes carry more signal than a three-word fragment, so among the
evidence actually stored we take the most substantial one rather than
whichever happened to be written first.
"""
def best_linkedin_quote(prospect: Prospect) -> str {
    best = "";
    for ev in [prospect --> [?:Evidence]] {
        if ev.source == EvidenceSource.LINKEDIN {
            quote = ev.quote.strip();
            if len(quote) > len(best) {
                best = quote;
            }
        }
    }
    return best;
}


"""Best GitHub artifact on record: a stored evidence quote, else the top repo."""
def best_github_artifact(prospect: Prospect) -> str {
    best = "";
    for ev in [prospect --> [?:Evidence]] {
        if ev.source == EvidenceSource.GITHUB {
            quote = ev.quote.strip();
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


"""Collapse whitespace and case so re-wrapping does not defeat a match."""
def normalize(text: str) -> str {
    return " ".join(text.lower().split());
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
        fragment = normalize(linkedin_quote)[:40];
        if fragment and (fragment not in body) {
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
        linkedin_quote = best_linkedin_quote(here);
        github_artifact = best_github_artifact(here);

        if (not linkedin_quote) and (not github_artifact) {
            report {
                "ok": False,
                "refused": True,
                "prospect": here.name,
                "prospect_id": jid(here),
                "reason": (
                    "refusing to compose: the graph holds no exact LinkedIn quote and "
                    + "no exact GitHub artifact for this prospect, so any email would be "
                    + "generic. Run cross-linking first."
                )
            };
            disengage;
        }

        founder = founder_context();
        draft = draft_outreach(
            founder["name"],
            founder["one_liner"],
            founder["needs"],
            here.name,
            here.headline,
            linkedin_quote,
            github_artifact
        );

        problem = citation_problem(draft, linkedin_quote, github_artifact);
        if problem {
            report {
                "ok": False,
                "refused": True,
                "prospect": here.name,
                "prospect_id": jid(here),
                "reason": f"refusing to send an ungrounded draft: {problem}",
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
            "prospect_id": jid(here),
            "email": here.email,
            "thread_jid": jid(thread),
            "subject": draft.subject,
            "body": draft.body,
            "linkedin_quote": linkedin_quote,
            "github_artifact": github_artifact
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

        intent = read_reply_intent(self.text, who);
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
            "reply_jid": jid(event)
        };
        disengage;
    }
}
