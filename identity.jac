"""Identity resolution: the email waterfall, bidirectional cross-linking, and ranking.

This module owns the hard gate. Every prospect that reaches outreach passes
through `ResolveEmail`, and a prospect without a deliverable, correctly
attributed address is dropped here regardless of how good their content is.

THE WATERFALL, AND THE STEP THAT ISN'T IN IT
--------------------------------------------------------------------------
The widely-circulated technique for harvesting GitHub emails reads
`/users/{login}/events/public` and pulls `payload.commits[].author.email`.
That is dead. Verified twice today against two different accounts: the 2026
PushEvent payload contains exactly {before, head, push_id, ref, repository_id}.
There is no commits array. Building on it would have returned an empty funnel
on stage with no error to explain why, so it is deliberately absent below.

What replaces it, in cost order (each verified live):

  1. GET /users/{login}.email          - free, and public more often than expected
  2. GET /search/commits?q=author:X    - THE WORKHORSE. One global call across
                                         every repo the person ever committed to
  3. GET /repos/{o}/{r}/commits?author - per-repo fallback
  4. commit .patch -> `From:` header   - works when the API omits it
  5. profile README / manifests / blog - low trust, must clear attribution
  6. LinkedIn Contact Info modal       - free, the LinkedIn lanes open it anyway

Step 2 is why the waterfall works at all: `simonw` has a null `.email` on his
profile, and step 2 finds `swillison@gmail.com` in one call. It is also the
expensive one - it draws on a 30-request-per-minute budget shared with Lane D's
candidate generation - so `gh.jac` caches it per login.

Step 2 is run with per_page=100 on purpose. A live probe using a small page
size reported one candidate as having no email; his real address appeared at
item 23. Truncating the scan silently converts a good prospect into a drop.

ASYMMETRIC CROSS-LINKING
--------------------------------------------------------------------------
LinkedIn -> GitHub is HEAVY and GitHub -> LinkedIn is LIGHT, by design. The
heavy direction reads the Contact Info modal, regexes the About section, and
scans post history for self-shared repo links, then disambiguates. The light
direction takes headline, company and two sentences of About for the top two
candidates only - Lane D stays programmatic, because the visual contrast
between three browsers pivoting to GitHub and one terminal that never opened a
browser is the point.

Disambiguation uses ORG MEMBERSHIP, never the GitHub `company` field. That
field is free text the user types and nobody verifies; `/orgs/{org}/members/
{login}` returns 204 or 404 and cannot be self-asserted.
"""

import re;
import from time { time }

import from gh { gh, GhResponse }
import from emailgate {
    judge_email, best_of, scan_emails, is_deliverable, attribution_score,
    EmailVerdict
}
import from contracts {
    LaneId, EmailSource, CompletenessTier, IdentityTier,
    EvidenceSource, EvidenceKind, ReasoningKind
}
import from schema {
    Founder, ResearchRun, Lane, Reasoning, Prospect, Evidence,
    IdentityProfile, GithubProfile, LinkedinProfile,
    Runs, HasLane, Surfaced, HasEvidence, Identity, HasWarmLead
}


"""Manifest files worth scanning for a contact address, in descending order of
how likely they are to name a real person rather than a build tool."""
glob MANIFEST_FILES: list[str] = [
    "package.json", "pyproject.toml", "Cargo.toml", "composer.json",
    "CITATION.cff", ".mailmap", "AUTHORS", "CONTRIBUTORS", "setup.py"
];

"""Convergence multiplier. A prospect surfaced independently by two or more
lanes is the product thesis made numeric: two different researchers, given
different instructions, walked different paths and arrived at the same human.
That is qualitatively different from one lane being confident twice, so it is
a multiplier rather than an additive bonus."""
glob CONVERGENCE_MULTIPLIER: float = 1.35;
glob CONVERGENCE_MULTIPLIER_3PLUS: float = 1.6;


# ===========================================================================
# Waterfall helpers - pure functions over the API client, no graph writes.
# ===========================================================================

"""Harvest every address visible in one commit-search or commit-list payload.

Reads the author slot, the committer slot, and the commit message itself -
`Co-authored-by:` trailers are a genuine third source and cost nothing extra
once the response is already in hand."""
def emails_from_commits(items: list[dict[str, any]]) -> list[str] {
    out: list[str] = [];
    for it in items {
        commit: dict[str, any] = it.get("commit", {}) as dict[str, any];
        for slot in ["author", "committer"] {
            who: dict[str, any] = commit.get(slot, {}) as dict[str, any];
            addr: str = (who.get("email", "") as str) if who else "";
            if addr {
                out.append(addr);
            }
        }
        msg: str = commit.get("message", "") as str;
        if msg {
            for found in scan_emails(msg) {
                out.append(found);
            }
        }
    }
    return out;
}


"""Map a waterfall step id onto the schema's EmailSource enum."""
def step_to_source(step: str) -> EmailSource {
    head: str = step.split(":")[0];
    if head == "1" {
        return EmailSource.GITHUB_PROFILE;
    }
    if head == "2" or head == "3" or head == "4" {
        return EmailSource.GITHUB_COMMIT;
    }
    if head == "5a" or head == "5b" {
        return EmailSource.GITHUB_README;
    }
    if head == "5c" {
        return EmailSource.PERSONAL_SITE;
    }
    if head == "6" {
        return EmailSource.LINKEDIN_CONTACT_INFO;
    }
    return EmailSource.NONE;
}


"""Run the waterfall for one GitHub login. Returns (email, step, trace).

Stops at the first step that yields an address surviving `best_of`, which
already applies the deliverability blocklist. Attribution is judged afterwards
by the caller, because it depends on which step produced the hit."""
def run_waterfall(login: str, name: str, repos: list[str], blog: str,
                  public_email: str) -> dict[str, any] {
    trace: list[str] = [];

    # -- 1: the profile's own email field ------------------------------------
    trace.append("1:users.email");
    if public_email {
        picked: str = best_of([public_email], login, name);
        if picked {
            return {"email": picked, "step": "1:users.email", "trace": trace};
        }
    }

    # -- 2: global commit search. The workhorse. -----------------------------
    sc: GhResponse = gh.commit_search(login);
    if sc.ok {
        bag: list[str] = emails_from_commits(sc.items);
        trace.append(f"2:search/commits(n={len(sc.items)})");
        picked2: str = best_of(bag, login, name);
        if picked2 {
            return {"email": picked2, "step": "2:search/commits", "trace": trace};
        }
    } else {
        # A failed search is NOT the same as "no email". Say so out loud, so a
        # rate-limited run is never mistaken for an empty one on the ledger.
        trace.append(f"2:search/commits FAILED({sc.status}:{sc.error[0:60]})");
    }

    # -- 3 and 4: per-repo commits, then the raw .patch ----------------------
    for full in repos[0:3] {
        rc: GhResponse = gh.repo_commits(full, login);
        if not rc.ok {
            continue;
        }
        trace.append(f"3:repos/{full}(n={len(rc.items)})");
        picked3: str = best_of(emails_from_commits(rc.items), login, name);
        if picked3 {
            return {"email": picked3, "step": f"3:repos/{full}", "trace": trace};
        }
        if rc.items {
            first: dict[str, any] = rc.items[0];
            sha: str = first.get("sha", "") as str;
            if sha {
                patch: GhResponse = gh.patch_text(full, sha);
                if patch.ok {
                    trace.append("4:.patch");
                    # Scanned line-by-line rather than with a MULTILINE regex:
                    # re.findall's flags parameter has no resolvable overload in
                    # Jac's type checker (E1054), and the `From:` header is
                    # always the second line of a .patch anyway.
                    hits: list[str] = [];
                    for line in patch.text.split("\n")[0:40] {
                        if line.startswith("From: ") and "<" in line and ">" in line {
                            inner: str = line.split("<")[1].split(">")[0];
                            if inner {
                                hits.append(inner);
                            }
                        }
                    }
                    picked4: str = best_of(hits, login, name);
                    if picked4 {
                        return {"email": picked4, "step": "4:.patch", "trace": trace};
                    }
                }
            }
        }
    }

    # -- 5a: the profile README ({login}/{login}) ----------------------------
    readme: GhResponse = gh.raw_file(f"{login}/{login}", "README.md");
    if readme.ok {
        trace.append("5a:profile-readme");
        picked5: str = best_of(scan_emails(readme.text), login, name);
        if picked5 {
            return {"email": picked5, "step": "5a:profile-readme", "trace": trace};
        }
    }

    # -- 5b: repo manifests. LOW TRUST - a forked repo carries the UPSTREAM
    #        author's address, so whatever comes out of here has to clear the
    #        attribution floor before it is allowed anywhere near an inbox.
    for full2 in repos[0:2] {
        for fname in MANIFEST_FILES {
            mf: GhResponse = gh.raw_file(full2, fname);
            if not mf.ok {
                continue;
            }
            picked6: str = best_of(scan_emails(mf.text), login, name);
            if picked6 {
                trace.append(f"5b:{fname}");
                return {"email": picked6, "step": f"5b:{fname}", "trace": trace};
            }
        }
    }

    # -- 5c: the linked personal site ---------------------------------------
    if blog {
        url: str = blog if blog.startswith("http") else f"https://{blog}";
        site: GhResponse = gh.get_text(url);
        if site.ok {
            trace.append("5c:blog");
            mailtos: list[str] = re.findall("mailto:([^\"'>\\s?]+)", site.text) as list[str];
            picked7: str = best_of(mailtos, login, name);
            if not picked7 {
                picked7 = best_of(scan_emails(site.text), login, name);
            }
            if picked7 {
                return {"email": picked7, "step": "5c:blog", "trace": trace};
            }
        }
    }

    return {"email": "", "step": "", "trace": trace};
}


# ===========================================================================
# WALKER 8 - ResolveEmail. THE HARD GATE.
# ===========================================================================

"""Resolve an email for every surfaced prospect, or drop them with a reason.

Traverses to every Prospect the run surfaced and runs the waterfall against
whichever GitHub identity is attached. A prospect with no GitHub identity and
no LinkedIn-supplied address has nothing to resolve from and is dropped - this
is expected for roughly a fifth of any pool and is not an error.

Every drop records a written `dropped_reason`. That is not politeness: the
ledger of eliminated candidates is shown on stage, and a candidate that simply
vanishes is indistinguishable from a bug in the pipeline."""
walker ResolveEmail {
    has resolved: int = 0;
    has dropped: int = 0;
    has ledger: list[dict[str, any]] = [];
    has reports: list[dict[str, any]] = [];

    can start with Root entry {
        targets: list[Prospect] = [
            root --> [?:Founder] ->:Runs:-> ->:HasLane:-> ->:Surfaced:->
        ];
        warm: list[Prospect] = [root --> [?:Founder] ->:HasWarmLead:->];
        for w in warm {
            if w not in targets {
                targets.append(w);
            }
        }
        visit targets;
    }

    can gate with Prospect entry {
        # A warm lead arrives with a known-good address. Re-deriving it would
        # risk overwriting a correct value with a worse guess.
        if here.is_warm_lead and here.email {
            here.email_confidence = 1.0;
            here.email_source = EmailSource.PROVIDED;
            self.resolved += 1;
            return;
        }

        profiles: list[GithubProfile] = [here ->:Identity:-> [?:GithubProfile]];
        login: str = "";
        gname: str = here.name;
        blog: str = "";
        public_email: str = "";
        repos: list[str] = [];

        if profiles {
            g: GithubProfile = profiles[0];
            login = g.login;
            if g.name {
                gname = g.name;
            }
            public_email = g.public_email;
            if g.top_repo {
                repos.append(g.top_repo);
            }
        }

        if not login {
            self._drop(here, "no GitHub identity was cross-linked, so there is "
                             + "nothing to resolve an address from");
            return;
        }

        if not repos {
            rr: GhResponse = gh.user_repos(login, 5);
            if rr.ok {
                for r in rr.items {
                    full: str = r.get("full_name", "") as str;
                    fork: bool = r.get("fork", False) as bool;
                    # Skip forks: their manifests carry the upstream author's
                    # contact details, which is exactly the false-attribution
                    # case the gate exists to catch.
                    if full and not fork {
                        repos.append(full);
                    }
                }
            }
        }

        result: dict[str, any] = run_waterfall(login, gname, repos, blog, public_email);
        email: str = result.get("email", "") as str;
        step: str = result.get("step", "") as str;
        trace: list[str] = result.get("trace", []) as list[str];

        verdict: EmailVerdict = judge_email(email, step, login, gname);
        if verdict.ok {
            here.email = verdict.email;
            here.email_confidence = verdict.confidence;
            here.email_source = step_to_source(step);
            here.dropped_reason = "";
            self.resolved += 1;
            self.ledger.append({
                "handle": here.handle, "name": here.name, "kept": True,
                "email": verdict.email, "step": step,
                "confidence": verdict.confidence, "why": verdict.reason,
                "steps_tried": trace
            });
        } else {
            self._drop(here, verdict.reason, trace);
        }
    }

    """Record a drop. Always writes a reason - see the class docstring."""
    def _drop(p: Prospect, reason: str, trace: list[str] = []) {
        p.email = "";
        p.email_source = EmailSource.NONE;
        p.email_confidence = 0.0;
        p.tier = CompletenessTier.DROPPED;
        p.dropped_reason = reason;
        self.dropped += 1;
        self.ledger.append({
            "handle": p.handle, "name": p.name, "kept": False,
            "email": "", "step": "", "confidence": 0.0,
            "why": reason, "steps_tried": trace
        });
    }

    can finish with Root exit {
        report {
            "resolved": self.resolved,
            "dropped": self.dropped,
            "ledger": self.ledger,
            "api": gh.stats(),
            "api_errors": gh.errors
        };
    }
}


# ===========================================================================
# WALKER 6 - CrossLinkToGithub. THE HEAVY DIRECTION.
# ===========================================================================

"""Pull candidate GitHub logins out of text harvested from a LinkedIn profile.

Handles the shapes people actually paste: full URLs, bare `github.com/x`,
trailing slashes, `.git` suffixes, and query strings. Rejects GitHub's own
reserved paths, which otherwise produce a confident link to a non-person."""
glob GITHUB_RESERVED: list[str] = [
    "orgs", "topics", "features", "about", "pricing", "enterprise", "sponsors",
    "collections", "events", "explore", "marketplace", "settings", "search",
    "login", "join", "apps", "site", "readme", "trending", "notifications"
];


def logins_from_text(text: str) -> list[str] {
    if not text {
        return [];
    }
    raw: list[str] = re.findall(
        "github\\.com/([A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?)", text
    ) as list[str];
    out: list[str] = [];
    for r in raw {
        low: str = r.lower();
        if low in GITHUB_RESERVED {
            continue;
        }
        if r not in out {
            out.append(r);
        }
    }
    return out;
}


"""Cross-link a LinkedIn-sourced prospect to a GitHub account. HEAVY.

Takes text already harvested by the LinkedIn lanes - the Contact Info modal,
the About section, and post bodies - rather than driving the browser itself.
That keeps the expensive browser work in one place (the lanes own the session)
and makes this walker testable without a browser at all.

Candidate logins are ranked by evidence that cannot be self-asserted:

  * An explicit github.com link in the Contact Info modal is the strongest
    signal available, because LinkedIn only shows what the person themselves
    entered on their own profile.
  * ORG MEMBERSHIP is the disambiguator between two plausible logins. The
    GitHub `company` field is free text - anyone can type "Stripe" - whereas
    /orgs/{org}/members/{login} returns 204 only if the org actually lists
    them. Where the LinkedIn company and a verified org membership agree, the
    match is VERIFIED.
  * Name similarity alone is POSSIBLE at best. Two humans share a name far
    more often than two humans share an org."""
walker CrossLinkToGithub {
    has contact_info_text: str = "";
    has about_text: str = "";
    has posts_text: str = "";
    has linkedin_company: str = "";
    has linked: int = 0;
    has reports: list[dict[str, any]] = [];

    can crosslink with Prospect entry {
        existing: list[GithubProfile] = [here ->:Identity:-> [?:GithubProfile]];
        if existing {
            report {"handle": here.handle, "already_linked": existing[0].login};
            return;
        }

        # Ordered strongest-first: the Contact Info modal is self-declared on
        # the person's own profile, About is next, a link inside a post is
        # weakest because people share other people's repos constantly.
        sources: list[list[str]] = [
            [self.contact_info_text, "contact info modal"],
            [self.about_text, "About section"],
            [self.posts_text, "a post they wrote"]
        ];
        for pair in sources {
            for login in logins_from_text(pair[0]) {
                verdict: dict[str, any] = self._adjudicate(login, pair[1], here);
                if (verdict.get("matched", False) as bool) {
                    self._attach(here, login, verdict);
                    self.linked += 1;
                    report verdict;
                    return;
                }
            }
        }
        report {"handle": here.handle, "matched": False,
                "basis": "no GitHub link found in contact info, About, or posts"};
    }

    """Decide whether `login` is the same human as this prospect, and how sure."""
    def _adjudicate(login: str, where: str, p: Prospect) -> dict[str, any] {
        r: GhResponse = gh.user(login);
        if not r.ok {
            return {"matched": False, "login": login,
                    "basis": f"github.com/{login} referenced in {where} but the account does not resolve"};
        }
        gname: str = (r.data.get("name", "") as str) or "";
        company: str = (r.data.get("company", "") as str) or "";

        # Compare the GITHUB side against the LINKEDIN side. Both comparisons
        # pass "" as the login argument on purpose: `attribution_score` scores a
        # local part against BOTH the login and the name it is handed and keeps
        # the better one, so passing the github login as both the subject AND
        # the target scores it against itself and returns 1.00 for everybody.
        # That bug cross-linked github.com/torvalds to a prospect named "Jane
        # Unrelated" with "similarity 1.00" - caught by the negative control in
        # proof_laned.jac. It is the exact false-attribution failure this whole
        # module exists to prevent, so the two sides are now named explicitly.
        by_login = attribution_score(f"{login}@x.invalid", "", p.name);
        name_sim: float = by_login[0] as float;
        if gname {
            flat: str = gname.replace(" ", "").replace(".", "");
            by_display = attribution_score(f"{flat}@x.invalid", "", p.name);
            if (by_display[0] as float) > name_sim {
                name_sim = by_display[0] as float;
            }
        }

        # A link the person put on their OWN LinkedIn contact card is as close
        # to a self-declaration as this pipeline can get.
        if where == "contact info modal" {
            return {"matched": True, "login": login, "tier": "verified",
                    "confidence": 0.97,
                    "basis": f"github.com/{login} is listed on their own LinkedIn contact card"};
        }

        # Otherwise, look for a VERIFIABLE affiliation. Never trust the
        # `company` string on its own - it is user-editable free text.
        if self.linkedin_company {
            orgs: GhResponse = gh.user_orgs(login);
            if orgs.ok {
                for o in orgs.items {
                    org_login: str = o.get("login", "") as str;
                    if not org_login {
                        continue;
                    }
                    if self._same_org(org_login, self.linkedin_company) {
                        if gh.is_org_member(org_login, login) {
                            return {"matched": True, "login": login, "tier": "verified",
                                    "confidence": 0.95,
                                    "basis": f"verified member of the {org_login} GitHub org, "
                                             + f"which matches their LinkedIn company '{self.linkedin_company}' "
                                             + "(org membership is verifiable; the profile company field is not)"};
                        }
                    }
                }
            }
        }

        if name_sim >= 0.85 {
            return {"matched": True, "login": login, "tier": "probable",
                    "confidence": 0.78,
                    "basis": f"github.com/{login} found in {where}; display name '{gname}' "
                             + f"closely matches '{p.name}' (similarity {name_sim:.2f})"};
        }
        if name_sim >= 0.55 {
            return {"matched": True, "login": login, "tier": "possible",
                    "confidence": 0.5,
                    "basis": f"github.com/{login} found in {where}; weak name similarity "
                             + f"{name_sim:.2f} - not enough to personalise outreach on its own"};
        }
        return {"matched": False, "login": login,
                "basis": f"github.com/{login} appeared in {where} but nothing corroborates "
                         + f"it being {p.name} (name similarity {name_sim:.2f}, no shared verified org)"};
    }

    """Loose org-name comparison. 'Acme, Inc.' on LinkedIn is 'acme' on GitHub."""
    def _same_org(org_login: str, company: str) -> bool {
        a: str = re.sub("[^a-z0-9]", "", org_login.lower());
        b: str = re.sub("[^a-z0-9]", "", company.lower());
        if not a or not b {
            return False;
        }
        return a == b or a in b or b in a;
    }

    def _attach(p: Prospect, login: str, verdict: dict[str, any]) {
        r: GhResponse = gh.user(login);
        prof: GithubProfile = GithubProfile(
            url=f"https://github.com/{login}",
            login=login,
            name=r.data.get("name", "") as str,
            company=r.data.get("company", "") as str,
            public_email=r.data.get("email", "") as str,
            bio=r.data.get("bio", "") as str,
            followers=r.data.get("followers", 0) as int
        );
        tier_name: str = verdict.get("tier", "possible") as str;
        p +>:Identity(tier=self._tier(tier_name),
                      basis=verdict.get("basis", "") as str,
                      confidence=verdict.get("confidence", 0.0) as float):+> prof;
    }

    def _tier(name: str) -> IdentityTier {
        if name == "verified" {
            return IdentityTier.VERIFIED;
        }
        if name == "probable" {
            return IdentityTier.PROBABLE;
        }
        if name == "possible" {
            return IdentityTier.POSSIBLE;
        }
        return IdentityTier.NOT_FOUND;
    }
}


# ===========================================================================
# WALKER 7 - CrossLinkToLinkedIn. THE LIGHT DIRECTION.
# ===========================================================================

"""Attach a shallow LinkedIn profile to a GitHub-sourced prospect. LIGHT.

Deliberately thin: headline, current company, and the opening of the About
section. Nothing else. Lane D's whole identity is that it never opens a
browser, and the demo's strongest visual beat is three browser panels pivoting
to GitHub while the fourth stays a terminal - spending sixty seconds of
scraping here would trade that away for detail the outreach does not need.

Runs against the top `limit` candidates only, for the same reason."""
walker CrossLinkToLinkedIn {
    has limit: int = 2;
    has harvested: dict[str, any] = {};
    has linked: int = 0;
    has reports: list[dict[str, any]] = [];

    can start with Root entry {
        pool: list[Prospect] = [
            root --> [?:Founder] ->:Runs:-> ->:HasLane:-> ->:Surfaced:->
        ];
        ranked: list[Prospect] = [];
        for p in pool {
            gp: list[GithubProfile] = [p ->:Identity:-> [?:GithubProfile]];
            lp: list[LinkedinProfile] = [p ->:Identity:-> [?:LinkedinProfile]];
            if gp and not lp {
                ranked.append(p);
            }
        }
        by_score = lambda (x: Prospect) -> float { return x.score; };
        ranked.sort(key=by_score, reverse=True);
        visit ranked[0:self.limit];
    }

    can light_pass with Prospect entry {
        payload: dict[str, any] = self.harvested.get(here.handle, {}) as dict[str, any];
        if not payload {
            report {"handle": here.handle, "matched": False,
                    "basis": "no LinkedIn profile was harvested for this handle"};
            return;
        }
        about: str = payload.get("about", "") as str;
        prof: LinkedinProfile = LinkedinProfile(
            url=payload.get("url", "") as str,
            handle=payload.get("handle", "") as str,
            name=payload.get("name", "") as str,
            headline=payload.get("headline", "") as str,
            company=payload.get("company", "") as str,
            about=self._first_sentences(about, 2)
        );
        here +>:Identity(tier=IdentityTier.PROBABLE,
                         basis="light pass from Lane D: headline, company and the "
                               + "opening of About, matched on name",
                         confidence=0.72):+> prof;
        if not here.linkedin_url {
            here.linkedin_url = prof.url;
        }
        if not here.headline {
            here.headline = prof.headline;
        }
        self.linked += 1;
        report {"handle": here.handle, "matched": True, "url": prof.url,
                "headline": prof.headline};
    }

    """Two sentences is the whole budget. More is Lane C's job, not Lane D's."""
    def _first_sentences(text: str, n: int) -> str {
        if not text {
            return "";
        }
        parts: list[str] = re.split("(?<=[.!?])\\s+", text.strip()) as list[str];
        return " ".join(parts[0:n]).strip();
    }
}


# ===========================================================================
# WALKER 9 - RankAndSelect.
# ===========================================================================

"""Tier, score, and select. Runs after the gate.

Completeness tiers are the plan's, unchanged: S is email plus BOTH LinkedIn and
GitHub content, A is email plus exactly one, and no email is DROPPED. The drop
list is reported alongside the winners on purpose - three survivors presented
without the twelve eliminations look cherry-picked, and the eliminations are
what make the survivors look earned.

The convergence multiplier is the product thesis expressed as arithmetic. A
prospect surfaced by two or more distinct lanes is not merely twice-confirmed;
they were found by researchers following different doctrines down different
paths who happened to land on the same human. `score_pre_crosslink` is recorded
before it is applied so the UI can show the number moving."""
walker RankAndSelect {
    has top_n: int = 3;
    has selected: list[dict[str, any]] = [];
    has drops: list[dict[str, any]] = [];
    has reports: list[dict[str, any]] = [];

    can rank with Root entry {
        pool: list[Prospect] = [
            root --> [?:Founder] ->:Runs:-> ->:HasLane:-> ->:Surfaced:->
        ];
        survivors: list[Prospect] = [];

        for p in pool {
            gh_profiles: list[GithubProfile] = [p ->:Identity:-> [?:GithubProfile]];
            li_profiles: list[LinkedinProfile] = [p ->:Identity:-> [?:LinkedinProfile]];
            evidence: list[Evidence] = [p ->:HasEvidence:->];
            has_gh: bool = len(gh_profiles) > 0;
            has_li: bool = len(li_profiles) > 0;

            # THE HARD GATE. No email, no seat - regardless of content quality.
            if not p.email {
                if not p.dropped_reason {
                    p.dropped_reason = "no deliverable email address could be resolved";
                }
                p.tier = CompletenessTier.DROPPED;
                p.score = 0.0;
                self.drops.append({
                    "handle": p.handle, "name": p.name,
                    "reason": p.dropped_reason,
                    "had_github": has_gh, "had_linkedin": has_li,
                    "evidence_count": len(evidence)
                });
                continue;
            }

            if has_gh and has_li {
                p.tier = CompletenessTier.S;
            } else {
                p.tier = CompletenessTier.A;
            }

            base: float = self._base_score(p, evidence, has_gh, has_li);
            p.score_pre_crosslink = base;

            lanes: list[LaneId] = p.convergence_lanes();
            mult: float = 1.0;
            if len(lanes) >= 3 {
                mult = CONVERGENCE_MULTIPLIER_3PLUS;
            } elif len(lanes) == 2 {
                mult = CONVERGENCE_MULTIPLIER;
            }
            final: float = base * mult;
            if final > 1.0 {
                final = 1.0;
            }
            p.score = final;

            lane_names: list[str] = [];
            for l in lanes {
                lane_names.append(str(l));
            }
            survivors.append(p);
            self.selected.append({
                "handle": p.handle, "name": p.name, "email": p.email,
                "tier": str(p.tier), "email_confidence": p.email_confidence,
                "score_pre_crosslink": round(base, 3),
                "score": round(final, 3),
                "convergence_lanes": lane_names,
                "converged": len(lanes) >= 2,
                "multiplier": mult,
                "evidence_count": len(evidence)
            });
        }

        by_final = lambda (x: dict[str, any]) -> float { return x["score"] as float; };
        self.selected.sort(key=by_final, reverse=True);
        self.selected = self.selected[0:self.top_n];
    }

    """Weighted completeness. Every term is something a judge can point at on
    screen: an address we can actually mail, corroborating artifacts, and the
    strength of the identity link behind them."""
    def _base_score(p: Prospect, evidence: list[Evidence],
                    has_gh: bool, has_li: bool) -> float {
        score: float = 0.30 * p.email_confidence;
        if has_gh {
            score += 0.18;
        }
        if has_li {
            score += 0.18;
        }
        strong: list[Evidence] = p.strong_evidence(0.6);
        ev_term: float = 0.20 * (len(strong) / 3.0);
        if ev_term > 0.20 {
            ev_term = 0.20;
        }
        score += ev_term;
        best_identity: float = 0.0;
        for e in [edge p ->:Identity:->] {
            if e.confidence > best_identity {
                best_identity = e.confidence;
            }
        }
        score += 0.14 * best_identity;
        return score;
    }

    can finish with Root exit {
        report {
            "selected": self.selected,
            "dropped": self.drops,
            "n_selected": len(self.selected),
            "n_dropped": len(self.drops)
        };
    }
}
