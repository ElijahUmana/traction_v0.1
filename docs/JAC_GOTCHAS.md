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

## 8e. ⛔ ONE PROCESS AT A TIME — the graph store is shared and unsynchronised

Every `jac run` and `jac start` in a project directory reads and writes the SAME
`.jac/data` anchor store. Several people (or agents) working in one checkout
will silently stomp each other's graph.

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

## 9. Stale state

`jac clean --all --force` (or `rm -rf .jac/`) when you see
`NodeAnchor ... is not a valid reference!` — that is recompiled archetypes
meeting persisted anchors from an older shape. `jac run` persists graph state to
`.jac/` in the cwd, so re-running a script duplicates its nodes.
