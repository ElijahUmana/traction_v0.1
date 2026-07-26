"""TRACTION - the live dashboard feed and the frontend's read surface.

This module is the seam between the graph and the 5-panel dashboard. Everything
the UI renders comes from here, and nothing here needs the UI to exist.

-----------------------------------------------------------------------------
WHY THE FEED LOOKS THE WAY IT DOES - READ BEFORE CHANGING IT
-----------------------------------------------------------------------------
Three properties of jac 0.34.7 were measured live (see docs/EVIDENCE.md) and
they dictate this design. Get one wrong and the dashboard silently freezes.

1. A WebSocket walker CANNOT read the live graph. Its view is pinned to the
   state that existed when the server started. Measured: with the same root
   jid, HTTP reported 9 then 10 Reasoning nodes while the WS walker kept
   reporting 8, permanently.

2. Inside a `-> Generator` body, `root` does not resolve to the caller's graph
   at all - a probe streamed `reasoning=0` for six consecutive ticks while the
   graph held 13 nodes. The generator body runs lazily, after the request
   context is gone.

3. `broadcast=True` only fires in response to a CLIENT frame. The connection
   manager is a private member of the server object, so no server-side lane
   walker can push into it.

Therefore:
  * LiveFeed NEVER touches the graph. It echoes the payload it is given, and
    `broadcast=True` fans that echo to every connected panel. This is the only
    arrangement that is both live and correct.
  * The pump reads fresh state over PLAIN HTTP - the one reliably-fresh path -
    and injects it as the frame body.
  * feed_backlog() snapshots the graph in the ENCLOSING def body, which does
    run in the request context, then streams the closed-over snapshot. That is
    why the read happens before `stream` is defined, not inside it.

Proven end-to-end: 5 panels, 3 rounds, 5/5 delivery every round, values
climbing 14 -> 15 -> 16 (fresh, not frozen).
"""

import from typing { Generator }

import from contracts {
    LaneId, LaneState, RunStatus, CompletenessTier, ProspectView
}
import from schema {
    Founder, ResearchRun, Lane, Reasoning, Prospect,
    Runs, HasLane, Emitted, Surfaced
}


# -----------------------------------------------------------------------------
# Flat wire projections. The return type IS the wire format, so the dashboard
# never has to know the graph shape.
# -----------------------------------------------------------------------------

obj ReasoningView {
    has seq: int;
    has t: float;
    has lane_id: LaneId;
    has sentence: str;
    has kind: str;
}


obj LaneView {
    has jid: str;
    has lane_id: LaneId;
    has doctrine: str = "";
    has state: LaneState = LaneState.IDLE;
    has live_url: str = "";
    has bb_session_id: str = "";
    has current_query: str = "";
    has reasoning_count: int = 0;
    has prospect_count: int = 0;
}


obj RunStateView {
    has jid: str = "";
    has status: RunStatus = RunStatus.PLANNING;
    has started_at: float = 0.0;
    has finished_at: float = 0.0;
    has lane_count: int = 0;
    has prospect_count: int = 0;
    has surviving_count: int = 0;
    has dropped_count: int = 0;
    has converged_count: int = 0;
    has reasoning_count: int = 0;
    has exists: bool = False;
}


obj FeedBatch {
    has seq: int = 0;
    has next_seq: int = 0;
    has reasoning: list[ReasoningView] = [];
    has lanes: list[LaneView] = [];
    has run: RunStateView = RunStateView();
    has prospects: list[ProspectView] = [];
}


# -----------------------------------------------------------------------------
# Internal graph readers. Underscore-prefixed, so they stay OFF the API surface.
# -----------------------------------------------------------------------------

"""Newest ResearchRun on the graph, or None before a run has been created.

Runs hang off the Founder (`Founder -:Runs:-> ResearchRun`), NOT off root, so
this is a two-hop read. Querying `[root --> [?:ResearchRun]]` directly returns
an empty list and silently blanks the entire dashboard.
"""
def _latest_run -> ResearchRun | None {
    runs: list[ResearchRun] = [];
    for f in [root --> [?:Founder]] {
        for r in [f --> [?:ResearchRun]] {
            runs.append(r);
        }
    }
    # tolerate a run parented straight to root (rehearsal / older graphs)
    for r in [root --> [?:ResearchRun]] {
        runs.append(r);
    }
    if not runs {
        return None;
    }
    newest = runs[0];
    for r in runs {
        if r.started_at > newest.started_at {
            newest = r;
        }
    }
    return newest;
}


"""Every Reasoning node across every lane, in global time order.

`seq` is assigned from that ordering and is what the dashboard uses as its
cursor. It is positional, so it stays stable only within one response - callers
should treat `next_seq` as opaque and just hand it back.
"""
def _all_reasoning -> list[ReasoningView] {
    run = _latest_run();
    if run is None {
        return [];
    }
    pairs: list[tuple] = [];
    for lane in [run --> [?:Lane]] {
        for r in [lane --> [?:Reasoning]] {
            pairs.append((r.t, lane.lane_id, r.sentence, str(r.kind)));
        }
    }
    pairs.sort(key=lambda (x: any) { x[0]; });
    out: list[ReasoningView] = [];
    i: int = 0;
    for p in pairs {
        out.append(ReasoningView(seq=i, t=p[0], lane_id=p[1], sentence=p[2], kind=p[3]));
        i += 1;
    }
    return out;
}


def _lane_views -> list[LaneView] {
    run = _latest_run();
    if run is None {
        return [];
    }
    out: list[LaneView] = [];
    for lane in [run --> [?:Lane]] {
        out.append(LaneView(
            jid=jid(lane),
            lane_id=lane.lane_id,
            doctrine=lane.doctrine,
            state=lane.state,
            live_url=lane.live_url,
            bb_session_id=lane.bb_session_id,
            current_query=lane.current_query,
            reasoning_count=len([lane --> [?:Reasoning]]),
            prospect_count=len([lane --> [?:Prospect]])
        ));
    }
    out.sort(key=lambda (l: any) { str(l.lane_id); });
    return out;
}


"""Every prospect surfaced by the run, deduped across lanes.

A prospect surfaced by two lanes appears twice in the raw traversal - that
double-surfacing IS the convergence signal, but the ledger must show the human
once. Dedup is by jid, which is stable for persisted nodes.
"""
def _prospects -> list[Prospect] {
    run = _latest_run();
    if run is None {
        return [];
    }
    seen: dict[str, Prospect] = {};
    for lane in [run --> [?:Lane]] {
        for p in [lane --> [?:Prospect]] {
            seen[jid(p)] = p;
        }
    }
    return [v for v in seen.values()];
}


# -----------------------------------------------------------------------------
# Read endpoints. These are `def:pub` with typed returns, NOT walkers: none of
# them traverses on the caller's behalf in a way a walker would model, and a
# walker would tax every caller with reports[0] unwrapping.
# -----------------------------------------------------------------------------

"""The four research lanes, each carrying the live_url its iframe embeds."""
def:pub list_lanes -> list[LaneView] {
    return _lane_views();
}


"""Every prospect on the ledger, best first.

DROPPED prospects are INCLUDED deliberately. Visible elimination is what makes
the survivors look earned rather than cherry-picked, so the UI must be able to
render the drops and their reasons.
"""
def:pub list_prospects -> list[ProspectView] {
    views: list[ProspectView] = [];
    for p in _prospects() {
        views.append(p.to_view());
    }
    views.sort(key=lambda (v: any) { -v.score; });
    return views;
}


"""Header state for the run: status, counts, and the drop/survive split."""
def:pub get_run_state -> RunStateView {
    run = _latest_run();
    if run is None {
        return RunStateView();
    }
    prospects = _prospects();
    surviving: int = 0;
    dropped: int = 0;
    converged: int = 0;
    for p in prospects {
        if p.tier == CompletenessTier.DROPPED {
            dropped += 1;
        } else {
            surviving += 1;
        }
        if p.is_converged() {
            converged += 1;
        }
    }
    lanes = [run --> [?:Lane]];
    reasoning_total: int = 0;
    for lane in lanes {
        reasoning_total += len([lane --> [?:Reasoning]]);
    }
    return RunStateView(
        jid=jid(run),
        status=run.status,
        started_at=run.started_at,
        finished_at=run.finished_at,
        lane_count=len(lanes),
        prospect_count=len(prospects),
        surviving_count=surviving,
        dropped_count=dropped,
        converged_count=converged,
        reasoning_count=reasoning_total,
        exists=True
    );
}


"""One fresh snapshot of everything the dashboard renders.

This is the endpoint the pump polls. It is a plain HTTP function on purpose -
that is the only path in jac 0.34.7 that reliably observes writes made by other
request contexts (the research lanes). Pass the `next_seq` from the previous
response as `since` to receive only newly-emitted reasoning.
"""
def:pub feed_since(since: int = 0) -> FeedBatch {
    all_r = _all_reasoning();
    fresh: list[ReasoningView] = [r for r in all_r if r.seq >= since];
    return FeedBatch(
        seq=since,
        next_seq=len(all_r),
        reasoning=fresh,
        lanes=_lane_views(),
        run=get_run_state(),
        prospects=list_prospects()
    );
}


# -----------------------------------------------------------------------------
# The realtime surface.
# -----------------------------------------------------------------------------

"""Live dashboard fan-out. ws://host/ws/walker/LiveFeed

Every frame sent by ANY client is echoed to ALL connected clients, so one pump
drives all five panels at once. `/ws/LiveFeed` is a legacy alias for the same
channel - verified to share one broadcast bus.

This walker deliberately does not read the graph: a WebSocket walker's view is
frozen at server-start (see the module docstring). The pump reads fresh state
over HTTP and passes it in here, which is what keeps the panels live.
"""
@restspec(protocol=APIProtocol.WEBSOCKET, broadcast=True)
async walker:pub LiveFeed {
    has kind: str = "tick";
    has seq: int = 0;
    has batch: dict = {};
    has note: str = "";

    async can fan with Root entry {
        report {
            "kind": self.kind,
            "seq": self.seq,
            "batch": self.batch,
            "note": self.note
        };
    }
}


"""SSE backlog feed. POST /function/feed_backlog

The fallback path for a client that cannot hold a WebSocket. It streams the
reasoning backlog one analyst sentence per frame, then closes.

The graph read happens HERE, in the enclosing body, which still runs inside the
request context. `stream` then closes over that snapshot. Reading the graph
inside the generator instead returns an EMPTY root - measured, not assumed.
"""
def:pub feed_backlog(since: int = 0) -> Generator {
    snapshot = [r for r in _all_reasoning() if r.seq >= since];
    lanes = _lane_views();

    def stream -> Generator[dict, None, None] {
        yield {
            "kind": "lanes",
            "lanes": [
                {
                    "lane_id": str(l.lane_id), "state": str(l.state),
                    "live_url": l.live_url, "doctrine": l.doctrine
                } for l in lanes
            ]
        };
        for r in snapshot {
            yield {
                "kind": "reasoning", "seq": r.seq, "t": r.t,
                "lane_id": str(r.lane_id), "sentence": r.sentence, "kind_of": r.kind
            };
        }
    }
    report stream();
}
