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

## CONFIRMED: with the spawn corrected, the chain RUNS

Spawned on the Founder, `RunResearch` does the whole fan-out. Graph census per
stage, so every number below was read back off the graph rather than reported by
the walker that claimed to have written it:

```
[2] RunResearch   prospects=20 (+20)  evidence=20  reasoning=112  identities=17  threads=37
[3] Lane W        prospects=21 (+1)   evidence=22  reasoning=119  identities=18  with_email=1
```

Four lanes, one run, live view URLs for the three browser lanes:

```
lane A  found 0   probes 5   live_url present
lane B  found 3   probes 5   live_url present
lane C  found 0   probes 6   live_url present
lane D  found 17  probes 9   (no browser, by design)
unique_prospects 20   converged 0
```

Lane W in the same run, on the real warm lead:

```
Becky Zhu  preferred='Becky'  Program Manager @Oracle
linkedin.com/in/xingzhi-zhu  xingzhizhu6@gmail.com [PROVIDED, 1.0]
tier A   lane state=done   live_url=yes
```

**The 15-minute silence in the earlier run was slowness, not a hang.** The
LinkedIn lanes completed. That correction matters: I recorded it as "unknown"
rather than guessing, and the guess would have been wrong.

---

## FINDING 4 — Lane A and Lane C surfaced ZERO, in production

```
lane A  found 0  probes_run 5   failure: ''
lane C  found 0  probes_run 6   failure: ''
```

Five and six probes each, no failure reported, nothing found. This is the
class-selector rot measured directly earlier (`LANE_A_SELECTORS_ALIVE=False`,
containers 0 on a page carrying 11 profile anchors) now visible end to end. Two
of the four lanes contribute nothing, and `converged 0` follows from it — with
only Lane B and Lane D producing, nobody is found from two directions.

`failure: ''` on both is the tell: the lanes do not consider themselves broken.
The honest-narration fix already landed for Lane A's comment path says so out
loud now, but the yield is still zero until the selectors themselves are
replaced.

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

`ResolveEmail` and everything downstream of it. Stage 4 was still grinding
through the GitHub email waterfall for 20 prospects when this was written —
that path is throttled to 30 search calls a minute by design, so it is slow
rather than stuck. `CrossLinkToLinkedIn` reported honestly while it went
(*"no LinkedIn profile was harvested for this handle"*).

**ComposeOutreach with real evidence is therefore still unproven end to end**,
and so is the `normalize()` punctuation fix, which I patched in this clone only.
I am not claiming that fix works — only that it is necessary. Nothing here
retires that question.

## Demo timing, measured

Research reached Lane W at roughly **twelve minutes**, and stage 4 had not
finished at twenty. The judging slot is four minutes. Pre-warming was already
the plan; the magnitude is now measured rather than assumed.

## A defect in my own layer, found by running it

The CDP event buffer prints one line per dropped event once it passes 2000:

```
[cdp] event buffer full at 2000; dropped 1 oldest (631 total)
```

Announcing the drop is right — a silent cap would be worse. Announcing it 631
times is not. It should log on a threshold, not per drop. Mine to fix.

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
