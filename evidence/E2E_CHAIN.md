# End-to-end chain: what is proven, what is not

Run in an isolated checkout of `1de0577` (`git clone` → `/tmp/traction-e2e`, own
`.env`, own `.jac/data`, `env -u REDIS_URL`). Nothing was run in the shared repo.
No email was sent and no call was placed.

Script: `e2e_chain.jac` — prints a graph census after every stage, because the
failure mode we hit repeatedly is a stage reporting success without writing
anything. **A count that does not change is a failed stage no matter what it
returned.**

---

## FINDING 1 — the dashboard's Go button is a silent no-op

`RunResearch` spawned on `root` does nothing at all:

```
[2] RunResearch — lanes fan out with flow/wait
    reports: []
    GRAPH  prospects=0  evidence=0  reasoning=0  identities=0  with_email=0
  runs                   0
  lanes                  0
  wall clock             0.0s
```

Zero seconds. No browser opened, no `ResearchRun` created, no `Lane` made.

**Cause:**

```jac
walker:pub RunResearch {
    can start with Founder entry;     // NOT Root
```

`POST /walker/<name>` spawns on **root**. `RunResearch` only declares a `Founder`
entry, so no ability fires: HTTP 200, empty reports, untouched graph. This is the
identical trap already fixed on `LaneW` by dropping `:pub`. `RunResearch` genuinely
needs the HTTP route, so it needs a `with Root entry` that locates the Founder —
as of `1de0577` that is not on `origin/main`.

Correct internal spawn is `RunResearch(...) spawn founder`.

### The cascade this causes

```
RunResearch no-op → no ResearchRun → no Lane → Lane W has nothing to attach to
                  → no evidence    → ResolveEmail drops
                                   → ComposeOutreach refuses
```

So "no email" has **two independent causes stacked**. Fixing only the grounding
bug leaves an empty graph; fixing only this leaves the grounding bug.

---

## FINDING 2 — Lane W is not wired into the orchestrator

`RunResearch` contains no reference to `LaneW`. The warm lead — the one prospect
that is emailed, called and booked — is never researched by the joined-up chain.
`e2e_chain.jac` spawns it explicitly as a workaround.

---

## FINDING 3 — the safety rails work; what is broken is upstream of them

Both gates behaved correctly on an empty graph, in their own words:

- `ResolveEmail` — *"no GitHub identity was cross-linked, so there is nothing to
  resolve an address from"*
- `ComposeOutreach` — *"the graph holds nothing this person actually wrote and no
  GitHub artifact they built, so any email would be generic. A headline on its own
  does not count — it is a job title, not something they said."*

Neither invented anything to fill a gap. That is the behaviour we want.

---

## WHAT IS CONFIRMED WORKING

**Lane D, live against the GitHub API** — 17 candidates, 6 search calls, 0 errors,
and a widening ladder that narrates its own reasoning rather than reporting an
empty result:

```
[pivot] Nothing usable pushed since 2026-07-01 … That angle is dry - widening
        the window to 2026-06-01 rather than declaring the market empty.
[hit]   16 people opened issues in the last two months saying "manual research"
        - stated in their own words, publicly, with a date.
[rank]  Lane D surfaced 17 candidates … and rejected 4 accounts that matched the
        query but showed no sign of a person maintaining them.
```

It also rejected four accounts with an honest reason (*"no display name, no bio,
no followers and few repos — an account with no signal that a person maintains
it"*) rather than padding the count.

**PlanCampaign** — resolves the ICP from the graph correctly.

---

## NOT PROVEN IN THIS RUN

The LinkedIn lanes (A/B/C), Lane W, cross-linking, and ComposeOutreach-with-real-
evidence. After the spawn fix, `RunResearch` ran Lane D to completion and then sat
in the LinkedIn lanes for **15+ minutes without further output** before this
artifact was written. That is not a pass or a fail — it is unfinished, and it is
recorded as unfinished.

**It is also a demo-timing risk in its own right.** The judging slot is four
minutes. A research phase that takes fifteen-plus minutes cannot be shown live and
must be pre-warmed, which the plan already anticipates — but the magnitude should
be measured rather than assumed.

---

## Reproduce

```bash
git clone /Users/elijahumana/jachacks-traction /tmp/traction-e2e
cp /Users/elijahumana/jachacks-traction/.env /tmp/traction-e2e/.env
cd /tmp/traction-e2e && env -u REDIS_URL jac run e2e_chain.jac
```

Isolated checkout, so it needs no freeze and touches no shared state.

## One local-only edit

`normalize()` in `outreach.jac` was patched **in the clone only** to strip
punctuation, to establish whether the grounding bug is the sole blocker on the
warm-lead email. Not pushed; OUTREACH owns that file and has the diff. The
question it was meant to answer is still open, because the chain did not reach
ComposeOutreach with evidence.
