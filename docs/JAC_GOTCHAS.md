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

### 0.1 ⛔ NEVER name a walker field `reports`

`has reports: list[T] = [];` **silently collects nothing.** The name collides
with the walker's built-in report channel. No error, no warning, empty list.

```jac
walker WA { has found: list[str] = [];    ... self.found.append(here.name);   }  # ✅ ['a','b']
walker WB { has reports: list[str] = [];  ... self.reports.append(here.name); }  # ❌ []  <- silent
walker WC { ...                                report here.name;             }  # ✅ ['a','b']
```

Verified output:
```
WA custom-field  -> ['a', 'b']
WB named-reports -> []          <- appends go nowhere
WC report-stmt   -> ['a', 'b']
```

**Do one of these instead:**
- use the built-in `report x;` statement and read `result.reports`, or
- name your typed accumulator anything else — `found`, `picked`, `collected`.

> Supersedes the earlier team guidance to declare `has reports: list[T] = [];`
> as the typed report channel. The `= []` half of that advice is right (see 0.2);
> the *name* is not.

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

### 0.4 Edge fields only bind through constructor parens

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

## 9. Stale state

`jac clean --all --force` (or `rm -rf .jac/`) when you see
`NodeAnchor ... is not a valid reference!` — that is recompiled archetypes
meeting persisted anchors from an older shape. `jac run` persists graph state to
`.jac/` in the cwd, so re-running a script duplicates its nodes.
