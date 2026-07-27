# TRACTION — Demo Runbook

Operational only. Everything here was measured today; nothing is theoretical.

---

## The five commands

```bash
ops/restart.sh              # start / restart, keeping the graph
ops/restart.sh --clean      # start fresh (WIPES the graph - loses any pre-warm)
ops/warm.sh save            # snapshot the pre-warmed graph
ops/warm.sh restore         # recover from a bricked server WITHOUT losing the pre-warm
ops/warm.sh status          # snapshot present? server healthy?
ops/tunnel.sh               # bring up / verify the Vapi tunnel
ops/test.sh                 # run the suite (no API keys needed)
```

---

## Demo-day sequence

1. **`ops/restart.sh --clean`** — fresh graph.
2. **Pre-warm the research run** off-stage (§6 of the master plan: the pipeline is 6–8 min, the slot is 4).
3. **`ops/warm.sh save`** ← **do not skip this.** It is the difference between a 20-second recovery and losing the pre-warm.
4. **`ops/tunnel.sh`** — bring up the Vapi tunnel, then **re-point Vapi's Custom Tool and Knowledge Base URLs** at the hostname it prints.
5. **`ops/warm.sh status`** — confirm snapshot present and server 200 before you go on stage.

---

## THE DEMO RUNS FROM AN ISOLATED CHECKOUT ON ITS OWN PORT

**This is the demo configuration.** The working directory's graph store cannot be trusted: every `jac run` and `jac start` in a checkout reads and writes the same unsynchronised `.jac/data`, and concurrent processes corrupt the shared anonymous root (§7 of EVIDENCE.md).

```bash
git clone /Users/elijahumana/jachacks-traction /tmp/demo
cp /Users/elijahumana/jachacks-traction/.env /tmp/demo/
cp /Users/elijahumana/jachacks-traction/.linkedin_cookies*.json /tmp/demo/
cd /tmp/demo && set -a && . ./.env && set +a
unset ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS ANTHROPIC_AUTH_TOKEN
rm -rf .jac
tail -f /dev/null | jac start main.jac --no-client --port 8123
```

- **`tail -f /dev/null` is required.** `< /dev/null` lets the server exit, and **`sleep infinity` does not exist on macOS** — BSD `sleep` rejects it and the server dies instantly.
- **A distinct port** stops a stray server elsewhere from shadowing you.
- **First start takes ~120 s** — it is compiling the project. Do not declare it dead early.
- **`unset` the Anthropic proxy vars**, or every `by llm()` auth-fails with a message that looks exactly like a bad API key.

Proven: 12 requests over 6 rounds, zero `_lock` errors, zero 500s, and the graph moving correctly every round (`founders 0 → 1, runs 0 → 5, lanes 0 → 20`). The identical sequence in a shared directory dies permanently.

**One process per checkout. That is the whole rule.**

---

## ⚠️ Two of our own scripts wipe the graph

`ops/test.sh` and `ops/coldstart_probe.sh` call `jac clean --all --force`, which deletes `.jac/data`. **This wiped the demo graph at 17:18 today** — 702 anchors, recovered only because a snapshot had been taken a minute earlier.

Both now **refuse to run in the primary checkout** unless you set `YES_WIPE=1`. Run them in a throwaway clone.

### Restoring a wiped graph

```bash
# 1. stop ALL writers first
# 2. copy the snapshot over the live store
cp evidence/graph_backup/anchor_store.PREWIPE-1717.db .jac/data/anchor_store.db
# 3. delete the sidecars and users.db so nothing disagrees with it
rm -f .jac/data/anchor_store.db-wal .jac/data/anchor_store.db-shm .jac/data/users.db
# 4. boot with PLAIN restart - never --clean
ops/restart.sh
```

Backups: `evidence/graph_backup/` (committed) and `~/traction-graph-backups/` (off-repo).


---

## If something breaks

### `/healthz` says ok but everything else 500s

**`/healthz` returns `{"status":"ok"}` the entire time every real endpoint is 500ing.** Never gate on it. `ops/restart.sh` now gates on `POST /function/get_run_state` instead — the endpoint the dashboard actually polls.

**The WebSocket also survives a `_lock` event**: the socket stays connected and broadcasting while every HTTP endpoint 500s. So the panels freeze with a healthy socket and a green `/healthz`, which is indistinguishable from "nobody is pumping." That is what makes the 3-second HTTP fallback in `docs/FRONTEND_INTEGRATION.md` §4.4 load-bearing rather than optional.

### Every endpoint returns 500, `'JacScaleUserManager' object has no attribute '_lock'`

**It never recovers on its own** — 6/6 failures 0.6 s apart. Do not retry. The cause is `users.db` naming a guest root that `anchor_store.db` does not contain; the runtime's own repair path needs a `_lock` that was never created, so it cannot heal. Fix:

```bash
rm .jac/data/users.db && ops/restart.sh    # keeps the graph
ops/warm.sh restore                        # or restore the snapshot, also keeps the graph
```

**What is actually broken** (jaclang 0.34.7, read out of the runtime that ships inside the `jac` binary):

`JacScaleUserManager.postinit` overrides `UserManager.postinit` and never calls it, and the parent is the only place that sets `self._lock`. So the scale user manager has no `_lock`, from boot. Harmless until the guest root id recorded in `.jac/data/users.db` is absent from `.jac/data/anchor_store.db` — then every request takes the guest self-heal branch, which calls `reset_root()`, the one method the scale subclass does *not* override, whose first statement is `with self._lock`. `reset_root` **is** the repair path, so it can never repair itself. The server 500s forever.

So the corruption lives in **`users.db`** (a guest root_id pointing at nothing), not in `anchor_store.db`. `anchor_store.db` is the graph and is fine — which is why dropping `users.db` alone fixes it without losing the pre-warm. There are no real accounts in `users.db` to lose: every TRACTION endpoint is anonymous.

**This has nothing to do with `[scale.websocket]`.** A/B verified — 60 anonymous POSTs against two copies of this repo, with and without the block, `OK=60 FAIL=0` both ways. `jac0core/runtime.jac:85 _scale_provider` is a bare `try { import jaclang.scale.plugin } except ImportError` with no jac.toml gate, and scale ships inside the binary, so it loads either way. Both copies also registered `/ws/walker/LiveFeed`. Removing the block buys nothing and costs nothing. Leave it alone.

Prevention: never wipe `.jac/data` while a server is live, and give the demo server a dedicated port and data dir so another operator's `pkill -f "jac start"` cannot reach it. Wiping one of the two db files without the other is what creates the divergence.

### The server was fine and then died a few minutes later

`jac start` exits on stdin EOF. Something must hold stdin open — and **`sleep infinity` is NOT that something on macOS.** BSD `sleep` rejects it and exits instantly, closing the pipe:

```
$ sleep infinity
usage: sleep number[unit] [...]
```

Use `tail -f /dev/null | jac start …`. `ops/restart.sh` already does.

### Every `by llm()` call returns null but the server looks perfectly healthy

`jac start` does **not** read `.env`. Source it first:

```bash
set -a && . ./.env && set +a && tail -f /dev/null | jac start main.jac --no-client
```

`ops/restart.sh` does this and warns if `ANTHROPIC_API_KEY` is still unset.

### `ws://…/ws/walker/LiveFeed` returns 404

Run **`jac install`** — the scale deps are unresolved, so the WS routes never register. `@restspec(protocol=APIProtocol.WEBSOCKET)` is then **silently ignored**: no error, `jac check` still passes, and the walker is served as a plain HTTP endpoint.

`[scale.websocket]` in `jac.toml` is **not** required for this — A/B verified, routes register and return 101 with the block removed. It only tunes limits (the default 20 msg/sec would throttle the dashboard pump). An earlier claim of mine that it was required was wrong.

`ops/restart.sh` warns if the routes did not register, but no longer exits — the dashboard's documented fallback is to poll `feed_since`, so a server that is otherwise healthy is worth keeping.

### The tunnel URL "cannot be resolved" from this laptop

**Probably a false alarm.** On this network the DHCP resolver returns NXDOMAIN for `*.trycloudflare.com` while `1.1.1.1` resolves it and the tunnel answers 200. **Vapi is unaffected** — its servers use their own resolvers. Verify the way `ops/tunnel.sh` does:

```bash
curl --doh-url https://1.1.1.1/dns-query https://<host>.trycloudflare.com/healthz
```

### The dashboard is connected but frozen

Exactly one client must **pump**: poll `POST /function/feed_since` over HTTP and forward each batch into the WebSocket. `LiveFeed` cannot read the graph, so with no pump the socket connects and delivers nothing forever. Panels should fall back to HTTP polling after 3 s of silence — see `docs/FRONTEND_INTEGRATION.md` §4.4.

Fastest fix under pressure: **have the dashboard poll `feed_since` directly and ignore the WebSocket entirely.**

### The test suite fails with `WriteConflict` on anchor `00000000-…`

`jac test` runs pytest-xdist with ten workers and injects `-n` unconditionally. Use `ops/test.sh`, which sets `PYTEST_XDIST_AUTO_NUM_WORKERS=1`. It is not a race in the code under test.

---

## Pre-demo checklist

- [ ] `ops/warm.sh status` → snapshot present, server 200
- [ ] `ops/tunnel.sh` → `TUNNEL_CARRIES_VAPI_CALLBACKS = True`
- [ ] Vapi Custom Tool + KB URLs re-pointed at the **current** tunnel hostname (it changes on every tunnel restart)
- [ ] `ops/test.sh` → green
- [ ] Browserbase context re-verified live (~6:30 PM per the register)
- [ ] Dashboard shows lanes with non-empty `live_url`
- [ ] **Hotspot tunnel proven** — `NETWORK=hotspot ops/tunnel.sh`; the register calls the hotspot PRIMARY
