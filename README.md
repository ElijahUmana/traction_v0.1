# TRACTION

**A founder describes what they're building. Four agents fan out across LinkedIn and GitHub in parallel, converge on the same three humans from opposite directions, prove each one is reachable, write them a personal email citing what they actually said, call them when they reply, answer their objections from a knowledge graph, and book the interview mid-call — and every layer of it, down to the WebSocket frames, is Jac.**

JacHacks SF 2026 · Founders, Inc. Fort Mason

---

## Who this is for

Not "founders" as a market. **One founder, this week**, who needs three beta testers and is cold-DMing strangers at a 1% reply rate. TRACTION finds the three people who already said, in public, that they have the problem — and gets one of them on a call.

The demo names that person, emails that person, calls that person, and books that person. Live.

---

## WHERE JAC RUNS

> The rubric asks us to point at it in the repo. Here is the map.
>
> **Product code is 100% Jac — 16,030 lines of `.jac` and not one line of anything else in the product path.** Including operational tooling (`ops/`: test harnesses, proof scripts, run plumbing — none of which ships) the repo is 82.9% Jac. Verify either number yourself with `ops/jac_audit.sh`; it prints both.

| Layer | Where Jac does the work | File |
|---|---|---|
| **Transport — the WebSocket/CDP client itself** | Hand-rolled RFC 6455 framing and masking over raw TLS sockets. We drive Browserbase's remote stealth browsers over `wss://` CDP from Jac. **No Playwright, no Stagehand, no SDK.** | `browser/ws.jac`, `browser/ws.impl.jac`, `browser/cdp.jac`, `browser/cdp.impl.jac` |
| **Browser automation** | Session lifecycle, page semantics (`navigate`, `type_human`, `click_ref`, `snapshot_ax`), Browserbase contexts | `browser/session.jac`, `browser/page.jac`, `browser/browserbase.jac` |
| **Data model** | The prospect graph **is** the data model: 14 node archetypes, 13 typed edges carrying `confidence` / `lane` / `tier` | `schema.jac` |
| **Shared vocabulary** | Enums + LLM-visible `obj`s + `sem` prompt wiring | `contracts.jac` |
| **Pipeline** | Walkers that genuinely traverse — none is RPC in walker costume | `research.jac`, `identity.jac`, `githublane.jac`, `lanes.jac`, `lane_w.jac` |
| **Parallelism** | `flow` / `wait` — the 4 concurrent research lanes, measured at a real 4× speedup | `research.jac` |
| **Intelligence** | `by llm()` + `sem` + ReAct tools: planning, scoring, cross-link adjudication, email composition, reply parsing | `research.jac`, `outreach.jac`, `voice.jac` |
| **Identity resolution** | Asymmetric cross-linking + the 6-step email waterfall (hard gate) | `identity.jac`, `emailgate.jac`, `gh.jac` |
| **Integration surface** | Five external services POST **straight into walkers** — Browserbase, AgentMail, Vapi, Google Calendar, GitHub. **Zero routing glue.** | `outreach.jac`, `voice.jac`, `gcal.jac` |
| **Realtime** | `@restspec(protocol=APIProtocol.WEBSOCKET, broadcast=True)` on an `async walker` → 5-panel dashboard fan-out; `def:pub -> Generator` + `report stream()` → SSE | `feed.jac` |
| **Persistence** | Graph survives restarts under `root` — the call agent reads what the browsers wrote hours earlier | `schema.jac` + the runtime |
| **Tests** | `test "..." { }` blocks, no API keys required | `*.test.jac` |

**The one-line answer when a judge asks "show me where Jac runs":** *we wrote the WebSocket frame masking.* Most teams `pip install` an SDK and wrap it in Jac — the rubric scores that 1/5 "peripheral". The transport layer here is Jac.

---

## Why a graph, and not tables

The closing shot of the demo is *"this human was found independently from two directions."*

That is a **convergence query on a graph** — the same human reachable from two different `Lane` nodes — and the score multiplier falls straight out of it. In Postgres that's a join and a `GROUP BY`. Here it is one traversal, and `Prospect.is_converged()` is the product thesis expressed as a graph read. The data structure and the thesis are the same object.

---

## Run it

Requires the **Jac 0.34.7 binary** (the pip `jaclang` package is 18 minor versions stale).

```bash
jac install          # resolve deps, including the scale subsystem
jac check .          # typecheck
ops/restart.sh       # serve on :8000  (use this, not `jac start` — see below)
```

Then, to develop against a populated graph without waiting for a live research run:

```bash
python3 ops/seed_and_capture.py
```

Tests (no API keys needed — 20/20 green):
```bash
ops/test.sh
```

Jac percentage audit:
```bash
ops/jac_audit.sh
```

### Two things that will cost you an hour if you don't know them

1. **Run `jac install` before serving.** Until the scale deps are resolved, `@restspec(protocol=APIProtocol.WEBSOCKET)` is **silently ignored** — no error, `jac check` still passes, the walker is served as a plain HTTP endpoint, and `ws://…/ws/walker/LiveFeed` 404s. (`[scale.websocket]` in `jac.toml` is not required for this; it only tunes rate limits.)
2. **Use `ops/restart.sh`.** Wiping `.jac/data` while a stale `jac start` is alive bricks the server: every endpoint 500s with `'JacScaleUserManager' object has no attribute '_lock'` and it does not recover. The script kills completely, waits for the port, then wipes, then warms up, then verifies WS registration.

More in `docs/JAC_GOTCHAS.md`.

---

## Documentation

| Doc | What it is |
|---|---|
| [`docs/FRONTEND_INTEGRATION.md`](docs/FRONTEND_INTEGRATION.md) | The complete frontend contract. Every endpoint, the exact envelopes, the WebSocket frame shape, the SSE format, the Browserbase iframe pattern. All JSON captured from the running server. **You can build the dashboard from this alone.** |
| [`docs/EVIDENCE.md`](docs/EVIDENCE.md) | Real artifacts for every claim, each with its reproducing command — and an explicit section listing what is **not** proven. |
| [`docs/RUNBOOK.md`](docs/RUNBOOK.md) | **Demo day.** The five commands, every failure mode we actually hit and its fix, and the pre-demo checklist. |
| [`docs/JAC_GOTCHAS.md`](docs/JAC_GOTCHAS.md) | Toolchain traps found the hard way. |

---

## Architecture

```
root
 └── Founder ──:Targets:──▶ ICP
      ├──:HasWarmLead:──▶ Prospect
      └──:Runs:──▶ ResearchRun
           └──:HasLane:──▶ Lane {A,B,C,D,W}    # A/B/C LinkedIn (visible browsers), D GitHub (programmatic), W warm lead
                ├──:Emitted:──▶ Reasoning       # the analyst-voice sidebar
                └──:Surfaced:──▶ Prospect       # 2+ lanes surfacing one human == convergence
                     ├──:HasEvidence:──▶ Evidence   {lane, confidence on the edge}
                     ├──:Identity:──▶ Github/LinkedinProfile  {tier, basis on the edge}
                     ├──:Outreach:──▶ EmailThread ──:GotReply:──▶ ReplyEvent
                     ├──:Called:──▶ CallSession ──:Learned:──▶ Insight
                     └──:Booked:──▶ Booking
```

**The lanes are three different researchers, not three views of one query.** Lane A mines comments under *mid-tier practitioner* posts (not the megathreads under famous accounts — those are ~90% "Great post!" noise). Lane B reads post authorship for first-person problem statements. Lane C sweeps synonyms to defeat vocabulary lock-in. Lane D goes GitHub-first and stays programmatic.

Cross-linking is deliberately **asymmetric**: LinkedIn→GitHub is heavy (the same visible browser navigates across, on three panels at once — the product thesis rendered as a screen transition), GitHub→LinkedIn is light.

The email gate is a **hard gate**. No email, no pitch — and the drops stay visible on the ledger, because visible elimination is what makes the surviving three look earned rather than cherry-picked.

---

## Status

See [`docs/EVIDENCE.md`](docs/EVIDENCE.md) §10 for the honest list of what is proven and what is not, and §11 for an open defect that blocks the demo.
