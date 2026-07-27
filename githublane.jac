"""Lane D - GitHub-first candidate generation. Programmatic, never a visible browser.

Lanes A, B and C are three researchers reading LinkedIn through three different
doctrines. Lane D is a fourth researcher who does not read LinkedIn at all. It
starts from artifacts rather than from statements: instead of finding someone
who SAID they have a problem, it finds someone who is actively SHIPPING code
against it. Those are different populations, and the overlap between them is
the convergence signal the whole product is built to detect. A prospect that
Lane A heard complaining and Lane D independently caught committing is a
qualitatively stronger lead than either lane could justify alone.

It also stays a terminal on screen while the other three drive browsers. That
contrast is deliberate and is the reason this lane is not implemented as a
fourth browser session.

TWO GENERATORS, BECAUSE ONE ANGLE FINDS ONE KIND OF PERSON
--------------------------------------------------------------------------
  REPOSITORY SEARCH mines builders. `search/repositories?q=<icp>&sort=updated`
  with a recency floor returns people whose code moved in the last few weeks.
  Filtering to low star counts is not a proxy for low quality - it is the
  actual ICP. Someone with four stars and a commit this morning needs beta
  testers; someone with forty thousand does not.

  ISSUE SEARCH mines complainers, and is the direct GitHub analogue of Lane A's
  comment mining. A person who opened an issue saying the thing is painful has
  stated the pain in their own words, in public, with a timestamp.

Both draw on the same 30-request-per-minute search budget that the email
waterfall needs, which is why `gh.jac` throttles centrally rather than each
call site guessing.

DRY BRANCHES NARRATE
--------------------------------------------------------------------------
A lane that returns nothing and sits still reads as broken. On zero yield this
lane widens its date window, then falls back to the next keyword, and says so
in the sidebar. An agent that announces "this angle is dry, widening to the
past month" looks like it is thinking; one that happens to succeed on the first
query looks lucky.
"""

import from time { time }
import from datetime { datetime }

import from gh { gh, GhResponse }
import from contracts {
    LaneId, LaneState, ReasoningKind, EvidenceSource, EvidenceKind, IdentityTier
}
import from schema {
    Lane, Reasoning, Prospect, Evidence, GithubProfile,
    Surfaced, HasEvidence, Identity, Emitted
}


"""Star ceiling for the ICP. Above this a maintainer has a community, a
Discord, and more beta testers than they can process - they are not the person
who needs what this founder is selling. Below it they are shipping alone."""
glob ICP_STAR_CEILING: int = 400;

"""Recency floor for the first pass. Widened by the ladder below on a dry run."""
glob RECENCY_LADDER: list[str] = ["2026-07-01", "2026-06-01", "2026-04-01", "2026-01-01"];


"""Compose a repository-search query. GitHub's search grammar is positional -
qualifiers must trail the free-text terms or they are silently treated as text."""
def repo_query(terms: str, pushed_since: str) -> str {
    return f"{terms} pushed:>{pushed_since}";
}


"""Compose an issue-search query for pain-phrase mining. `type:issue` excludes
pull requests, whose titles are change descriptions rather than problem
statements."""
def issue_query(phrase: str, since: str) -> str {
    return f"\"{phrase}\" type:issue created:>{since}";
}


walker:pub GithubLane {
    has keywords: list[str] = [];
    has pain_phrases: list[str] = [];
    has negative_keywords: list[str] = [];
    has max_candidates: int = 25;
    has star_ceiling: int = 400;
    has min_personhood: int = 2;
    has surfaced: int = 0;
    has seen: list[str] = [];
    has rejected: list[dict[str, any]] = [];
    has narration: list[dict[str, any]] = [];
    has reports: list[dict[str, any]] = [];

    can run with Lane entry {
        here.state = LaneState.SEARCHING;
        self._say(here, ReasoningKind.PLAN,
                  "Lane D running programmatically against the GitHub REST API - "
                  + "no browser. Looking for people shipping code against this "
                  + "problem right now, not people talking about it.");

        if not gh.has_token() {
            here.state = LaneState.FAILED;
            self._say(here, ReasoningKind.MISS,
                      "No GITHUB_TOKEN in the environment. Unauthenticated GitHub "
                      + "search is capped at 10 requests per minute and blocks the "
                      + "commit-search endpoint entirely, so this lane cannot run.");
            report {"lane": "D", "error": "no GITHUB_TOKEN", "surfaced": 0};
            return;
        }

        self._generate_from_repos(here);
        self._generate_from_issues(here);

        here.state = LaneState.DONE;
        self._say(here, ReasoningKind.RANK,
                  f"Lane D surfaced {self.surfaced} candidates from GitHub, and "
                  + f"rejected {len(self.rejected)} accounts that matched the query but "
                  + "showed no sign of a person maintaining them. "
                  + f"{gh.stats()['search_calls']} search calls, "
                  + f"{gh.stats()['cache_hits']} served from cache.");
        report {
            "lane": "D",
            "surfaced": self.surfaced,
            "candidates": self.seen,
            "rejected_low_signal": self.rejected,
            "narration": self.narration,
            "api": gh.stats(),
            "api_errors": gh.errors
        };
    }

    """GENERATOR 1 - repository search. Finds builders by their artifacts.

    Walks the recency ladder rather than firing one query: a tight window that
    comes back empty is information, not failure, and widening it in public is
    what makes the lane look like it is reasoning."""
    def _generate_from_repos(lane: Lane) {
        terms: str = " ".join(self.keywords[0:4]) if self.keywords else "ai agent";
        for (rung, since) in enumerate(RECENCY_LADDER) {
            if self.surfaced >= self.max_candidates {
                return;
            }
            q: str = repo_query(terms, since);
            lane.query_index = rung;
            r: GhResponse = gh.search_repos(q, 40);
            if not r.ok {
                self._say(lane, ReasoningKind.MISS,
                          f"Repository search failed ({r.status}): {r.error[0:90]}. "
                          + "This is an API failure, not an empty result - not treating "
                          + "it as 'nobody is building this'.");
                return;
            }
            kept: int = self._absorb_repos(lane, r.items, q);
            if kept > 0 {
                self._say(lane, ReasoningKind.HIT,
                          f"{kept} candidates from repositories pushed since {since} "
                          + f"matching '{terms}'. Filtering above {self.star_ceiling} "
                          + "stars on purpose - a maintainer with a community already "
                          + "has beta testers; someone shipping alone this week does not.");
                return;
            }
            if rung + 1 < len(RECENCY_LADDER) {
                lane.state = LaneState.DRY;
                self._say(lane, ReasoningKind.PIVOT,
                          f"Nothing usable pushed since {since} for '{terms}'. "
                          + f"That angle is dry - widening the window to {RECENCY_LADDER[rung + 1]} "
                          + "rather than declaring the market empty.");
                lane.state = LaneState.SEARCHING;
            }
        }
    }

    """GENERATOR 2 - issue search. The GitHub analogue of Lane A's comment mining.

    Someone who opened an issue stating the pain has said it in their own words,
    in public, with a timestamp - which is exactly the kind of quote the outreach
    email needs in order to prove it was written for one person."""
    def _generate_from_issues(lane: Lane) {
        if self.surfaced >= self.max_candidates {
            return;
        }
        if not self.pain_phrases {
            return;
        }
        self._say(lane, ReasoningKind.PLAN,
                  "Switching from artifacts to complaints: searching issue bodies for "
                  + "people stating this problem in their own words. Same doctrine as "
                  + "Lane A's comment mining, different surface.");
        for phrase in self.pain_phrases[0:3] {
            if self.surfaced >= self.max_candidates {
                return;
            }
            q: str = issue_query(phrase, RECENCY_LADDER[1]);
            r: GhResponse = gh.search_issues(q, 30);
            if not r.ok {
                self._say(lane, ReasoningKind.MISS,
                          f"Issue search failed ({r.status}): {r.error[0:90]}");
                continue;
            }
            kept: int = self._absorb_issues(lane, r.items, q, phrase);
            if kept > 0 {
                self._say(lane, ReasoningKind.HIT,
                          f"{kept} people opened issues in the last two months saying "
                          + f"\"{phrase}\" - stated in their own words, publicly, with a date.");
            } else {
                self._say(lane, ReasoningKind.MISS,
                          f"Nobody filed an issue matching \"{phrase}\" recently. "
                          + "Trying the next phrasing.");
            }
        }
    }

    def _absorb_repos(lane: Lane, items: list[dict[str, any]], q: str) -> int {
        kept: int = 0;
        for it in items {
            if self.surfaced >= self.max_candidates {
                return kept;
            }
            owner: dict[str, any] = it.get("owner", {}) as dict[str, any];
            login: str = owner.get("login", "") as str;
            otype: str = owner.get("type", "") as str;
            stars: int = it.get("stargazers_count", 0) as int;
            full: str = it.get("full_name", "") as str;
            desc: str = it.get("description", "") as str;
            fork: bool = it.get("fork", False) as bool;

            # Organizations are not people and cannot be emailed or called.
            if otype != "User" or not login or login in self.seen {
                continue;
            }
            if stars > self.star_ceiling {
                continue;
            }
            # A fork's description is the upstream author's words, not this
            # person's - quoting it in outreach would attribute someone else's
            # writing to them.
            if fork or not desc {
                continue;
            }
            if self._excluded(desc) {
                continue;
            }
            if self._surface(lane, login, full, desc, it, q, EvidenceKind.REPO,
                             f"https://github.com/{full}") {
                kept += 1;
            }
        }
        return kept;
    }

    def _absorb_issues(lane: Lane, items: list[dict[str, any]], q: str,
                       phrase: str) -> int {
        kept: int = 0;
        for it in items {
            if self.surfaced >= self.max_candidates {
                return kept;
            }
            user: dict[str, any] = it.get("user", {}) as dict[str, any];
            login: str = user.get("login", "") as str;
            utype: str = user.get("type", "") as str;
            if utype != "User" or not login or login in self.seen {
                continue;
            }
            title: str = it.get("title", "") as str;
            body: str = it.get("body", "") as str;
            url: str = it.get("html_url", "") as str;
            quote: str = self._best_line(body, phrase) if body else title;
            if not quote {
                continue;
            }
            if self._excluded(quote) {
                continue;
            }
            if self._surface(lane, login, "", quote, it, q, EvidenceKind.ISSUE, url) {
                kept += 1;
            }
        }
        return kept;
    }

    """Create the Prospect, its GitHub identity, and the evidence that justified
    surfacing it - then hang it off this Lane via `Surfaced`, which is the edge
    the convergence query later reads back up."""
    def _surface(lane: Lane, login: str, repo: str, quote: str,
                 raw: dict[str, any], q: str, kind: EvidenceKind, url: str) -> bool {
        self.seen.append(login);

        prof_r: GhResponse = gh.user(login);
        display: str = login;
        bio: str = "";
        company: str = "";
        public_email: str = "";
        followers: int = 0;
        if prof_r.ok {
            # GitHub returns JSON null for every unset profile field, and a null
            # landing in a non-Optional `has str` is a serializer warning at best
            # and a None leaking into an f-string at worst. Coerce at the boundary.
            display = (prof_r.data.get("name", "") as str) or login;
            bio = (prof_r.data.get("bio", "") as str) or "";
            company = (prof_r.data.get("company", "") as str) or "";
            public_email = (prof_r.data.get("email", "") as str) or "";
            followers = (prof_r.data.get("followers", 0) as int) or 0;

            substance: int = self._personhood(prof_r.data, login);
            if substance < self.min_personhood {
                self.rejected.append({
                    "login": login, "score": substance,
                    "why": "no display name, no bio, no followers and few repos - "
                           + "an account with no signal that a person maintains it"
                });
                return False;
            }
        }

        p: Prospect = Prospect(
            name=display,
            handle=login,
            headline=bio,
            company=company
        );
        lane +>:Surfaced(at_rank=self.surfaced, found_at=time(), query=q):+> p;

        # Lane D found this person ON GitHub, so the GitHub identity is verified
        # by construction - there is no inference step that could be wrong.
        prof: GithubProfile = GithubProfile(
            url=f"https://github.com/{login}",
            login=login,
            name=display,
            company=company,
            public_email=public_email,
            bio=bio,
            top_repo=repo,
            followers=followers
        );
        p +>:Identity(tier=IdentityTier.VERIFIED,
                      basis="Lane D surfaced this person directly from their own "
                            + "GitHub account, so the identity is not inferred",
                      confidence=1.0):+> prof;

        ev: Evidence = Evidence(
            source=EvidenceSource.GITHUB,
            quote=quote[0:400],
            url=url,
            kind=kind,
            recency_days=self._age_days(raw)
        );
        p +>:HasEvidence(lane=LaneId.D, confidence=0.82):+> ev;
        self.surfaced += 1;
        return True;
    }

    """Reject anything hitting a negative keyword. Cheap, and it keeps course-ware
    and tutorial repos out of a pool meant for people with a real product."""
    def _excluded(text: str) -> bool {
        low: str = text.lower();
        for neg in self.negative_keywords {
            if neg and neg.lower() in low {
                return True;
            }
        }
        return False;
    }

    """Pull the single most relevant line out of an issue body. The outreach
    email quotes this verbatim, so a whole body would be unusable and the first
    line is usually a template header."""
    def _best_line(body: str, phrase: str) -> str {
        low_phrase: str = phrase.lower();
        best: str = "";
        for line in body.split("\n") {
            clean: str = line.strip().lstrip("#->*| ").strip();
            if len(clean) < 25 or len(clean) > 320 {
                continue;
            }
            if clean.startswith("[") or clean.startswith("<!--") {
                continue;
            }
            if low_phrase in clean.lower() {
                return clean;
            }
            if not best {
                best = clean;
            }
        }
        return best;
    }

    def _age_days(raw: dict[str, any]) -> int {
        stamp: str = (raw.get("pushed_at", "") as str) or (raw.get("created_at", "") as str);
        if not stamp or len(stamp) < 10 {
            return -1;
        }
        try {
            when = datetime.strptime(stamp[0:10], "%Y-%m-%d");
            delta = datetime.utcnow() - when;
            return delta.days as int;
        } except Exception {
            return -1;
        }
    }

    """Does a real human maintain this account, or is it a throwaway?

    The first live run surfaced `Vitorlindo201` - no display name, no bio, zero
    followers, one repository created weeks ago - alongside `Mubder Alfaris`,
    "Founder & Lead Architect", 68 followers. Both matched the keyword query
    equally well. Only one of them is a person a founder would want to email,
    and putting the other on stage makes the whole pipeline look indiscriminate.

    Scored rather than hard-filtered on any single attribute, because real
    people fail individual checks all the time - plenty of working engineers
    have no bio, and plenty have no followers. Needing two independent signals
    of a maintained account keeps them while dropping accounts that carry no
    signal at all."""
    def _personhood(prof: dict[str, any], login: str) -> int {
        score: int = 0;
        name: str = (prof.get("name", "") as str) or "";
        bio: str = (prof.get("bio", "") as str) or "";
        followers: int = (prof.get("followers", 0) as int) or 0;
        repos: int = (prof.get("public_repos", 0) as int) or 0;
        if name and name.lower() != login.lower() {
            score += 1;
        }
        if bio {
            score += 2;
        }
        if followers >= 5 {
            score += 2;
        } elif followers >= 1 {
            score += 1;
        }
        if repos >= 5 {
            score += 1;
        }
        return score;
    }

    """Emit one line into the analyst sidebar and keep a copy for the report."""
    def _say(lane: Lane, kind: ReasoningKind, sentence: str) {
        t: float = time();
        lane.narrate(sentence, kind, t);
        self.narration.append({"t": t, "kind": str(kind), "sentence": sentence});
    }
}
