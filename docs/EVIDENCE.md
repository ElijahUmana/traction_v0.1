# TRACTION — Evidence

**Standard for this file: real artifacts only.** Every claim was produced by running the system on this machine. Nothing here is illustrative, representative, reconstructed or hand-written.

**All artifacts live in one place: [`evidence/`](../evidence/) at the repo root.** Every item below names the command that reproduces it.

**Where a raw number is flattering but not defensible, this file reports the validated number and shows the gap.** A judge who spot-checks one inflated figure stops believing the rest of the document.

§10 lists what is **not** proven, and §11 lists an **open defect that blocks the demo**.

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

Each was measured, and each silently breaks a live dashboard.

### 4.1 WebSocket routes are silently dropped without `[scale.websocket]`

`@restspec(protocol=APIProtocol.WEBSOCKET)` is ignored with **no error and no warning**; `jac check` passes; the walker is served as an ordinary HTTP endpoint. Proof it was not our code: **Jac's own fixture walkers** from `jac/jaclang/scale/tests/fixtures/test_api.jac` (`EchoMessage`, `BroadcastChat`), copied in verbatim, 404'd identically.

| | before | after `[scale.websocket]` + `jac install` |
|---|---|---|
| `GET /ws/walker/LiveFeed` | **404** | **101** Switching Protocols |
| `POST /walker/LiveFeed` | **200** (wrongly HTTP) | **405** (correct) |
| server log | *(silent)* | `Registered WebSocket walker endpoint: …` |

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

## 7. ⚠️ The guest-root corruption is PERSISTENT — and it conflicts with the pre-warm plan

**Status: ROOT-CAUSED. This is the most operationally dangerous thing in this document.**

Once the guest root is lost, every anonymous endpoint returns 500 forever:

```
Guest root anchor 449d29b5ca4944a7bfe6ace00d1959d2 is missing from the
anchor store; minting a fresh guest root.
  -> 'JacScaleUserManager' object has no attribute '_lock'   (HTTP 500)
```

**The corruption is written into `.jac/data/anchor_store.db` and SURVIVES A RESTART.** Measured back to back:

| Action | Result |
|---|---|
| `ops/restart.sh` (keeps `.jac/data`) | **500 500 500** — the same dead anchor id is re-read every request |
| `ops/restart.sh --clean` (wipes `.jac/data`) | **200 200 200 200 200** |

Restarting the process is **not** a fix. The only fix found is wiping the graph.

### Why this matters more than it looks

§6 of the master plan resolves the 4-minute-slot problem with **pre-warm**: the research run starts off-stage and the demo opens mid-flight. If the guest root corrupts during that pre-warm window, **the only known recovery destroys the pre-warmed run** — the thing the demo depends on.

Earlier measurements show it is not cold start (3/3 clean cold starts) and not ordinary load (15 rapid anonymous writes + 5 reads, all 200, zero remint events). It appeared reliably once many modules and multiple concurrent operators were in play.

**Mitigations, in order of preference:**
1. **Snapshot `.jac/data` immediately after a good pre-warm** (`cp -r .jac/data .jac/data.warm`). Recovery then becomes restore-and-restart instead of wipe-and-lose.
2. Run the demo server on a **dedicated port with a dedicated data dir**, so nobody else's `pkill -f "jac start"` or `--clean` can touch it. Multiple operators sharing one server and one data dir is what surfaced this.
3. Treat any 500 with `_lock` in it as "restore the snapshot", never as "restart and hope".

---

## 8. Test suite

**Status: GREEN — 20/20, with no API key set.**

```
$ ops/test.sh
1 worker [20 items]
....................                                    [100%]
20 passed
PASS - and it passed with no ANTHROPIC_API_KEY set.
```

`feed.test.jac` covers the two-hop `Founder → Runs → ResearchRun` read, lane ordering and `live_url` presence, convergence dedup to one row while recording both lanes, DROPPED prospects staying on the ledger, score sort order, run-state survivor/drop/converged counts, global time ordering of reasoning across lanes, and `feed_since` cursor semantics.

### The failure that was not a failure

Before the fix: **5 failures**, all `WriteConflict: anchor 00000000-… (root) changed concurrently`. Non-deterministic, and it presents exactly like a race in the walker code. It is not one.

`jac test` runs **pytest-xdist with ten workers** by default and injects `-n` unconditionally, so `-p no:xdist` is rejected and there is no CLI flag. Ten workers mutating the single root anchor is the whole story. Measured: **5 failures with default workers, 0 with one.** Found by GHIDENT; `PYTEST_XDIST_AUTO_NUM_WORKERS=1` is now baked into `ops/test.sh`.

The 2 failures that survived the worker fix were a real bug: `feed.jac` does not import `ReasoningKind`, so the `.test.jac` annex could not see it. An annex sees its base module's declarations, not the names its base chose not to import. Fixed by importing it in the annex.

---

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

- **The joined-up live E2E chain** — real lanes → real prospect → real email → real reply → real Vapi call → real Calendar booking — **has not been run end to end.** Segments have strong individual proofs (§1, §2, §3); the joined-up artifact does not exist. `PlanCampaign` was missing as of this writing and `RunResearch` raises without an ICP, so the Go button was routed but not runnable.
- **The mobile-hotspot tunnel test** (§6) has not been run, and the register calls the hotspot primary.
- **No fix exists for the persistent guest-root corruption** (§7) beyond wiping the graph. The snapshot mitigation is proposed, not yet exercised.
- **No browser client has rendered these endpoints.** The frontend contract is verified at the wire level only.
- **Lane D's ~40%** (§2) is my adversarial read of the artifact, not an independently re-run deliverability check. No address was SMTP-verified.

---

## 11. ⚠️ OPEN DEFECT — blocks the demo

**Lane W bound the wrong person's email to a prospect's identity and evidence.** Artifact: `evidence/lane_w_proof.txt`.

```
[0] target: https://www.linkedin.com/in/elijah-umana-4964b3206/
[plan]  Opening Xingzhi Zhu's profile directly...
[yield] Lane W complete. 7 pieces of evidence on Elijah Umana,
        reachable at xingzhizhu6@gmail.com.
```

One `Prospect` node carries **person A's** name, headline, company, LinkedIn URL and all 7 `Evidence` quotes, and **person B's** email address. The narration also claims it opened Xingzhi's profile while it demonstrably opened Elijah's.

**Why it blocks:** `ComposeOutreach` cites verbatim evidence from the graph. Fed this node it sends to `xingzhizhu6@gmail.com` an email quoting **Elijah Umana's** posts as "what you said" — a pitch that looks grounded and is not, delivered on stage. `feedseed.jac`'s own docstring names this as the failure the system exists to prevent.

**Root cause:** `TEAMMATE_LINKEDIN_URL` is unset, so Lane W fell back to a stand-in profile while `email` stayed hard-wired to the real target. Proving the mechanism against a stand-in was correct; letting the stand-in identity and the real target's address share one node was not.

**Required to clear:** the email must come from the same human the evidence came from (real URL, or a stand-in email for a stand-in profile); an invariant at the gate refusing to compose when a `PROVIDED` email does not match the identity the evidence was scraped from; and the artifact relabelled to what it actually proves — that Lane W can open a profile, extract 7 evidence pieces and narrate it, which it does well.

**Until then, no run carrying `xingzhizhu6@gmail.com` should be treated as demo-ready.**
