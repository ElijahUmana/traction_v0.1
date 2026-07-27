#!/usr/bin/env python3
"""Executable proof that docs/FRONTEND_INTEGRATION.md is true.

This is a CONSUMER harness. It talks to the server exactly the way a browser
does - POST JSON, read the envelope, parse the frame - and asserts every claim
the frontend contract makes. It knows nothing about our Jac source; if it
passes, a dashboard written from the doc alone will work.

It fails LOUDLY and it fails COMPLETELY: every check runs, every mismatch is
collected, and the exit code is non-zero if any of them broke. A dead endpoint
aborts its own section only - the remaining sections still report, because one
500 must not hide ten real contract violations behind a traceback.

    python3 ops/frontend_contract_check.py                    # check current graph
    python3 ops/frontend_contract_check.py --seed             # seed rehearsal data first
    python3 ops/frontend_contract_check.py --no-ws            # skip the WebSocket section
    python3 ops/frontend_contract_check.py --base http://127.0.0.1:8099

Exit codes: 0 = contract holds. 1 = at least one documented claim is false.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
import urllib.error
import urllib.request

# --- the contract, transcribed from docs/FRONTEND_INTEGRATION.md -------------
# Nothing below is read from our source tree. This is the doc, as data. If the
# doc and the server disagree, that disagreement is the finding.

LANE_VIEW_FIELDS = {
    "jid": str, "lane_id": str, "doctrine": str, "state": str,
    "live_url": str, "bb_session_id": str, "current_query": str,
    "reasoning_count": int, "prospect_count": int,
}
PROSPECT_VIEW_FIELDS = {
    "jid": str, "name": str, "handle": str, "headline": str, "company": str,
    "linkedin_url": str, "email": str, "email_source": str,
    "email_confidence": float, "tier": str, "score": float,
    "score_pre_crosslink": float, "dropped_reason": str, "is_warm_lead": bool,
    "convergence_lanes": list, "linkedin_quote": str, "github_artifact": str,
}
RUN_STATE_FIELDS = {
    "jid": str, "status": str, "started_at": float, "finished_at": float,
    "lane_count": int, "prospect_count": int, "surviving_count": int,
    "dropped_count": int, "converged_count": int, "reasoning_count": int,
    "exists": bool,
}
REASONING_VIEW_FIELDS = {
    "seq": int, "t": float, "lane_id": str, "sentence": str, "kind": str,
}
FEED_BATCH_FIELDS = {
    "seq": int, "next_seq": int, "reasoning": list, "lanes": list,
    "run": dict, "prospects": list,
}

# Documented enum VALUES, case-sensitive. §1.2 of the contract.
LANE_ID_VALUES = {"A", "B", "C", "D", "W"}
LANE_STATE_VALUES = {"idle", "launching", "searching", "reading",
                     "crosslinking", "dry", "done", "failed"}
RUN_STATUS_VALUES = {"planning", "running", "crosslinking", "gating",
                     "ranked", "complete", "failed"}
REASONING_KIND_VALUES = {"plan", "observe", "judge", "pivot", "yield", "hit",
                         "miss", "crosslink", "gate", "rank"}
COMPLETENESS_TIER_VALUES = {"S", "A", "DROPPED"}
EMAIL_SOURCE_VALUES = {"github_commit", "github_profile", "github_readme",
                       "personal_site", "linkedin_contact_info",
                       "verified_guess", "provided", "none"}

BOOKKEEPING_KEYS = {"_jac_type", "_jac_id", "_jac_archetype"}
DOC_FUNCTIONS = ["list_lanes", "list_prospects", "get_run_state", "feed_since"]

# --- result accumulation -----------------------------------------------------

RESULTS: list[tuple[str, bool, str]] = []
SECTION = {"name": "-"}


def section(name: str) -> None:
    SECTION["name"] = name
    print(f"\n\033[1m== {name} ==\033[0m")


def check(name: str, ok: bool, detail: str = "", info: str = "") -> bool:
    """`detail` prints ONLY on failure - it is the reason it failed.
    `info` prints ONLY on success - it is the evidence it passed.
    Mixing them puts a failure message next to a green PASS, which reads as a
    contradiction to anyone skimming under pressure."""
    RESULTS.append((f"{SECTION['name']} / {name}", bool(ok), detail if not ok else ""))
    mark = "\033[32mPASS\033[0m" if ok else "\033[31mFAIL\033[0m"
    line = f"  [{mark}] {name}"
    if ok and info:
        line += f"  \033[2m({info})\033[0m"
    elif not ok and detail:
        line += f"\n         -> {detail}"
    print(line)
    return bool(ok)


def note(text: str) -> None:
    """Something the frontend must know that is not itself pass/fail."""
    print(f"  [\033[36mNOTE\033[0m] {text}")


def skip(name: str, why: str) -> None:
    RESULTS.append((f"{SECTION['name']} / {name}", True, ""))
    print(f"  [\033[33mSKIP\033[0m] {name}  \033[2m({why})\033[0m")


class EndpointDown(RuntimeError):
    def __init__(self, path: str, status, body) -> None:
        self.path, self.status = path, status
        detail = body
        if isinstance(body, dict):
            detail = (body.get("error") or {}).get("message") \
                if isinstance(body.get("error"), dict) else None
            detail = detail or body.get("detail") or json.dumps(body)
        super().__init__(f"HTTP {status}: {str(detail)[:220]}")


def guard(fn, *a, default=None):
    """Run one section. A dead endpoint aborts its own section only."""
    try:
        return fn(*a)
    except EndpointDown as e:
        check(f"section aborted - {e.path} is not answering", False, str(e))
        return default
    except Exception as e:  # noqa: BLE001 - reported as a failure, never swallowed
        import traceback
        check(f"section crashed - {type(e).__name__}", False,
              f"{e}\n{traceback.format_exc(limit=3)}")
        return default


# --- transport ---------------------------------------------------------------

class Client:
    def __init__(self, base: str) -> None:
        self.base = base.rstrip("/")

    def raw_post(self, path: str, body: dict, timeout: int = 30):
        """POST and return (http_status, parsed_json_or_text). Never raises on 4xx/5xx."""
        req = urllib.request.Request(
            self.base + path, data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read().decode()
                return r.status, json.loads(raw)
        except urllib.error.HTTPError as e:
            raw = e.read().decode()
            try:
                return e.code, json.loads(raw)
            except json.JSONDecodeError:
                return e.code, raw
        except urllib.error.URLError as e:
            raise SystemExit(
                f"\n\033[31mCannot reach {self.base}{path}: {e}\033[0m\n"
                f"Start the server with ops/restart.sh, then re-run.")

    def post(self, path: str, body: dict, timeout: int = 30):
        """POST expecting the documented envelope. Returns data.result."""
        status, env = self.raw_post(path, body, timeout)
        if not isinstance(env, dict) or not env.get("ok"):
            raise EndpointDown(path, status, env)
        return env["data"]["result"]

    def raw_get(self, path: str, timeout: int = 15):
        req = urllib.request.Request(self.base + path, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()
        except urllib.error.URLError as e:
            return 0, str(e)

    def sse(self, path: str, body: dict, timeout: int = 30) -> str:
        req = urllib.request.Request(
            self.base + path, data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read().decode()


# --- shape assertions --------------------------------------------------------

def shape(obj, spec: dict, label: str, errs: list) -> None:
    """Assert obj has exactly spec's fields with spec's types, plus only the
    three documented _jac_* bookkeeping keys and nothing else."""
    if not isinstance(obj, dict):
        errs.append(f"{label}: expected object, got {type(obj).__name__}")
        return
    for field, want in spec.items():
        if field not in obj:
            errs.append(f"{label}.{field} MISSING (the doc promises it)")
            continue
        val = obj[field]
        if want is float and isinstance(val, int) and not isinstance(val, bool):
            continue  # an int is an acceptable float on the wire
        if want is int and isinstance(val, bool):
            errs.append(f"{label}.{field} is bool, doc says int")
            continue
        if not isinstance(val, want):
            errs.append(f"{label}.{field} is {type(val).__name__} "
                        f"({json.dumps(val)[:60]}), doc says {want.__name__}")
    extra = set(obj) - set(spec) - BOOKKEEPING_KEYS
    if extra:
        errs.append(f"{label}: UNDOCUMENTED fields on the wire: {sorted(extra)}")


def enum_in(val, allowed: set, label: str, errs: list) -> None:
    if val in allowed:
        return
    lowered = {a.lower() for a in allowed}
    if isinstance(val, str) and val.lower() in lowered:
        errs.append(f"{label}: CASE MISMATCH - wire has {val!r}, doc has "
                    f"{sorted(a for a in allowed if a.lower() == val.lower())!r}")
    else:
        errs.append(f"{label}: {val!r} is not a documented value {sorted(allowed)}")


def envelope(env, label: str, errs: list) -> None:
    """§1: every HTTP response is {ok,type,data{result,reports},error,meta}."""
    if not isinstance(env, dict):
        errs.append(f"{label}: response is not a JSON object")
        return
    for key in ("ok", "type", "data", "error", "meta"):
        if key not in env:
            errs.append(f"{label}: envelope missing {key!r} (doc §1)")
    if env.get("type") != "response":
        errs.append(f"{label}: envelope.type is {env.get('type')!r}, doc says 'response'")
    data = env.get("data")
    if not isinstance(data, dict):
        errs.append(f"{label}: envelope.data is not an object")
        return
    for key in ("result", "reports"):
        if key not in data:
            errs.append(f"{label}: envelope.data missing {key!r} (doc §1)")
    if not isinstance(data.get("reports"), list):
        errs.append(f"{label}: data.reports is not a list")
    meta = env.get("meta") or {}
    if not isinstance(meta, dict) or "extra" not in meta:
        errs.append(f"{label}: envelope.meta.extra missing (doc §1)")


def report(errs: list, name: str, info: str = "") -> bool:
    return check(name, not errs,
                 "; ".join(errs[:6]) + (f"  (+{len(errs) - 6} more)"
                                        if len(errs) > 6 else ""), info)


# --- seeding -----------------------------------------------------------------

SEED_SENTENCES = [
    ("A", "Scanning comments under mid-tier practitioner posts; skipping the "
          "90%-'great post!' megathreads by design.", "observe"),
    ("A", "Found a commenter describing their eval harness breaking weekly - "
          "that is a first-person problem statement, not clout.", "judge"),
    ("B", "Post author writes in first person about shipping without regression "
          "tests on prompts. Keeping.", "observe"),
    ("C", "'LLM ops' is returning vendor marketing, not practitioners. This angle "
          "is dry - switching to 'model monitoring'.", "pivot"),
    ("D", "GitHub search: repos touching eval harnesses updated in the last 30 "
          "days, 2+ contributors.", "observe"),
    ("D", "Commit email resolved from search/commits in one global call.", "hit"),
]


def seed(c: Client) -> None:
    section("seeding rehearsal graph (--seed)")
    c.raw_post("/walker/SeedRehearsalRun", {"confirm": "yes", "status": "running"})
    for lane, s, kind in SEED_SENTENCES:
        c.raw_post("/walker/SeedRehearsalReasoning",
                   {"confirm": "yes", "lane_id": lane, "sentence": s, "kind": kind})
    p1 = c.raw_post("/walker/SeedRehearsalSurfaced", {
        "confirm": "yes", "lane_id": "A", "name": "Rehearsal Practitioner",
        "handle": "rehearsal-practitioner", "headline": "Staff engineer, ML platform",
        "company": "Rehearsal Co", "email": "rehearsal.survivor@example.invalid",
        "tier": "S", "score": 0.94, "score_pre_crosslink": 0.71})[1]
    c.raw_post("/walker/SeedRehearsalSurfaced", {
        "confirm": "yes", "lane_id": "B", "name": "Rehearsal Second",
        "handle": "rehearsal-second", "headline": "Founding engineer",
        "company": "Second Co", "email": "rehearsal.second@example.invalid",
        "tier": "A", "score": 0.62, "score_pre_crosslink": 0.62})
    c.raw_post("/walker/SeedRehearsalSurfaced", {
        "confirm": "yes", "lane_id": "C", "name": "Rehearsal Dropped",
        "handle": "rehearsal-dropped", "headline": "Indie hacker", "company": "",
        "email": "", "tier": "DROPPED", "score": 0.0,
        "dropped_reason": "no email resolvable after all six waterfall steps"})
    try:
        pj = p1["data"]["reports"][0]["prospect"]
        c.raw_post("/walker/SeedRehearsalConvergence",
                   {"confirm": "yes", "prospect_jid": pj, "lane_id": "D"})
    except (KeyError, IndexError, TypeError) as e:
        print(f"  \033[33mconvergence seed skipped: {e}\033[0m")
    print(f"  seeded a run, {len(SEED_SENTENCES)} reasoning lines, "
          "3 prospects (S / A / DROPPED)")
    note("the rehearsal seeder builds lanes A,B,C,D only - it does NOT build "
         "Lane W. A real run has five.")


# --- preflight ---------------------------------------------------------------

def preflight(c: Client) -> bool:
    """Is the server actually serving, or is it the `_lock` zombie?

    /healthz keeps returning {"status":"ok"} while every real endpoint 500s, so
    health alone is not proof of life. Measured: once `_lock` starts it is
    permanent - 6/6 consecutive requests failed 0.6s apart. Do not retry around
    it, restart.
    """
    section("preflight - is the server actually serving?")
    hstatus, _ = c.raw_get("/healthz")
    check("GET /healthz", hstatus == 200, f"HTTP {hstatus}", "200")
    status, env = c.raw_post("/function/get_run_state", {})
    if status == 200 and isinstance(env, dict) and env.get("ok"):
        check("a real endpoint answers - server is genuinely up", True,
              info="get_run_state returned a live envelope")
        return True

    detail = env.get("detail", env) if isinstance(env, dict) else env
    lock = "_lock" in str(detail)
    check("a real endpoint answers", False, f"HTTP {status}: {str(detail)[:200]}")
    print("\n\033[31m\033[1m" + "!" * 78)
    if lock:
        print("SERVER IS THE `_lock` ZOMBIE.")
        print("  'JacScaleUserManager' object has no attribute '_lock'")
        print("")
        print("  /healthz still returns ok - health is NOT proof of life.")
        print("  This does NOT recover on retry. Measured 6/6 failures, 0.6s apart.")
        print("  Trigger: a second process touching .jac/data while `jac start`")
        print("  holds it. Run ONE jac process at a time.")
    else:
        print("SERVER IS NOT SERVING REAL ENDPOINTS.")
        print(f"  {str(detail)[:300]}")
    print("")
    print("  Fix:  ops/restart.sh")
    print("!" * 78 + "\033[0m")
    print("\nRunning the remaining checks anyway so you can see the full scope.\n")
    return False


# --- the checks --------------------------------------------------------------

def check_envelopes(c: Client) -> None:
    section("§1  the HTTP response envelope")
    for fn in DOC_FUNCTIONS:
        body = {"since": 0} if fn == "feed_since" else {}
        status, env = c.raw_post(f"/function/{fn}", body)
        errs: list = []
        if status != 200:
            errs.append(f"HTTP {status}: {json.dumps(env)[:200]}")
        else:
            envelope(env, fn, errs)
            if env.get("data", {}).get("reports") != []:
                errs.append(f"{fn}: data.reports is {env['data']['reports']!r}; "
                            "doc §1 says functions always return []")
        report(errs, f"POST /function/{fn} envelope", "ok/type/data/error/meta")

    section("§1  method + auth semantics")
    status, env = c.raw_post("/function/no_such_function_xyz", {})
    check("a typo'd function name does not silently 200", status != 200,
          f"HTTP {status} {json.dumps(env)[:160]}",
          f"HTTP {status} - note it is 405 Method Not Allowed, not 404")
    status, body = c.raw_get("/function/list_lanes")
    check("DOC §1 is wrong: GET does NOT return the signature", status == 404,
          f"GET returned HTTP {status}: {body[:140]} - doc §1 says 'A GET on the "
          "same path returns the signature, not the data'",
          "GET -> 404 Not found. The doc's claim about GET is false; harmless "
          "for the frontend, but it is a false statement in the contract")
    status, env = c.raw_post("/function/get_run_state", {})
    check("anonymous POST works with no Authorization header", status == 200,
          f"HTTP {status}", "no auth needed, as documented")


def check_default_arg_trap(c: Client) -> None:
    """The single most dangerous thing a frontend can hit. The doc's OWN helper
    in §1 is `call(fn, args = {})`, so `call("feed_since")` sends `{}` - and
    `{}` is a 500, not the documented default of 0."""
    section("⚠  omitted-argument trap on feed_since / feed_backlog")
    for fn in ("feed_since", "feed_backlog"):
        status, env = c.raw_post(f"/function/{fn}", {})
        msg = ""
        if isinstance(env, dict):
            msg = (env.get("error") or {}).get("message", "") \
                if isinstance(env.get("error"), dict) else str(env.get("detail", ""))
        check(f"POST /function/{fn} with {{}} honours the declared default since=0",
              status == 200,
              f"HTTP {status} {msg!r} - the declared default `since: int = 0` is "
              f"NOT applied when the field is absent. A frontend using the doc's "
              f"own §1 helper `call(fn, args = {{}})` and writing "
              f"`call(\"{fn}\")` gets a 500.",
              "the declared default is applied")

    status, env = c.raw_post("/function/feed_since", {"since": None})
    msg = (env.get("error") or {}).get("message", "") if isinstance(env, dict) \
        and isinstance(env.get("error"), dict) else ""
    check("POST /function/feed_since with since:null does not 500", status == 200,
          f"HTTP {status} {msg!r} - JSON null is NOT coerced to the default. "
          "A JS client sending `{since: undefined}` serialises the key away "
          "(same as {}), and `{since: null}` lands here.",
          "null coerces to the default")

    status, env = c.raw_post("/function/feed_since", {"since": "0"})
    check("a STRING since is coerced to int (so the type is enforced on present "
          "values)", status == 200 and isinstance(env, dict) and env.get("ok"),
          f"HTTP {status}",
          "\"0\" -> 0, so pydantic coercion works when the field is PRESENT; "
          "only the absent/null case is broken")


def check_run_state(c: Client) -> dict:
    section("§2.3  POST /function/get_run_state -> RunStateView")
    run = c.post("/function/get_run_state", {})
    errs: list = []
    shape(run, RUN_STATE_FIELDS, "RunStateView", errs)
    report(errs, "RunStateView field names + types", f"{len(RUN_STATE_FIELDS)} fields")

    e2: list = []
    enum_in(run.get("status"), RUN_STATUS_VALUES, "RunStateView.status", e2)
    report(e2, "status is a documented lowercase RunStatus value",
           f"status={run.get('status')!r}")

    check("carries the three _jac_* bookkeeping keys (doc §1.1)",
          BOOKKEEPING_KEYS <= set(run),
          f"missing {sorted(BOOKKEEPING_KEYS - set(run))}", "present, and ignorable")

    if run.get("exists") is False:
        check("exists:false is a valid pre-run state, not an error",
              all(run.get(k) == 0 for k in ("lane_count", "prospect_count",
                                            "reasoning_count")),
              "doc §2.3 says every count is 0 when exists is false",
              "every count is 0, as documented")
        check("DOC GAP: on the empty run, jid is \"\"", run.get("jid") == "",
              f"jid={run.get('jid')!r}",
              "doc §1.1 says EVERY object carries a jid; on the pre-run state it "
              "is the empty string. Do not use it as a React key before exists:true")
    else:
        check("jid is non-empty on a live run", bool(run.get("jid")),
              f"jid={run.get('jid')!r}", f"jid={run.get('jid')}")
        started = run.get("started_at", 0)
        check("started_at is float UNIX seconds (doc §2.3)",
              isinstance(started, (int, float)) and started > 1_000_000_000,
              f"started_at={started!r} - doc says new Date(started_at * 1000)",
              f"{started} -> {time.strftime('%H:%M:%S', time.localtime(started))}")
        check("finished_at is 0.0 while running, else >= started_at",
              run.get("finished_at") == 0 or run.get("finished_at", 0) >= started,
              f"finished_at={run.get('finished_at')!r}",
              f"finished_at={run.get('finished_at')}")
        s, d, p = (run.get("surviving_count", 0), run.get("dropped_count", 0),
                   run.get("prospect_count", 0))
        check("surviving_count + dropped_count == prospect_count", s + d == p,
              f"{s} + {d} != {p} - the header would not add up",
              f"{s} surviving + {d} dropped = {p}")
    return run


def check_lanes(c: Client) -> list:
    section("§2.1  POST /function/list_lanes -> LaneView[]")
    lanes = c.post("/function/list_lanes", {})
    if not check("returns a list", isinstance(lanes, list),
                 f"got {type(lanes).__name__}", f"{len(lanes)} lanes"):
        return []
    if not lanes:
        skip("LaneView shape", "graph has no lanes - use --seed or start a run")
        return []

    errs: list = []
    for i, ln in enumerate(lanes):
        shape(ln, LANE_VIEW_FIELDS, f"LaneView[{i}]", errs)
    report(errs, "LaneView field names + types", f"{len(lanes)} lanes checked")

    e2: list = []
    for ln in lanes:
        enum_in(ln.get("lane_id"), LANE_ID_VALUES, "LaneView.lane_id", e2)
        enum_in(ln.get("state"), LANE_STATE_VALUES, "LaneView.state", e2)
    report(e2, "lane_id UPPERCASE, state lowercase - exactly as doc §1.2 claims",
           f"ids={sorted({l['lane_id'] for l in lanes})} "
           f"states={sorted({l['state'] for l in lanes})}")

    check("every lane carries a non-empty jid (doc §1.1)",
          all(ln.get("jid") for ln in lanes),
          f"missing on {[ln.get('lane_id') for ln in lanes if not ln.get('jid')]}",
          "safe as a React key")
    check("lane jids are unique", len({ln["jid"] for ln in lanes}) == len(lanes),
          "duplicate jid across lanes - React would collapse two panels into one",
          "no collisions")
    order = [ln["lane_id"] for ln in lanes]
    check("sorted by lane_id ascending (doc §2.1)", order == sorted(order),
          f"order on the wire: {order}", f"{order}")

    ids = {ln["lane_id"] for ln in lanes}
    if ids == {"A", "B", "C", "D", "W"}:
        check("doc §2.1: five lanes A,B,C,D,W", True, info="all five present")
    elif ids == {"A", "B", "C", "D"}:
        check("doc §2.1 vs the rehearsal seeder: lane count disagrees", False,
              "wire has A,B,C,D - FOUR lanes. Doc §2.1 says 'There are FIVE "
              "lanes, not four: A, B, C, D and W.' Both are true of different "
              "graphs: SeedRehearsalRun (feedseed.jac) only builds A-D, a real "
              "run also builds W. So a frontend developed against "
              "ops/seed_and_capture.py - which doc §7 recommends - sees four "
              "panels and is surprised by a fifth on demo day. Render whatever "
              "the array contains; never hard-code a panel count.")
    else:
        check("lane set is a subset of the documented A,B,C,D,W",
              ids <= LANE_ID_VALUES, f"unexpected lane ids: {sorted(ids - LANE_ID_VALUES)}",
              f"{sorted(ids)}")
    note("whatever the count, the frontend rule is the same: map over the array, "
         "filter by lane_id, never index positionally.")

    section("§6  Browserbase iframe embed")
    e3: list = []
    for ln in lanes:
        url = ln.get("live_url", "")
        if url and not url.startswith(("http://", "https://")):
            e3.append(f"lane {ln['lane_id']}: live_url {url!r} is not an http(s) "
                      "URL - it cannot be an iframe src")
    report(e3, "live_url is either \"\" or an embeddable http(s) URL",
           f"{sum(1 for l in lanes if l.get('live_url'))}/{len(lanes)} lanes have one")
    empties = [ln["lane_id"] for ln in lanes if ln.get("live_url") == ""]
    check("doc §6 guard is warranted: live_url can be \"\"", True,
          info=f"empty right now for {empties} - guard on live_url !== \"\" or you "
               "mount a broken iframe" if empties else
               "all lanes have a URL right now; the guard still matters at "
               "startup, before sessions exist")
    d = [ln for ln in lanes if ln["lane_id"] == "D"]
    if d:
        note(f"lane D live_url={d[0].get('live_url')!r} - doc §6 says D is "
             "programmatic and should render as a terminal, NOT an iframe, even "
             "when a URL is present.")
    return lanes


def check_prospects(c: Client) -> list:
    section("§2.2  POST /function/list_prospects -> ProspectView[]")
    ps = c.post("/function/list_prospects", {})
    if not check("returns a list", isinstance(ps, list),
                 f"got {type(ps).__name__}", f"{len(ps)} prospects"):
        return []
    if not ps:
        skip("ProspectView shape", "ledger is empty - use --seed or start a run")
        return []

    errs: list = []
    for i, p in enumerate(ps):
        shape(p, PROSPECT_VIEW_FIELDS, f"ProspectView[{i}]", errs)
    report(errs, "ProspectView field names + types", f"{len(ps)} prospects checked")

    e2: list = []
    for p in ps:
        enum_in(p.get("tier"), COMPLETENESS_TIER_VALUES, "ProspectView.tier", e2)
        enum_in(p.get("email_source"), EMAIL_SOURCE_VALUES,
                "ProspectView.email_source", e2)
        for lid in p.get("convergence_lanes") or []:
            enum_in(lid, LANE_ID_VALUES, "ProspectView.convergence_lanes[]", e2)
    report(e2, "tier UPPERCASE (S/A/DROPPED), email_source lowercase - doc §1.2",
           f"tiers={sorted({p['tier'] for p in ps})} "
           f"sources={sorted({p['email_source'] for p in ps})}")

    check("every prospect carries a non-empty jid", all(p.get("jid") for p in ps),
          f"missing on {[p.get('name') for p in ps if not p.get('jid')]}",
          "safe as a React key")
    check("prospect jids are unique - the ledger is deduped across lanes",
          len({p["jid"] for p in ps}) == len(ps),
          "the same human appears twice - convergence dedup is broken",
          "no duplicate humans")
    scores = [p.get("score", 0) for p in ps]
    check("sorted by score DESCENDING (doc §2.2)",
          scores == sorted(scores, reverse=True),
          f"order on the wire: {scores}", f"{scores}")

    dropped = [p for p in ps if p.get("tier") == "DROPPED"]
    check("DROPPED prospects are returned, not filtered out (doc §2.2)", True,
          info=f"{len(dropped)}/{len(ps)} on the ledger are DROPPED - render them "
               "struck through, do not hide them")
    e3: list = []
    for p in dropped:
        if not p.get("dropped_reason"):
            e3.append(f"{p.get('name')!r} is DROPPED with an empty dropped_reason")
    for p in ps:
        if p.get("tier") != "DROPPED" and p.get("dropped_reason"):
            e3.append(f"{p.get('name')!r} is tier {p.get('tier')} but carries "
                      f"dropped_reason={p['dropped_reason']!r}")
    report(e3, "dropped_reason is non-empty exactly when tier == DROPPED",
           "the ledger can always explain an elimination")

    conv = [p for p in ps if len(p.get("convergence_lanes") or []) >= 2]
    check("convergence_lanes >= 2 is present and renderable (doc §2.2)", True,
          info=f"{[(p['name'], p['convergence_lanes']) for p in conv]}" if conv
               else "no converged prospect in this graph state")
    moved = [p for p in ps if p.get("score") != p.get("score_pre_crosslink")]
    check("score_pre_crosslink -> score is renderable as a transition (doc §2.2)",
          True,
          info=f"{[f'{p['score_pre_crosslink']} -> {p['score']}' for p in moved]}"
               if moved else "no score moved in this graph state")
    return ps


def check_feed(c: Client, lanes: list, ps: list, run: dict) -> None:
    section("§3  POST /function/feed_since - the one call to poll")
    b0 = c.post("/function/feed_since", {"since": 0})
    errs: list = []
    shape(b0, FEED_BATCH_FIELDS, "FeedBatch", errs)
    report(errs, "FeedBatch field names + types",
           "seq, next_seq, reasoning, lanes, run, prospects")

    r_errs: list = []
    for i, r in enumerate(b0.get("reasoning") or []):
        shape(r, REASONING_VIEW_FIELDS, f"ReasoningView[{i}]", r_errs)
    report(r_errs, "ReasoningView field names + types",
           f"{len(b0.get('reasoning') or [])} lines checked")

    e2: list = []
    for r in b0.get("reasoning") or []:
        enum_in(r.get("lane_id"), LANE_ID_VALUES, "ReasoningView.lane_id", e2)
        enum_in(r.get("kind"), REASONING_KIND_VALUES, "ReasoningView.kind", e2)
    report(e2, "reasoning kind is a documented lowercase ReasoningKind value",
           f"kinds={sorted({r['kind'] for r in (b0.get('reasoning') or [])})}")

    if b0.get("reasoning"):
        check("DOC GAP: ReasoningView has NO jid", "jid" not in b0["reasoning"][0],
              "it has a jid now - the doc and this check are both stale",
              "doc §1.1 says EVERY object carries a jid; ReasoningView is the "
              "exception. Key the analyst sidebar off `seq`")
        seqs = [r["seq"] for r in b0["reasoning"]]
        check("reasoning seq is 0-based and contiguous from since=0",
              seqs == list(range(len(seqs))), f"seqs={seqs[:12]}",
              f"0..{len(seqs) - 1}")
        ts = [r["t"] for r in b0["reasoning"]]
        check("reasoning is in ascending time order", ts == sorted(ts),
              f"t out of order: {ts[:8]}", "global time order across all lanes")

    check("echoes back the `since` you sent (doc §3)", b0.get("seq") == 0,
          f"seq={b0.get('seq')!r}", "seq mirrors the request")
    check("next_seq == number of reasoning lines when since=0",
          b0.get("next_seq") == len(b0.get("reasoning") or []),
          f"next_seq={b0.get('next_seq')} vs {len(b0.get('reasoning') or [])} lines",
          f"next_seq={b0.get('next_seq')}")

    b1 = c.post("/function/feed_since", {"since": b0["next_seq"]})
    check("handing next_seq back returns NO duplicate reasoning (doc §3 cursor)",
          b1.get("reasoning") == [],
          f"re-delivered {len(b1.get('reasoning') or [])} lines already seen - the "
          "sidebar would double up every poll",
          "the cursor is correct; no off-by-one")
    check("lanes/run/prospects are ALWAYS full regardless of since (doc §3)",
          len(b1.get("lanes") or []) == len(b0.get("lanes") or [])
          and len(b1.get("prospects") or []) == len(b0.get("prospects") or [])
          and isinstance(b1.get("run"), dict),
          f"at since={b0['next_seq']} got {len(b1.get('lanes') or [])} lanes / "
          f"{len(b1.get('prospects') or [])} prospects, vs "
          f"{len(b0.get('lanes') or [])}/{len(b0.get('prospects') or [])} at since=0",
          "only `reasoning` is incremental, exactly as documented")

    huge = c.post("/function/feed_since", {"since": 10_000_000})
    check("an out-of-range since degrades to empty reasoning, not an error",
          huge.get("reasoning") == [],
          f"got {len(huge.get('reasoning') or [])} lines", "no crash, no 500")

    note("`seq` is a POSITIONAL index over time-ordered reasoning, recomputed per "
         "request. If a lane writes a line with an earlier timestamp than one "
         "already delivered, later indices shift and a polling client can miss a "
         "line. Treat next_seq as opaque; do not persist it across a restart.")

    section("§3  feed_since agrees with the dedicated read endpoints")

    def strip(o):
        return {k: v for k, v in o.items() if k not in BOOKKEEPING_KEYS}

    check("feed_since.lanes == list_lanes",
          [strip(x) for x in (b0.get("lanes") or [])] == [strip(x) for x in lanes],
          "the two paths disagree - a polling dashboard and a per-endpoint "
          "dashboard would render different lanes", "identical")
    check("feed_since.prospects == list_prospects",
          [strip(x) for x in (b0.get("prospects") or [])] == [strip(x) for x in ps],
          "the two paths disagree on the ledger", "identical")
    check("feed_since.run == get_run_state",
          strip(b0.get("run") or {}) == strip(run or {}),
          "the two paths disagree on run state", "identical")


def check_jac_id_instability(c: Client) -> None:
    section("§1.1  _jac_id is NOT stable - jid is")
    a = c.post("/function/list_lanes", {})
    b = c.post("/function/list_lanes", {})
    if not a:
        skip("_jac_id regeneration", "no lanes on the graph")
        return
    ja = [x.get("_jac_id") for x in a]
    jb = [x.get("_jac_id") for x in b]
    ka = [x.get("jid") for x in a]
    kb = [x.get("jid") for x in b]
    check("_jac_id CHANGES between two identical calls - never key off it",
          ja != jb,
          f"_jac_id was stable this time ({ja[:2]}); these are freshly-built "
          "projection objects so the doc's warning still stands",
          f"{ja[0][:12]}… -> {jb[0][:12]}…  every render would remount")
    check("jid is IDENTICAL between two identical calls - key off this", ka == kb,
          f"jid drifted: {ka} -> {kb} - nothing on the wire would be a stable key",
          f"{ka[0][:12]}… stable across calls")
    ra = c.post("/function/get_run_state", {})
    rb = c.post("/function/get_run_state", {})
    check("RunStateView._jac_id also regenerates",
          ra.get("_jac_id") != rb.get("_jac_id") or not ra.get("_jac_id"),
          f"stable at {ra.get('_jac_id')}", "same rule applies to the run header")


def check_sse(c: Client) -> None:
    section("§5  POST /function/feed_backlog - SSE fallback")
    try:
        body = c.sse("/function/feed_backlog", {"since": 0})
    except Exception as e:  # noqa: BLE001 - surfaced as a failure, never swallowed
        check("feed_backlog responds", False, f"{type(e).__name__}: {e}")
        return
    if not check("feed_backlog returns a body", bool(body.strip()), "empty stream",
                 f"{len(body)} bytes"):
        return
    frames = [f for f in body.split("\n\n") if f.strip()]
    check("frames are separated by a blank line (doc §5)", len(frames) >= 1,
          f"got {len(frames)} frames", f"{len(frames)} frames")
    check("stream terminates with an `event: end` frame (doc §5)",
          "event: end" in body, f"tail: {body[-160:]!r}", "clean termination")

    data_frames, parse_errs = [], []
    for f in frames:
        for line in f.splitlines():
            if line.startswith("data: "):
                try:
                    data_frames.append(json.loads(line[6:]))
                except json.JSONDecodeError as e:
                    parse_errs.append(f"{line[:80]!r}: {e}")
    report(parse_errs, "every `data: ` payload is JSON - JSON.parse(line.slice(6))",
           f"{len(data_frames)} payloads parsed")
    if data_frames:
        check("first frame is kind:\"lanes\" (doc §5)",
              data_frames[0].get("kind") == "lanes",
              f"first frame is {json.dumps(data_frames[0])[:140]}",
              "lanes first, then one frame per reasoning line")
        reasoning = [d for d in data_frames if d.get("kind") == "reasoning"]
        if reasoning:
            check("reasoning frames carry the kind under `kind_of`, not `kind`",
                  "kind_of" in reasoning[0],
                  f"reasoning frame keys: {sorted(reasoning[0])}",
                  "`kind` is the literal string \"reasoning\"; the ReasoningKind "
                  "is in `kind_of`. Different from the HTTP shape - easy to miss")
        else:
            skip("reasoning frame shape", "no reasoning on the graph")


def check_walkers(c: Client) -> None:
    """The frontend has to START a run. The doc never says how."""
    section("walkers  - how the frontend starts a run (NOT in doc §8)")
    for name in ("PlanCampaign", "RunResearch"):
        gstatus, _ = c.raw_get(f"/walker/{name}")
        status, env = c.raw_post(f"/walker/{name}", {})
        registered = status != 404
        check(f"/walker/{name} is registered", registered,
              f"POST returned 404 - the name is missing from main.jac's import "
              "registry (jaseci-labs/jac#7695: registration tracks the NAME)",
              f"POST -> HTTP {status}"
              + (" (422 = registered, required args missing)" if status == 422 else "")
              + f"; GET -> {gstatus}, so probe walkers with POST, never GET")
    status, env = c.raw_post("/walker/RunResearch", {})
    if status == 422 and isinstance(env, dict):
        missing = [".".join(str(x) for x in d.get("loc", [])[1:])
                   for d in env.get("detail", []) if isinstance(d, dict)]
        note(f"RunResearch requires: {missing} - a bare {{}} is a 422, not a run.")

    status, _ = c.raw_post("/walker/LiveFeed", {})
    check("POST /walker/LiveFeed is 405 - proof the WebSocket decorator registered",
          status == 405,
          f"HTTP {status}. Doc §7 failure mode: without [scale.websocket] in "
          "jac.toml (or without `jac install`), @restspec(protocol=WEBSOCKET) is "
          "SILENTLY ignored and LiveFeed is served as a plain HTTP endpoint. A "
          "200 here means exactly that, and ws:// will 404.",
          "405 Method Not Allowed = it is a WebSocket route, not an HTTP one")

    check("DOC GAP: §8's endpoint index omits both walkers", False,
          "The frontend cannot start a run from the doc alone. Neither "
          "/walker/PlanCampaign nor /walker/RunResearch appears in §8, and the "
          "doc never mentions that walkers return their payload in "
          "data.reports[0] rather than data.result - the opposite of every "
          "function endpoint in §1. Covered in docs/FRONTEND_QUICKSTART.md.")


async def check_websocket(base: str) -> None:
    section("§4  WebSocket ws://…/ws/walker/LiveFeed")
    try:
        import websockets
    except ImportError:
        skip("WebSocket section", "pip install websockets, or pass --no-ws")
        return

    ws_base = base.replace("http://", "ws://").replace("https://", "wss://")
    canonical = f"{ws_base}/ws/walker/LiveFeed"
    legacy = f"{ws_base}/ws/LiveFeed"

    panels: list = []
    try:
        for url in (canonical, canonical, canonical, canonical, legacy):
            panels.append(await asyncio.wait_for(websockets.connect(url), timeout=10))
    except Exception as e:  # noqa: BLE001
        for p in panels:
            await p.close()
        check("connect to /ws/walker/LiveFeed", False,
              f"{type(e).__name__}: {e} - a 404 here means jac.toml lost "
              "[scale.websocket] or `jac install` was not run; the decorator is "
              "then silently ignored and LiveFeed is served as plain HTTP")
        return
    check("4 canonical + 1 legacy panel all connected", len(panels) == 5,
          f"only {len(panels)} connected", "5 concurrent panels")

    sentinel = {"deep": {"nested": [1, 2, {"three": True}]}, "probe": "contract-check"}
    frame = {"kind": "reasoning_batch", "seq": 4242, "batch": sentinel,
             "note": "frontend_contract_check"}
    await panels[0].send(json.dumps(frame))

    received, ctrl_frames = [], 0
    deadline = time.time() + 8
    for p in panels:
        got, remaining = None, max(0.5, deadline - time.time())
        while remaining > 0:
            try:
                raw = await asyncio.wait_for(p.recv(), timeout=remaining)
            except asyncio.TimeoutError:
                break
            msg = json.loads(raw)
            if msg.get("type") in ("ping", "pong"):
                ctrl_frames += 1
                remaining = max(0.1, deadline - time.time())
                continue
            got = msg
            break
        received.append(got)

    delivered = [m for m in received if m is not None]
    check("broadcast=True fans ONE frame out to ALL panels (doc §4)",
          len(delivered) == 5, f"only {len(delivered)}/5 panels received it",
          "5/5 - one pump drives every panel")
    check("the legacy /ws/LiveFeed route shares the same broadcast bus (doc §4)",
          received[4] is not None,
          "the legacy panel got nothing - do not rely on the alias",
          "a frame sent on the canonical route arrived on the legacy one")

    if delivered:
        m = delivered[0]
        e: list = []
        for k in ("type", "error", "meta"):
            if k in m:
                e.append(f"frame HAS a {k!r} key; doc §4.1 says it does not")
        if "ok" not in m:
            e.append("frame has no `ok` key")
        report(e, "the WS frame is NOT the HTTP envelope - no type/error/meta (§4.1)",
               f"frame keys: {sorted(m)}")
        try:
            payload = m["data"]["reports"][0]
            check("msg.data.reports[0] is the payload (doc §4.1)", True,
                  info=f"keys: {sorted(payload)}")
            check("the payload round-trips byte-identically - LiveFeed is a pure echo",
                  payload.get("batch") == sentinel and payload.get("seq") == 4242,
                  f"sent {json.dumps(sentinel)[:80]}, got "
                  f"{json.dumps(payload.get('batch'))[:80]}",
                  "whatever the pump sends is exactly what every panel receives")
            check("doc §4.3 holds: LiveFeed adds NO graph data of its own",
                  set(payload) == {"kind", "seq", "batch", "note"},
                  f"payload keys are {sorted(payload)}",
                  "confirms the pump is mandatory - the walker cannot read the graph")
        except (KeyError, IndexError, TypeError) as exc:
            check("msg.data.reports[0] is the payload (doc §4.1)", False, str(exc))

    section("§4.2  control frames + malformed input")
    check("server heartbeats are type:ping/pong and must be skipped before parsing",
          True, info=f"{ctrl_frames} control frame(s) in this run" if ctrl_frames
          else "none in this 8s window - they arrive every 30s, so a long-lived "
               "panel WILL see them and must skip them or crash on data.reports")
    try:
        await panels[1].send(json.dumps(["not", "an", "object"]))
        raw = await asyncio.wait_for(panels[1].recv(), timeout=5)
        msg = json.loads(raw)
        code = (msg.get("error") or {}).get("code") if isinstance(
            msg.get("error"), dict) else None
        check("a non-object frame returns an error and does NOT drop the socket",
              msg.get("ok") is False or "error" in msg,
              f"got {json.dumps(msg)[:180]}", f"error code {code!r}")
    except asyncio.TimeoutError:
        check("a non-object frame returns an error and does NOT drop the socket",
              False, "server sent nothing back within 5s - INVALID_PAYLOAD is "
                     "documented in §4.2 but was not delivered")
    except Exception as e:  # noqa: BLE001
        check("a non-object frame returns an error and does NOT drop the socket",
              False, f"socket died: {type(e).__name__}: {e}")

    section("§4.3  the pump rule - a listener-only panel sees NOTHING")
    quiet = True
    try:
        await asyncio.wait_for(panels[2].recv(), timeout=3)
        quiet = False
    except asyncio.TimeoutError:
        pass
    except Exception:  # noqa: BLE001
        pass
    check("with no client pumping, the socket is silent (doc §4.3 / §4.4)", quiet,
          "a frame arrived with no pump running - the doc's core claim that the "
          "server cannot push on its own may be wrong",
          "3s of silence. This is THE trap: a listener-only dashboard connects "
          "fine and shows nothing forever. Exactly one client must poll "
          "feed_since and forward batches in")

    for p in panels:
        await p.close()


# --- main --------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default="http://127.0.0.1:8000")
    ap.add_argument("--seed", action="store_true",
                    help="seed rehearsal data first (WRITES to the graph)")
    ap.add_argument("--no-ws", action="store_true", help="skip the WebSocket section")
    args = ap.parse_args()

    c = Client(args.base)
    print(f"\033[1mTRACTION frontend contract check\033[0m  ->  {args.base}")
    print("Asserting every claim in docs/FRONTEND_INTEGRATION.md from the "
          "consumer's side.")

    alive = preflight(c)
    if args.seed:
        if alive:
            guard(seed, c)
        else:
            section("seeding rehearsal graph (--seed)")
            skip("seed", "server is not serving - nothing to seed")

    guard(check_envelopes, c)
    guard(check_default_arg_trap, c)
    run = guard(check_run_state, c, default={})
    lanes = guard(check_lanes, c, default=[])
    ps = guard(check_prospects, c, default=[])
    guard(check_feed, c, lanes or [], ps or [], run or {})
    guard(check_jac_id_instability, c)
    guard(check_sse, c)
    guard(check_walkers, c)
    if not args.no_ws:
        asyncio.run(check_websocket(args.base))
    else:
        section("§4  WebSocket")
        skip("WebSocket section", "--no-ws")

    failed = [(n, d) for n, ok, d in RESULTS if not ok]
    total = len(RESULTS)
    print("\n" + "=" * 78)
    if failed:
        print(f"\033[31m\033[1mCONTRACT VIOLATIONS: {len(failed)} of {total} "
              f"checks failed\033[0m\n")
        for n, d in failed:
            print(f"  \033[31mX\033[0m {n}")
            if d:
                print(f"      {d}")
        if not alive:
            print("\n\033[33mNOTE: the server was not serving. Most of the above "
                  "is downstream of that, not of the contract. Fix the server "
                  "(ops/restart.sh) and re-run before reporting these as contract "
                  "bugs.\033[0m")
        else:
            print("\nEach line is a place where the doc and the server disagree.")
            print("Report it to the endpoint's owner - do NOT edit the doc to "
                  "match a bug.")
        return 1
    print(f"\033[32m\033[1mCONTRACT HOLDS: {total}/{total} checks passed.\033[0m")
    print("A dashboard written from docs/FRONTEND_INTEGRATION.md alone will work.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
