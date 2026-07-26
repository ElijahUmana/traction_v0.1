# TRACTION — Frontend Integration Contract

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
| The 4 lane panels + their iframe URLs | `POST /function/list_lanes` |
| The prospect ledger (incl. drops) | `POST /function/list_prospects` |
| Run header / counts | `POST /function/get_run_state` |
| **Everything at once (poll this)** | `POST /function/feed_since` |
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
- `data.reports` is `[]` for functions. It is only populated for walkers (§5).
- On failure `ok` flips to `false` and `error` is `{ "code", "message", "details" }`, e.g. `{"code": "EXECUTION_ERROR", ...}`.

All endpoints are **`POST`**, always `Content-Type: application/json`, always with a JSON object body (`{}` when there are no arguments). A `GET` on the same path returns the signature, not the data.

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

---

## 2. Read endpoints

### 2.1 `POST /function/list_lanes` → `LaneView[]`

The four research lanes. Sorted A, B, C, D. **`live_url` is the Browserbase URL you embed in the panel iframe** (§6).

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

`state` is one of: `idle`, `launching`, `searching`, `reading`, `crosslinking`, `dry`, `done`, `failed`.
`dry` is not an error — it means the angle yielded nothing and the lane is pivoting. Style it as "info", not "danger".

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

Use the script rather than `jac start` directly. It guarantees the old process is dead **before** the data directory is wiped, waits for health, warms the first anonymous request, and fails loudly if the WebSocket routes did not register.

To develop against a populated graph without waiting for a real research run:

```bash
python3 ops/seed_and_capture.py    # seeds a run + 4 lanes + reasoning + a 3-row ledger
```

That seeding is rehearsal-only scaffolding (`feedseed.jac`) and is not part of the product path.

### Two failure modes worth recognising

- **WebSocket 404 / connection refused on `/ws/walker/LiveFeed`** → the server was started without `[scale.websocket]` in `jac.toml`, or without `jac install`. The decorator is then silently ignored and the walker is served as a plain HTTP endpoint. `ops/restart.sh` checks for this and fails loudly.
- **Every endpoint suddenly 500s with `'JacScaleUserManager' object has no attribute '_lock'`** → a stale `jac start` process was left holding a guest root while `.jac/data` was wiped underneath it. The server does not recover on its own. Fix: `ops/restart.sh`.

---

## 8. Endpoint index

| Method | Path | Body | Returns |
|---|---|---|---|
| POST | `/function/list_lanes` | `{}` | `LaneView[]` |
| POST | `/function/list_prospects` | `{}` | `ProspectView[]` |
| POST | `/function/get_run_state` | `{}` | `RunStateView` |
| POST | `/function/feed_since` | `{"since": int}` | `FeedBatch` |
| POST | `/function/feed_backlog` | `{"since": int}` | SSE stream |
| WS | `/ws/walker/LiveFeed` | frame object | broadcast echo |
| GET | `/healthz` | — | `{"status":"ok"}` |

Read-side contract owner: **verifier**. If a field you need is missing, ask — do not read it out of the graph yourself.
