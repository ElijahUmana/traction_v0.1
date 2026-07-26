"""Tests for the dashboard feed projections.

Run with:  jac test feed.jac

These need NO API keys - nothing here calls an LLM. Run `jac clean --all --force`
first if a previous run left nodes behind: tests in a file share one persisted
root and it also survives between runs, so assertions here always scope
themselves to the run they just created rather than counting totals on root.
"""

import time;


"""Build an isolated run with N lanes, reusing one Founder.

Every test asserts against ITS run, so leftover state from an earlier test or an
earlier `jac test` invocation cannot make assertions flap. Because _latest_run()
picks the newest by started_at, each call must be strictly newer than the last -
hence the explicit, increasing timestamp.

The Founder is created at most ONCE. Doing `root ++> Founder(...)` in every test
bumps the root anchor's version each time and the suite dies with
`WriteConflict: anchor 00000000-... changed concurrently (expected v0, found v6)`.
Runs hang off the Founder, so only the first test ever writes to root.
"""
def _founder -> Founder {
    existing = [root --> [?:Founder]];
    if existing {
        return existing[0];
    }
    return (root ++> Founder(name="t", email="t@example.invalid")) as Founder;
}


def _mk_run(stamp: float) -> ResearchRun {
    run = (_founder() +>: Runs :+> ResearchRun(
        started_at=stamp, status=RunStatus.RUNNING
    )) as ResearchRun;
    for key in ["A", "B", "C", "D"] {
        run +>: HasLane :+> Lane(
            lane_id=LaneId(key),
            doctrine=f"doctrine {key}",
            state=LaneState.SEARCHING,
            live_url=f"https://live/{key}"
        );
    }
    return run;
}


def _lane_of(run: ResearchRun, which: str) -> Lane {
    hits = [l for l in [run --> [?:Lane]] if str(l.lane_id) == which];
    assert hits, f"no lane {which} on this run";
    return hits[0];
}


test "a run is found through the Founder, not off root" {
    # The graph is Founder -:Runs:-> ResearchRun. Reading [root --> [?:ResearchRun]]
    # returns nothing and silently blanks the whole dashboard, so this two-hop
    # read is the single most load-bearing line in feed.jac.
    run = _mk_run(1000.0);
    found = _latest_run();
    assert found is not None, "two-hop Founder->Runs read returned None";
    assert jid(found) == jid(run), "did not resolve the run we just made";
}


test "the newest run wins when several exist" {
    _mk_run(2000.0);
    newest = _mk_run(3000.0);
    found = _latest_run();
    assert found is not None;
    assert jid(found) == jid(newest), "picked an older run";
}


test "lanes project in A-B-C-D order and carry the iframe url" {
    _mk_run(4000.0);
    views = list_lanes();
    assert len(views) == 4, f"expected 4 lanes, got {len(views)}";
    assert [str(v.lane_id) for v in views] == ["A", "B", "C", "D"], "lanes out of order";
    for v in views {
        assert v.live_url != "", f"lane {v.lane_id} has no live_url to embed";
        assert v.jid != "", "LaneView must carry a stable jid for the frontend";
    }
}


test "a prospect surfaced by two lanes appears once but records both lanes" {
    # This is the product thesis as a test: convergence must survive the dedup.
    run = _mk_run(5000.0);
    a = _lane_of(run, "A");
    d = _lane_of(run, "D");
    p = (a +>: Surfaced :+> Prospect(
        name="Converged", handle="conv", email="c@example.invalid",
        tier=CompletenessTier.S, score=0.94, score_pre_crosslink=0.71
    )) as Prospect;
    d +>: Surfaced :+> p;

    rows = [v for v in list_prospects() if v.name == "Converged"];
    assert len(rows) == 1, f"convergence must dedup to one ledger row, got {len(rows)}";
    lanes = sorted([str(x) for x in rows[0].convergence_lanes]);
    assert lanes == ["A", "D"], f"expected both lanes recorded, got {lanes}";
    assert p.is_converged(), "two distinct lanes must count as converged";
}


test "dropped prospects stay on the ledger with their reason" {
    # Visible elimination is a demo beat - dropping them from the payload would
    # make the survivors look cherry-picked.
    run = _mk_run(6000.0);
    lane = _lane_of(run, "C");
    lane +>: Surfaced :+> Prospect(
        name="NoEmail", handle="noemail", email="",
        tier=CompletenessTier.DROPPED, score=0.0,
        dropped_reason="no email after all six waterfall steps"
    );
    rows = [v for v in list_prospects() if v.name == "NoEmail"];
    assert len(rows) == 1, "DROPPED prospects must still be returned";
    assert str(rows[0].tier) == "DROPPED";
    assert rows[0].dropped_reason != "", "a drop must explain itself";
}


test "the ledger is sorted best-score-first" {
    run = _mk_run(7000.0);
    lane = _lane_of(run, "A");
    for pair in [("low", 0.10), ("high", 0.90), ("mid", 0.50)] {
        lane +>: Surfaced :+> Prospect(
            name=pair[0], handle=pair[0], email="x@example.invalid",
            tier=CompletenessTier.A, score=pair[1]
        );
    }
    scores = [v.score for v in list_prospects()];
    assert scores == sorted(scores, reverse=True), f"ledger not sorted: {scores}";
}


test "run state splits survivors from drops and counts convergence" {
    run = _mk_run(8000.0);
    a = _lane_of(run, "A");
    d = _lane_of(run, "D");
    keeper = (a +>: Surfaced :+> Prospect(
        name="Keeper", handle="k", email="k@example.invalid",
        tier=CompletenessTier.S, score=0.9
    )) as Prospect;
    d +>: Surfaced :+> keeper;
    a +>: Surfaced :+> Prospect(
        name="Gone", handle="g", email="",
        tier=CompletenessTier.DROPPED, dropped_reason="no email"
    );

    state = get_run_state();
    assert state.exists, "run state must report exists=True once a run is present";
    assert state.lane_count == 4, f"lane_count={state.lane_count}";
    assert state.prospect_count == 2, f"prospect_count={state.prospect_count}";
    assert state.surviving_count == 1, f"surviving={state.surviving_count}";
    assert state.dropped_count == 1, f"dropped={state.dropped_count}";
    assert state.converged_count == 1, f"converged={state.converged_count}";
    assert state.jid != "", "RunStateView must carry the run jid";
}


test "reasoning is ordered by time across all lanes, not per lane" {
    # The analyst sidebar interleaves four lanes, so global time order is what
    # makes it read like one narrative instead of four transcripts.
    run = _mk_run(9000.0);
    a = _lane_of(run, "A");
    b = _lane_of(run, "B");
    a +>: Emitted :+> Reasoning(t=9003.0, sentence="third", kind=ReasoningKind.OBSERVE);
    b +>: Emitted :+> Reasoning(t=9001.0, sentence="first", kind=ReasoningKind.PLAN);
    a +>: Emitted :+> Reasoning(t=9002.0, sentence="second", kind=ReasoningKind.PIVOT);

    got = [r.sentence for r in _all_reasoning()];
    assert got == ["first", "second", "third"], f"not in time order: {got}";
    seqs = [r.seq for r in _all_reasoning()];
    assert seqs == [0, 1, 2], f"seq must be a dense 0-based index, got {seqs}";
}


test "feed_since is a cursor: it returns only what is new" {
    run = _mk_run(10000.0);
    lane = _lane_of(run, "A");
    for i in range(3) {
        lane +>: Emitted :+> Reasoning(
            t=10000.0 + i, sentence=f"s{i}", kind=ReasoningKind.OBSERVE
        );
    }
    first = feed_since(0);
    assert len(first.reasoning) == 3, f"since=0 must return all, got {len(first.reasoning)}";
    assert first.next_seq == 3, f"next_seq={first.next_seq}";

    # nothing new emitted -> handing next_seq back must yield an empty delta
    again = feed_since(first.next_seq);
    assert len(again.reasoning) == 0, "cursor did not suppress already-seen reasoning";

    lane +>: Emitted :+> Reasoning(t=10009.0, sentence="fresh", kind=ReasoningKind.HIT);
    delta = feed_since(first.next_seq);
    assert len(delta.reasoning) == 1, f"expected 1 new, got {len(delta.reasoning)}";
    assert delta.reasoning[0].sentence == "fresh";
}


test "feed_since always returns lanes, run and prospects in full" {
    # Only `reasoning` is incremental. If the cursor also trimmed the lanes or
    # the ledger, a late-joining panel would render an empty dashboard.
    run = _mk_run(11000.0);
    _lane_of(run, "A") +>: Surfaced :+> Prospect(
        name="Full", handle="f", email="f@example.invalid",
        tier=CompletenessTier.A, score=0.5
    );
    batch = feed_since(9_999_999);
    assert len(batch.reasoning) == 0, "cursor past the end should yield no reasoning";
    assert len(batch.lanes) == 4, "lanes must always come back in full";
    assert batch.run.exists, "run state must always come back";
    assert len(batch.prospects) >= 1, "ledger must always come back in full";
}
