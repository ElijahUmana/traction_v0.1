"""Ranking and convergence tests. Builds a synthetic graph - no network.

The convergence multiplier is the product thesis expressed as arithmetic, and
the demo turns on one specific number moving: "this prospect scored 0.71 before
the cross-link and 0.94 after." If that number does not move, the closing claim
is unsupported. These tests pin it.

    jac test identity.test.jac
"""

import from time { time }
import from gh { gh }


"""Two lanes surfacing the SAME human is the whole product. The multiplier has
to be visible in the numbers, and `score_pre_crosslink` has to survive so the UI
can render the before and the after side by side."""
test "convergence from two lanes raises the score and is recorded" {
    f: Founder = (root ++> Founder(name="F", email="f@x.io")) as Founder;
    run: ResearchRun = (f +>:Runs(created_at=1.0):+> ResearchRun(started_at=1.0)) as ResearchRun;
    lane_a: Lane = (run +>:HasLane(launched_at=1.0):+> Lane(lane_id=LaneId.A)) as Lane;
    lane_d: Lane = (run +>:HasLane(launched_at=1.0):+> Lane(lane_id=LaneId.D)) as Lane;

    solo: Prospect = Prospect(name="Solo Person", handle="solo",
                              email="solo@real.dev", email_confidence=0.9);
    both: Prospect = Prospect(name="Converged Person", handle="both",
                              email="both@real.dev", email_confidence=0.9);

    lane_d +>:Surfaced(at_rank=0, found_at=1.0, query="q"):+> solo;
    # The same human, found independently by two lanes following different doctrines.
    lane_a +>:Surfaced(at_rank=0, found_at=1.0, query="qa"):+> both;
    lane_d +>:Surfaced(at_rank=1, found_at=1.0, query="qd"):+> both;

    for p in [solo, both] {
        gp: GithubProfile = GithubProfile(login=p.handle, url="https://github.com/x");
        p +>:Identity(tier=IdentityTier.VERIFIED, basis="test", confidence=0.9):+> gp;
        ev: Evidence = Evidence(source=EvidenceSource.GITHUB, quote="shipped a thing",
                                kind=EvidenceKind.REPO);
        p +>:HasEvidence(lane=LaneId.D, confidence=0.8):+> ev;
    }

    res = root spawn RankAndSelect(top_n=10);
    rep = res.reports[0];
    picked: list[dict[str, any]] = rep["selected"] as list[dict[str, any]];

    by_handle: dict[str, dict[str, any]] = {};
    for row in picked {
        by_handle[row["handle"] as str] = row;
    }
    assert "both" in by_handle, "the converged prospect must be selected";
    assert "solo" in by_handle;

    conv = by_handle["both"];
    single = by_handle["solo"];

    assert (conv["converged"] as bool), "two distinct lanes must register as converged";
    assert not (single["converged"] as bool), "one lane is not convergence";
    assert len(conv["convergence_lanes"] as list) == 2;

    # The demo beat: the number has to MOVE, and both halves have to be readable.
    assert (conv["score"] as float) > (conv["score_pre_crosslink"] as float), "convergence must raise the score, otherwise the closing claim is unsupported";
    assert (conv["multiplier"] as float) > 1.0;
    assert (single["score"] as float) == (single["score_pre_crosslink"] as float), "a single-lane prospect must not be inflated";

    # Same base evidence and same email confidence, so convergence alone
    # separates them - which is exactly the claim being made on stage.
    assert (conv["score"] as float) > (single["score"] as float);
}


"""No email means no seat, regardless of how strong the content is. This is the
hard gate, and it has to beat a prospect that is otherwise perfect."""
test "the email gate drops a content-rich prospect with no address" {
    f: Founder = (root ++> Founder(name="F2", email="f2@x.io")) as Founder;
    run: ResearchRun = (f +>:Runs(created_at=1.0):+> ResearchRun(started_at=1.0)) as ResearchRun;
    lane: Lane = (run +>:HasLane(launched_at=1.0):+> Lane(lane_id=LaneId.B)) as Lane;

    rich: Prospect = Prospect(name="No Email", handle="noemail", email="");
    lane +>:Surfaced(at_rank=0, found_at=1.0, query="q"):+> rich;
    gp: GithubProfile = GithubProfile(login="noemail", url="u");
    lp: LinkedinProfile = LinkedinProfile(handle="noemail", url="u");
    rich +>:Identity(tier=IdentityTier.VERIFIED, basis="t", confidence=1.0):+> gp;
    rich +>:Identity(tier=IdentityTier.VERIFIED, basis="t", confidence=1.0):+> lp;
    for i in [0, 1, 2] {
        ev: Evidence = Evidence(source=EvidenceSource.LINKEDIN, quote="strong signal",
                                kind=EvidenceKind.COMMENT);
        rich +>:HasEvidence(lane=LaneId.B, confidence=0.95):+> ev;
    }

    res = root spawn RankAndSelect(top_n=10);
    rep = res.reports[0];
    dropped: list[dict[str, any]] = rep["dropped"] as list[dict[str, any]];
    handles: list[str] = [];
    for d in dropped {
        handles.append(d["handle"] as str);
    }
    assert "noemail" in handles, "a prospect with no email must be dropped even with full content";
    assert rich.tier == CompletenessTier.DROPPED;
    for d in dropped {
        assert len(d["reason"] as str) > 10, "every drop needs a reason for the ledger";
    }
}


"""S-tier requires BOTH sides. A-tier is email plus exactly one."""
test "tiering distinguishes S from A by cross-link completeness" {
    f: Founder = (root ++> Founder(name="F3", email="f3@x.io")) as Founder;
    run: ResearchRun = (f +>:Runs(created_at=1.0):+> ResearchRun(started_at=1.0)) as ResearchRun;
    lane: Lane = (run +>:HasLane(launched_at=1.0):+> Lane(lane_id=LaneId.C)) as Lane;

    s_tier: Prospect = Prospect(name="Both Sides", handle="stier",
                                email="s@real.dev", email_confidence=0.9);
    a_tier: Prospect = Prospect(name="One Side", handle="atier",
                                email="a@real.dev", email_confidence=0.9);
    lane +>:Surfaced(at_rank=0, found_at=1.0, query="q"):+> s_tier;
    lane +>:Surfaced(at_rank=1, found_at=1.0, query="q"):+> a_tier;

    s_gp: GithubProfile = GithubProfile(login="stier", url="u");
    s_lp: LinkedinProfile = LinkedinProfile(handle="stier", url="u");
    s_tier +>:Identity(tier=IdentityTier.VERIFIED, basis="t", confidence=0.9):+> s_gp;
    s_tier +>:Identity(tier=IdentityTier.VERIFIED, basis="t", confidence=0.9):+> s_lp;

    a_gp: GithubProfile = GithubProfile(login="atier", url="u");
    a_tier +>:Identity(tier=IdentityTier.VERIFIED, basis="t", confidence=0.9):+> a_gp;

    _ = root spawn RankAndSelect(top_n=10);
    assert s_tier.tier == CompletenessTier.S, "email + GitHub + LinkedIn is S";
    assert a_tier.tier == CompletenessTier.A, "email + one side only is A";
    assert s_tier.score > a_tier.score, "S must outrank A on identical evidence";
}


"""Three or more lanes is a stronger claim than two and must score higher."""
test "three-lane convergence beats two-lane convergence" {
    f: Founder = (root ++> Founder(name="F4", email="f4@x.io")) as Founder;
    run: ResearchRun = (f +>:Runs(created_at=1.0):+> ResearchRun(started_at=1.0)) as ResearchRun;
    la: Lane = (run +>:HasLane(launched_at=1.0):+> Lane(lane_id=LaneId.A)) as Lane;
    lb: Lane = (run +>:HasLane(launched_at=1.0):+> Lane(lane_id=LaneId.B)) as Lane;
    lc: Lane = (run +>:HasLane(launched_at=1.0):+> Lane(lane_id=LaneId.C)) as Lane;

    two: Prospect = Prospect(name="Two", handle="two", email="t@real.dev", email_confidence=0.9);
    three: Prospect = Prospect(name="Three", handle="three", email="th@real.dev", email_confidence=0.9);
    la +>:Surfaced(at_rank=0, found_at=1.0, query="q"):+> two;
    lb +>:Surfaced(at_rank=0, found_at=1.0, query="q"):+> two;
    la +>:Surfaced(at_rank=1, found_at=1.0, query="q"):+> three;
    lb +>:Surfaced(at_rank=1, found_at=1.0, query="q"):+> three;
    lc +>:Surfaced(at_rank=0, found_at=1.0, query="q"):+> three;

    for p in [two, three] {
        gp: GithubProfile = GithubProfile(login=p.handle, url="u");
        p +>:Identity(tier=IdentityTier.VERIFIED, basis="t", confidence=0.9):+> gp;
    }

    _ = root spawn RankAndSelect(top_n=10);
    assert len(three.convergence_lanes()) == 3;
    assert len(two.convergence_lanes()) == 2;
    assert three.score > two.score, "more independent lanes must mean a higher score";
}


"""The heavy cross-link parses the shapes people actually paste, and refuses
GitHub's own reserved paths - `github.com/features` is not a person."""
test "github login extraction handles real url shapes and rejects reserved paths" {
    found = logins_from_text("my code is at https://github.com/octocat and github.com/torvalds/linux");
    assert "octocat" in found;
    assert "torvalds" in found;

    reserved = logins_from_text("see github.com/features and github.com/pricing");
    assert len(reserved) == 0, "GitHub's own pages are not people";

    assert len(logins_from_text("")) == 0;
    assert len(logins_from_text("no links here at all")) == 0;
}


"""EmailSource has to round-trip every waterfall step, or the UI cannot say
where an address came from."""
test "every waterfall step maps to a distinct email source" {
    assert step_to_source("1:users.email") == EmailSource.GITHUB_PROFILE;
    assert step_to_source("2:search/commits") == EmailSource.GITHUB_COMMIT;
    assert step_to_source("3:repos/a/b") == EmailSource.GITHUB_COMMIT;
    assert step_to_source("4:.patch") == EmailSource.GITHUB_COMMIT;
    assert step_to_source("5a:profile-readme") == EmailSource.GITHUB_README;
    assert step_to_source("5c:blog") == EmailSource.PERSONAL_SITE;
    assert step_to_source("6:linkedin") == EmailSource.LINKEDIN_CONTACT_INFO;
    assert step_to_source("") == EmailSource.NONE;
}


"""Co-authored-by trailers are a real third source and cost nothing once the
commit payload is already in hand."""
test "commit harvesting reads author, committer and message trailers" {
    payload: list[dict[str, any]] = [
        {"commit": {"author": {"email": "a@x.io"}, "committer": {"email": "b@x.io"},
                    "message": "fix thing\n\nCo-authored-by: C <c@x.io>"}}
    ];
    got = emails_from_commits(payload);
    assert "a@x.io" in got;
    assert "b@x.io" in got;
    assert "c@x.io" in got;
    assert len(emails_from_commits([])) == 0;
}


"""REGRESSION. The heavy cross-link once matched github.com/torvalds to a
prospect named "Jane Unrelated" and reported "similarity 1.00" while doing it.

The cause was scoring the GitHub login against ITSELF: `attribution_score`
weighs a local part against both the login and the name it is given and keeps
the better result, so passing the same login as subject and target returned 1.0
for every human alive. The negative control in proof_laned.jac caught it.

This is the precise failure the module exists to prevent - a confident link to
a stranger, which then feeds a personalised email about someone else's code -
so it gets a permanent test. Network-guarded, because adjudication has to
resolve the account before it can judge it."""
test "an unrelated github link in a post is never matched to the prospect" {
    if gh.has_token() {
        stranger: Prospect = (root ++> Prospect(name="Jane Unrelated",
                                                handle="jane-regression")) as Prospect;
        res = stranger spawn CrossLinkToGithub(
            posts_text="Great work by github.com/torvalds on this release!"
        );
        v = res.reports[0];
        assert not (v["matched"] as bool), "a repo someone merely praised is not their account";
        assert (v["considered"] as int) > 0, "the link WAS seen - this must not be reported as 'found nothing'";
        assert "nothing corroborates" in (v["basis"] as str);
        assert len([stranger ->:Identity:-> [?:GithubProfile]]) == 0, "no Identity edge may be written on a rejection";
    }
}


"""A github.com link on the person's own LinkedIn contact card is the strongest
signal available - LinkedIn only renders what they entered themselves."""
test "a contact-card github link resolves to a verified identity" {
    if gh.has_token() {
        p: Prospect = (root ++> Prospect(name="Simon Willison",
                                         handle="simonw-regression")) as Prospect;
        res = p spawn CrossLinkToGithub(
            contact_info_text="GitHub: https://github.com/simonw",
            linkedin_company="Datasette"
        );
        v = res.reports[0];
        assert (v["matched"] as bool);
        assert (v["login"] as str) == "simonw";
        assert (v["tier"] as str) == "verified";
        linked: list[GithubProfile] = [p ->:Identity:-> [?:GithubProfile]];
        assert len(linked) == 1, "a match must write exactly one Identity edge";
        assert linked[0].login == "simonw";
    }
}
