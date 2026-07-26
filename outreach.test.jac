"""Tests for the citation gate - the safety property the whole product rests on.

Runs with NO API keys and no network: every assertion here is about pure
functions, so this suite stays green on a laptop with no .env at all.

The gate exists to answer one question: did this email actually quote the human,
or did the model merely write something that sounds like it did? Both directions
matter and both are tested. A gate that rejects real quotes is useless because
it blocks the demo; a gate that accepts paraphrase is worse than useless because
it certifies exactly the generic outreach this product exists to prevent.
"""

# NOTE: no `import from outreach` here. A `<module>.test.jac` file is an ANNEX of
# its parent module - every symbol in outreach.jac, including the names it
# imports, is already in scope. Importing them explicitly makes the module fail
# to load with a misleading "cannot import name ... from 'outreach'".


glob QUOTE: str = "Every time I add a new tool to my agent the retry logic drifts and I end up debugging timeouts instead of building features.";
glob ABOUT: str = "Hi, this is Xingzhi (Becky) Zhu, UCLA alum. I am passionate about turning messy data into decisions people actually act on.";


def rejected(body: str, quote: str, artifact: str) -> bool {
    return citation_problem(EmailDraft(subject="s", body=body), quote, artifact) != "";
}


test "a verbatim quote is accepted" {
    assert not rejected(f'You wrote: "{QUOTE}" and you built agent-runner.', QUOTE, "agent-runner - a harness");
}

test "a sentence lifted from inside a longer About is accepted" {
    # The right editorial choice is to quote the sentence that describes the
    # person's problem, not to recite their self-introduction from the top.
    body = 'You wrote: "I am passionate about turning messy data into decisions people actually act on."';
    assert not rejected(body, ABOUT, "");
}

test "trimming a leading I am to fit the sentence is still quoting" {
    body = 'you are "passionate about turning messy data into decisions people actually act on"';
    assert not rejected(body, ABOUT, "");
}

test "paraphrase is rejected" {
    body = "You seem frustrated by flaky retries and tooling drift in your agent stack.";
    assert rejected(body, QUOTE, "");
}

test "generic filler is rejected" {
    body = "I came across your profile and was impressed by your work. Let us connect.";
    assert rejected(body, QUOTE, "");
}

test "reusing the topic words without quoting is rejected" {
    # The failure mode that looks most like success: every salient word present,
    # nothing actually quoted.
    body = "Your retry logic and your agent tools and the timeouts you debug are interesting.";
    assert rejected(body, QUOTE, "");
}

test "an invented artifact is rejected even when the quote is perfect" {
    assert rejected(f'You wrote: "{QUOTE}"', QUOTE, "some-repo-they-never-built");
}

test "the artifact identifier is the name, not our description of it" {
    assert artifact_identifier("agent-runner - a small harness for retrying flaky tool calls") == "agent-runner";
    assert artifact_identifier("agent-runner") == "agent-runner";
    assert artifact_identifier("parser: a tokenizer") == "parser";
}

test "naming the repo satisfies the artifact citation" {
    body = f'You wrote: "{QUOTE}" Your agent-runner repo shows it.';
    assert not rejected(body, QUOTE, "agent-runner - a small harness for retrying flaky tool calls");
}

test "a headline is never citable but authored text is" {
    # Quoting someone's job title back at them as something they wrote is the
    # exact tell this product must avoid.
    assert citation_rank(EvidenceKind.HEADLINE) == 0;
    assert citation_rank(EvidenceKind.ABOUT) > 0;
    assert citation_rank(EvidenceKind.POST) > 0;
    assert citation_rank(EvidenceKind.COMMENT) > 0;
}

test "attribution names the real source so the email cannot overclaim" {
    assert "About" in attribution_for(EvidenceKind.ABOUT);
    assert "post" in attribution_for(EvidenceKind.POST);
    assert "comment" in attribution_for(EvidenceKind.COMMENT);
    assert attribution_for(EvidenceKind.HEADLINE) == "";
}

test "word runs are counted contiguously" {
    assert longest_verbatim_run(normalize("one two three four"), normalize("one two three four")) == 4;
    assert longest_verbatim_run(normalize("one two zzz three four"), normalize("one two three four")) == 2;
    assert longest_verbatim_run(normalize("nothing alike here"), normalize("completely different words")) == 0;
}

test "whitespace and case differences do not defeat a real quote" {
    body = 'You WROTE:   "every time i add a NEW tool to my agent the retry logic drifts"';
    assert not rejected(body, QUOTE, "");
}

test "an empty stored quote is not treated as grounded" {
    assert not quote_is_grounded(normalize("any body text at all"), "");
}

test "a short stored quote must appear in full" {
    short = "ships on Fridays";
    assert quote_is_grounded(normalize("They ships on Fridays reportedly"), short);
    assert not quote_is_grounded(normalize("They ship on Tuesdays"), short);
}
