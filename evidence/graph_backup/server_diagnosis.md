# TRACTION :8000 — `JacScaleUserManager has no attribute '_lock'` — diagnosis

Investigated 2026-07-26 ~17:15–17:21 local. **Diagnosis only — nothing was killed, cleaned, or purged.**

Runtime source root (the `jac` binary is a 123 MB Mach-O bundle; Python + jaclang live in a cache dir):

```
JACRT=/Users/elijahumana/.cache/jac/rt/13d383ad3c816638-28e78870c521ddda/site
```

`jac -c "import jaclang; print(jaclang.__file__)"` → `$JACRT/jaclang/__init__.py`, version **0.34.7**.
There is no `jac_scale` / `jac_cloud` / `jaclang_jaseci` distribution — `scale` is a **subpackage of jaclang itself** (`$JACRT/jaclang/scale/`).

---

## 0. STATE OF THE WORLD AT DIAGNOSIS TIME (read this first)

The premise in the task brief is now stale. Verified facts:

| Claim in brief | Actual state |
|---|---|
| server pid 95287 on :8000 | **DEAD.** `ps -p 95287` → no such process. |
| `GET /healthz` returns 200 | **False now.** Nothing is LISTENing on 8000 (`lsof -nP -iTCP:8000 -sTCP:LISTEN` empty, `nc -z` refused). |
| one server | **Four** `jac start main.jac --no-client` processes were alive at 17:20 (pids 5973, 6589, 6994, 7144), plus `jac test` (75405) and a `jac clean` (51981) — **all sharing one `.jac/data`**. |

`/tmp/jacdemo.log` stops at `00:14:10Z` (= 17:14 local) and has not been written since. The 500s it records are from a process that no longer exists.

---

## 1. WHERE `JacScaleUserManager` LIVES, AND THE EXACT `_lock` MECHANISM

### The class chain

**Base class** — `$JACRT/jaclang/runtimelib/server.jac:37-41`

```jac
obj UserManager {
    has base_path: str,
        _db_path: str postinit,
        _conn: (sqlite3.Connection | None) postinit,
        _lock: threading.RLock postinit;      // <- server.jac:41
```

`_lock` is a `postinit` field: it has **no default**, so it only exists if some `postinit` assigns it.

**The only place it is ever assigned** — `$JACRT/jaclang/runtimelib/impl/server.impl.jac:12-25`

```jac
impl UserManager.postinit -> None {
    ...
    self._db_path = os.path.join(data_dir, "main.db");
    self._conn = None;

    self._lock = threading.RLock();            // <- server.impl.jac:23
}
```

**Subclass** — `$JACRT/jaclang/scale/identity/user_manager.jac:36-38`

```jac
obj JacScaleUserManager(UserManager) {
    has SUPPORTED_PLATFORMS: dict = {},
        ADMIN_USER_ID: str = '00000000-0000-0000-0000-000000000000',
        _identity_storage: IdentityStorage postinit;

    def postinit -> None;                      // <- OVERRIDES the parent
```

**The override** — `$JACRT/jaclang/scale/identity/impl/user_manager.impl.jac:1-42`

```jac
impl JacScaleUserManager.postinit -> None {
    sso_config = get_scale_config().get_sso_config();
    for platform in Platforms { ... }          // fills SUPPORTED_PLATFORMS

    db_config = get_scale_config().get_database_config();
    mongodb_uri = db_config.get('mongodb_uri');
    if mongodb_uri is not None {
        self._identity_storage = MongoIdentityStorage(...);
    } else {
        db_path = os.path.join(data_dir, 'users.db');
        self._identity_storage = SqliteIdentityStorage(db_path=db_path);
    }
}
```

> It **never calls `super().postinit()`** and **never assigns `self._lock`, `self._db_path`, or `self._conn`.**
> A `JacScaleUserManager` therefore has no `_lock` attribute **from the moment it is constructed, permanently.** This is a latent defect present on every single boot, not a state that develops.

### Why it stays harmless — and then doesn't

`JacScaleUserManager` overrides 27 methods (create_user, authenticate, get_root_id, ensure_user_root, validate_jwt_token, …). Every method it overrides uses `_identity_storage` and never touches `_lock`. That is why normal traffic works.

But it does **not** override two inherited methods:

```
$ grep -rn "reset_root\|_ensure_connection" $JACRT/jaclang/scale/
   (no matches)
```

So `reset_root` and `_ensure_connection` resolve to the **base** implementations, which do use `_lock`:

`$JACRT/jaclang/runtimelib/impl/server.impl.jac:80-84`
```jac
impl UserManager.reset_root(username: str) -> (str | None) {
    import from jaclang.jac0core.constructs { Root }
    self._ensure_connection();                 // <- line 82
    assert self._conn is not None;
    with self._lock {                          // <- line 84
```

`$JACRT/jaclang/runtimelib/impl/server.impl.jac:26-28`
```jac
impl UserManager._ensure_connection -> None {
    import sqlite3;
    with self._lock {                          // <- line 28  *** AttributeError RAISED HERE ***
```

**The AttributeError is raised at `server.impl.jac:28`**, reached via `reset_root` line 82. `_lock` is the first attribute touched, so it fails before `_db_path`/`_conn` would.

### The single caller that reaches it

`$JACRT/jaclang/runtimelib/impl/server.impl.jac:271-308`, `_abegin_user_request_context`:

```jac
    try {
        (ctx, token) = await _begin_request_context(root_id);
        return (ctx, token, root_id);
    } except MissingAnchorError {                                  // line 291
        if username != Con.GUEST.value {
            raise RuntimeError(
                f"Root anchor {root_id} for user '{username}' does not "
                "exist in the anchor store. The data store was likely "
                "reset or migrated out from under the users db; restore "
                "it or re-register the user."
            );
        }
        logging.getLogger('jaclang.serve').warning(
            f"Guest root anchor {root_id} is missing from the anchor store; "   // line 302
            "minting a fresh guest root."                                       // line 303
        );
        healed_id = await asyncio.to_thread(user_manager.reset_root, username);  // line 305
        ...
    }
```

### Why it is DETERMINISTIC after the first failure

This is the important part, and it is a genuine self-perpetuating trap:

1. Every anonymous request resolves the guest root via `JacScaleUserManager.get_root_id('__guest__')`, which reads `root_id` from **`.jac/data/users.db`** (`scale/identity/impl/user_manager.impl.jac:99-120`).
2. The graph anchors live in a **different file**, `.jac/data/anchor_store.db`.
3. If `anchor_store.db` is replaced/reset while `users.db` survives, the guest `root_id` in `users.db` (here `8a2142d38c044ffcab813dc493084684`) points at an anchor that no longer exists → `MissingAnchorError` → the heal branch at line 291.
4. The heal branch calls `reset_root`, whose entire job is to mint a new root and **write the new id back into `users.db`**.
5. `reset_root` dies at `server.impl.jac:28` on `self._lock` **before writing anything**.
6. So `users.db` still holds the same dead `root_id`. The next request repeats steps 1-5 identically.

**`reset_root` IS the repair path, and the repair path is the thing that is broken.** The server can never heal itself; it is bricked until the on-disk divergence is corrected from outside the process. That is exactly what the log shows — one `Guest root anchor … is missing` warning per request, same anchor id every time, 500 every time, forever.

Why the first request succeeded: at 00:13:32-00:13:34Z the guest root anchor still existed, so `_begin_request_context` never raised and `reset_root` was never called. The divergence appeared between 00:13:34Z and 00:13:51Z, and from 00:13:51Z on **every** request 500s — including from localhost (`127.0.0.1:49569` at 00:14:10Z), not just the tunnel.

---

## 2. IS REDIS THE CAUSE? — **NO. It is a red herring.**

Evidence:

**(a) The Redis warning fires on SUCCESSFUL requests too.** From `/tmp/jacdemo.log`:
```
00:13:32.353Z  INFO     127.0.0.1:49508 - "POST /walker/KbQuery HTTP/1.1" 200
00:13:32.382Z  WARNING  Redis connection failed: 'NoneType' object has no attribute 'from_url'
```
It precedes 200s and 500s identically. It is per-request background noise, uncorrelated with the failure.

**(b) The warning is not about a connection at all — the `redis` module is not bundled.**
```
$ jac -c "import redis"
ModuleNotFoundError: No module named 'redis'
```
`redis` resolves to a `None` optional-dependency stub (`jaclang/scale/_optdeps/redis`), so `redis.from_url(...)` raises `AttributeError: 'NoneType' object has no attribute 'from_url'`, which is then caught and logged. Source: `$JACRT/jaclang/scale/memory/impl/memory_hierarchy.redis.impl.jac:26`, inside `RedisBackend.postinit`:
```jac
        try {
            _process_cache['redis_client'] = redis.from_url(self.redis_url, ...);
        } except Exception as e {
            logger.warning(f"Redis connection failed: {e}");
        }
```
`RedisBackend` is an **optional cache tier in the memory hierarchy**. It is not the user manager and is not on the identity path.

**Note:** `REDIS_URL` *is* set in the environment (`redis://default:…@redis-18402.c244.us-east-1-2.ec2.cloud.redislabs.com:18402`), which is why the code attempts the connection at all. Pointing at a *working* Redis would change nothing, because the Python client library is absent from the binary.

**(c) `JacScaleUserManager` is not constructed via a Redis fallback.** Its `postinit` branches only on `mongodb_uri` (Mongo vs SQLite identity storage). Redis is never consulted. Both branches skip `super().postinit()`, so `_lock` is missing either way.

**(d) The scale plugin is NOT gated on `jac.toml`.** `$JACRT/jaclang/jac0core/runtime.jac:85-96`:
```jac
def _scale_provider -> any {
    if _scale_provider_cache { return _scale_provider_cache[0]; }
    result: any = None;
    try {
        import from jaclang.scale.plugin { JacScalePlugin }
        result = JacScalePlugin;
    } except ImportError { }
    _scale_provider_cache.append(result);
    return result;
}
```
A bare unconditional `try/except ImportError`. `jaclang.scale` ships **inside** the binary, so the import can never fail, so the plugin is **always** active. The hook that swaps in the broken manager is `$JACRT/jaclang/scale/plugin.jac:526-533`:
```jac
    static def get_user_manager(base_path: str) -> UserManager | None {
        try { import from .identity.user_manager { JacScaleUserManager } }
        except ImportError { return None; }
        return JacScaleUserManager(base_path=base_path);
    }
```
There is **no `JAC_*` env var to select or deselect the scale backend** — `rg "JAC_DISABLE|disable_plugin|JAC_NO_SCALE|JAC_PLUGIN"` over the whole of `$JACRT/jaclang` returns nothing. Deleting `[scale.websocket]` from `jac.toml` would **not** change which UserManager is used. (`ops/restart.sh:16-22` records that a previous agent A/B-verified this: 60/60 requests green both ways.)

---

## 3. `.jac/data` — CONTENTS, AND WHETHER THE GRAPH SURVIVED

`.jac/data` was **wiped and recreated during this investigation**, by concurrent tooling, not by the `_lock` bug.

Timeline measured directly (all reads were on *copies*; the live files were never opened by me in write mode):

| time | `anchor_store.db` size | anchors | Prospects | note |
|---|---|---|---|---|
| 17:15 | 380,928 B (+226 KB WAL) | — | — | original demo graph |
| 17:17 | 380,928 B (+4.0 MB WAL) | **702** | **29** | snapshot taken (see below) |
| 17:18 | **4,096 B** | — | — | **file deleted & recreated** |
| 17:19 | 4,096 B (+1.1 MB WAL) | 156 | 3 | repopulating |
| 17:20 | 4,096 B (+1.4 MB WAL) | 311 | 7 | still climbing |

A 380,928 B main db becoming a 4,096 B main db is an unambiguous delete-and-recreate, not a checkpoint.

**Is anchor `8a2142d38c044ffcab813dc493084684` present? — NO.** Verified three ways on the 17:17 snapshot:
```sql
select id,type,arch_type from anchors where id='8a2142d38c044ffcab813dc493084684';  -- 0 rows
```
```
$ strings anchor_store.db | grep -c 8a2142d38c044ffcab813dc493084684
0
```
The only `Root` anchor in the snapshot was the super root `00000000-0000-0000-0000-000000000000`. So the guest root was already gone by 17:17 — consistent with the 500s starting at 00:13:51Z.

### Schema
`anchor_store.db` tables: `anchors(id, type, arch_module, arch_type, fingerprint, data, format_version, updated_at)`, `anchors_quarantine` (0 rows — nothing quarantined), `schema_meta`, `aliases`.

### The 17:17 snapshot — the original graph is RECOVERABLE
Before the wipe I copied the db (+WAL, which sqlite replayed on open). It is intact and preserved at:

```
/tmp/vqa/anchor_store.PREWIPE-1717.db      (765,952 B, WAL fully checkpointed in)
```
Contents: **702 anchors — 29 Prospect, 18 Founder, 73 Lane, 44 Evidence, 33 Reasoning, 27 ResearchRun, 21 GithubProfile, 15 LinkedinProfile, 13 each of Booking/CallSession/EmailThread/ICP**, plus the matching edges (73 HasLane, 46 Surfaced, 44 HasEvidence, 36 Identity, 33 Emitted, 13 each Booked/Called/GotReply/Learned/Outreach/Targets).

### What wiped it
Not the `_lock` bug — the bug never writes. The project's own tooling did, run concurrently by other agents:
- `ops/test.sh:23` → `jac clean --all --force`
- `ops/coldstart_probe.sh:11` → `jac clean --all --force; rm -rf .jac/data`
- a live `jac clean` process (pid 51981) and `jac test` (75405) were observed running
- **four** `jac start` processes were simultaneously bound to the same unsynchronised `.jac/data`

`ops/restart.sh:60-62` already documents the rule being violated: *"A stale server on another port still holds this same .jac/data, and that is the thing that corrupts it … one process at a time — the graph store is shared and unsynchronised."*

### Current divergence status: **currently CONSISTENT**
At 17:20 a fresh `users.db` (28,672 B) existed with guest `root_id = d261d2b7998e463caf82a5d7c5de9aae`, and that root **is** present in `anchor_store.db`:
```sql
select count(*) from anchors where replace(id,'-','')='d261d2b7998e463caf82a5d7c5de9aae';  -- 1
```
Four `Root` anchors now exist (`f76edfda…`, `d261d2b7…`, `52d2a9fd…`, `00000000…`) — one per racing server process, which is itself a symptom of the concurrency problem.

---

## 4. SAFEST MINIMAL FIX

### Options evaluated

| Option | Verdict |
|---|---|
| **Disable the scale plugin** (remove `[scale.websocket]`) | **Does not work.** `runtime.jac:85` loads scale unconditionally via bare `try/except ImportError`; scale is inside the binary so the import cannot fail. No config or env var gates it. Already A/B-verified by a prior agent (`ops/restart.sh:16-22`). Also would risk the WebSocket dashboard for zero benefit. |
| **Set a `JAC_*` env var to pick the backend** | **No such var exists.** `rg "JAC_DISABLE\|disable_plugin\|JAC_NO_SCALE\|JAC_PLUGIN"` over `$JACRT/jaclang` → 0 hits. |
| **Point at a real Redis** | **Irrelevant.** Redis is uninvolved (§2), and the `redis` client module is not even bundled, so no URL can help. |
| **Plain `jac start` restart** | **Insufficient on its own.** A restart re-reads the same `users.db`; if it still holds an orphaned guest `root_id`, the very first request re-enters the broken heal path. It also leaves the racing processes alive, which is what caused the divergence. |
| **`ops/restart.sh` (no `--clean`)** | **CORRECT.** Kills every `jac start` and *waits*; then runs a preflight that compares `users.db`'s guest `root_id` (bare hex) against `anchor_store.db` (dashed uuid) with dashes stripped; if divergent it deletes **only `users.db`**, leaving `anchor_store.db` — the actual prospect graph — untouched; sources `.env`; boots with `tail -f /dev/null |` holding stdin; then runs a 12-request smoke gate and self-repairs once if a `_lock` 500 still escapes. This is precisely the minimal repair, and it is already written and committed. |

Dropping `users.db` loses nothing: every TRACTION endpoint is anonymous (`walker:pub` on the guest graph), so there are no real accounts in it (`ops/restart.sh:107-110`).

### RECOMMENDED COMMAND — NOT EXECUTED

```bash
cd /Users/elijahumana/jachacks-traction && ops/restart.sh
```

Do **not** pass `--clean` — that deletes `.jac/data` and the graph with it.

### Warnings that must accompany it

1. **`ops/restart.sh:64` runs `pkill -f "jac start"`**, which is deliberately *not* port-scoped. It will terminate the other agent's servers (the four `jac start` processes, including the one on :8901). That is the correct behaviour — the shared unsynchronised `.jac/data` is exactly why the divergence happened — but it is cross-agent-destructive and needs coordination first. This is why I did not run it.
2. **The original 29-Prospect graph is already gone** and is being overwritten right now by concurrent `jac test` / `jac run` traffic. `ops/restart.sh` preserves whatever `anchor_store.db` contains *at the moment it runs* — which is no longer the demo graph. To restore the real one, stop all writers, then copy `/tmp/vqa/anchor_store.PREWIPE-1717.db` over `.jac/data/anchor_store.db` (deleting the stale `-wal`/`-shm` alongside it) **and** delete `.jac/data/users.db` so a fresh guest root is minted against the restored store.
3. **Fixing the underlying jaclang bug is out of reach here** — the defect is in a read-only vendored runtime inside a 123 MB binary. The real fix upstream is either `JacScaleUserManager.postinit` calling `super().postinit()`, or `JacScaleUserManager` overriding `reset_root`. Neither is patchable from this repo.
4. **Until only one `jac start` owns `.jac/data` at a time, this will recur.** That is the actual root cause of the *divergence*; the missing `_lock` is what turns a recoverable divergence into a permanent brick.

---

## Evidence artifacts

| path | what |
|---|---|
| `/tmp/vqa/anchor_store.PREWIPE-1717.db` | 702-anchor / 29-Prospect graph snapshot, pre-wipe |
| `/tmp/vqa/dbcopy/` | working copy of the same |
| `/tmp/vqa/db2/`, `/tmp/vqa/db3/` | post-wipe copies (156 and 311 anchors) |
| `/tmp/jacdemo.log` | dead server's log; last entry 00:14:10Z |
