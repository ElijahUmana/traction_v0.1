# Jac 0.34.7 — gotchas, verified live on this machine

Every item here was reproduced by executing code, not by reading docs. Where a
claim came from a teammate it is credited; where it contradicts a claim, the
contradiction is shown with the command that settles it.

Read this before writing your first archetype. Several of these fail **silently
or point at the wrong line**, which is what makes them expensive.

---

## 0. THE SILENT ONES — wrong results, no error

These produce incorrect behaviour with a clean `jac check`. They are the reason
this file exists.

### 0.1 A walker field named `reports` silently discards MANUAL appends

**Scope corrected after re-measuring — read the boundary, it is narrower than
the original warning in this file.**

`has reports: list[T] = [];` collides with the walker's built-in report channel.
What that does depends entirely on how you write to it:

```jac
# A - has reports + the BUILT-IN report statement          ✅ WORKS
walker A { has reports: list[dict] = [];
    can hit with P entry { report {"n": here.name}; } }

# B - has reports + MANUAL append                          ❌ SILENTLY LOST
walker B { has reports: list[dict] = [];
    can hit with P entry { self.reports.append({"n": here.name}); } }

# C - both                                                 ⚠️ manual ones VANISH
walker C { has reports: list[dict] = [];
    can hit with P entry { self.reports.append({"manual": ...}); report {"builtin": ...}; } }
```
Measured:
```
A  report-stmt only : [{'n': 'a'}, {'n': 'b'}]      ✅
B  manual append    : []                            ❌ no error, no warning
C  both             : [{'builtin': 'a'}, {'builtin': 'b'}]   manual entries gone
```

**The rule:**
- Using the built-in `report x;` statement → declaring `has reports` is harmless
  dead weight. It reads back correctly. **Nothing to fix.**
- Using `self.reports.append(...)` as a manual accumulator → **your data is
  silently discarded.** Rename the field (`found`, `picked`, `collected`) or
  switch to `report x;`.
- Mixing both is the worst case: the built-in entries survive and the manual
  ones disappear, so the list looks populated and is quietly incomplete.

This repo has 14 `has reports` declarations across identity/outreach/voice/
research/githublane/rehearsal. **All 14 are the safe form** — audited with
`grep -rn 'self\.reports\.append\|self\.reports\s*='`, zero hits. They are
redundant, not broken; leave them alone rather than churning six files.

> An earlier revision of this entry said "NEVER name a walker field `reports`"
> and implied every such walker was broken. That was over-broad. The
> distinguishing factor is the manual append, not the name.

### 0.15 ⛔ A walker whose entry ability is a NODE type is a SILENT NO-OP when spawned on root

`POST /walker/<Name>` spawns on **root**. If the walker's only entry ability
triggers on a node type, nothing fires: no error, no reports, HTTP 200, and the
graph is untouched.

```jac
walker:pub RunResearch {
    can start with Founder entry { ... }   # never fires from `root spawn`
}
```
Measured before/after with graph counts — this is what it looks like:
```
[02 planned]              founders=1 runs=0 lanes=0 reasoning=0
    spawn-on-ROOT    reports: 0        <- silent
[03a after root-spawn]    founders=1 runs=0 lanes=0 reasoning=0   <- IDENTICAL
    spawn-on-FOUNDER reports: 1
[03 researched]           founders=1 runs=1 lanes=3 reasoning=265
```

**Fixes, pick one:**
- Call the node-scoped route: `POST /walker/<Name>/{nd}` with the node's `jid`.
- Or give the walker a `can ... with Root entry` that finds its anchor and
  `visit`s it — what `PlanCampaign` does (`root -> Founder`), so it works from a
  bare `root spawn`.

**This is the failure mode that costs you a demo**: the button returns 200, the
dashboard shows no error, and nothing happened. Always confirm a stage moved the
graph, never that it returned 200.

### 0.2 Omitting `= []` on a walker list makes it a REQUIRED spawn parameter

```jac
walker W { has found: list[str]; }      # root spawn W()  ->  E1050
walker W { has found: list[str] = []; } # ✅
```
`E1050: Not all required parameters were provided in the function call: 'found'`
— then a cascading `type object 'W' has no attribute 'found'` at runtime.

### 0.3 A node filter whose predicate name matches the enclosing parameter self-compares

```jac
def find(handle: str) -> list[Prospect] {
    return [root -->[?:Prospect, handle == handle]];   # ❌ ALWAYS TRUE — returns everything
}
```
`handle` inside the filter binds to the *node field*, not your parameter, so it
compares the field to itself. Emits `W3040` (a warning, not an error) and
returns wrong data. Rename the parameter: `def find(who: str)` → `handle == who`.

### 0.4 Converting a `has` field to a `def` method silently breaks every call site

A bare method reference is **always truthy**, so a guard that used to read a
bool now always passes. `jac check` says nothing.

```jac
if p.is_warm_lead  { ... }   # was a field -> now a METHOD REF -> ALWAYS TRUE
if p.is_warm_lead() { ... }  # correct
```
Measured:
```
if p.warm and p.email    ->  branch taken: True     # bound method ref is truthy
if p.warm() and p.email  ->  branch taken: False
```
This bit `identity.jac:295` when `is_warm_lead` moved from a stored field to an
edge-derived method: every prospect with an email took the warm-lead
short-circuit, bypassing the entire six-step email waterfall and its attribution
floor — the floor that catches the forked-repo case where we would have emailed
the wrong human about someone else's repository.

**When you convert a field to a method, grep every call site in the same
commit.** The compiler will not help you.

### 0.5 `disengage` does not work inside an impl-separated walker ability

```jac
impl MyWalker.start with Root entry {
    disengage;        # E2083: 'disengage' is only valid inside a walker ability
}
```
The compiler does not treat an impl-separated ability as an ability for this
check. If an ability needs `disengage`, write its body **inline** in the walker.
(`plan.jac` does exactly this and says why in a comment.)

### 0.6 Edge fields only bind through constructor parens

```jac
a +>:Surfaced(at_rank=3):+> p;    # ✅
a +>:Surfaced:at_rank=3:+> p;     # ❌ parses fine, silently drops the value (edge default-constructs)
```

---

## 1. Docstring placement — position-dependent, and the error points at the wrong line

Verified all four cases:

| Where | Semicolon | Failure if wrong |
|---|---|---|
| module docstring (first thing in file) | **no `;`** | — |
| archetype body (`obj`/`node`/`walker`/`edge`/`enum`) | **NO `;`** | `E0046: Unexpected token in archetype body` |
| `def` / `can` / `impl` body | **`;` REQUIRED** | `E0002: Missing ';'` reported on the **NEXT** line |
| bare string at module level (not first) | always an error | — |

```jac
node P {
    """A human."""              # no semicolon
    has name: str;
}
def helper(x: int) -> int {
    """Does a thing.""";        # semicolon REQUIRED
    return x;
}
```

Because `E0002` points at the following line, you will hunt in the wrong place.
**Safest habit: use `#` comments above the declaration instead of body
docstrings.** That is what `schema.jac` does throughout.

*(Rule contributed by RESEARCH; independently re-verified here, all four cases.)*

---

## 2. Syntax and parser

1. `pass` is not valid Jac → `E0010`.
2. **Zero-arg defs take NO parens in the declaration**: `def foo -> str { }`, not
   `def foo() -> str { }` (`W3005`). Call sites still write `foo()`.
3. **Walker ability triggers use capital `Root`, no backtick.** `` can x with `root entry ``
   → `E1116: Walker ability trigger must be a node, edge, or Root`. Correct:
   `can x with Root entry { }`.
4. **Graph reads cannot appear inside f-string interpolation.**
   `f"{[p ->:E:->]}"` → `E0001`/`E0004`. Assign to a variable first, then interpolate.
5. `-> Generator` alone warns `W1036` — write `Generator[str, None, None]`.
6. `with urlopen(...) as r { }` fails `E1091`/`E1092` because `urlopen` returns
   `any`. Call it bare and cast the `.read()`. *(GHIDENT — stdlib `urllib` works
   with zero extra dependencies, which is load-bearing for the Jac-% audit.)*
7. Module-level `glob` evaluates **before** archetypes declared later in the
   file. Declare types above any `glob` that constructs them.
8. Concatenating a string with an Exception fails — wrap with `str(e)`.

### On `<` / `>` being parsed as generics
Reported as a cascade risk. **Could not reproduce on 0.34.7** — this passes clean:
```jac
def grade(a: int, b: int) -> str {
    if a < 10 { return "low"; }
    if b > 20 { return "high"; }
    return "mid";
}
```
So bare comparisons are fine in ordinary guards. If you *do* hit a cascade of
distant errors around comparison operators, parenthesizing (`if (a < 10)`) is a
cheap fix — but don't pre-emptively parenthesize everything, it isn't needed.

---

## 3. Graph and types

1. **Untyped edges return `Unknown`.** Declare endpoints — `edge E: Src --> Tgt {}` —
   so every `[src ->:E:->]` infers `Tgt`. Otherwise attribute access only *warns*
   (`W1051`) but passing the node to a typed parameter fails `E1053`.
2. **There is no `A --> B | C` endpoint union.** For a polymorphic edge, give the
   targets a common base node and narrow at the read site:
   `edge Identity: Prospect --> IdentityProfile` + `[p ->:Identity:->[?:GithubProfile]]`.
3. **One edge type declares ONE endpoint pair.** For a second relationship, declare
   a second edge type (that is why the probe ladder uses `Probe: Lane --> SearchProbe`
   *and* `Widened: SearchProbe --> SearchProbe`).
4. `W1051` on edge-field predicates (`[p ->:E:confidence > 0.7:->]`) is
   **COSMETIC ONLY**. Runtime results are correct — verified: it selected 0.91 and
   0.84 and rejected 0.22. `jac check` still passes. **Do not chase it.**
5. Edge-field predicates require the edge type named. `[a ->::attr > 0:->]` is
   duck-typed and blows up on any edge lacking the field.
6. Typed edge filter uses **single** arrows: `[src ->:E:->]`. `[src -->:E:-->]` is a parse error.
7. `[edge n -->]` returns edge *objects* — the way to read edge `has` fields.
8. Non-default `has` fields must be declared **before** any defaulted field (`E2004`).
9. **Parent defaults force child defaults.** If an inherited field has a default,
   every field in the subclass needs one — passes `jac check`, crashes at runtime otherwise.
10. `++>` mirrors its right-hand side: `n = here ++> Todo(...)` makes `n` the Todo node.
11. Node needs a path from `root` to be findable later.

---

## 4. Enums

**Always use the str-backed form** — `enum LaneId: str { A = "A" }`. Members
*are* strings: they compare equal to plain strings, serialize to bare strings on
the wire, and round-trip through the persistent graph.

```jac
p.tier == CompletenessTier.S   # True
p.tier == "S"                  # True
isinstance(p.tier, str)        # True
```
**Never write `.value`** on a typed-base enum member. Verified surviving a full
process restart, on both node fields and edge fields.

### E1110: comparing a variable to the enum literal you just assigned it

```jac
warm.email_source = EmailSource.PROVIDED;
assert warm.email_source == EmailSource.PROVIDED;   # ❌ E1110
# Operator "==" not supported between types "<EmailSource.PROVIDED>" and "<EmailSource.PROVIDED>"
```
The checker narrows the field to the *literal* type after assignment, then
refuses to compare literal-to-literal. Runtime is fine; `jac check` fails.

**Fix — read it back through the graph instead of off the local variable:**
```jac
fetched = [founder ->:HasWarmLead:->][0];
assert fetched.email_source == EmailSource.PROVIDED;   # ✅
```
This is a better assertion anyway: it proves the value round-tripped through
the graph rather than that a local variable still holds what you just put in it.

---

## 5. Testing

1. **Each test gets its OWN isolated root.** A test does **not** see nodes created
   by an earlier test in the same file. Seed inside every test (see
   `seed_demo_graph()` in `schema.test.jac`).
   > This contradicts the `jac-testing` skill, which claims tests share one
   > persisted root. The skill is wrong on 0.34.7 — verified: 6 of 7 tests failed
   > with `IndexError` reading a founder an earlier test had created.
2. `<mod>.test.jac` is an **annex**, not standalone — `schema.test.jac` pairs with
   `schema.jac`, and you run `jac test schema.jac`. It sees the module's
   declarations without imports.
3. Never name a file `test_*.jac` — collides with Python's test-module machinery.
4. All checks are plain `assert`, with an optional message.
5. Tests run in parallel across workers; don't assume ordering.
6. **`test` takes a QUOTED STRING, not an identifier.** `test my_name { }` fails
   with `E0001: Expected '{', got 'NAME'`. Write `test "my name" { }`.
7. **Run the suite with `PYTEST_XDIST_AUTO_NUM_WORKERS=1` or walker tests flake.**
   `jac test` shells out to pytest-xdist with ten workers. Any test that spawns a
   walker on `root` will *intermittently* fail with:
   ```
   WriteConflict: anchor 00000000-0000-0000-0000-000000000000
                  changed concurrently (expected v0, found v1)
   ```
   Ten workers mutating the one root anchor. Measured on the identity suite:
   **29 passed / 1 failed at ten workers, 30 passed / 0 failed at one** — same
   code, same commit. It is not a logic bug and it moves around between runs,
   so it reads as a flaky test at exactly the wrong moment.

   There is no CLI flag, and `PYTEST_ADDOPTS="-p no:xdist"` does **not** work —
   jac injects `-n` unconditionally and pytest then rejects the run with
   `unrecognized arguments: -n`. The env var is the only lever:
   ```bash
   PYTEST_XDIST_AUTO_NUM_WORKERS=1 jac test
   ```
8. **A network-dependent assertion belongs behind a capability guard**, not in a
   mock. `if gh.has_token() { ... }` keeps the suite green on a machine with no
   credentials while still exercising the real path on one that has them.
   Mocking the thing under test here would have hidden a live cross-link bug
   that only a real API response exposed.

---

## 6. Concurrency — verified by RESEARCH, do not re-test

- Walkers **can** be spawned inside `flow` threads.
- Concurrent graph writes are safe under both disjoint parents and a shared
  parent (200/200 writes, none lost).
- True parallelism confirmed: 4 × 0.6s → 0.70s wall clock.
- Creating a node mid-traversal and `visit`ing it works — the widening ladder
  depends on this.

### ⛔ 6.1 `flow` inside a list comprehension RACES on the loop variable

The single worst bug found in this project. It produces wrong results with no
error, and it passes tests most of the time.

```jac
futures = [flow run_lane(s.node, s.lane_id, ...) for s in specs];   # RACY
```

The worker thread can read the comprehension's loop variable **after the loop
has advanced**, so every thread ends up running the **last** item. Measured in
the research orchestrator: all three `LaneResult`s came back `"C"`, lane C's
node carried 3× the narration while lanes A and B sat at zero. On stage that is
three identical browser panels instead of three researchers.

It is a **race**, not a syntax rule — the same code was correct on a cold first
run and wrong on a warmer second run *in the same process*. Repro:

```
[flow show(s.name) for s in specs]  -> ['A','B','C']   usually — wins the race
[flow show(s)      for s in specs]  -> ['C','C','C']   always
[flow show(c[0])   for c in calls]  -> ['C','C','C']   always
```

Bare loop variables and subscripts lose every time. **Attribute reads win often
enough to look correct**, which is why this survives casual testing.

**The fix — launch through a function, and cross the boundary with values only:**

```jac
def launch_lane(lane_jid: str, lane_id: str, phrases_json: str) -> any {
    return flow run_lane(lane_jid, lane_id, phrases_json);   # own param binding
}
futures = [launch_lane(s.lane_jid, s.lane_id, s.phrases_json) for s in specs];
```

- The **node crosses as its `jid`**, re-resolved with `jobj()` in the worker.
  Verified `jobj(jid(n)) is n` → **True** — same node, not a copy, and thread
  writes are visible through the original reference.
- **Lists cross as JSON**, decoded per-thread — which also guarantees no two
  workers share one mutable list.

This is forced as well as chosen: **E1308 rejects objs, bare nodes and bare
lists across a `flow` boundary**, so strings are the only option that both
type-checks and binds eagerly.

**Audit rule:** if your loop variable appears anywhere inside a `flow` call, you
have this bug — it may just be winning the race today.

### 6.2 Reverse-edge reads race against sibling threads

`[probe <-:Probe:<-]` to rediscover a parent works fine single-threaded and
fails intermittently under `flow` (`"SearchProbe is not attached to any Lane"`).
If a walker needs the node it was spawned on, **capture it at entry**
(`self.lane_node = here`) rather than walking edges backwards later.

---

## 7. Server / endpoints

### ⛔ 401 vs 405 tells you WHICH of the two wiring bugs you have

Verified against the live server — memorise this, it saves the whole diagnosis:

| Response to an anonymous `POST /walker/<Name>` | Meaning | Fix |
|---|---|---|
| **405** Method Not Allowed | The name is **not in `main.jac`'s import registry** at all. Not routed. | Add the name to an `import from <mod> { ... }` block in `main.jac` |
| **401** Unauthorized | Registered and routed, but declared plain `walker` instead of `walker:pub`. Plain walkers require a JWT. | Change `walker X` → `walker:pub X` |
| **500** | Routed AND public. It ran and failed on missing required args — this is the healthy state for a bare `{}` probe. | Nothing; pass real args |

Measured on this project, all three states at once:
```
405  /walker/RunResearch          <- module not in main.jac registry
401  /walker/RankAndSelect        <- plain walker, needs :pub
401  /walker/ResolveEmail         <- plain walker, needs :pub
500  /walker/ComposeOutreach      <- correct: walker:pub + registered
```

**Why plain `walker` is not merely an auth annoyance:** an anonymous
`walker:pub` call runs on the **shared guest graph** (`root.shared`), whereas a
plain/`:priv` walker runs on the **caller's own isolated root**. Mixing the two
in one product splits the graph in half — the browsers write to one root and
the voice agent reads from another, and nothing errors. If the demo is
unauthenticated, **every** endpoint on the critical path must be `:pub`.

Verified the shared path is consistent: an anonymous `walker:pub` write
(`SeedRehearsalRun`) was read back by an anonymous `def:pub` read
(`get_run_state`) — same run id, four lanes. So `:pub` end-to-end works.

1. **404 or 405 on a new endpoint = its name is missing from `main.jac`'s import list.**
   Registration tracks the exact *name*, not the module (jaseci-labs/jac#7695).
   Adding a `def:pub` to a module `main.jac` already imports still 405s until the
   new name joins that import. Add the name in the same commit.
2. Import obj/node **types** alongside functions, or you get a server-side
   `NameError` at request time.
3. **No `visit`, no walker.** A `walker:pub` whose only ability is one
   `can run with Root entry { report X; }` should be a `def:pub` with a typed return.
4. Mark an endpoint `async def:pub` when its body uses `await`.
5. Don't pass nodes across the wire — pass `jid(node)` strings.
6. `jac start` needs a `jac.toml` in cwd; boolean flags are hyphenated (`--no-client`).
7. `{"detail": "Invalid anchor id ..."}` 500 after editing node schemas = stale
   persisted anchors. Stop the server, `rm -rf .jac/data/`, restart.
8. Reader responses are cached 60s client-side; a writer call invalidates them.

### ⛔ 7.0a A 401 can also mean a PLAIN `def` elsewhere is shadowing your `def:pub`

The 401/405 table above assumes one declaration per name. If two modules declare
the same function name and only one is `:pub`, the **private one wins the
route** and every anonymous call gets 401 — even though your `def:pub` is
correct, imported, and registered.

Measured while wiring the web client. `bridge.jac` declared
`async def:pub draft_outreach() -> WorkspaceView` (the UI's contract function)
while `outreach.jac` already had `def draft_outreach(...) -> EmailDraft by llm()`
— a plain, private byLLM helper that happened to share the name:

```
POST /function/draft_outreach    -> 401   {"code":"UNAUTHORIZED"}
POST /function/build_personas    -> 200   <- identical shape, no name clash
POST /function/run_signal_search -> 200   <- identical shape, no name clash
```
After renaming the private helper to `draft_outreach_email` and changing nothing
else:
```
POST /function/draft_outreach    -> 200
```

The tell is that **one** endpoint 401s while its identically-declared siblings
return 200. That rules out a missing `:pub` on your own function and points at a
duplicate name elsewhere in the program. `rg -n '\bthe_name\b' *.jac` settles it
in one command. `jac check` is green throughout.

This is the function-level cousin of 8d (archetypes) and 8d-ii (objs): in every
case Jac resolves a duplicate name across modules silently, and differently from
how you would expect. **Grep before you name a new endpoint.**

---

## 7a. ⛔ The client bundle fails on `@jac/wasm_host`, and jac's own suggested fix does not work

Symptom, on a `kind = "web-app"` project: the API is perfect — `graph_health`
200, smoke gate 12/12, WebSocket registered — and `GET /` returns **503**. The
server log carries the real cause, several hundred lines above the request:

```
⚠ Failed to build client bundle
│  Module "@jac/wasm_host" is not installed.
│  Quick fix:  $ jac install --npm @jac/wasm_host
[vite]: Rollup failed to resolve import "@jac/wasm_host"
        from ".jac/client/compiled/main.js"
```

**Do not run the quick fix — the package does not exist.**
`npm view @jac/wasm_host` returns `E404 Not Found`. It is not published on npm;
it ships inside the jac runtime as `runtimelib/wasm_host.cl.jac`.

The real cause is codespace inference. `main.jac` held a `cl { }` block *and* a
plain `import from contracts { ... }`, and the client compiler decided
`contracts` belonged in the client bundle as a **native/wasm** module:

```js
/* .jac/client/compiled/main.js */
import { __na_bind as __jac_na_bind } from "@jac/wasm_host";
const {LaneId, ..., ProspectView} = __jac_na_bind("contracts", [...]);
```

`contracts.jac` was 12 enums and 10 objs with **zero imports** — nothing marked
it server-only, so nothing stopped it being pulled across.

**The fix that works: pin the module by filename — `contracts.jac` →
`contracts.sv.jac`.** A `.sv.jac` variant module keeps its module name, so every
`import from contracts` in the project is unchanged; it is a pure rename.
Measured, same tree otherwise:
```
before:  ⚠ Failed to build client bundle      GET / -> 503
after:   ✔ Client bundle built (3.3s)         GET / -> 200, 4129 bytes
         compiled main.js: no __na_bind, no @jac/wasm_host
```

Two fixes tried first that are **wrong**:

- **`sv import from contracts { ... }`** — reads like server-pinning; it is not.
  Per the `jac-codespaces` skill, `sv import` *from server code* declares a
  **microservice boundary**. It auto-spawned `contracts` as its own service
  process whose gateway tried to bind `0.0.0.0:8000` — the live demo port — and
  died with `[Errno 48] address already in use`, tearing down only its own
  service group. It does make the bundle build, for entirely the wrong reason.
  **Never put `sv import` in a server module in this repo.**
- **An `sv { }` block around the import** — the documented "region of a mixed
  file" override. It parses and typechecks, and it does **not** stop the
  `__na_bind`; the compiled entry was byte-identical on that line.

Only the filename override worked. A minimal sandbox (a pure enums+objs module
imported into a `cl`-bearing `main.jac`) does **not** reproduce it, so do not
expect to bisect this quickly — go straight to `.sv.jac` for any pure enum/obj
module that a client-bearing entry imports.


---

## 8. Environment

**Google OAuth**: `GOOGLE_CLIENT_ID`/`SECRET` in `.env` come from a *different*
OAuth client than the refresh token in `~/.workspace-mcp/credentials/`. A refresh
token is bound to its issuing client, so mixing them returns
`401 unauthorized_client`. Source `client_id` + `client_secret` + `refresh_token`
as one matched set. *(OUTREACH — `svc.jac` already does this; do not hand-roll a
second Google auth path.)*

**GitHub noreply filtering**: block **both** `@users.noreply.github.com` **and**
the bare `noreply@github.com` (GitHub's generic web-UI/merge proxy). The narrow
filter passes four dead addresses per pool and reports them as successes.
*(GHIDENT, measured on a live 15-candidate pool.)*

---

## 8a. ⛔ byLLM: `ANTHROPIC_BASE_URL` in the shell breaks EVERY `by llm()` call

Claude Code agent shells export `ANTHROPIC_BASE_URL` (a local proxy) and
`ANTHROPIC_CUSTOM_HEADERS`. litellm honours them, routes the byLLM call to that
proxy, and the proxy rejects the real Anthropic key from `.env`:

```
LLM AuthenticationError: AnthropicException -
{"type":"error","error":{"type":"authentication_error",
 "message":"Missing or invalid local proxy token"}}
```

The key in `.env` is fine. The environment is what is wrong. Fix — unset before
running anything that calls an LLM:

```bash
unset ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS ANTHROPIC_AUTH_TOKEN
```

Verified both directions on `PlanCampaign`: with the vars set, `source` came
back `fallback:litellm.AuthenticationError...`; with them unset, the same call
returned a real plan. **This affects every `by llm()` in the product** —
`plan.draft_icp`, `research.classify_texts`, `ComposeOutreach`, `KbQuery`,
`OnCallEnd`. If the demo machine has these exported, every LLM feature silently
degrades to its fallback (or fails, where there is no fallback).

Also: jac.toml's `[byllm.model]` does NOT bind the ambient model. A module that
calls `by llm()` must declare its own `glob llm: Model = Model(model_name=...)`.
And the LLM's return `obj` must be declared **locally, not imported** — an
imported obj arrives as a string reference and the call dies with
`'str' object has no attribute 'fields'`.

## 8a2. An unimported edge type in a traversal matches EVERYTHING

If a module writes `[lanes ->:Probe:->]` without importing `Probe`, the hop is
not narrowed - it duck-types across every out-edge. My first end-to-end
instrumentation reported `probes=310 reasoning=310 prospects=310`, three
different traversals returning the identical set, which is impossible. Importing
`Probe`, `Emitted` and `Surfaced` gave the true `probes=3 reasoning=265
prospects=0`.

Import every edge type you traverse, not just the node types. Identical counts
across supposedly-different traversals is the tell.

## 8b. Graph reads that silently under-count

`[root --> [?:ResearchRun]]` returns **0** in this project even when a run
exists, because runs hang off `Founder`, not off `root`. A "count the nodes"
health check must TRAVERSE:

```jac
founders = [root --> [?:Founder]];
runs     = [founders ->:Runs:->];          # anchor may be a LIST of nodes
lanes    = [runs ->:HasLane:->];
```
This bit `graph_health` — it reported `runs: 0, lanes: 0` while `get_run_state`
simultaneously reported a live run with four lanes. Anything that looks like a
"total" is suspect unless it follows the edges. Dedupe multi-source unions by
`jid(n)`, since a prospect can be reachable by several paths.

## 8c. printgraph in tests

`printgraph(root)` works at runtime (verified: renders SearchProbe/Widened) but
throws `NodeAnchor ... is not a valid reference` under `jac test`'s parallel
workers. Demo it in a `jac run`; never assert on it in a test.

## 8d. Archetypes belong to schema.jac ONLY

Declaring a `node` or `edge` locally instead of importing it from `schema.jac`
creates a SECOND archetype with the same name. The types are distinct, but
**edge traversal matches by NAME at runtime**, so `[lane ->:Probe:->]` returns a
mixture of both and reads of a field only one of them has raise at run time.
`jac check` passes on both files, because each module resolves its own
declaration in its own scope. Measured:
```
SearchProbe same type?  False
Probe edge same type?   False
lane.probes() after one probe from each module: 2   <- both, incompatible
```
If you need a node or edge, add it to `schema.jac` — never declare it locally.

## 8d-ii. ⛔ Importing the SAME obj name from two modules SEGFAULTS the process

8d is about archetypes. This is the `obj` analogue, and it is worse: not a
silent mixture but a hard crash, at import time, with `jac check` green.

Found while merging Becky's UI: `contracts.sv.jac` and her `traction/domain.jac`
each declared an `obj ProspectView` and an `obj OutreachDraft`, with different
fields. The natural thing — import each from the module that owns it — kills the
interpreter:

```jac
import from a { ProspectView }   # obj ProspectView { has jid: str; }
import from b { ProspectView }   # obj ProspectView { has id: str; }
```
```
jac check m.jac   ->  m.jac ok [100%]      1 passed        <- green
jac run   m.jac   ->  Segmentation fault at address 0x0
                      aborting due to recursive panic
```

Measured, four variants and two controls, jac 0.34.7 / Darwin arm64:

| case | `jac check` | `jac run` |
|---|---|---|
| import `ProspectView` from **a** only | PASS | ok — `from-contracts` |
| import `ProspectView` from **b** only | PASS | ok — `from-views` |
| import from **a then b** | PASS | **segfault** |
| import from **b then a** | PASS | **segfault** |
| two modules, **different** obj names | PASS | ok — both usable |
| same name from both, **never constructed** | PASS | **segfault** |

Two things in that table matter:

- **Order is irrelevant** — it is not last-one-wins shadowing, it is a crash
  either way.
- **You do not have to USE the type.** The last row imports both names and
  constructs neither, and still dies. The trigger is the duplicate NAME in one
  module's import list, at load time. You cannot reach for it defensively and
  "just not call it".

**The rule: never let one module import two same-named objs.** Import the other
symbols explicitly and let the ambiguous name come from exactly one place. This
is why `main.jac` takes `ProspectView`/`OutreachDraft` from `contracts` (which
`feed.jac` needs) and only `WorkspaceView` from `views.jac`, even though
`views.jac` declares a `ProspectView` too — importing both would have
segfaulted the server on boot, after a clean `jac check`.

Repro kept minimal on purpose: three files, no graph, no server.

## 8e. ⛔ ONE PROCESS AT A TIME — the graph store is shared and unsynchronised

Every `jac run` and `jac start` in a project directory reads and writes the SAME
`.jac/data` anchor store. Several people (or agents) working in one checkout
will silently stomp each other's graph.

### 8e-0. `ps` CANNOT tell you which data dir a process holds — check its CWD

`anchor_store.db` resolves **relative to the process's working directory**, so
two processes with byte-identical command lines can be on completely different
stores. A `ps` line is therefore worthless for diagnosing store contention:

```
51903  jac start main.jac --no-client -p 8877     <- looks like the repo
73494  jac start main.jac --no-client -p 8000     <- looks like the repo

$ lsof -a -p 51903 -d cwd   ->  /private/tmp/traction-demo        # ISOLATED
$ lsof -a -p 73494 -d cwd   ->  /Users/elijahumana/jachacks-...   # the repo
```

Only the second is on the repo's store. **Two people independently read that
same `ps` output as "two servers fighting over one store" within a minute of
each other, and both were wrong** — one was a correctly-isolated instance.

Use these, in this order:
```bash
lsof -a -p <pid> -d cwd                      # which directory this pid is in
lsof <repo>/.jac/data/anchor_store.db        # who ACTUALLY holds the store
pgrep -f 'jac (run|test)'                    # then check each one's cwd
```
A process that merely *looks* like it is in the repo is not evidence. The file
handle is.

Corollary for background work: a command that times out and is backgrounded
**keeps running**, holding the store long after the shell that started it has
moved on. Check by CWD before concluding you are clean.

Observed, back-to-back in one shell with nothing in between:
```
rm -rf .jac
jac run lane_w_proof.jac   ->  LANE_W_OK=True, real prospect written   ✅
jac run _inspect.jac       ->  that prospect GONE; a different founder
                               and three unrelated fixture prospects,
                               each duplicated 3x
```
An earlier inspection found **7 Founder nodes**, six identical, none created by
the inspecting run. No product module has a `with entry` block, so nothing
seeds on import — the only explanation that fits is concurrent writers.

**Consequences:**
- `rm -rf .jac` deletes a store another process is mid-write on.
- Counts from any instrumentation are untrustworthy while others are running.
- This is a strong candidate for the unrecoverable
  `'JacScaleUserManager' object has no attribute '_lock'` 500s: N processes
  against one SQLite anchor store is exactly that shape.

**RUNBOOK RULE: during setup and during the demo, exactly one process may touch
the graph.** Stop every other `jac run` / `jac start` in the directory first.
Seeding with a proof script and then demoing through the server is only safe if
the seed has finished and nothing else is live.

If you need to work in parallel, take a separate checkout — the store is
per-directory, so different working copies are isolated.

### The isolated checkout is the only trustworthy environment — and it also fixes the server

```bash
git clone /Users/elijahumana/jachacks-traction /tmp/x
cp /Users/elijahumana/jachacks-traction/.env /tmp/x/
cp /Users/elijahumana/jachacks-traction/.linkedin_cookies*.json /tmp/x/   # if scraping
cd /tmp/x && set -a && . ./.env && set +a
unset ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS ANTHROPIC_AUTH_TOKEN
rm -rf .jac
tail -f /dev/null | jac start main.jac --no-client --port 8123   # distinct port
```

**Measured, same code and same config, only the contention removed — 12 requests
over 6 rounds:**
```
round 1: graph_health 200 {"founders":0,"runs":0,"lanes":0}   walker 200 ok
round 6: graph_health 200 {"founders":1,"runs":5,"lanes":20}  walker 200 ok
```
Zero `_lock` errors, zero 500s, and the graph moves correctly every round. In the
shared directory the same sequence dies permanently with
`'JacScaleUserManager' object has no attribute '_lock'`.

**The two faults compose:** contention corrupts the guest root → the runtime calls
`reset_root` to heal → `reset_root` needs `_lock`, which `JacScaleUserManager.postinit`
never created → permanently unrecoverable. Contention is the trigger; the missing
`_lock` is why it never recovers. This is also why a restart preserving `.jac/data`
stays broken while `--clean` fixes it.

Notes that cost real time:
- `tail -f /dev/null | jac start` is required. `< /dev/null` lets it exit immediately,
  and **`sleep infinity` does not exist on macOS** (GNU extension) — the pipe closes
  and the server dies on launch.
- A fresh checkout takes **~120 s** to start; it is compiling the project. Don't
  declare it dead early.
- Use a distinct `--port` so a stray server elsewhere can't shadow you.

### 8e-i. 🔴 `JAC_DATA_PATH` DOES NOT ISOLATE A DATA DIR — it manufactures the bug

The obvious way to give a server its own store is `JAC_DATA_PATH`. **Do not.** In
jaclang 0.34.7 it moves two of the three files and not the third:

| file | path resolution |
|---|---|
| `main.db` | honours `JAC_DATA_PATH` — `runtimelib/impl/server.impl.jac:16` |
| `users.db` | honours `JAC_DATA_PATH` — `scale/identity/impl/user_manager.impl.jac:37` |
| **`anchor_store.db`** | **ignores it** — hard-coded relative `'.jac/data/anchor_store.db'`, `scale/config/impl/config_loader.impl.jac:218`. Only a `database.shelf_db_path` key in jac.toml can move it; there is no env override. |

So `JAC_DATA_PATH=/tmp/foo jac start` puts `users.db` under `/tmp/foo/.jac/data`
and leaves `anchor_store.db` at `$CWD/.jac/data`. The guest root is then recorded
in one store and absent from the other — **which is exactly the divergence that
produces the permanent `_lock` 500s.** You would be hand-building the failure you
were trying to isolate away from, and it would look like the bug appearing
spontaneously in a "clean" environment.

`anchor_store.db` resolves relative to the working directory, so **the only thing
that isolates a Jac server is its own DIRECTORY.** That is why the isolated
checkout above works, and it is what `ops/serve.sh` automates.

### 8e-ii-b. The WebSocket also survives a `_lock` event — so the dashboard shows nothing wrong

During a `_lock` failure the socket still connects, still accepts frames, and
still broadcasts to every connected client, while every HTTP endpoint 500s.
Combined with `/healthz` staying green, the dashboard's whole liveness surface
looks healthy: socket up, health up, panels frozen.

That is indistinguishable from "nobody is running the pump" — which is a real
and separate condition (`docs/FRONTEND_INTEGRATION.md` §4.4: exactly one client
must poll `feed_since` and forward batches into the socket). So the same symptom
has two very different causes, and the socket cannot tell you which.

**The only way to tell them apart is to POST a function endpoint yourself.**
`ops/serve.sh --status` does exactly this and prints `graph_health` next to
`healthz`. If `graph_health` 500s it is the `_lock` failure; if it returns 200
while panels are frozen, the pump is missing.

### 8e-ii. `/healthz` returns 200 for the entire duration of the failure

Caught live by FRONTEND with timestamps: the server served ~10 requests, another
process touched `.jac/data`, and from then on every function endpoint 500'd —
while `/healthz` kept answering `{"status":"ok"}`, 6/6.

**Anything that gates on `/healthz` is worthless for this failure**, including a
start script's wait-for-health loop: it declares a dead server up and hands it to
the dashboard, which then just looks frozen. Gate on a real endpoint instead —
`POST /function/graph_health`, which traverses `founders → Runs → HasLane` and so
proves the persisted graph is actually readable. `ops/restart.sh` and
`ops/serve.sh --status` both do this; neither trusts `/healthz`.

### 8e-iii. The `_lock` defect is unconditional — no setting can turn it off

Worth stating because two plausible config theories were chased and both are dead:

- **`[scale.websocket]` is not involved.** A/B, two full copies of the repo, fresh
  data, 60 anonymous POSTs each: `OK=60 FAIL=0` **both with and without the
  block**. The copy without it still logged the scale Redis warning 63 times and
  still registered `/ws/walker/LiveFeed`. `jac0core/runtime.jac:85 _scale_provider`
  is a bare `try { import jaclang.scale.plugin } except ImportError` with no
  jac.toml gate, and scale ships inside the binary, so it loads either way.
- **`REDIS_URL` is not involved.** It is set in the shell env and every start logs
  `Redis connection failed: 'NoneType' object has no attribute 'from_url'` — but
  that warning was present 63 times during the `OK=60 FAIL=0` run. A condition
  present throughout success is not the cause of failure. `JacScaleUserManager.postinit`
  has no Redis branch at all, and no branch of it sets `_lock`.

`_lock` is set in exactly one place, `UserManager.postinit`
(`runtimelib/impl/server.impl.jac:12`), which the scale subclass overrides and
never calls. So the attribute is **always** absent, in every environment,
including the clean isolated checkout that runs green forever — it simply is
never read there, because the only reader is `reset_root`, and `reset_root` only
fires when the guest root anchor is missing. A missing attribute costs nothing
until something reads it.

The practical consequence: **stop looking for a setting that fixes this.** There
isn't one. The only levers are preventing the divergence (one process per data
dir — `ops/serve.sh`) and repairing it before serving (`ops/restart.sh`'s
preflight, which drops `users.db` and keeps the graph).

It is also doubly broken: even with `_lock` present, `reset_root` does
`SELECT 1 FROM users` against `main.db`, while scale keeps identities in
`users.db` via `SqliteIdentityStorage`. The guest heal path cannot work under
scale at all.

## 9. Stale state

`jac clean --all --force` (or `rm -rf .jac/`) when you see
`NodeAnchor ... is not a valid reference!` — that is recompiled archetypes
meeting persisted anchors from an older shape. `jac run` persists graph state to
`.jac/` in the cwd, so re-running a script duplicates its nodes.
