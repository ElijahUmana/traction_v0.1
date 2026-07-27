# TRACTION — Frontend Integration Contract

**In a hurry? Read [`FRONTEND_QUICKSTART.md`](FRONTEND_QUICKSTART.md) instead — it is the 10-minute version with the copy-pasteable polling loop, the enum table, and the five traps.** This page is the exhaustive reference.

**You can build the entire dashboard from this document. You do not need to read our Jac source.**

Every JSON payload below was **captured from the running server**, not hand-written. Regenerate them any time with `python3 ops/seed_and_capture.py`.

- Base URL (local): `http://127.0.0.1:8000`
- WebSocket: `ws://127.0.0.1:8000`
- No auth. Every endpoint here is `:pub` (anonymous). Do not send an `Authorization` header.
- CORS: single-process `jac start` hardwires `allow_origins=['*']`. There is no knob. Browser calls work from any origin.

---

## 0. Thirty-second version

| You want | Call |
|---|---|
| The lane panels + their iframe URLs (**five** — A,B,C,D,W — not four; §2.1) | `POST /function/list_lanes` |
| The prospect ledger (incl. drops) | `POST /function/list_prospects` |
| Run header / counts | `POST /function/get_run_state` |
| **Everything at once (poll this)** | `POST /function/feed_since` with `{"since": 0}` |
| Start a run | `POST /walker/PlanCampaign`, `POST /walker/RunResearch` (§8) |
| Live fan-out to all panels | `ws://…/ws/walker/LiveFeed` |
| SSE fallback | `POST /function/feed_backlog` |

**If you only implement one thing: poll `POST /function/feed_since` every 750 ms.** It returns lanes + prospects + run state + reasoning in one payload and is always fresh. The WebSocket is an optimisation on top, not a prerequisite.

---

## 1. The HTTP response envelope

Every HTTP response is wrapped. **This is not the same shape as the WebSocket frame** — see §4.

```json
{
  "ok": true,
  "type": "response",
  "data": { "result": "<the return value>", "reports": [] },
  "error": null,
  "meta": { "extra": { "http_status": 200 } }
}
```

- **Read `data.result`** for every endpoint in §2–§3 (they are functions).
- `data.reports` is `[]` for functions. It is only populated for **walkers** — see §8, where the payload is at `data.reports[0]` instead.
- On failure `ok` flips to `false` and `error` is `{ "code", "message", "details" }`, e.g. `{"code": "EXECUTION_ERROR", ...}`.

All endpoints are **`POST`**, always `Content-Type: application/json`, always with a JSON object body. A `GET` on the same path returns **404**, not the data and not a signature.

> ### `since` is now safe to omit — but pass it anyway
>
> `feed_since` and `feed_backlog` used to **500** on `{}` and on `{"since": null}`: the declared `since: int = 0` was not applied when the field was absent, and the first `>=` blew up with `'>=' not supported between instances of 'int' and 'str'`. That mattered because the helper below defaults `args` to `{}`, so `call("feed_since")` — the most natural call there is — was a 500, as was `{ since: undefined }` (JSON.stringify drops undefined keys).
>
> **Fixed.** Both endpoints now coerce whatever arrives into a cursor, defaulting to `0`. Verified: `{}`, `null`, `"abc"`, `[1,2]`, `{"a":1}`, `-5`, `true`, `1e18` and a 20-digit string all return **200**.
>
> Still pass an explicit integer and initialise your cursor to `0` — it is the honest expression of intent, and it is what the polling loop in §3 does.

```js
async function call(fn, args = {}) {
  const r = await fetch(`${BASE}/function/${fn}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  const env = await r.json();
  if (!env.ok) throw new Error(env.error?.message ?? "call failed");
  return env.data.result;
}
```

### 1.1 `_jac_type` / `_jac_id` / `_jac_archetype` — ignore them, and never key off `_jac_id`

Objects on the wire carry three bookkeeping keys. Ignore all three.

**`_jac_id` is regenerated on every single response** for these payloads, because they are freshly-built projection objects. Measured: two back-to-back `list_lanes` calls returned different `_jac_id`s for the same lanes.

> **Every object we return carries an explicit `jid` field. That is the stable identity. Use `jid` as your React key, your map key, and your diff key. Never `_jac_id`.**

### 1.2 Enums are bare strings — and it is the **value**, not the member name

Enums are `str`-backed and serialize as plain strings. There is no `{"value": ...}` wrapper.

**The string you receive is the enum's VALUE, which is not always the member name.** `LaneState.SEARCHING` arrives as `"searching"`, lowercase. A `switch` on `"SEARCHING"` silently never matches — no error, just a panel that never changes state.

Captured live from the running server:

| Enum | Member | **On the wire** |
|---|---|---|
| `LaneId` | `A` | `"A"` |
| `LaneState` | `SEARCHING` | **`"searching"`** |
| `RunStatus` | `RUNNING` | **`"running"`** |
| `CompletenessTier` | `S` | `"S"` |
| `EmailSource` | `NONE` | **`"none"`** |
| `ReasoningKind` | `OBSERVE` | **`"observe"`** |

Rule of thumb: **`LaneId` and `CompletenessTier` are uppercase; everything else is lowercase.** Compare case-sensitively against the values in the tables below, or lowercase before comparing.

---

## 2. Read endpoints

### 2.1 `POST /function/list_lanes` → `LaneView[]`

The research lanes, sorted by `lane_id`. **`live_url` is the Browserbase URL you embed in the panel iframe** (§6).

> **There are FIVE lanes, not four: A, B, C, D and W.** Do not hard-code four panels, and do not assume the list is fixed — render whatever the array contains. `W` is the warm-lead lane and behaves differently from the rest; see §2.1.1.
>
> The rehearsal seeder used to build only four (`A`–`D`, no `W`), so anyone developing against `ops/seed_and_capture.py` — which §7 recommends — shipped four panels and met a fifth on demo day. `SeedRehearsalRun` now builds all five. The rule stands regardless: map over the array and filter by `lane_id`, never index positionally.

Request: `{}`

`data.result[0]`, captured:

```json
{
  "_jac_type": "LaneView",
  "_jac_id": "883ec5cda9404db697bac43742198377",
  "_jac_archetype": "archetype",
  "jid": "dfa6b41630c94bf0967e1f54f7c2482b",
  "lane_id": "A",
  "doctrine": "comment mining under mid-tier practitioner posts",
  "state": "searching",
  "live_url": "https://www.browserbase.com/devtools-fullscreen/inspector.html?rehearsal=A",
  "bb_session_id": "rehearsal-session-A",
  "current_query": "",
  "reasoning_count": 2,
  "prospect_count": 1
}
```

| Field | Type | Notes |
|---|---|---|
| `jid` | `string` | **stable id — key off this** |
| `lane_id` | `"A"｜"B"｜"C"｜"D"｜"W"` | A/B/C = LinkedIn, D = GitHub (terminal panel), W = warm lead |
| `doctrine` | `string` | one-line description of what this lane is doing — show it under the panel title |
| `state` | see below | drives the panel's status chip |
| `live_url` | `string` | iframe `src`. **May be `""` before the lane's browser session exists — render a placeholder, do not mount an empty iframe.** |
| `bb_session_id` | `string` | Browserbase session id; useful for the replay link |
| `current_query` | `string` | the query the lane is running right now |
| `reasoning_count`, `prospect_count` | `int` | cheap counters for badges |

`state` is one of: `idle`, `launching`, `searching`, `reading`, `crosslinking`, `dry`, `done`, `failed` — **all lowercase on the wire** (§1.2).

Two states carry meaning worth styling deliberately:
- **`dry` is not an error.** The angle yielded nothing and the lane is pivoting. Style it as "info", never "danger" — an agent that says *"this angle is dry, switching"* reads as smarter than one that got lucky.
- `failed` is the only genuine error state.

### 2.1.1 Lane W is not like the others

`W` is the **warm-lead** lane. Instead of searching for unknown people, it deep-researches **one known person** — the human the demo actually emails, calls and books.

- It surfaces that person through the same `Surfaced` relationship every other lane uses, so **she appears in `list_prospects` normally**. There is no special-case endpoint and no bypass; if she is on the ledger it is because a lane put her there.
- Its panel should read as *dossier assembly on a named person*, not *search*. `current_query` will look different, and the interesting output is her `Evidence`, not a result count.
- Treat `W` as ordinary data. Filter panels by `lane_id` rather than positional index, or Lane W will land in whichever slot you left over.

### 2.2 `POST /function/list_prospects` → `ProspectView[]`

The ledger, **sorted by `score` descending**.

> **`DROPPED` prospects are included on purpose. Render them.** Visible elimination is what makes the surviving three look earned rather than cherry-picked. Show them struck through / dimmed with `dropped_reason`.

Request: `{}`

`data.result[0]`, captured:

```json
{
  "_jac_type": "ProspectView",
  "_jac_id": "cfe978932bd449cd9690f4f87de1db04",
  "_jac_archetype": "archetype",
  "jid": "9a82d16aac294270bb0562f445138bd9",
  "name": "Rehearsal Practitioner",
  "handle": "rehearsal-practitioner",
  "headline": "Staff engineer, ML platform",
  "company": "Rehearsal Co",
  "linkedin_url": "",
  "email": "rehearsal.survivor@example.invalid",
  "email_source": "none",
  "email_confidence": 0.0,
  "tier": "S",
  "score": 0.94,
  "score_pre_crosslink": 0.71,
  "dropped_reason": "",
  "is_warm_lead": false,
  "convergence_lanes": ["A", "D"],
  "linkedin_quote": "",
  "github_artifact": ""
}
```

| Field | Type | Notes |
|---|---|---|
| `jid` | `string` | **stable id** |
| `tier` | `"S"｜"A"｜"DROPPED"` | S = email + LinkedIn + GitHub; A = email + one of them; DROPPED = no email |
| `score` | `float` | final score, after the convergence multiplier |
| `score_pre_crosslink` | `float` | score **before** cross-linking |
| `convergence_lanes` | `string[]` | lanes that independently surfaced this human |
| `dropped_reason` | `string` | non-empty only when `tier == "DROPPED"` |
| `linkedin_quote` / `github_artifact` | `string` | the two evidence strings to show side by side |
| `email_source` | enum | `none`, and the waterfall sources when resolved |

**Two fields carry the entire product thesis — make them prominent:**

1. **`convergence_lanes.length >= 2`** → this human was found independently from two directions. Badge it.
2. **`score_pre_crosslink` → `score`** → render as a transition, e.g. `0.71 → 0.94`. It proves the cross-link the judges just watched actually changed the answer.

### 2.3 `POST /function/get_run_state` → `RunStateView`

Request: `{}`

Captured:

```json
{
  "_jac_type": "RunStateView",
  "_jac_id": "107446e5c9474799b515b2a33084b80b",
  "_jac_archetype": "archetype",
  "jid": "1554356c77764a869e7e53d0fd4c3901",
  "status": "running",
  "started_at": 1785106804.891181,
  "finished_at": 0.0,
  "lane_count": 4,
  "prospect_count": 3,
  "surviving_count": 2,
  "dropped_count": 1,
  "converged_count": 1,
  "reasoning_count": 6,
  "exists": true
}
```

- `status`: `planning`, `running`, `crosslinking`, `gating`, `ranked`, `complete`, `failed`.
- `started_at` / `finished_at` are **float UNIX seconds** → `new Date(started_at * 1000)`. `finished_at` is `0.0` while running.
- **`exists: false`** means no run has been created yet. Every count is `0` and the other endpoints return `[]`. Render the pre-run empty state; this is not an error.

---

## 3. `POST /function/feed_since` — the one call to poll

Returns everything above **plus** the reasoning stream, in a single fresh read. This is the primary data path.

Request: `{ "since": 0 }`

```json
{
  "seq": 0,
  "next_seq": 7,
  "reasoning": [
    {
      "_jac_type": "ReasoningView",
      "jid": "…",
      "seq": 0,
      "t": 1785106804.9,
      "lane_id": "A",
      "sentence": "Scanning comments under mid-tier practitioner posts; skipping the 90%-'great post!' megathreads by design.",
      "kind": "observe"
    }
  ],
  "lanes":     [ /* LaneView, §2.1 */ ],
  "run":       { /* RunStateView, §2.3 */ },
  "prospects": [ /* ProspectView, §2.2 */ ]
}
```

**Cursor:** pass `0` first. Then pass back the `next_seq` you were given as the next `since`, and you will only receive reasoning emitted since. `lanes`, `run` and `prospects` are **always returned in full** regardless of `since` — only `reasoning` is incremental.

> `seq` is a positional index over the run's reasoning ordered by time. Treat `next_seq` as **opaque**: hand it back, don't compute with it, don't persist it across a server restart.

`ReasoningView.kind` ∈ `plan`, `observe`, `judge`, `pivot`, `yield`, `hit`, `miss`, `crosslink`, `gate`, `rank` — use it to colour the analyst sidebar. `pivot` is the interesting one ("this angle is dry, switching") and is worth visually distinguishing.

```js
let since = 0;
setInterval(async () => {
  const b = await call("feed_since", { since });
  since = b.next_seq;
  appendReasoning(b.reasoning);   // incremental
  renderLanes(b.lanes);           // full
  renderLedger(b.prospects);      // full
  renderHeader(b.run);            // full
}, 750);
```

---

## 4. WebSocket — `ws://127.0.0.1:8000/ws/walker/LiveFeed`

Every frame sent by **any** client is echoed to **all** connected clients (`broadcast=True`). One pump therefore drives all five panels at once.

| Route | Status |
|---|---|
| `ws://host/ws/walker/LiveFeed` | **canonical — use this** |
| `ws://host/ws/LiveFeed` | legacy alias, still works |

Both land on the **same broadcast bus** — verified: a client on the legacy route received a frame sent on the canonical route.

### 4.1 The frame shape is NOT the HTTP envelope

There is no `type`, no `error`, no `meta`. Captured verbatim:

```json
{
  "ok": true,
  "data": {
    "result": {
      "_jac_type": "LiveFeed", "_jac_id": "…", "_jac_archetype": "walker",
      "kind": "reasoning_batch", "seq": 0, "note": "round 0",
      "batch": { "next_seq": 7, "reasoning_count": 7, "lane_count": 4, "prospect_count": 3 },
      "reports": [ { "kind": "reasoning_batch", "seq": 0, "batch": { … }, "note": "round 0" } ],
      "restspec": { "broadcast": true, "protocol": "websocket", … }
    },
    "reports": [ { "kind": "reasoning_batch", "seq": 0, "batch": { … }, "note": "round 0" } ]
  }
}
```

> **Read `msg.data.reports[0]`.** Everything else (`data.result`, its echoed `has` fields, `restspec`) is server bookkeeping — ignore it.

You send an object matching the walker's fields; anything you omit takes its default:

```json
{ "kind": "reasoning_batch", "seq": 3, "batch": { "...": "any JSON object" }, "note": "" }
```

### 4.2 Control frames you must handle

| Frame | Meaning |
|---|---|
| `{"type":"ping","ts":…}` | server heartbeat, every 30 s — **ignore it, or reply `{"type":"pong"}`** |
| `{"type":"pong","ts":…}` | reply to your ping |
| `{"ok":false,"error":{…}}` | error; see codes below |

**Skip any frame that has a `type` of `ping`/`pong` before parsing it as data**, or you will crash on `data.reports`.

The server closes a connection idle for **more than 90 s**. It sends a ping every 30 s, so simply staying connected is enough — but implement reconnect-with-backoff anyway.

Limits (from `jac.toml`, `[scale.websocket]`): 100 messages/sec per connection, 500 anonymous connections per target, 30 s per-message execution timeout. Error codes you may see: `RATE_LIMITED`, `MESSAGE_TOO_LARGE`, `INVALID_PAYLOAD` (frame was not a JSON **object**), `EXECUTION_TIMEOUT`, `EXECUTION_ERROR`.

### 4.3 ⚠️ The rule that decides whether your dashboard works

**`LiveFeed` does not read the graph, and it cannot.** In jac 0.34.7 a WebSocket walker's view of the graph is frozen at server-start state: with the same root, HTTP returned 9 then 10 nodes while the WS walker kept returning 8, permanently. Broadcast also only fires *in response to a client frame* — the server cannot push on its own.

So the live loop is:

```
   research lanes ──write──▶ graph
                              │
   pump  ──HTTP feed_since──▶ (always fresh)
     │
     └──WS frame (payload inlined)──▶ LiveFeed ──broadcast──▶ all 5 panels
```

**One client is the pump.** Elect it however you like (first tab, or a dedicated hidden connection). The pump polls `feed_since` and forwards each batch into the socket. Every other panel is a pure listener and never polls.

If you skip the pump, the socket connects fine and simply never delivers anything.

Verified on the real server: **5 panels (4 canonical + 1 legacy), 3 rounds, 5/5 delivery every round, reasoning count climbing 7 → 8 → 9.** Reproduce with `python3 ops/live_feed_proof.py`.

```js
const ws = new WebSocket(`${WS_BASE}/ws/walker/LiveFeed`);
ws.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  if (msg.type === "ping" || msg.type === "pong") return;   // control frames
  if (!msg.ok) { console.warn(msg.error); return; }
  const payload = msg.data.reports[0];                       // <- the only field you want
  applyBatch(payload.batch);
};

// exactly ONE tab does this:
let since = 0;
setInterval(async () => {
  const b = await call("feed_since", { since });
  since = b.next_seq;
  ws.send(JSON.stringify({ kind: "reasoning_batch", seq: since, batch: b }));
}, 750);
```

### 4.4 The pump is a single point of failure — every panel MUST have a fallback

If the pump dies mid-demo, the socket stays connected and simply goes quiet. **Every panel freezes, and it looks exactly like the frozen-graph bug in §4.3.** Do not let a dead pump be indistinguishable from a broken product.

**Required behaviour: if a panel receives no data frame for 3 seconds, it starts polling the plain-HTTP read endpoints itself** until frames resume. HTTP is the reliably-fresh path (that is the whole basis of this design), so the fallback is strictly correct — just slower and chattier.

```js
let lastFrame = Date.now();
let polling = null;

ws.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  if (msg.type === "ping" || msg.type === "pong") return;  // NOT a data frame
  lastFrame = Date.now();
  if (polling) { clearInterval(polling); polling = null; }  // pump is back
  applyBatch(msg.data.reports[0].batch);
};

setInterval(() => {
  if (Date.now() - lastFrame < 3000 || polling) return;
  console.warn("pump silent >3s - falling back to HTTP polling");
  polling = setInterval(async () => {
    const b = await call("feed_since", { since });
    since = b.next_seq;
    applyBatch(b);
  }, 1000);
}, 1000);
```

Note the ping/pong exclusion: server heartbeats arrive every 30 s and must **not** reset `lastFrame`, or a dead pump on a healthy socket will never be detected.

### 4.5 Where the pump runs, and what supervises it

**Recommendation: the pump is the dashboard itself — a browser tab, not a server process.**

The dashboard shell elects itself pump on load and runs the `setInterval` in §4.3. Rationale:

- **Nothing extra to supervise.** No sidecar, no systemd unit, no extra line in the runbook, nothing that dies when the laptop sleeps independently of the thing displaying the result.
- **Its failure mode is benign.** If the tab is closed there is no dashboard to feed anyway. If it is reloaded, the pump restarts automatically.
- **It cannot be a `flow` task or a server thread.** Server-side code cannot trigger a broadcast at all (§4.3) — `ws_manager` is a private member of the server object. A server-side pump would have to talk to its own WebSocket as a client, which is strictly worse than a browser doing it.

Combined with the §4.4 fallback, **there is no single point of failure**: if the pump tab dies, every other panel notices within 3 s and self-serves over HTTP.

If you would rather not think about any of this: **skip the WebSocket entirely and poll `feed_since`.** That path has no pump, no election, and no fallback logic. It is the recommended option under time pressure.

---

## 5. SSE fallback — `POST /function/feed_backlog`

For a client that cannot hold a WebSocket. It streams the reasoning **backlog** — a snapshot taken when you call it — then closes. It is a backfill mechanism, **not** a live tail: it will not deliver anything emitted after the request started. Poll `feed_since` for live data.

Request: `{ "since": 0 }`. Wire format, captured:

```
data: {"kind": "lanes", "lanes": [...]}

data: {"kind": "reasoning", "seq": 0, "t": ..., "lane_id": "A", "sentence": "...", "kind_of": "observe"}

event: end
data: {}

```

- First frame is always `kind: "lanes"`, then one frame per reasoning sentence.
- Payloads are **JSON-encoded** — `JSON.parse(line.slice(6))`, not the raw slice.
- Frames are separated by a **blank line**; the stream ends with an `event: end` frame.
- Chunks split at arbitrary byte boundaries: buffer, split on `\n\n`, and keep the trailing partial frame.

---

## 6. Embedding the Browserbase live views

Each lane's `live_url` goes straight into an iframe:

```html
<iframe
  src={lane.live_url}
  sandbox="allow-same-origin allow-scripts"
  style="width:100%;height:100%;border:0"
  title={`Lane ${lane.lane_id}`}
></iframe>
```

- `sandbox="allow-same-origin allow-scripts"` is required. Fewer permissions and the debugger will not render.
- **Guard on `live_url !== ""`.** It is empty until the lane's browser session exists; mounting an empty iframe shows a broken frame during the opening seconds of the demo — exactly when the judges are looking.
- Lane **D is deliberately not a browser**. It is the GitHub lane and stays programmatic — render it as a terminal-style log fed from `reasoning` filtered to `lane_id === "D"`. The visual contrast with the three browser panels is intentional.
- The panels are 3 browser iframes + Lane D terminal + the evidence ledger, with the analyst sidebar at roughly a 70/30 split.

---

## 7. Running the server

```bash
ops/restart.sh            # keep the graph
ops/restart.sh --clean    # wipe the graph too (after a schema change)
```

Use the script rather than `jac start` directly. It guarantees the old process is dead **before** the data directory is wiped, sources `.env`, holds stdin open, waits for health, warms the first anonymous request, and fails loudly if the WebSocket routes did not register.

The launch line it runs, and why each half matters:

```bash
set -a && . ./.env && set +a && tail -f /dev/null | jac start main.jac
```

- **`. ./.env`** — `jac start` does **not** read `.env`. Without this, litellm never sees `ANTHROPIC_API_KEY` and **every `by llm()` call silently returns null while the server looks perfectly healthy.** No error, no warning; walkers just quietly produce nothing.
- **`tail -f /dev/null |`** — `jac start` exits on stdin EOF. `< /dev/null` serves fine for a while, then logs `drain: started` and dies mid-session. This holds stdin open for the life of the process. (This line previously read `sleep infinity |`, which is a GNU extension that **does not exist on macOS** — BSD `sleep` rejects it and the server dies on launch. `ops/restart.sh` has always used `tail -f /dev/null`; the doc was wrong, not the script.)
- **no `--no-client`** — the web client and the walkers are one program now. That flag skips building and mounting the client, so `/` serves nothing while the API looks perfectly fine.

To develop against a populated graph without waiting for a real research run:

```bash
python3 ops/seed_and_capture.py    # seeds a run + lanes + reasoning + a 3-row ledger
```

That seeding is rehearsal-only scaffolding (`feedseed.jac`) and is not part of the product path.

### 7.1 We stay a pure API — you run your own client

`jac.toml` is `kind = "service"`. Jac can also serve the UI itself (`kind = "web-app"` plus a `def:pub app`), and **the recommendation is that we do not do that.**

- The dashboard is being built separately by the frontend teammates, in their own stack, with their own dev server. Flipping to `web-app` would put a client build step in the server's startup path on demo day, for zero functional gain.
- CORS is already wide open (`allow_origins=['*']`, hardwired in single-process `jac start`), so a client on `localhost:5173` or any other origin talks to `:8000` with no proxy and no config.
- Keeping the API pure means a frontend build failure cannot take the API down, and the API can be restarted without touching the UI. On a deadline those are the failure modes that matter.

**So: point your dev server at `http://127.0.0.1:8000` and build however you like.** Nothing on our side needs to change, and nobody needs to flip `kind`.

### Three failure modes worth recognising

- **WebSocket 404 on `/ws/walker/LiveFeed`** → run **`jac install`**. The scale deps have not been resolved, so the WS routes never register; the decorator is silently ignored and the walker is served as a plain HTTP endpoint instead. `ops/restart.sh` fails loudly if the routes did not register.
- **WebSocket connects, then closes with `4503 subscribe_unavailable` the moment you send** → `[scale.websocket]` is missing from `jac.toml`, so the backplane **defaults to Redis**, and Redis is not installed. The server log says it outright: `WS ensure_subscribed failed for walker:LiveFeed: RedisBackplane selected but 'redis' is not installed`. The load-bearing line is `backplane = "memory"`.

  This one is dangerous because **every indirect signal still looks healthy**: the route logs as registered, `POST /walker/LiveFeed` still returns 405, `/healthz` is 200, all five function endpoints are 200, and even `WebSocket.connect()` succeeds. Only an actual `send()` reveals it — and to a dashboard the result is indistinguishable from "nobody is pumping" (§4.3). A/B/A verified: with the section → send OK and broadcast delivered; without it → `4503` on send, twice.

  `python3 ops/frontend_contract_check.py` catches this and names the cause.
- **Every endpoint suddenly 500s with `'JacScaleUserManager' object has no attribute '_lock'`** → a stale `jac start` process was left holding a guest root while `.jac/data` was wiped underneath it. **It does not recover on retry** — measured 6/6 consecutive failures 0.6 s apart — and `/healthz` keeps returning `{"status":"ok"}` the entire time, so health checks do not catch it. Fix: `ops/restart.sh`.

---

## 8. Endpoint index

| Method | Path | Body | Returns |
|---|---|---|---|
| POST | `/function/list_lanes` | `{}` | `data.result` → `LaneView[]` |
| POST | `/function/list_prospects` | `{}` | `data.result` → `ProspectView[]` |
| POST | `/function/get_run_state` | `{}` | `data.result` → `RunStateView` |
| POST | `/function/feed_since` | `{"since": int}` ⚠️ never `{}` | `data.result` → `FeedBatch` |
| POST | `/function/feed_backlog` | `{"since": int}` ⚠️ never `{}` | SSE stream |
| POST | `/walker/PlanCampaign` | `{}` | **`data.reports[0]`** |
| POST | `/walker/RunResearch` | `{"run": …}` | **`data.reports[0]`** |
| WS | `/ws/walker/LiveFeed` | frame object | broadcast echo |
| GET | `/healthz` | — | `{"status":"ok"}` |

**Walkers are not functions.** A walker's payload is at **`data.reports[0]`**, not `data.result` — the opposite of every `/function/` endpoint above. `GET` on a walker path is a 404, so always probe with `POST`; a `422` means *registered, wrong arguments* (`RunResearch` requires a `run` field), while a `404` means the walker is genuinely unregistered and is a backend bug.

### 8.1 One more envelope that is not the Jac envelope

Two consumers on this project have now been bitten by assuming our response shape is universal:

- **The WebSocket frame** is not the HTTP envelope — no `type`, `error` or `meta`; read `data.reports[0]` (§4.1).
- **Vapi's mid-call tool responses** are not the Jac envelope either. Vapi expects `{"results": [{"toolCallId": …, "result": …}]}`. A walker returning Jac's standard envelope is a well-formed 200 that Vapi reads as `No result returned` — the call proceeds and the tool silently contributes nothing.

Both failures look identical from our side: correct code, valid JSON, HTTP 200, and a consumer that sees nothing. **When an external system defines the response shape, its shape wins.** If you add an endpoint consumed by anything other than our own dashboard, check what envelope that consumer expects before assuming ours.

Read-side contract owner: **verifier**. If a field you need is missing, ask — do not read it out of the graph yourself.

**Verify this document:** `python3 ops/frontend_contract_check.py` asserts every claim on this page against a live server from the consumer's side — envelope shape, exact field names and types, undocumented extra fields, enum value casing, `jid` stability, cursor semantics, SSE grammar, walker registration and the full WebSocket path. Exit 0 means the contract holds; exit 1 prints exactly which claim broke.

---

# 9. The conversion loop — approve, email, reply, call, booking

Everything above is the research half: lanes running, prospects appearing. This
section is the back half — what the dashboard drives after a human looks at the
ranked list and says "yes, contact this one".

Every shape below was copied from a real run against real services, not written
from the source.

## 9.0 Two rules that will cost you an hour each

**Only four of these endpoints are yours to call.** `ComposeOutreach`,
`SendOutreach`, `ScheduleCall` and the read paths are driven by the dashboard.
`KbQuery`, `BookInterview` and `OnCallEnd` are called **by Vapi**, mid-call, over
the public tunnel. Calling them from the frontend will create real calendar
events and overwrite call transcripts. They are documented here so you can
recognise their side-effects on the graph, not so you can invoke them.

**The graph the HTTP server reads is not the graph the CLI writes.** Anonymous
HTTP callers share one guest root; `jac run` writes to a local root. If a
prospect was seeded from the CLI it will not exist for these endpoints. Symptom:
`list_prospects` returns `[]` while data plainly exists on disk. Seed over HTTP.

## 9.1 `POST /walker/ComposeOutreach` — draft a cited email

```json
{"prospect_id": "b330dc6955ac41838071b7d7d1524339"}
```
`prospect_id` is the `jid` from `list_prospects`. Omit it entirely and the
walker picks the highest-scoring prospect on the graph.

**Success** (`data.reports[0]`):
```json
{
  "ok": true, "refused": false, "source": "llm",
  "prospect": "Becky Zhu", "addressed_as": "Becky",
  "prospect_id": "b330dc69...", "email": "xingzhizhu6@gmail.com",
  "thread_jid": "97f12866...",
  "subject": "Finding users who already feel your problem",
  "body": "Becky, your LinkedIn About section opens with \"...\"",
  "linkedin_quote": "Hi, this is Xingzhi (Becky) Zhu, UCLA alum...",
  "linkedin_quote_kind": "about",
  "github_artifact": "",
  "degraded_reason": ""
}
```

Render `addressed_as` somewhere. It is how the system shows it knew she goes by
Becky though her profile says Xingzhi Zhu — a visible proof of personalisation.

`linkedin_quote` and `github_artifact` are the exact strings cited. Highlighting
them inside `body` is the strongest thing this UI can show: the email is
provably built from those two pieces of evidence. `linkedin_quote_kind` tells
you what to label them (`about`, `post`, `comment`) — do not print "recent post"
for an `about`, the attribution has to stay truthful.

`source` is `"llm"` normally and `"template"` when the model was unreachable and
a mechanical draft was produced from the same citations. `degraded_reason`
carries the failure. **If `source` is `template`, say so in the UI** — it is
still grounded, but it is not model-written and should not be presented as such.

**Refusal — a first-class outcome, not an error.** HTTP is still 200:
```json
{
  "ok": false, "refused": true,
  "prospect": "No Evidence Person", "addressed_as": "No",
  "reason": "refusing to compose: the graph holds nothing this person actually
             wrote and no GitHub artifact they built, so any email would be
             generic. A headline on its own does not count - it is a job title,
             not something they said.",
  "linkedin_quote": "", "linkedin_quote_kind": "", "github_artifact": ""
}
```
Render `reason` verbatim. A refusal is the product working: it means the system
declined to send something generic. There are three:
- no citable evidence at all
- the draft did not actually quote the evidence (anti-hallucination check)
- identity integrity — the address cannot be attributed to the profile the
  evidence came from

Nothing is written to the graph on a refusal. No `EmailThread` is created, so it
is safe to retry after the graph gains evidence.

**Latency: 5-20s** — it is a live model call. Show a spinner, don't time out
under 60s.

## 9.2 `POST /walker/SendOutreach` — actually send it

```json
{"prospect_id": "b330dc69..."}
```
Sends the most recent **unsent** draft for that prospect through AgentMail.
```json
{
  "ok": true, "prospect": "Becky Zhu", "to": "xingzhizhu6@gmail.com",
  "subject": "...", "thread_id": "71c8d1cc-dd7d-45f9-a0f3-d36f522248f8",
  "message_id": "<0100019fa0bbf5cc-...@email.amazonses.com>",
  "thread_jid": "730420c9...", "sent_at": 1785107989.11
}
```
`thread_id` is AgentMail's; `thread_jid` is the graph node. Errors (HTTP 500)
are named: no resolved email address, or no unsent draft — call
`ComposeOutreach` first.

**This sends a real email.** There is no dry-run.

## 9.3 Watching for the reply

`OnEmailReply` is spawned by the `mailwatch.jac` listener, which polls AgentMail
and fires the walker when a reply lands. The frontend does not call it — it
polls for the *result*:

```
POST /function/list_prospects   ->  re-read the prospect
```
A prospect with a reply has a `ReplyEvent` hanging off its `EmailThread`. The
parsed intent is what drives the UI:
```json
{"intent": "wants_call", "wants_call": true,
 "phone_number": "+12812991277",
 "proposed_times": ["now if you can - I am free for the next hour",
                    "Tomorrow at 2pm"],
 "sentiment": "positive", "source": "llm"}
```
`intent` is one of `wants_call`, `wants_info`, `not_interested`, `unclear`.
`proposed_times` are verbatim as the human wrote them — deliberately not
normalised, so show them as written. `source` is `"keyword"` if the model was
down and a conservative keyword parse ran instead; that path biases toward
`unclear` rather than risk auto-dialling someone who never agreed to a call.

**Gate the "Call now" button on `wants_call == true`.**

## 9.4 `POST /walker/ScheduleCall` — place the call

```json
{"prospect_id": "b330dc69...", "delay_seconds": 5, "dry_run": false}
```
- `delay_seconds` sets Vapi's `schedulePlan.earliestAt` to now+N. 5 makes the
  phone ring while the operator is still on screen.
- `phone_number` optional — otherwise taken from the reply, then `TEAMMATE_PHONE`.
- **`dry_run: true` builds and returns the entire payload without dialling.**
  Use it for any wiring check; it resolves the live Vapi ids and renders the
  callback URLs so you can confirm them without ringing a human.

```json
{"ok": true, "prospect": "Becky Zhu",
 "vapi_call_id": "019fa0e2-6cc5-766a-a197-80eadccc22a6",
 "to": "+12812991277", "earliest_at": "2026-07-27T00:03:45.098112Z",
 "call_session_jid": "054065de...", "dossier_chars": 918,
 "kb_endpoint": "https://<tunnel>/walker/KbQuery",
 "book_endpoint": "https://<tunnel>/walker/BookInterview"}
```

`ScheduleCall` also flattens the prospect's whole dossier into a string on the
`CallSession` at schedule time. That is what makes the mid-call answer fast
enough to not stutter — see 9.5.

**Requires `PUBLIC_BASE_URL`** in the environment. Without it the walker raises a
named error rather than dialling with dead callback URLs.

## 9.5 What Vapi does mid-call — do not call these, but do render them

**`KbQuery`** — fires when the prospect asks anything like "how does this
actually help me?". Answers from the pre-flattened dossier: **no model call and
no network on that path**, because a live human is waiting mid-sentence.
Measured 0.317ms in-process and 1.28-3.13ms through the public tunnel, against a
50ms budget. Its report carries `resolved_by` (`cache` | `graph` |
`sole-session` | `none`) — `none` means it could not identify the call and
answered with nothing, which is the one state worth surfacing.

**`BookInterview`** — fires when she names a time. Creates a real Google Calendar
event with a Meet link and invites both parties, then writes a `Booking`:
```json
{"event_id": "9fc2fvcl2u59l83vt8cbpasbi4",
 "meet_link": "https://meet.google.com/jpf-rbiu-wye",
 "start": "2026-07-26T16:51:43-07:00",
 "attendees": ["elijah@uni.minerva.edu", "xingzhizhu6@gmail.com"],
 "html_link": "https://www.google.com/calendar/event?eid=..."}
```
**This is the closing frame of the demo.** Poll for the `Booking` after the call
starts and render `meet_link` prominently the moment it appears.

**`OnCallEnd`** — the transcript, plus `Insight` nodes distilled from it. Vapi
posts *every* server message here, so the walker ignores anything that is not
`end-of-call-report`; you will see one write per call, not twenty.

## 9.6 Sequence the dashboard implements

```
list_prospects            -> operator picks one
ComposeOutreach           -> show subject, body, highlighted citations
   refused? render reason, stop
SendOutreach              -> "sent", show thread_id
poll list_prospects       -> ReplyEvent appears, intent=wants_call
ScheduleCall              -> phone rings; show vapi_call_id
   (Vapi -> KbQuery)         agent answers from the graph
   (Vapi -> BookInterview)   Booking node appears -> render the Meet link
   (Vapi -> OnCallEnd)       transcript + Insights
```

## 9.7 Rehearsal seeding

`POST /walker/SeedRehearsalProspect` puts one prospect on the graph so the back
half can be exercised without a full research run. It requires
`{"confirm": "rehearsal"}` and **refuses to seed a prospect with no evidence**,
so it can never manufacture the grounding `ComposeOutreach` checks for. Needs
`linkedin_url` (or `TEAMMATE_LINKEDIN_URL`) or the identity gate will correctly
refuse the resulting prospect.

Verification only. It is not part of the product path.
