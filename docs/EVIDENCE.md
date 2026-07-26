# TRACTION — Evidence

**Standard for this file: real artifacts only.** Every claim below was produced by running the system on this machine. Nothing here is illustrative, representative, reconstructed, or hand-written. Where something is *unproven*, it says so.

Every item names the command that reproduces it.

---

## 1. Vapi tunnel — the #1 infra risk in the plan

**Status: PROVEN on venue-class wifi. Hotspot re-test PENDING.**

`cloudflared` quick tunnel, run 2026-07-26 15:31 PDT (3.5h ahead of the 2 PM deadline in the risk register):

| Check | Result |
|---|---|
| Public URL issued | `https://valves-signs-north-southern.trycloudflare.com` |
| External **GET** through the tunnel | **200**, 0.459 s |
| External **POST** to a Vapi-shaped path with a JSON body | **reached the local server** — the 501 came from python's `http.server` refusing POST, i.e. the tunnel forwarded method *and* body correctly |
| Egress IP | `12.125.194.54` |
| Cloudflare edge | `sjc01`, QUIC, connIndex 0 |

Raw log: `/tmp/traction-cfd-test.log`.

Reproduce:
```bash
cloudflared tunnel --url http://127.0.0.1:8000 --no-autoupdate
curl -X POST https://<issued-host>/walker/KbQuery -H 'Content-Type: application/json' -d '{}'
```

> **Not yet proven and it matters:** the risk register calls the **mobile hotspot PRIMARY**, and this test ran on the current network. The identical check must be repeated on the hotspot before the demo. Quick-tunnel hostnames also change on every restart, so the Vapi tool URLs must be re-pointed after any tunnel restart.

---

## 2. WebSocket routes are silently dropped without `[scale.websocket]`

**Status: PROVEN, root-caused, fixed in `jac.toml`.**

Symptom: `@restspec(protocol=APIProtocol.WEBSOCKET)` is ignored with **no error and no warning**. `jac check` passes. The walker is served as an ordinary HTTP endpoint and `ws://…/ws/walker/<Name>` returns 404.

Proof it was not our code: Jac's own fixture walkers from `jac/jaclang/scale/tests/fixtures/test_api.jac` (`EchoMessage`, `BroadcastChat`) were copied in **verbatim** and 404'd identically.

| | before fix | after `[scale.websocket]` + `jac install` |
|---|---|---|
| `GET /ws/walker/LiveFeed` | **404** | **101** Switching Protocols |
| `POST /walker/LiveFeed` | **200** (wrongly served over HTTP) | **405** (correct — WS targets are not HTTP-reachable) |
| server log | *(silent)* | `Registered WebSocket walker endpoint: /ws/walker/LiveFeed (+ legacy /ws/LiveFeed)` |

`ops/restart.sh` now fails loudly if the registration line is absent.

---

## 3. A WebSocket walker cannot read the live graph

**Status: PROVEN. This is why `LiveFeed` never touches the graph.**

Same root jid, same server, same moment — a diagnostic walker/function pair reporting `jid(root)` and `len([root --> [?:Reasoning]])`:

| Step | HTTP sees | WebSocket sees |
|---|---|---|
| after a fresh restart | 8 | 8 ✓ |
| write 1 node over HTTP | **9** | **8** ✗ |
| write another | **10** | **8** ✗ |

Root jid was identical (`7fa4597cf48845cab30d82f3c9adf06a`) throughout. The WS view is pinned to server-start state and never refreshes.

**SSE is worse:** inside a `-> Generator` body, `root` does not resolve to the caller's graph at all — a probe streamed `reasoning=0` for six consecutive ticks while the graph held 13+ nodes, because the generator body runs lazily after the request context is gone. `feed_backlog()` therefore snapshots the graph in the *enclosing* def body and streams the closed-over snapshot.

**Also:** `broadcast=True` only fires in response to a *client* frame. The connection manager (`ws_manager`) is a private member of the server object, so no server-side lane walker can push into it.

---

## 4. The dashboard feed works end to end

**Status: PROVEN on the real TRACTION server.**

```
$ python3 ops/live_feed_proof.py
panels connected      : 5 (4 canonical + 1 legacy alias)
panels that received  : 5 -> ['panel1','panel2','panel3','panel4','panel5']
  round 0: delivered to 5/5 panels
  round 1: delivered to 5/5 panels
  round 2: delivered to 5/5 panels
reasoning count per round (must strictly climb): [7, 8, 9]
ALL_PANELS_EVERY_ROUND = True
VALUES_FRESH_NOT_FROZEN = True
```

This proves all three properties the demo depends on: fan-out to every panel, canonical and legacy routes sharing one broadcast bus, and values that are genuinely fresh rather than frozen.

Captured frames: `/tmp/traction-evidence/ws-frame-sample.json`, `/tmp/traction-evidence/sse-sample.txt`.

SSE wire format, captured verbatim from `POST /function/feed_backlog`:
```
data: {"kind": "lanes", "lanes": [{"lane_id": "A", "state": "searching", "live_url": "...", "doctrine": "..."}]}

data: {"kind": "reasoning", "seq": 0, "t": 1785107480.807, "lane_id": "A", "sentence": "...", "kind_of": "observe"}
```

---

## 5. Wire responses in the frontend contract are real captures

**Status: PROVEN.** Every JSON in `docs/FRONTEND_INTEGRATION.md` came from `ops/seed_and_capture.py` hitting the running server. Full capture: `/tmp/traction-evidence/captured-envelopes.json`.

Two findings that came out of it:

- **`_jac_id` is regenerated on every response** for these payloads. Two back-to-back `list_lanes` calls returned different `_jac_id`s (`JID_STABLE_ACROSS_CALLS = False`). These are freshly-built projection **objs**, not persisted nodes — persisted node jids *are* stable. Every projection therefore carries an explicit `jid` field, and the contract tells the frontend to key off that.
- **Convergence works**: seeding the same prospect from lanes A and D produced `now_surfaced_by: ['A','D']`, one deduped ledger row, and `convergence_lanes: ["A","D"]` with `score_pre_crosslink: 0.71 → score: 0.94`.

> **Labelling, explicitly:** these captures come from a graph seeded by `feedseed.jac` (rehearsal-only, caller-supplied content, `confirm="yes"` required). They prove the **shape of the wire format and the behaviour of the feed**. They are **not** evidence that the research lanes found a real human. That evidence belongs to the lanes' own proof runs.

---

## 6. The bug that bricks the server

**Status: ROOT-CAUSED, mitigated by `ops/restart.sh`.**

If a stale `jac start` survives while `.jac/data` is wiped underneath it, the server logs:
```
Guest root anchor <id> is missing from the anchor store; minting a fresh guest root.
```
and then **every endpoint returns 500** with:
```
'JacScaleUserManager' object has no attribute '_lock'
```
It does **not** recover on its own. Hit twice during development.

Measurements that isolated it:

| Probe | Result |
|---|---|
| 3 clean cold starts (`ops/coldstart_probe.sh 3`) | `clean=3 recovered=0 terminal=0` — cold start is **not** the trigger |
| 15 rapid anonymous **writes** + 5 reads on a clean server | all **200**, `Guest root anchor` events: **0** — normal load is **not** the trigger |
| stale process + wiped data dir | reproduces the 500 |

Mitigation: `ops/restart.sh` kills completely, **waits for the port to be free**, only then wipes, then warms the first anonymous request, then verifies WS registration. Use it instead of `jac start`.

---

## 7. Jac percentage audit

**Status: PASSED — 97.12%, target was >85%.**

```
$ ops/jac_audit.sh
.jac (product + tests)        11159 lines
non-.jac (ops/tooling)          330 lines
TOTAL                         11489 lines

JAC PERCENTAGE: 97.12%   (target: >85%)
```

All 330 non-Jac lines are operational tooling; **there is no Python in the product path**:

| lines | file | why it is not Jac |
|---|---|---|
| 115 | `ops/seed_and_capture.py` | captures wire responses for the contract doc |
| 101 | `ops/live_feed_proof.py` | drives 5 real WebSocket clients to prove fan-out |
| 74 | `ops/restart.sh` | process/port lifecycle — shell's job |
| 40 | `ops/coldstart_probe.sh` | reliability measurement harness |

Counted over `git ls-files` so vendored, generated and ignored files cannot inflate it. Re-runnable by a judge.

---

## 8. Test suite

**Status: PARTIAL — honest state.**

`feed.test.jac` adds 10 tests covering the two-hop `Founder → Runs → ResearchRun` read, lane ordering and `live_url` presence, convergence dedup, DROPPED prospects staying on the ledger, ledger sort order, run-state counts, global time ordering of reasoning, and `feed_since` cursor semantics. They need **no API keys** — nothing in this module calls an LLM.

Last full run: **15 passed, 5 failed.** The 5 failures are all the same cause and are **not** assertion failures:

```
WriteConflict: anchor 00000000-0000-0000-0000-000000000000 changed concurrently
(expected v0, found v4)
```

Anchor `00000000-…` is **root**. `jac test` runs every test file in one session against one shared persisted root, so test files that each write to root contend on its version. Reducing my own root writes to one (create the Founder once, hang all runs off it) cut the failures from 5 to 5 but did not eliminate them, because other test files still write root in the same session.

**This is a real, unresolved issue and it is not fixed.** It is a test-harness isolation problem rather than a defect in `feed.jac` — the same projections are exercised successfully end-to-end over HTTP in §4 and §5. The correct fix is per-file graph isolation (`JacTestClient` with `base_path=tmp_path`, or running each file in its own process). Not attempted before the deadline.

---

## 9. What is NOT proven

Stated plainly, because the evidence standard for this project is absolute:

- **The full live E2E chain** — real Browserbase lanes → real prospects → real email to the demo target → real reply → real Vapi call → real Google Calendar booking with a Meet link — **has not been run by me end to end.** Individual stages have their own proofs owned by other teammates; the joined-up run does not yet have an artifact.
- **The mobile-hotspot tunnel test** (§1) has not been run.
- **The 5 failing tests** (§8) are unresolved.
- The dashboard has not been rendered against these endpoints by a browser client; the contract is verified at the wire level only.
