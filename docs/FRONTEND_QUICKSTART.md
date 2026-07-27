# TRACTION — Frontend Quickstart

**You have 30 minutes and a dashboard to ship. Read this, not the 500-line contract.**

Everything here is verified against a live server by `ops/frontend_contract_check.py`.
Run it yourself: `python3 ops/frontend_contract_check.py`. If it exits 0, this page is true.

- Base URL: `http://127.0.0.1:8000`
- No auth. No `Authorization` header. CORS is `*` — call it from any dev server.
- Every endpoint is **POST**, always `Content-Type: application/json`.

---

## 1. The whole thing, in one call

Ignore the WebSocket. Poll **one** endpoint every 750 ms and you have the entire dashboard:
lanes, prospects, run header, and the reasoning stream.

```js
const BASE = "http://127.0.0.1:8000";

async function call(fn, args) {
  const r = await fetch(`${BASE}/function/${fn}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  const env = await r.json();
  if (!env.ok) throw new Error(env.error?.message ?? "call failed");
  return env.data.result;                // <- the payload lives at data.result
}

let since = 0;
setInterval(async () => {
  const b = await call("feed_since", { since });
  since = b.next_seq;          // hand it back next time; treat it as opaque
  appendReasoning(b.reasoning); // INCREMENTAL - only what's new
  renderLanes(b.lanes);         // full, every time
  renderLedger(b.prospects);    // full, every time
  renderHeader(b.run);          // full, every time
}, 750);
```

That is the entire data path. It is always fresh, it has no pump, no socket, no
reconnect logic, and no failure mode more exotic than "the server is down."

---

## 2. Exactly what you get back

`POST /function/feed_since` with `{"since": 0}`. Every HTTP response is wrapped in
an envelope — **read `data.result`**:

```json
{
  "ok": true,
  "type": "response",
  "data": { "result": { /* everything below */ }, "reports": [] },
  "error": null,
  "meta": { "extra": { "http_status": 200 } }
}
```

`data.result` for `feed_since`:

```json
{
  "seq": 0,
  "next_seq": 6,
  "reasoning": [
    {
      "seq": 0,
      "t": 1785111108.188597,
      "lane_id": "A",
      "sentence": "Scanning comments under mid-tier practitioner posts; skipping the 90%-'great post!' megathreads by design.",
      "kind": "observe"
    }
  ],
  "lanes": [
    {
      "jid": "069aeb87509946a78266f39986dbb74a",
      "lane_id": "A",
      "doctrine": "comment mining under mid-tier practitioner posts",
      "state": "searching",
      "live_url": "https://www.browserbase.com/devtools-fullscreen/inspector.html?...",
      "bb_session_id": "rehearsal-session-A",
      "current_query": "",
      "reasoning_count": 2,
      "prospect_count": 1
    }
  ],
  "prospects": [
    {
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
  ],
  "run": {
    "jid": "0bc8bf99c1c74cadaf97291285511de0",
    "status": "running",
    "started_at": 1785111108.164969,
    "finished_at": 0.0,
    "lane_count": 4,
    "prospect_count": 3,
    "surviving_count": 2,
    "dropped_count": 1,
    "converged_count": 1,
    "reasoning_count": 6,
    "exists": true
  }
}
```

Every object also carries `_jac_type`, `_jac_id`, `_jac_archetype`. **Ignore all three** — see Trap 2.

Notes that save you time:
- `run.exists === false` means no run has started. Every count is `0`, `lanes` and
  `prospects` are `[]`, and `run.jid` is `""`. Render your empty state. **This is not an error.**
- `started_at` / `finished_at` are **float UNIX seconds** → `new Date(started_at * 1000)`.
  `finished_at` is `0.0` while running.
- `prospects` is sorted by `score` **descending**. `lanes` is sorted by `lane_id` ascending.
- `DROPPED` prospects are included **on purpose**. Render them struck-through with
  `dropped_reason`. Visible elimination is what makes the survivors look earned.

---

## 3. Enum values — copy this table, compare case-sensitively

Enums arrive as **bare strings**, and the string is the enum's **value**, which is
usually **lowercase**. A `switch` on `"SEARCHING"` never matches and never errors —
you just get a panel that silently never changes state.

| Field | Allowed values on the wire |
|---|---|
| `lane.lane_id`, `reasoning.lane_id`, `prospect.convergence_lanes[]` | `"A"` `"B"` `"C"` `"D"` `"W"` — **UPPERCASE** |
| `prospect.tier` | `"S"` `"A"` `"DROPPED"` — **UPPERCASE** |
| `lane.state` | `"idle"` `"launching"` `"searching"` `"reading"` `"crosslinking"` `"dry"` `"done"` `"failed"` |
| `run.status` | `"planning"` `"running"` `"crosslinking"` `"gating"` `"ranked"` `"complete"` `"failed"` |
| `reasoning.kind` | `"plan"` `"observe"` `"judge"` `"pivot"` `"yield"` `"hit"` `"miss"` `"crosslink"` `"gate"` `"rank"` |
| `prospect.email_source` | `"github_commit"` `"github_profile"` `"github_readme"` `"personal_site"` `"linkedin_contact_info"` `"verified_guess"` `"provided"` `"none"` |

**The rule: `lane_id` and `tier` are UPPERCASE. Everything else is lowercase.**

Two values worth styling deliberately:
- **`state: "dry"` is not an error.** The angle yielded nothing and the lane is
  pivoting. Style it as *info*, never *danger*. An agent that says "this angle is
  dry, switching" reads as smarter than one that got lucky.
- **`state: "failed"`** is the only genuine error state.
- **`kind: "pivot"`** is the most interesting line in the sidebar. Make it stand out.

---

## 4. The traps

### Trap 1 — pass `since` explicitly

`feed_since` and `feed_backlog` used to return **HTTP 500** on `{}` and on
`{"since": null}` — the declared `since: int = 0` was not applied when the field
was absent. **That is fixed.** Both now coerce whatever arrives into a cursor and
default to `0`. Verified against a live server: `{}`, `null`, `"abc"`, `[1,2]`,
`{"a":1}`, `-5`, `true`, `1e18` and a 20-digit string all return 200.

Be explicit anyway — the cursor is state you own:

```js
call("feed_since", { since: since ?? 0 });   // ✅
```

Initialise it to `0`, never `undefined` or `null`. `JSON.stringify` drops
undefined keys, so `{ since: undefined }` is indistinguishable from `{}` on the
wire.


### Trap 2 — key off `jid`, never `_jac_id`

`_jac_id` is **regenerated on every single response**. These are freshly-built
projection objects, so two back-to-back calls return different `_jac_id`s for the
same lane. Use it as a React key and every panel remounts on every poll — iframes
reload, animations restart, focus is lost.

```jsx
{lanes.map(l => <Panel key={l.jid} lane={l} />)}   // ✅ jid is stable
{lanes.map(l => <Panel key={l._jac_id} … />)}      // ❌ remounts every 750ms
```

Every object carries `jid` **except**:
- `reasoning[]` entries have **no `jid`** — key them off `seq`.
- `run.jid` is `""` until `run.exists === true` — don't key off it before then.

### Trap 3 — don't hard-code the number of lane panels

A run has **five** lanes: `A`, `B`, `C`, `D`, **`W`**. The rehearsal seeder used to
build only four (`A`–`D`), so anyone developing against it shipped four panels and
met a fifth on demo day. The seeder now builds all five — but the rule stands,
because lane count is not yours to assume:

```js
lanes.map(...)                       // ✅ render whatever the array contains
lanes.filter(l => l.lane_id === "W") // ✅ select by id
lanes[4]                             // ❌ positional indexing
```

Lane `W` is the **warm-lead** lane: it deep-researches one known person rather than
searching for unknown ones. Its panel should read as *dossier assembly on a named
person*. She appears in `prospects` normally — no special endpoint.

### Trap 4 — the WebSocket needs a pump, or it is silent forever

**Only relevant if you use the WebSocket. If you're following §1, skip this.**

`LiveFeed` **cannot read the graph** — its view is frozen at server-start state, and
the server cannot push on its own. It is a pure echo bus: whatever a client sends
is broadcast to every connected client.

So **exactly one** client must be the *pump*: poll `feed_since` over HTTP and forward
each batch into the socket. Every other panel is a pure listener.

```
 research lanes ──write──▶ graph
                            │
 pump ──HTTP feed_since──▶ (always fresh)
   └──WS frame──▶ LiveFeed ──broadcast──▶ all panels
```

**If nobody pumps, the socket connects fine and delivers nothing, forever.** That
looks identical to a broken product. Verified: 3 seconds of silence with no pump running.

### Trap 5 — the WebSocket frame is **not** the HTTP envelope

No `type`, no `error`, no `meta`. Read `msg.data.reports[0]` — *not* `data.result`.
And skip `ping`/`pong` control frames **before** parsing, or you crash on `.reports`.

```js
const ws = new WebSocket("ws://127.0.0.1:8000/ws/walker/LiveFeed");
ws.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  if (msg.type === "ping" || msg.type === "pong") return;  // ← MUST come first
  if (!msg.ok) { console.warn(msg.error); return; }
  applyBatch(msg.data.reports[0].batch);
};

// exactly ONE tab runs this:
let since = 0;
setInterval(async () => {
  const b = await call("feed_since", { since });
  since = b.next_seq;
  ws.send(JSON.stringify({ kind: "reasoning_batch", seq: since, batch: b }));
}, 750);
```

The server pings every 30 s and closes a connection idle for 90 s. Staying connected
is enough, but **ping frames must not count as data** — if they reset your
"pump is alive" timer, a dead pump on a healthy socket is undetectable.

---

## 5. Embedding the Browserbase live views

`lane.live_url` holds Browserbase's `debuggerFullscreenUrl`. It goes straight into an iframe:

```jsx
{lane.live_url ? (
  <iframe
    src={lane.live_url}
    sandbox="allow-same-origin allow-scripts"
    style={{ width: "100%", height: "100%", border: 0 }}
    title={`Lane ${lane.lane_id}`}
  />
) : (
  <Placeholder>launching browser session…</Placeholder>
)}
```

- **`sandbox="allow-same-origin allow-scripts"` is required.** With fewer
  permissions the debugger does not render.
- **Guard on `live_url !== ""`.** It is empty until the lane's browser session
  exists. Mounting an empty iframe shows a broken frame during the opening seconds
  of the demo — exactly when the judges are looking.
- **Lane `D` is deliberately not a browser.** It's the GitHub lane and stays
  programmatic. Render it as a terminal-style log fed from
  `reasoning.filter(r => r.lane_id === "D")`. The contrast with the browser panels
  is intentional — *don't* iframe it even if `live_url` is populated.

Suggested layout: 3 browser iframes + Lane D terminal + the evidence ledger, with
the analyst sidebar at roughly a 70/30 split.

---

## 6. Starting a run

Not in the main contract doc — **walkers behave differently from functions.**

| | Functions (`/function/*`) | Walkers (`/walker/*`) |
|---|---|---|
| Payload lives at | `data.result` | **`data.reports[0]`** |
| `GET` on the path | 404 | 404 — always POST |

```js
async function spawn(walker, args = {}) {
  const r = await fetch(`${BASE}/walker/${walker}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  const env = await r.json();
  return env.data.reports[0];      // ← reports[0], NOT result
}
```

- `POST /walker/PlanCampaign` `{}` → plans the campaign.
- `POST /walker/RunResearch` → **requires a `run` field**; a bare `{}` returns
  HTTP 422 with `{"detail":[{"loc":["body","run"],"msg":"Field required"}]}`.

A 422 means *registered, wrong arguments*. A **404 means the walker isn't registered
at all** — that's a backend bug, report it.

---

## 7. Endpoint index

| Method | Path | Body | Returns |
|---|---|---|---|
| POST | `/function/feed_since` | `{"since": 0}` ⚠️ never `{}` | everything (poll this) |
| POST | `/function/list_lanes` | `{}` | `LaneView[]` |
| POST | `/function/list_prospects` | `{}` | `ProspectView[]` |
| POST | `/function/get_run_state` | `{}` | `RunStateView` |
| POST | `/function/feed_backlog` | `{"since": 0}` ⚠️ never `{}` | SSE backlog, then closes |
| POST | `/walker/PlanCampaign` | `{}` | `data.reports[0]` |
| POST | `/walker/RunResearch` | `{"run": …}` | `data.reports[0]` |
| WS | `/ws/walker/LiveFeed` | frame object | broadcast echo |
| GET | `/healthz` | — | `{"status":"ok"}` |

⚠️ **`/healthz` returning `ok` does not mean the API works.** There is a known
failure mode where health stays green while every endpoint 500s with
`'JacScaleUserManager' object has no attribute '_lock'`. If every call fails at
once, that's the server, not your code — tell the backend team, and don't bother
retrying (it does not recover on its own).

---

## 8. Is the contract still true?

```bash
python3 ops/frontend_contract_check.py            # against a running server
python3 ops/frontend_contract_check.py --seed     # seed rehearsal data first
```

Exit 0 means every claim on this page is verified against a live server. Exit 1
prints exactly which claim broke. If you hit behaviour this page doesn't describe,
run it before assuming it's your bug.
