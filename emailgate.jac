"""The email gate: deliverability and attribution. Pure logic, no graph, no network.

THIS MODULE EXISTS BECAUSE THE OBVIOUS IMPLEMENTATION IS WRONG
--------------------------------------------------------------------------
The plan specifies one filter for the email waterfall: drop anything matching
`@users.noreply.github.com`. Run against a live pool of 15 real candidates
(indie AI-agent builders who had pushed code that day), that filter produced a
80% hit rate. Six of those hits were unusable, and each failed differently:

  * FOUR were the bare string `noreply@github.com`. That is GitHub's GENERIC
    proxy, stamped on commits authored through the web UI and on merge commits.
    It is a different string from `<user>@users.noreply.github.com` and the
    specified filter does not match it. Four emails would have been sent into a
    black hole while the pipeline reported success.

  * ONE was `agent@example.com`, copied verbatim out of a pyproject.toml
    template the candidate had never edited. Syntactically perfect, belongs to
    nobody.

  * ONE was `kacarumit.phd@gmail.com`, harvested from the package.json of a
    repo the candidate had FORKED. The address belongs to the upstream author.
    We would have sent a personalised email about someone else's repository to
    a stranger who never wrote it. Syntactically valid, deliverable, and
    completely wrong - the only defence is asking whether the address plausibly
    belongs to THIS human.

Real validated hit rate after both checks: 40%, not 80%. That is the number the
pipeline is sized against (a 25-candidate pool to seat 3 finalists), and it is
the number that goes in the evidence doc. An unvalidated 80% would have looked
better in a slide and failed on stage.

TWO INDEPENDENT CHECKS, BECAUSE THERE ARE TWO INDEPENDENT FAILURES
--------------------------------------------------------------------------
  DELIVERABILITY - will mail sent here reach a human at all? Blocklists for
  proxy domains, reserved TLDs, template placeholders and bot accounts.

  ATTRIBUTION - does this address belong to the person we think it does?
  Correlates the local part against the login and the profile name, and weighs
  that against how much the SOURCE deserves trust. An address off someone's own
  authored commits is near-certain. An address scraped out of a repo manifest is
  a coin flip, so it has to earn its place by matching the name.

Nothing here fabricates, guesses, or pattern-generates an address. A candidate
who fails both checks is dropped with a written reason and shown on the ledger.
"""

import re;
import from difflib { SequenceMatcher }


# ---------------------------------------------------------------------------
# Deliverability blocklists. Every entry below was hit by a real candidate in a
# live run, or is the documented sibling of one that was.
# ---------------------------------------------------------------------------

"""Domains that never deliver to a person: GitHub's two distinct privacy
proxies, plus the RFC 2606 / template placeholders that ship inside scaffolding
files and get committed unedited."""
glob DEAD_DOMAINS: list[str] = [
    "users.noreply.github.com",
    "github.com",
    "example.com", "example.org", "example.net", "example.edu",
    "test.com", "test.test", "localhost", "localhost.localdomain",
    "email.com", "domain.com", "yourdomain.com", "mydomain.com",
    "company.com", "mycompany.com", "acme.com", "sample.com",
    "changeme.com", "none.com", "noreply.com", "invalid.com"
];

"""Reserved / non-routable TLDs (RFC 2606 and RFC 6761). `.local` in particular
shows up constantly in commits made on a machine with no configured git email."""
glob DEAD_TLDS: list[str] = [
    ".local", ".invalid", ".test", ".example", ".localdomain", ".internal", ".lan"
];

"""Local parts that are structurally impersonal. If the whole local part is one
of these, no human is on the other end regardless of the domain."""
glob DEAD_LOCALPARTS: list[str] = [
    "noreply", "no-reply", "donotreply", "do-not-reply", "nobody",
    "root", "admin", "administrator", "webmaster", "postmaster",
    "test", "testing", "user", "username", "you", "your", "me", "my",
    "name", "email", "mail", "info", "contact", "hello", "support",
    "agent", "bot", "robot", "ci", "cd", "build", "builder", "deploy",
    "action", "actions", "github-actions", "dependabot", "renovate",
    "someone", "somebody", "foo", "bar", "baz", "example", "placeholder",
    "changeme", "todo", "xxx", "n-a", "na"
];

"""Substrings that mark an automated account rather than a person."""
glob BOT_MARKERS: list[str] = [
    "[bot]", "-bot@", "+bot@", "bot@users", "actions@github", "action@github",
    "dependabot", "renovate[", "greenkeeper", "semantic-release",
    "githubactions"
];
# Deliberately NOT listing "noreply@github" here. It would fire before the
# domain rule and report "automated account", when the accurate and more
# useful ledger reason is "non-deliverable domain (github.com)". Both reject
# it; only one explains it to someone reading the drop ledger on stage.

glob EMAIL_PATTERN: str = "^[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}$";
glob EMAIL_SCAN: str = "[A-Za-z0-9._%+\\-]+@[A-Za-z0-9\\-]+\\.[A-Za-z0-9.\\-]*[A-Za-z]{2,}";

"""Attribution floor for low-trust sources. An address pulled out of a repo
manifest must correlate with the candidate's login or name at least this well,
or it is assumed to belong to the upstream author of a forked repo. 0.55 was
chosen because it accepts `jose.matzkin@gmail.com` for login `jmatzkin1980`
(a real match, 0.90) and rejects `kacarumit.phd@gmail.com` for login
`othmane55` (a real fork-inherited false positive, 0.18)."""
glob ATTRIBUTION_FLOOR: float = 0.55;


obj EmailVerdict {
    has ok: bool = False;
    has email: str = "";
    has reason: str = "";
    has confidence: float = 0.0;
    has attribution: float = 0.0;
    has trust: str = "none";
}


"""Strip to comparable lowercase letters. Digits and punctuation carry no
identity signal - `jmatzkin1980` and `jose.matzkin` are the same human, and the
`1980` is a birth year, not a distinguishing feature."""
def alpha_only(s: str) -> str {
    return re.sub("[^a-z]", "", (s if s else "").lower());
}


"""Extract every syntactically plausible address from free text - README bodies,
manifest files, HTML, commit trailers."""
def scan_emails(text: str) -> list[str] {
    if not text {
        return [];
    }
    found: list[str] = re.findall(EMAIL_SCAN, text) as list[str];
    out: list[str] = [];
    for f in found {
        cleaned: str = f.strip(".,;:'\"<>()[]{}");
        if cleaned not in out {
            out.append(cleaned);
        }
    }
    return out;
}


"""Will mail sent to this address reach a human? Returns (ok, reason).

Checked in cheapest-first order. The `github.com` entry is the one the plan's
specified filter misses, and it was the single largest source of false hits in
the live run."""
def is_deliverable(email: str) -> tuple {
    if not email {
        return (False, "empty");
    }
    e: str = email.strip().lower();
    if not re.match(EMAIL_PATTERN, e) {
        return (False, "malformed address");
    }
    if e.count("@") != 1 {
        return (False, "malformed address");
    }
    parts: list[str] = e.split("@");
    local: str = parts[0];
    domain: str = parts[1];

    for marker in BOT_MARKERS {
        if marker in e {
            return (False, f"automated account ({marker})");
        }
    }
    if domain in DEAD_DOMAINS {
        return (False, f"non-deliverable domain ({domain})");
    }
    if domain.endswith(".users.noreply.github.com") or domain == "users.noreply.github.com" {
        return (False, "github privacy proxy");
    }
    for tld in DEAD_TLDS {
        if domain.endswith(tld) {
            return (False, f"reserved TLD ({tld})");
        }
    }
    if local in DEAD_LOCALPARTS {
        return (False, f"impersonal local part ({local})");
    }
    if "." not in domain {
        return (False, "domain has no TLD");
    }
    return (True, "deliverable");
}


"""Does this address plausibly belong to THIS human? Returns (score 0..1, basis).

Compares the local part against both the GitHub login and the profile display
name, taking the better of the two. Tries exact match, containment, per-token
containment (which is what catches `first.last@` against a display name), and
finally a fuzzy ratio."""
def attribution_score(email: str, login: str, name: str) -> tuple {
    local: str = email.split("@")[0].lower();
    lp: str = alpha_only(local);
    if not lp {
        # Numeric local parts are normal and legitimate - QQ Mail hands out
        # all-digit addresses to every user in China, and plenty of people use
        # a number they have had since school. There is simply no name signal
        # to read, which is different from a signal that disagrees. Callers
        # weigh this against source trust: off the person's own commits it is
        # still their address, but a manifest file offers nothing to check.
        return (0.0, "local part carries no name signal (numeric or symbolic address)");
    }
    best: float = 0.0;
    basis: str = "no correlation with login or profile name";
    targets: list[list[str]] = [[alpha_only(login), "login"], [alpha_only(name), "profile name"]];
    for pair in targets {
        cand: str = pair[0];
        label: str = pair[1];
        if not cand {
            continue;
        }
        score: float = 0.0;
        why: str = "";
        if cand == lp {
            score = 1.0;
            why = f"local part is exactly the {label}";
        } elif cand in lp or lp in cand {
            score = 0.90;
            why = f"local part contains the {label}";
        } else {
            score = SequenceMatcher(None, cand, lp).ratio() as float;
            why = f"fuzzy {label} similarity {score:.2f}";
            # first.last / first_last style: any substantial token landing inside
            # the target is strong evidence even when the full strings diverge.
            for tok in re.split("[._\\-+0-9]+", local) {
                t: str = alpha_only(tok);
                if len(t) > 2 and t in cand {
                    if 0.85 > score {
                        score = 0.85;
                        why = f"name token '{t}' appears in the {label}";
                    }
                }
            }
        }
        if score > best {
            best = score;
            basis = why;
        }
    }
    return (best, basis);
}


"""How much does a given waterfall step deserve to be believed? Returns
(tier, base_confidence).

The ordering is not arbitrary. Steps 1-4 all read an address the candidate
themselves configured in git or on their profile, so the address is theirs by
construction. Step 5b - scraping a repo's manifest files - is categorically
weaker, because a forked repo carries the UPSTREAM author's contact details and
the fork's owner may never have touched them. That is the single case that
produces a confidently wrong human, so it is the one tier that has to clear the
attribution floor on its own merits."""
def source_trust(source: str) -> tuple {
    step: str = source.split(":")[0] if ":" in source else source;
    if step == "1" {
        return ("high", 0.95);
    }
    if step == "2" {
        return ("high", 0.90);
    }
    if step == "3" {
        return ("high", 0.88);
    }
    if step == "4" {
        return ("medium", 0.80);
    }
    if step == "5a" {
        return ("medium", 0.75);
    }
    if step == "5b" {
        return ("low", 0.35);
    }
    if step == "5c" {
        return ("medium", 0.70);
    }
    if step == "6" {
        return ("high", 0.92);
    }
    return ("low", 0.30);
}


"""The gate. Runs deliverability, then attribution weighted by source trust.

A candidate reaching this function with no email is not an error - it is the
expected outcome roughly 20% of the time - but it must still produce a written
reason, because every drop is shown on the ledger and an unexplained
disappearance is indistinguishable from a bug."""
def judge_email(email: str, source: str, login: str, name: str) -> EmailVerdict {
    if not email {
        return EmailVerdict(ok=False, reason="waterfall exhausted - all six steps returned nothing");
    }
    deliverable = is_deliverable(email);
    if not (deliverable[0] as bool) {
        return EmailVerdict(ok=False, email=email,
                            reason=f"undeliverable: {deliverable[1] as str}");
    }
    trust = source_trust(source);
    tier: str = trust[0] as str;
    base: float = trust[1] as float;
    attrib = attribution_score(email, login, name);
    attr: float = attrib[0] as float;
    basis: str = attrib[1] as str;

    if tier == "low" and attr < ATTRIBUTION_FLOOR {
        return EmailVerdict(
            ok=False, email=email, attribution=attr, trust=tier,
            reason=f"unverifiable attribution: found via {source} but {basis} - "
                   + f"most likely the upstream author of a forked repo, not {login}"
        );
    }
    conf: float = base * (0.65 + (0.35 * attr));
    if conf > 0.99 {
        conf = 0.99;
    }
    # Phrase the ledger line the way it will be read on stage. "high-trust
    # source 2:search/commits" means nothing to a judge; "taken from commits
    # they authored themselves" is the same fact stated so it can be checked.
    where: str = HUMAN_SOURCE.get(source.split(":")[0], "their public GitHub data") as str;
    return EmailVerdict(ok=True, email=email, confidence=conf, attribution=attr, trust=tier,
                        reason=f"{where}; {basis}");
}


"""Ledger-facing wording for each waterfall step. The drop ledger is shown to an
audience, so every line has to say what was actually done, not which branch ran."""
glob HUMAN_SOURCE: dict[str, str] = {
    "1": "published on their own GitHub profile",
    "2": "taken from commits they authored themselves",
    "3": "taken from commits they authored in their own repository",
    "4": "read from the From: header of a commit patch they signed",
    "5a": "found in the README of their own profile repository",
    "5b": "scraped from a file in one of their repositories",
    "5c": "found on the personal site linked from their profile",
    "6": "listed on their own LinkedIn contact card"
};


"""Pick the best address from a bag of candidates harvested at one waterfall step.

Frequency is the tiebreaker on purpose: someone's real git identity appears on
most of their commits, while a stray co-author trailer or a one-off machine
misconfiguration appears once. Ties break toward the better name correlation."""
def best_of(emails: list[str], login: str, name: str) -> str {
    counts: dict[str, int] = {};
    for e in emails {
        if not e {
            continue;
        }
        low: str = e.strip().lower();
        d = is_deliverable(low);
        if not (d[0] as bool) {
            continue;
        }
        counts[low] = (counts.get(low, 0) as int) + 1;
    }
    if not counts {
        return "";
    }
    best: str = "";
    best_rank: float = -1.0;
    for (addr, n) in counts.items() {
        a = attribution_score(addr, login, name);
        rank: float = (n as float) + ((a[0] as float) * 10.0);
        if rank > best_rank {
            best_rank = rank;
            best = addr;
        }
    }
    return best;
}
