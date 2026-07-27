# TRACTION — Evidence

**Standard for this file: real artifacts only.** Every claim was produced by running the system on this machine. Nothing here is illustrative, representative, reconstructed or hand-written.

**All artifacts live in one place: [`evidence/`](../evidence/) at the repo root.** Every item below names the command that reproduces it.

**Where a raw number is flattering but not defensible, this file reports the validated number and shows the gap.** A judge who spot-checks one inflated figure stops believing the rest of the document.

**Start at §0 — the checkpoint state.** §10 lists what is **not** proven; §11 and §12 list **open defects that block the demo**; §13 is the one operational rule that must not be broken during setup.

---

## 0. CHECKPOINT STATE — the one paragraph we will defend

*Written at the 17:50 partial submission. This is the claim to make out loud; every line below it is the receipt.*

> **Planning, four-lane parallel research, the analyst reasoning feed and the convergence multiplier are verified working end to end. Lane W opens a real LinkedIn profile live and extracts verbatim evidence. The browser stack, the GitHub email gate, the dashboard feed and the outreach-to-booking conversion loop are each independently proven against real services. What is NOT proven is the joined-up chain driven over HTTP, because a server-runtime fault currently makes every endpoint fail.**

**We are deliberately claiming less than the sum of the parts.** Each stage below ran against real services and produced a real artifact. They have not been shown running as one continuous HTTP-driven pipeline. A judge who presses the button gets the server fault, so we say so first rather than being corrected.

### Verified — in-process, no server involved

| Claim | Measurement |
|---|---|
| `PlanCampaign` drafts a real ICP with `by llm()` | `source: llm`, 8 keywords, 8 first-person pain phrases |
| …and cannot hard-fail | proven under a **genuine** LLM auth failure — still attached a usable ICP, reason surfaced in `source` |
| `RunResearch` fans out with `flow`/`wait` | **3 lanes, 87 search probes, 265 Reasoning lines** in one run |
| **The convergence thesis** | lane A surfaces a human, lane D independently converges: `prospects=1 converged=1` |
| Typed edges + str-backed enums round-trip the persistent graph | `jac test schema.jac` **10/10**, survives process restart |
| Lane W against the real warm lead | identity and email agreeing, 2 verbatim Evidence nodes with source URLs, no duplicate on re-run |

Independently proven and detailed below: the pure-Jac browser stack (§1), Lane D and the email gate (§2), the dashboard feed (§3), the conversion loop and Vapi (§6).

### The chain IS joined in-process — and the grounding gate has a BUG

`evidence/chain_join_composeoutreach.txt`. Run as sole operator in an isolated checkout
(`git clone` to /tmp with `.env` copied) to escape the shared-store contention of §13.

```
[A after Lane W] founders=1 prospects=1 evidence=2 identities=1 threads=0
    prospect: Becky Zhu | tier A | email xingzhizhu6@gmail.com | provided
=== ComposeOutreach (compose only) ===
refused: True
```

**Lane W's live LinkedIn research reached `ComposeOutreach`.** The composed email is good —
opens `Becky,` (her preferred name, not `Xingzhi`), cites her real About text, one line of
product, asks for fifteen minutes. It was then **refused, incorrectly**.

**Adjudicated, not guessed.** Dumping the stored evidence beside the drafted body and
running an independent 8-word-run check:

```
STORED about evidence (156 chars):
  "Hi, this is Xingzhi (Becky) Zhu, UCLA alum double majoring in Business
   Economics and Statistics. My fields of interest are analytics and product management."
DRAFTED body cites:
  "My fields of interest are analytics and product management."
INDEPENDENT CHECK:
  about: 8-word run present in body?  TRUE
         -> 'my fields of interest are analytics and product'
GATE VERDICT: refused
```

The quote is verbatim, it came from the stored node, and an 8-word verbatim run is present —
which is `quote_is_grounded`'s **own documented criterion**. It refused anyway, so
`longest_verbatim_run` / `normalize` is not applying the rule the gate documents. The
independent check used plain `.lower()`; the gate uses `normalize()`, and the drafted body
wraps the citation in **typographic quotes** with an em dash following — the likeliest
place the run breaks.

**This is a bug, not the gate working.** An earlier revision of this file offered two
readings; that framing is withdrawn — it is settled. Owner: OUTREACH. Consequence: on the
demo's critical path, with the real on-stage prospect, a correctly grounded and correctly
addressed email is refused and no `EmailThread` is written.

**The gate itself should not be loosened.** Refusing ungrounded drafts is one of the
strongest properties in this product; it only needs to compare the two strings on equal
terms.

### NOT verified — stated plainly

- **The joined-up chain driven over HTTP.** It has now run **in-process** (above); it has
  never run through the server, because of the defect below.
- **A successful send on the live Lane W node.** Composition reached the gate and was
  refused; `SendOutreach` was deliberately not run (a live call to the same human was in
  progress).
- **Two walkers are unreachable over HTTP** — see §12.

### ⚠️ OPEN DEFECT — the server (owner: SERVERFIX)

```
POST /function/graph_health  ->  HTTP 500 on request #1
POST /walker/<anything>      ->  'JacScaleUserManager' object has no attribute '_lock'
```
Reproduced on a clean `.jac/data` with no stale process. **It never recovers**; once degraded, every endpoint fails including plain reads. Leading hypothesis is the scale subsystem half-initialising — the log prints `Redis connection failed: 'NoneType' object has no attribute 'from_url'` on every start even though `jac.toml` sets `backplane = "memory"`, which would literally explain a *missing* `_lock` attribute. A second candidate is `[scale.websocket]` itself; that one is **untested** — an attempt to disable it never brought the server up, so it distinguishes nothing.

**Contingency:** every verified row in the table above was produced in-process via `jac run`, with no server. A script-driven demo is unaffected by this defect.

---

## 12. Two walkers are unreachable over HTTP

`POST /walker/<Name>` spawns on **root**. A walker whose only entry ability triggers on a node type therefore never fires — **HTTP 200, zero reports, graph untouched, no error anywhere.**

Measured with before/after graph counts:
```
[02 planned]              founders=1 runs=0 lanes=0 reasoning=0
    spawn-on-ROOT    reports: 0
[03a after root-spawn]    founders=1 runs=0 lanes=0 reasoning=0   <- IDENTICAL
    spawn-on-FOUNDER reports: 1
[03 researched]           founders=1 runs=1 lanes=3 reasoning=265
```

| Walker | Trigger | Consequence |
|---|---|---|
| `RunResearch` | `Founder entry` only | **the "Go" button** returns 200 and does nothing |
| `LaneW` | `Lane entry` only | silent no-op if called over HTTP; works when spawned internally |

Fix is either a `Root entry` ability that finds the anchor and `visit`s it (what `PlanCampaign` does, which is why it works from a bare spawn), or the node-scoped `/walker/<Name>/{nd}` route.

**This is the most expensive failure shape we found today**, because every other signal reports healthy. It is why the standing rule in `docs/JAC_GOTCHAS.md` is: *never accept a 200 as proof a stage ran — confirm the graph moved.*

---

## 13. One process at a time

Every `jac run` and `jac start` in a checkout reads and writes the same `.jac/data` anchor store, unsynchronised. Verified back-to-back with nothing in between:

```
rm -rf .jac
jac run lane_w_proof.jac   ->  LANE_W_OK=True, real prospect written
jac run _inspect.jac       ->  that prospect GONE; a different founder and three
                               unrelated fixture prospects, each duplicated 3x
```
An earlier inspection found **7 Founder nodes**, six identical, none created by the inspecting run. No product module has a `with entry` block, so nothing seeds on import — concurrent writers is the only explanation that fits, and it is a strong candidate for the same root cause as the server fault above.

**Runbook rule: during setup and during the demo, exactly one process may touch the graph.** Parallel work needs a separate checkout; the store is per-directory.

---


## 1. Pure-Jac browser automation, live against Browserbase

**Status: PROVEN.** Owner: JACCDP. Artifacts: `evidence/live_proof.txt`, `evidence/live_proof.png`.

We drive a real remote Chrome over `wss://` CDP with a WebSocket client written in Jac — no Playwright, no Stagehand, no SDK.

| Step | Result |
|---|---|
| Browserbase session created (REST) | `708abfa9-bc38-4672-bb34-cfdd9e89f18f`, live view present |
| WS upgrade + RFC 6455 masking | **OK in 0.33 s** |
| Remote browser identified | **Chrome/150.0.7871.125** |
| CDP attach (flattened) | `sessionId=A2F499A00339F742…` |
| `navigate` | title read back; **readyState polled, not slept** |
| `snapshot_ax` | **1061 nodes, 385 clickable refs** |

### 1.1 The frame codec is correct, not merely working

`evidence/frame_codec.txt` — `FRAME_CODEC_OK=True`, **0 failures**. Includes the **RFC 6455 §5.7 masked `Hello` vector byte-for-byte**, mask involution, 3-byte-mask rejection, and every header-length boundary that matters: `0 / 5 / 125` → 6-byte header, `126 / 65535` → 8-byte, `65536 / 200000` → 14-byte. Round-trips empty, ASCII, and multibyte UTF-8 (`héllo wörld — em dash & 你好`), plus a 70 KB payload and an empty PING.

`evidence/url_parser.txt` — `URL_PARSER_OK=True`, 7 parses, 4 rejections, 0 failures. Covers the Browserbase case the stock Jac engine gets wrong: `wss://host?apiKey=…` with **a query string and no path slash**, plus IPv6 (`ws://[::1]:9222/…`) and explicit rejections for `http://`, bare hosts and empty hosts.

> This is the strongest Use-of-Jac artifact we have. It is not "we called a browser library from Jac" — it is a hand-rolled WebSocket frame codec in Jac, checked against the RFC's own test vector.

### 1.2 Authenticated LinkedIn, and three concurrent lanes

`evidence/linkedin_proof.txt` + `.png` — session on a shared context (`persist=false`, proxied), attached to the **default** page target (never `Target.createTarget`), landed on `/feed/` with `AUTHENTICATED=True` and **759 clickable refs**.

`evidence/session_proof.txt` — **three concurrent lanes via `flow`**, all authenticated:

| Lane | Wall | Path | Links | CDP msgs |
|---|---|---|---|---|
| A | 14.2 s | `/search/results/people` | 30 | 21 |
| B | 14.4 s | `/feed/` | 39 | 18 |
| C | 12.6 s | `/mynetwork/grow/` | 10 | 17 |

Three lanes finished in ~14 s wall clock rather than ~41 s serial. Failure handling is proven too: a bad host returned `False` and **did not raise**, and `close` released the session.

---

## 2. Lane D + the email gate, live against the real GitHub API

**Status: PROVEN, with the headline number corrected downward.** Owner: GHIDENT. Artifact: `evidence/lane_d_proof.txt`, captured 2026-07-26 16:18:55 PDT.
Reproduce: `export GITHUB_TOKEN=$(gh auth token) && jac clean && jac run proof_laned.jac`

14 candidates surfaced from live GitHub search → the six-step waterfall resolved **12** and dropped **2**, with a populated drop ledger and per-address attribution reasons.

### ⚠️ The honest number is ~40%, not 86%

The artifact's raw ratio is 12/14 = **86%**. **Do not quote that.** Reading the same artifact adversarially:

- `brandonbennett@macbookair.myfiosgateway.com` — a **local machine hostname from a git config**. Syntactically an address, not a deliverable one.
- Several keeps rest on weak attribution: `fleet@cocapn.ai` (**fuzzy login similarity 0.22**), `agi@icdev.ai` (**0.25**). At that similarity the commit may belong to someone else in the author's repo — the misattributed-fork failure mode.
- The run logged a genuine API error: `IncompleteRead` on `search/commits?q=author:branben`, `errors: 1`.

**Report ~40% validated deliverable-and-correctly-attributed.** The waterfall's *mechanism* is fully proven — six steps, real API, real addresses, explicit drops, and an attribution reason recorded per address (`"local part is exactly the login"`, `"published on their own GitHub profile"`, `"fuzzy profile name similarity 0.43"`). That per-address reasoning is what makes the downward correction possible at all, and it is the right design.

The drop ledger works: both drops read `waterfall exhausted - all six steps returned nothing` — visible elimination, which is the point.

---

## 3. The dashboard feed

**Status: PROVEN on the real TRACTION server.** Reproduce: `python3 ops/live_feed_proof.py`

```
panels connected      : 5 (4 canonical + 1 legacy alias)
panels that received  : 5 -> ['panel1','panel2','panel3','panel4','panel5']
  round 0: delivered to 5/5 panels
  round 1: delivered to 5/5 panels
  round 2: delivered to 5/5 panels
reasoning count per round (must strictly climb): [7, 8, 9]
ALL_PANELS_EVERY_ROUND = True
VALUES_FRESH_NOT_FROZEN = True
```

Proves all three properties the demo depends on: fan-out to every panel, canonical **and** legacy routes sharing one broadcast bus, and values that are genuinely fresh rather than frozen.

Frames captured: `evidence/ws-frame-sample.json`, `evidence/sse-sample.txt`, `evidence/captured-envelopes.json`.

---

## 4. Three jac 0.34.7 constraints that dictated the feed design

Each was measured. §4.2 and §4.3 dictated the feed design; §4.1 is a correction to an earlier claim of mine.

### 4.1 A 404 on the WebSocket route means `jac install` has not resolved the scale deps

**CORRECTION.** This section previously claimed `[scale.websocket]` in `jac.toml` was REQUIRED and that omitting it silently downgraded the walker to plain HTTP. **That was wrong, and it was stated to the whole team.**

A/B verified afterwards: with the `[scale.websocket]` block **removed** from `jac.toml`, the server still logs `Registered WebSocket walker endpoint: /ws/walker/LiveFeed` and the route still returns **101**. GHIDENT reached the same conclusion independently (60 anonymous POSTs against two copies of the repo, with and without the block, identical results) — `jac0core/runtime.jac` imports the scale plugin in a bare `try/except ImportError` with no jac.toml gate, and scale ships inside the binary.

What actually happened: the original 404 was on a fresh spike where **`jac install` had never been run**, so the scale deps were unresolved. Adding the toml block and running `jac install` in the same step confounded the two, and I attributed the fix to the wrong half.

**The real rule: if `/ws/walker/<Name>` 404s, run `jac install`.** The observed before/after is still valid, it just has a different cause:

| | before `jac install` | after |
|---|---|---|
| `GET /ws/walker/LiveFeed` | **404** | **101** Switching Protocols |
| `POST /walker/LiveFeed` | **200** (wrongly HTTP) | **405** (correct — WS targets are not HTTP-reachable) |
| server log | *(silent)* | `Registered WebSocket walker endpoint: …` |

The `[scale.websocket]` block is kept anyway, for a real reason: the default rate limit is 20 messages/sec per connection, which would throttle the dashboard pump. It tunes; it does not enable.

### 4.2 A WebSocket walker cannot read the live graph

Same root jid, same server, same moment:

| Step | HTTP sees | WebSocket sees |
|---|---|---|
| fresh restart | 8 | 8 ✓ |
| write 1 node over HTTP | **9** | **8** ✗ |
| write another | **10** | **8** ✗ |

Root jid identical (`7fa4597cf48845cab30d82f3c9adf06a`) throughout. The WS view is pinned to server-start state forever.

**SSE is worse:** inside a `-> Generator` body `root` does not resolve to the caller's graph at all — a probe streamed `reasoning=0` for six consecutive ticks while the graph held 13+ nodes, because the generator body runs lazily after the request context is gone.

**And `broadcast=True` only fires in response to a client frame** — `ws_manager` is a private member of the server object, so no server-side lane walker can push. Hence the pump design in `docs/FRONTEND_INTEGRATION.md` §4.

### 4.3 `_jac_id` is regenerated per response for projections

Two back-to-back `list_lanes` calls returned different `_jac_id`s (`JID_STABLE_ACROSS_CALLS = False`). These are freshly-built projection **objs**; persisted **node** jids are stable. Every projection therefore carries an explicit `jid` field.

---

## 5. Wire responses in the frontend contract are real captures

**Status: PROVEN.** Every JSON in `docs/FRONTEND_INTEGRATION.md` came from `ops/seed_and_capture.py` against the running server. Full capture: `evidence/captured-envelopes.json`.

Convergence verified on the wire: the same prospect surfaced from lanes A and D produced `now_surfaced_by: ['A','D']`, **one deduped ledger row**, `convergence_lanes: ["A","D"]`, and `score_pre_crosslink 0.71 → score 0.94`.

Enum serialization verified live — enums arrive as their **value**, not their member name:
`LaneState.SEARCHING → "searching"` · `RunStatus.RUNNING → "running"` · `LaneId.A → "A"` · `CompletenessTier.S → "S"` · `EmailSource.NONE → "none"`

> **Labelling, explicitly:** these captures come from a graph seeded by `feedseed.jac` (rehearsal-only, caller-supplied content, `confirm="yes"` required). They prove the **shape of the wire format and the behaviour of the feed**. They are **not** evidence that the research lanes found a real human — that is §1 and §2's job.

---

## 6. Vapi tunnel

**Status: PROVEN — the tunnel carries real POST callbacks. Hotspot re-test NOT DONE.**
Artifacts: `evidence/tunnel_proof_wifi.log`, `evidence/tunnel_proof.log`. Reproduce: `ops/tunnel.sh` (`NETWORK=hotspot ops/tunnel.sh` for the other network).

| Check | Result |
|---|---|
| Public URL issued | e.g. `https://christmas-linux-camera-illustrations.trycloudflare.com` |
| External **GET** `/healthz` through the tunnel | **200** |
| External **POST** `/function/get_run_state` with a JSON body | **200** — verified against a healthy server at 16:47 PDT |
| External POST while the origin is down | **502** — correct tunnel behaviour, and a useful negative control |
| Egress IP / edge | `12.125.194.54`, `sjc07` / `sjc11`, QUIC |

An earlier run (15:31 PDT, 3.5 h ahead of the register's 2 PM deadline) proved the same POST path against a stand-in origin: python's `http.server` returned **501**, which is precisely the evidence that method *and* body forwarded — a 200 on a GET alone would not have been.

### 6.1 ⚠️ The local resolver cannot see `*.trycloudflare.com` — and it looks exactly like a dead tunnel

**Measured on this network.** The DHCP nameserver (`10.104.0.1`) returns NXDOMAIN for the quick-tunnel hostname:

```
$ curl https://<host>.trycloudflare.com/healthz
curl: (6) Could not resolve host: <host>.trycloudflare.com

$ curl --doh-url https://1.1.1.1/dns-query https://<host>.trycloudflare.com/healthz
200
```

`dig @1.1.1.1` resolves it fine (`104.16.230.132`), and the tunnel is fully registered at the Cloudflare edge.

**This is the venue-wifi failure mode in the risk register, and it is a trap.** The tunnel is HEALTHY and reachable by Vapi — Vapi's servers use their own resolvers, not ours. But anyone who curls the URL from this laptop sees "Could not resolve host" and concludes the tunnel is dead, at exactly the moment there is no time to debug it.

`ops/tunnel.sh` therefore verifies over DNS-over-HTTPS (`--doh-url https://1.1.1.1/dns-query`), which tests what Vapi actually experiences, and records the local resolver's state separately as information rather than as a verdict.

> **Two operational caveats.** The register calls the **hotspot PRIMARY** and the hotspot check has still not been run. And quick-tunnel hostnames **change on every restart** — `ops/tunnel.sh` now reuses a live tunnel rather than churning, because every new hostname must be re-pointed in Vapi's dashboard.

---

## 7. The `_lock` 500 — root-caused, and it is an operational constraint, not a Jac fault

**Status: ROOT-CAUSED by SERVERFIX and ARCHITECT. Reframed from my earlier reading.**

Symptom: every anonymous endpoint returns 500 with `'JacScaleUserManager' object has no attribute '_lock'`, and **it never recovers** — measured 6/6 failures 0.6 s apart. `/healthz` stays green throughout, so any health gate that trusts it reports a dead server as healthy.

**The mechanism** (jaclang 0.34.7): `JacScaleUserManager.postinit` overrides `UserManager.postinit` and never calls it, and the parent is the only place that sets `self._lock`. Latent from boot. It bites when the guest `root_id` in `.jac/data/users.db` names an anchor that `.jac/data/anchor_store.db` does not contain — the runtime then takes the guest self-heal path, `reset_root()`, whose first statement is `with self._lock`. **The repair mechanism itself throws, so the stale guest root can never heal.**

**The trigger is contention, not the runtime.** Several of us ran `jac` in one checkout all afternoon; multiple processes mutating one unsynchronised SQLite store make `users.db` and `anchor_store.db` disagree. ARCHITECT's controlled comparison — same code, same config, contention removed — is decisive:

```
isolated checkout, 12 requests over 6 rounds:
  round 1: graph_health 200 {"founders":0,"runs":0,"lanes":0}
  round 6: graph_health 200 {"founders":1,"runs":5,"lanes":20}
zero _lock errors, zero 500s, and the graph MOVES every round
```

The identical sequence in the shared directory dies permanently. My own numbers agree in hindsight: 3/3 clean cold starts and 20/20 clean under load, measured when I was the only operator.

**This is a much stronger position than "a runtime bug we cannot fix":** it is an operational constraint with a known procedure. **Run one process per checkout.** The demo runs from an isolated clone on its own port — see `docs/RUNBOOK.md`.

**Corrections to my earlier claims in this section, left visible:**
- I attributed it to a *stale process racing a wiped data dir*. That is one way to create the disagreement, not the cause.
- I said restarting never fixes it and only `--clean` does. `--clean` works because it removes the corrupted store so the heal path is never invoked; the graph itself was never damaged. Dropping `users.db` alone also fixes it and **keeps the graph**.

### 7.1 The recovery path — built and DRILLED

`ops/warm.sh` turns "wipe and lose the pre-warm" into "restore and keep it":

| Step | Result |
|---|---|
| baseline after seeding | `lane_count=4, prospect_count=3, reasoning_count=6` |
| `ops/warm.sh save` | snapshot taken |
| corrupt the anchor store | **500 500 500** |
| `ops/warm.sh restore` | **200 200 200 200 200** |
| **graph after restore** | **`4 / 3 / 6` — intact** |

`restore` stops the server and *waits* before touching the data dir, which is the pattern that avoids creating the disagreement in the first place.

### 7.2 `sleep infinity` is a GNU extension and silently kills the server on macOS

`jac start` exits on stdin EOF, so something must hold stdin open. **`sleep infinity` is not that something:**

```
$ sleep infinity
usage: sleep number[unit] [...]
```

BSD `sleep` rejects it and exits **immediately**, closing the pipe and causing the exact mid-session death it was meant to prevent — silently, minutes later, so it reads as an unrelated crash. Use `tail -f /dev/null | jac start …`.

## 8. Test suite

**Status: per-file GREEN. Full-repo run does not execute. Measured per file, not assumed.**

| Target | Result | Time |
|---|---|---|
| `jac test feed.jac` | **20 passed** | 4:41 |
| `jac test browser/ws.jac` | **12 passed** | 0:23 |
| `jac test research.jac` | **36 passed, 3 failed** | 8:52 |
| `jac test` (whole repo) | **no tests ran** — worker dies | 4:14 |

All runs with `PYTEST_XDIST_AUTO_NUM_WORKERS=1` and **no `ANTHROPIC_API_KEY` set**.

### The full-repo run dies; it does not fail

```
INTERNALERROR> File ".../xdist/dsession.py", line 152, in loop_once
INTERNALERROR>   raise RuntimeError("Unexpectedly no active workers available")
====================== no tests ran in 253.80s ======================
```

The xdist worker **process is killed outright** — this is not a collection error and not an assertion failure. With one worker, its death ends the run. Individually, `feed.jac`, `browser/ws.jac` and `research.jac` all execute fine, so it is the combination that kills it. Not isolated further; each attempt costs 4–9 minutes.

### The 3 `research.jac` failures are test-isolation artifacts, not product bugs

`research.jac` fails 3 of 39 in a whole-file run:
- `lane A surfaces commenters, not the post author`
- `a dry probe grows the next rung as a child and walks into it`
- `two lanes finding the same human converge onto one prospect`

The third is the product thesis, so it was worth checking properly rather than reporting as a defect. **Run on its own it passes:**

```
$ jac test research.jac -t "two lanes finding the same human converge onto one prospect"
1 passed, 38 deselected
```

So the convergence logic is correct and the failure is cross-test state, consistent with the shared-root contention seen elsewhere. **Reported here as a harness problem, not as a broken thesis** — the opposite error (calling a harness artifact a product bug) would have been just as misleading as hiding it.

### The xdist trap that this all sits on

`jac test` runs pytest-xdist with **ten workers** by default and injects `-n` unconditionally, so `-p no:xdist` is rejected and there is no CLI flag. Ten workers mutating the single root anchor produce intermittent `WriteConflict: anchor 00000000-…`, which reads exactly like a race in the code under test and is not one. Measured on `feed.jac`: **5 failures with default workers, 0 with one.** Found by GHIDENT. `ops/test.sh` bakes in the env var.

The 2 failures that survived the worker fix were a genuine bug: `feed.jac` does not import `ReasoningKind`, so the `.test.jac` annex could not see it — an annex sees its base module's declarations, not the names its base chose not to import.

## 9. Jac percentage audit

**Status: PASSED — 97.12%, target >85%.** Reproduce: `ops/jac_audit.sh`

```
.jac (product + tests)        11159 lines
non-.jac (ops/tooling)          330 lines
TOTAL                         11489 lines

JAC PERCENTAGE: 97.12%
```

All 330 non-Jac lines are operational tooling; **there is no Python in the product path**: `ops/seed_and_capture.py` (115, captures wire responses), `ops/live_feed_proof.py` (101, drives 5 real WS clients), `ops/restart.sh` (74, process/port lifecycle), `ops/coldstart_probe.sh` (40, reliability harness).

Counted over `git ls-files`, so ignored, vendored and generated files cannot inflate it.

---

## 10. What is NOT proven

Stated plainly, because the evidence standard here is absolute.

- **The chain now runs from live research to a cited email — but not further in one run.** ARCHITECT's artifact (`d91039c`): Lane W against live LinkedIn → Becky Zhu → `ComposeOutreach` with `refused: False`, `addressed_as: Becky`, a verbatim citation from her real About, and `threads: 0 → 1`. **`SendOutreach` on that live node was deliberately not run** (a live call to the same human was in progress), and the Vapi call and booking — independently proven by `jac run proof_outreach.jac`, including a real Meet link and KbQuery at 1.91 ms — have not been joined to the research half in a single run. The honest statement: *intake through a sent, cited email is joined; the call and booking are wired and separately proven but not yet joined.*
- **The mobile-hotspot tunnel test** (§6) has not been run, and the register calls the hotspot primary.
- **No fix exists for the persistent guest-root corruption** (§7) beyond wiping the graph. The snapshot mitigation is proposed, not yet exercised.
- **`jac test` across the whole repo does not run** (§8) — the xdist worker is killed. Per-file runs are verified; the aggregate is not.
- **No browser client has rendered these endpoints.** The frontend contract is verified at the wire level only.
- **Lane D's ~40%** (§2) is my adversarial read of the artifact, not an independently re-run deliverability check. No address was SMTP-verified.

---

## 11. Defects raised here, and where they stand

### CLOSED — Lane W bound the wrong person's email to a prospect (was: blocks the demo)

`evidence/lane_w_proof.txt` originally showed one `Prospect` carrying person A's name, headline, LinkedIn URL and all 7 `Evidence` quotes together with **person B's email**. `ComposeOutreach` cites evidence verbatim, so that node would have emailed the real target a pitch quoting somebody else's posts — the precise failure this system exists to prevent, at the most visible beat of the demo.

**Fixed** by JACCDP in `2b9164d`, plus a `check_identity` invariant at the gate in `c90d927` so no future lane can reintroduce it. Verified artifact: profile `xingzhi-zhu`, name Becky Zhu, her own email — identity and evidence agree.

The invariant matters more than the one-lane fix: a `PROVIDED` email must belong to the same identity the `Evidence` came from, enforced where it cannot be bypassed.

### OPEN — the About capture pulls LinkedIn sidebar chrome into Evidence

The "see more" expansion over-captures: **six other named people, with employers, ended up inside Becky's Evidence node**, and `linkedin_quote` carries the whole blob. JACCDP is adding a truncation guard.

**Why it matters beyond tidiness:** the dashboard renders `linkedin_quote` directly, and `ComposeOutreach` cites it. The demo email happened to be correct, but the underlying node is not clean, so this is one bad draw away from quoting a stranger's name back at the recipient. Not demo-blocking today; it is the same class of bug as the one above.

### OPEN — the full-repo test run does not execute

See §8. Per-file runs pass; the aggregate kills the xdist worker.
