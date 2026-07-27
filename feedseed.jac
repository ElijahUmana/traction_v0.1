"""TRACTION - run-shaped graph seeding for VERIFICATION AND REHEARSAL ONLY.

This is not part of the product path. It exists for two honest reasons:

  1. The frontend contract in docs/FRONTEND_INTEGRATION.md documents REAL
     captured responses, not hand-written JSON. Capturing a response with a
     populated ledger requires a populated graph, and waiting on a six-minute
     live research run to document a wire format is not a good trade.
  2. The demo has to be rehearsable before the research lanes are green.

Everything it writes is supplied by the caller. It invents no evidence, no
quotes and no scores: a seeded prospect carrying fabricated evidence would
produce an email that LOOKS grounded and is not, which is the exact failure
this system exists to prevent.

Responses captured from a graph seeded here are labelled as such in
docs/EVIDENCE.md. They prove the SHAPE of the wire format and the behaviour of
the feed; they are not evidence that the research lanes found anyone.
"""

import time;

import from contracts { LaneId, LaneState, RunStatus, ReasoningKind, CompletenessTier }
import from svc { cfg }
import from schema {
    Founder, ResearchRun, Lane, Reasoning, Prospect,
    Runs, HasLane, Emitted, Surfaced
}


"""Runs hang off the Founder, not root - same two-hop read the feed uses."""
def _rehearsal_runs -> list[ResearchRun] {
    out: list[ResearchRun] = [];
    for f in [root --> [?:Founder]] {
        for r in [f --> [?:ResearchRun]] {
            out.append(r);
        }
    }
    for r in [root --> [?:ResearchRun]] {
        out.append(r);
    }
    return out;
}


"""Create a ResearchRun with four lanes, so the feed has a run to project.

`confirm` must be the literal string "yes" - this can never fire by accident.
"""
walker:pub SeedRehearsalRun {
    has confirm: str = "";
    has status: str = "running";

    can build with Root entry {
        if self.confirm != "yes" {
            report {"ok": False, "error": "refusing to seed without confirm='yes'"};
            disengage;
        }
        founders = [root --> [?:Founder]];
        founder = founders[0] if founders else (root ++> Founder(
            name="rehearsal founder", email="rehearsal@example.invalid"
        )) as Founder;

        run = (founder +>: Runs :+> ResearchRun(
            started_at=time.time(), status=RunStatus(self.status)
        )) as ResearchRun;

        # FIVE lanes. The frontend contract tells the dashboard team not to
        # hard-code four panels, so a seeder that only makes four would have
        # them build four and meet the fifth on demo day.
        doctrines = {
            "A": "comment mining under mid-tier practitioner posts",
            "B": "post authorship - first-person problem statements",
            "C": "synonym sweep - defeats vocabulary lock-in",
            "D": "GitHub-first, programmatic",
            "W": "warm lead - deep research on one known person"
        };
        made: list[str] = [];
        for key in ["A", "B", "C", "D", "W"] {
            lane = (run +>: HasLane :+> Lane(
                lane_id=LaneId(key),
                doctrine=doctrines[key],
                state=LaneState.SEARCHING,
                live_url=f"https://www.browserbase.com/devtools-fullscreen/inspector.html?rehearsal={key}",
                bb_session_id=f"rehearsal-session-{key}"
            )) as Lane;
            made.append(jid(lane));
        }
        report {"ok": True, "run": jid(run), "lanes": made};
    }
}


"""Attach one analyst sentence to a lane, exactly as a live lane would."""
walker:pub SeedRehearsalReasoning {
    has confirm: str = "";
    has lane_id: str = "A";
    has sentence: str = "";
    has kind: str = "observe";

    can emit with Root entry {
        if self.confirm != "yes" or not self.sentence {
            report {"ok": False, "error": "need confirm='yes' and a non-empty sentence"};
            disengage;
        }
        runs = _rehearsal_runs();
        if not runs {
            report {"ok": False, "error": "no ResearchRun - call SeedRehearsalRun first"};
            disengage;
        }
        run = runs[-1];
        for lane in [run --> [?:Lane]] {
            if str(lane.lane_id) == str(LaneId(self.lane_id)) {
                r = (lane +>: Emitted :+> Reasoning(
                    t=time.time(), sentence=self.sentence, kind=ReasoningKind(self.kind)
                )) as Reasoning;
                report {"ok": True, "reasoning": jid(r), "lane": str(lane.lane_id)};
                disengage;
            }
        }
        report {"ok": False, "error": f"no lane {self.lane_id} on the newest run"};
    }
}


"""Surface a caller-supplied prospect from one lane, so the ledger has rows."""
walker:pub SeedRehearsalSurfaced {
    has confirm: str = "";
    has lane_id: str = "A";
    has name: str = "";
    has handle: str = "";
    has headline: str = "";
    has company: str = "";
    has email: str = "";
    has tier: str = "DROPPED";
    has score: float = 0.0;
    has score_pre_crosslink: float = 0.0;
    has dropped_reason: str = "";

    can surface with Root entry {
        if self.confirm != "yes" or not self.name {
            report {"ok": False, "error": "need confirm='yes' and a name"};
            disengage;
        }
        runs = _rehearsal_runs();
        if not runs {
            report {"ok": False, "error": "no ResearchRun - call SeedRehearsalRun first"};
            disengage;
        }
        run = runs[-1];
        for lane in [run --> [?:Lane]] {
            if str(lane.lane_id) == str(LaneId(self.lane_id)) {
                p = (lane +>: Surfaced :+> Prospect(
                    name=self.name, handle=self.handle, headline=self.headline,
                    company=self.company, email=self.email,
                    tier=CompletenessTier(self.tier), score=self.score,
                    score_pre_crosslink=self.score_pre_crosslink,
                    dropped_reason=self.dropped_reason
                )) as Prospect;
                report {"ok": True, "prospect": jid(p)};
                disengage;
            }
        }
        report {"ok": False, "error": f"no lane {self.lane_id} on the newest run"};
    }
}


"""Surface an EXISTING prospect from a second lane - the convergence signal.

This is what makes `is_converged()` true: the same human, reached independently
by two different doctrines. It connects; it never creates.
"""
walker:pub SeedRehearsalConvergence {
    has confirm: str = "";
    has prospect_jid: str = "";
    has lane_id: str = "D";

    can converge with Root entry {
        if self.confirm != "yes" or not self.prospect_jid {
            report {"ok": False, "error": "need confirm='yes' and prospect_jid"};
            disengage;
        }
        runs = _rehearsal_runs();
        if not runs {
            report {"ok": False, "error": "no ResearchRun"};
            disengage;
        }
        run = runs[-1];
        matches: list[Prospect] = [];
        for lane in [run --> [?:Lane]] {
            for p in [lane --> [?:Prospect]] {
                if jid(p) == self.prospect_jid {
                    matches.append(p);
                }
            }
        }
        if not matches {
            report {"ok": False, "error": "prospect not found on this run"};
            disengage;
        }
        found = matches[0];
        for lane in [run --> [?:Lane]] {
            if str(lane.lane_id) == str(LaneId(self.lane_id)) {
                lane +>: Surfaced :+> found;
                report {
                    "ok": True, "prospect": self.prospect_jid,
                    "now_surfaced_by": [str(l) for l in found.convergence_lanes()]
                };
                disengage;
            }
        }
        report {"ok": False, "error": f"no lane {self.lane_id}"};
    }
}
