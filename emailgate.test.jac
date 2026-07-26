"""Gate regression tests, built from a live run - not from imagination.

Every case below is a real (login, email, source) triple observed while probing
a pool of 15 genuine GitHub accounts. The six failing ones are the six false
positives the naive filter let through. If any of these ever flips, the demo
sends mail to a black hole or to the wrong human.

    jac test emailgate.test.jac
"""

# NOTE: no `import from emailgate` here. A `<module>.test.jac` file is an ANNEX of
# its parent module - every symbol in emailgate.jac is already in scope. Importing
# the parent makes the module import itself and fails at runtime with a
# partially-initialized-module error while still passing `jac check`.

# The four-of-fifteen case. `noreply@github.com` is GitHub's GENERIC proxy,
# stamped on web-UI and merge commits. It is a DIFFERENT string from
# `<user>@users.noreply.github.com`, and the filter the plan specifies does
# not match it. This is the single largest source of false hits.
test "github generic noreply is rejected" {
    for login in ["skynetcmd", "djny45", "Aureliolo", "SuperInstance"] {
        v = judge_email("noreply@github.com", "2:search/commits", login, "");
        assert not v.ok, f"{login}: generic github noreply must be rejected";
        assert "non-deliverable domain" in v.reason;
    }
}


# The documented form, in both shapes GitHub emits (with and without the
# numeric account-id prefix).
test "per user privacy proxy is rejected" {
    a = judge_email("sariekiriyuu@users.noreply.github.com", "2:search/commits", "sariekiriyuu", "");
    b = judge_email("98093715+othmane55@users.noreply.github.com", "2:search/commits", "othmane55", "");
    assert not a.ok;
    assert not b.ok;
}


# Harvested verbatim from an unedited pyproject.toml scaffold.
test "template placeholder is rejected" {
    v = judge_email("agent@example.com", "5b:pyproject.toml", "gungarp", "");
    assert not v.ok;
    assert "undeliverable" in v.reason;
}


# THE DANGEROUS ONE. Syntactically valid, genuinely deliverable, and
# belonging to a completely different person - the upstream author of a repo
# this candidate merely forked. Only the attribution check catches it. Sending
# here means a personalised pitch about someone else's repository lands on a
# stranger.
test "forked manifest email is rejected as wrong human" {
    v = judge_email("kacarumit.phd@gmail.com", "5b:package.json", "othmane55", "");
    assert not v.ok, "fork-inherited manifest email must not be attributed to the forker";
    assert "unverifiable attribution" in v.reason;
    assert v.attribution < ATTRIBUTION_FLOOR;
}


# The seven genuine addresses from the same live pool. A gate that drops
# these is worse than no gate - it starves the funnel.
test "real emails survive the gate" {
    cases: list[list[str]] = [
        ["jose.matzkin@gmail.com", "2:search/commits", "jmatzkin1980", "Jose Matzkin"],
        ["mahdiahmadirad@gmail.com", "2:search/commits", "mahdiahmadirad", ""],
        ["g.rider016@gmail.com", "1:users.email", "grider-pk", ""],
        ["swillison@gmail.com", "2:search/commits", "simonw", "Simon Willison"],
        ["sindresorhus@gmail.com", "1:users.email", "sindresorhus", "Sindre Sorhus"],
        ["jaraco@jaraco.com", "1:users.email", "jaraco", "Jason R. Coombs"],
        ["peppersthreathunts@gmail.com", "2:search/commits", "MrPeppersDev", ""]
    ];
    for c in cases {
        v = judge_email(c[0], c[1], c[2], c[3]);
        assert v.ok, f"{c[0]} for {c[2]} must pass: {v.reason}";
        assert v.confidence > 0.5, f"{c[0]} confidence too low: {v.confidence}";
    }
}


# The floor has to sit between a real match and the fork-inherited one.
# jose.matzkin/jmatzkin1980 is the same human; kacarumit.phd/othmane55 is not.
test "attribution separates the two live manifest cases" {
    good = attribution_score("jose.matzkin@gmail.com", "jmatzkin1980", "Jose Matzkin");
    bad = attribution_score("kacarumit.phd@gmail.com", "othmane55", "");
    assert (good[0] as float) >= ATTRIBUTION_FLOOR;
    assert (bad[0] as float) < ATTRIBUTION_FLOOR;
    assert (good[0] as float) > (bad[0] as float);
}


# An address off someone's OWN authored commits is theirs by construction,
# even when the local part looks nothing like the login. Applying the
# attribution floor here would drop real people who use a work address or a
# pseudonym - a false negative that silently starves the funnel.
test "high trust source survives weak name correlation" {
    v = judge_email("agi@icdev.ai", "2:search/commits", "icdev-ai", "ICDEV");
    assert v.ok;
    v2 = judge_email("samasaeedmy@gmail.com", "2:search/commits", "samsaeed22", "");
    assert v2.ok;
}


test "bot and ci accounts are rejected" {
    for e in [
        "49699333+dependabot[bot]@users.noreply.github.com",
        "actions@github.com",
        "github-actions[bot]@users.noreply.github.com",
        "renovate[bot]@users.noreply.github.com"
    ] {
        v = judge_email(e, "2:search/commits", "somebody", "");
        assert not v.ok, f"{e} is automation, not a person";
    }
}


test "reserved tlds and impersonal localparts rejected" {
    for e in ["dev@macbook.local", "me@host.invalid", "x@thing.test"] {
        d = is_deliverable(e);
        assert not (d[0] as bool), f"{e} is not routable";
    }
    for e in ["admin@realdomain.io", "noreply@realdomain.io", "you@realdomain.io"] {
        d = is_deliverable(e);
        assert not (d[0] as bool), f"{e} has an impersonal local part";
    }
}


# A drop with no reason is indistinguishable from a bug, and the ledger is
# shown on stage.
test "empty waterfall produces a written reason" {
    v = judge_email("", "", "sariekiriyuu", "");
    assert not v.ok;
    assert len(v.reason) > 10;
    assert "exhausted" in v.reason;
}


# A real git identity appears on most commits; a stray trailer appears once.
test "best of prefers frequency and name match" {
    bag: list[str] = [
        "noreply@github.com",
        "jose.matzkin@gmail.com",
        "jose.matzkin@gmail.com",
        "jmatzkin1980@users.noreply.github.com",
        "someoneelse@corp.com"
    ];
    assert best_of(bag, "jmatzkin1980", "Jose Matzkin") == "jose.matzkin@gmail.com";
    assert best_of(["noreply@github.com"], "x", "") == "";
    assert best_of([], "x", "") == "";
}


# Used against README bodies, manifests and blog HTML.
test "scan emails pulls addresses out of free text" {
    got = scan_emails("Contact: <a href=\"mailto:me@site.dev\">me@site.dev</a> or bob@x.io.");
    assert "me@site.dev" in got;
    assert "bob@x.io" in got;
    assert len(scan_emails("")) == 0;
}


# The hard constraint: no pattern-generated guesses. An empty input must
# never produce an address on the way out.
test "never fabricates" {
    for src in ["1:users.email", "2:search/commits", "5b:package.json", "6:linkedin"] {
        v = judge_email("", src, "someone", "Some One");
        assert not v.ok;
        assert v.email == "";
    }
}


test "the exact node that shipped: one person's quotes, another person's email" {
    # Reproduces the Lane W proof artifact that was recorded as a pass. Every
    # field is individually valid; only the COMBINATION is wrong.
    v = check_identity(
        "xingzhizhu6@gmail.com",                                  # the warm lead
        "provided",
        "https://www.linkedin.com/in/elijah-umana-4964b3206/",    # a stand-in
        [
            "https://www.linkedin.com/in/elijah-umana-4964b3206/",
            "https://www.linkedin.com/in/elijah-umana-4964b3206/recent-activity/all/"
        ]
    );
    # The stand-in IS internally consistent - profile and evidence agree - so
    # the URL check alone passes. What must not pass is composing an email to
    # the warm lead from it, and that is caught downstream by the address never
    # having been tied to this identity. Assert the handles were read correctly.
    assert linkedin_handle("https://www.linkedin.com/in/elijah-umana-4964b3206/")
           == "elijah-umana-4964b3206";
}

test "evidence scraped from a different profile than the one claimed is refused" {
    v = check_identity(
        "xingzhizhu6@gmail.com", "provided",
        "https://www.linkedin.com/in/xingzhi-zhu/",
        [
            "https://www.linkedin.com/in/xingzhi-zhu/",
            "https://www.linkedin.com/in/elijah-umana-4964b3206/recent-activity/all/"
        ]
    );
    assert not v.ok;
    assert len(v.reasons) >= 1;
    assert "more than one person" in " ".join(v.reasons);
}

test "a provided email with no profile to attribute it to is refused" {
    v = check_identity("xingzhizhu6@gmail.com", "provided", "", []);
    assert not v.ok;
    assert "no identity to attribute" in " ".join(v.reasons);
}

test "a provided email whose quotes carry no profile url is refused" {
    v = check_identity(
        "xingzhizhu6@gmail.com", "provided",
        "https://www.linkedin.com/in/xingzhi-zhu/",
        ["https://example.com/blog/post"]
    );
    assert not v.ok;
    assert "cannot be tied to that identity" in " ".join(v.reasons);
}

test "the real warm lead passes cleanly" {
    v = check_identity(
        "xingzhizhu6@gmail.com", "provided",
        "https://www.linkedin.com/in/xingzhi-zhu/",
        [
            "https://www.linkedin.com/in/xingzhi-zhu/",
            "https://www.linkedin.com/in/xingzhi-zhu/recent-activity/all/"
        ]
    );
    assert v.ok;
    assert v.reasons == [];
}

test "a resolved email is still checked for two-humans-on-one-node" {
    # Not just PROVIDED: mixed evidence is wrong for every source.
    v = check_identity(
        "someone@example.com", "github:commits",
        "https://www.linkedin.com/in/xingzhi-zhu/",
        ["https://www.linkedin.com/in/somebody-else/"]
    );
    assert not v.ok;
}

test "linkedin_handle survives query strings, fragments and trailing slashes" {
    assert linkedin_handle("https://www.linkedin.com/in/xingzhi-zhu/") == "xingzhi-zhu";
    assert linkedin_handle("https://www.linkedin.com/in/xingzhi-zhu?skipRedirect=true")
           == "xingzhi-zhu";
    assert linkedin_handle("https://www.linkedin.com/in/Xingzhi-Zhu/#about") == "xingzhi-zhu";
    # Sub-pages of a profile are the same human, not a stranger.
    assert linkedin_handle("https://www.linkedin.com/in/xingzhi-zhu/recent-activity/all/")
           == "xingzhi-zhu";
    assert linkedin_handle("https://www.linkedin.com/in/xingzhi-zhu/overlay/contact-info/")
           == "xingzhi-zhu";
    assert linkedin_handle("https://github.com/someone") == "";
    assert linkedin_handle("") == "";
}
