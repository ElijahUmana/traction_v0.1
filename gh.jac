"""Pure-Jac GitHub REST client - the transport layer under Lane D and the email gate.

WHY THIS EXISTS AS AN `obj` AND NOT A PILE OF FUNCTIONS
--------------------------------------------------------------------------
Three pieces of state have to be shared across every call in a run, and getting
any of them wrong silently zeroes the funnel on stage:

  1. THE SEARCH BUDGET. GitHub's search endpoints are limited to 30 requests
     per MINUTE (measured live, not read: /rate_limit reports search.limit=30
     while core.limit=5000). Critically, that 30 is a SINGLE bucket shared by
     search/commits, search/repositories, search/issues and search/users. Lane
     D's candidate generation and the email waterfall's workhorse step both
     draw on it. A naive implementation exhausts the bucket mid-run and every
     subsequent lookup returns 403 - which, if swallowed, looks exactly like
     "this person has no email" and drops a perfectly good prospect.

  2. THE CACHE. `search/commits?q=author:X` is the single most expensive call
     in the system and the most likely to be repeated (once by the lane, once
     by the email waterfall). Paying for it twice is paying twice out of a
     30/min budget.

  3. THE ERROR LEDGER. Every non-200 is recorded AND printed. Nothing is
     swallowed - see `GhResponse` below.

ERRORS ARE VALUES, NOT SILENCE
--------------------------------------------------------------------------
`get_json` cannot return a bare dict, because then "403 rate limited" and
"this user genuinely has no email" are the same empty result. Every call
returns a `GhResponse` with an explicit `ok` flag, so a caller that forgets to
check gets `.data` = empty AND `.ok` = False sitting right there, rather than a
plausible-looking blank. A 403 or 429 additionally prints a loud banner and is
appended to `errors`, which walkers surface into the graph as Reasoning nodes.

VERIFIED JAC/HTTP CONSTRAINTS ENCODED HERE (each was a real `jac check` error)
--------------------------------------------------------------------------
  * `with urlopen(req) as r { }` fails E1091/E1092 - urlopen is typed `any`,
    which has no __enter__/__exit__. Call it bare and cast the `.read()`.
  * Bare `dict` warns W1036 - every dict needs type arguments.
  * `.get()` off an any-typed dict needs an explicit `as` cast or E1032/E1022.
  * Brace imports take NO trailing semicolon; module imports DO.
No `requests` dependency: this is stdlib urllib only, so jac.toml stays clean.
"""

import json;
import os;
import from time { time, sleep }
import from urllib.request { Request, urlopen }
import from urllib.error { HTTPError, URLError }
import from urllib.parse { quote }


glob GH_API: str = "https://api.github.com";
glob GH_WEB: str = "https://github.com";
glob GH_RAW: str = "https://raw.githubusercontent.com";

# GitHub's own documented ceiling for authenticated search. We stop at 26 to
# leave headroom for the retry path - hitting the wall costs a full 60s stall.
glob SEARCH_BUDGET_PER_MIN: int = 26;
glob SEARCH_WINDOW_SECONDS: float = 60.0;


"""One HTTP result. `ok` is the only thing a caller may branch on.

The whole point of this type is that an empty `data` is never ambiguous:
ok=False means the network or GitHub said no, ok=True with empty data means
GitHub genuinely had nothing. Collapsing those two is how an email gate
silently reports "no email found" for a person who has one.
"""
obj GhResponse {
    has ok: bool = False;
    has status: int = 0;
    has data: dict[str, any] = {};
    has items: list[dict[str, any]] = [];
    has text: str = "";
    has error: str = "";
    has from_cache: bool = False;
}


"""Authenticated GitHub client with a shared search budget and a response cache."""
obj GithubApi {

    has token: str = "";
    has cache: dict[str, any] = {};
    has errors: list[str] = [];
    has search_calls: list[float] = [];
    has core_calls: int = 0;
    has search_total: int = 0;
    has cache_hits: int = 0;
    has verbose: bool = True;

    def postinit {
        if self.token == "" {
            self.token = os.environ.get("GITHUB_TOKEN", "") as str;
        }
        if self.token == "" {
            self.token = os.environ.get("GH_TOKEN", "") as str;
        }
    }

    def has_token -> bool {
        return len(self.token) > 0;
    }

    """Record and print. Errors are never silent - that is the whole contract."""
    def _note(msg: str) {
        self.errors.append(msg);
        print(f"[gh] {msg}");
    }

    """Token bucket over a rolling 60s window against the 30/min search cap.

    Blocks rather than failing: a 40-second stall mid-run is recoverable and
    visible; a 403 mistaken for "no email" is neither.
    """
    def _throttle_search {
        now: float = time();
        fresh: list[float] = [];
        for t in self.search_calls {
            if now - t < SEARCH_WINDOW_SECONDS {
                fresh.append(t);
            }
        }
        self.search_calls = fresh;
        if len(self.search_calls) >= SEARCH_BUDGET_PER_MIN {
            oldest: float = self.search_calls[0];
            nap: float = (SEARCH_WINDOW_SECONDS - (now - oldest)) + 1.0;
            if nap > 0.0 {
                self._note(f"search budget spent ({len(self.search_calls)}/{SEARCH_BUDGET_PER_MIN}) - waiting {nap:.1f}s for the window to roll");
                sleep(nap);
            }
            self.search_calls = [];
        }
    }

    """Single HTTP GET. Every failure path produces an explicit, loud GhResponse."""
    def _raw(url: str, accept: str, is_search: bool) -> GhResponse {
        if is_search {
            self._throttle_search();
            self.search_calls.append(time());
            self.search_total += 1;
        } else {
            self.core_calls += 1;
        }
        headers: dict[str, str] = {
            "Accept": accept,
            "User-Agent": "traction-jachacks-2026",
            "X-GitHub-Api-Version": "2022-11-28"
        };
        if self.has_token() {
            headers["Authorization"] = f"Bearer {self.token}";
        }
        req = Request(url, headers=headers);
        try {
            resp = urlopen(req, timeout=25);
            body: str = (resp.read() as bytes).decode("utf-8", "replace");
            return GhResponse(ok=True, status=200, text=body);
        } except HTTPError as e {
            code: int = e.status as int;
            detail: str = "";
            try {
                detail = (e.read() as bytes).decode("utf-8", "replace")[0:220];
            } except Exception {
                detail = "<unreadable body>";
            }
            # 404 is ordinary and expected - most candidates have no profile
            # README, no pyproject.toml, no personal site. Do not shout.
            if code == 404 {
                return GhResponse(ok=False, status=404, error="not found");
            }
            if code == 403 or code == 429 {
                self._note(f"!! HTTP {code} RATE-LIMITED/FORBIDDEN on {url[0:110]} :: {detail}");
                self._note("!! this is the failure mode that must never be read as 'no email found'");
            } else {
                self._note(f"!! HTTP {code} on {url[0:110]} :: {detail}");
            }
            return GhResponse(ok=False, status=code, error=f"HTTP {code}: {detail}");
        } except URLError as e {
            self._note(f"!! NETWORK FAILURE on {url[0:110]} :: {str(e)}");
            return GhResponse(ok=False, status=0, error=f"network: {str(e)}");
        } except Exception as e {
            self._note(f"!! UNEXPECTED {type(e).__name__} on {url[0:110]} :: {str(e)}");
            return GhResponse(ok=False, status=0, error=f"{type(e).__name__}: {str(e)}");
        }
    }

    """GET an api.github.com path returning a JSON object. Cached."""
    def get(path: str) -> GhResponse {
        return self._json_call(path, False);
    }

    """GET a /search/* path. Draws on the 30/min bucket. Cached."""
    def search(path: str) -> GhResponse {
        return self._json_call(path, True);
    }

    def _json_call(path: str, is_search: bool) -> GhResponse {
        key: str = f"J:{path}";
        if key in self.cache {
            self.cache_hits += 1;
            cached = self.cache[key] as GhResponse;
            return GhResponse(ok=cached.ok, status=cached.status, data=cached.data,
                              items=cached.items, text=cached.text, error=cached.error,
                              from_cache=True);
        }
        url: str = path;
        if not path.startswith("http") {
            url = GH_API + path;
        }
        r: GhResponse = self._raw(url, "application/vnd.github+json", is_search);
        if r.ok {
            try {
                parsed = json.loads(r.text);
                if isinstance(parsed, list) {
                    r.items = parsed as list[dict[str, any]];
                    r.data = {};
                } else {
                    r.data = parsed as dict[str, any];
                    raw_items = r.data.get("items", []);
                    if isinstance(raw_items, list) {
                        r.items = raw_items as list[dict[str, any]];
                    }
                }
            } except Exception as e {
                # A 200 whose body will not parse is a real bug, never a "no result".
                self._note(f"!! JSON PARSE FAILURE on {url[0:110]} :: {str(e)}");
                r = GhResponse(ok=False, status=r.status, error=f"unparseable body: {str(e)}");
            }
        }
        r.text = "";
        self.cache[key] = r;
        return r;
    }

    """Fetch a non-API URL as raw text: .patch files, raw.githubusercontent, blogs."""
    def get_text(url: str) -> GhResponse {
        key: str = f"T:{url}";
        if key in self.cache {
            self.cache_hits += 1;
            cached = self.cache[key] as GhResponse;
            return GhResponse(ok=cached.ok, status=cached.status, text=cached.text,
                              error=cached.error, from_cache=True);
        }
        self.core_calls += 1;
        r: GhResponse = self._raw(url, "text/plain, text/html, */*", False);
        self.cache[key] = r;
        return r;
    }

    # -- typed convenience wrappers used by the lane and the waterfall --------

    def user(login: str) -> GhResponse {
        return self.get(f"/users/{login}");
    }

    def user_repos(login: str, n: int) -> GhResponse {
        return self.get(f"/users/{login}/repos?sort=pushed&direction=desc&per_page={n}");
    }

    """Public org memberships. The ONLY trustworthy affiliation signal on GitHub -
    the profile `company` field is free text the user types and is not verified."""
    def user_orgs(login: str) -> GhResponse {
        return self.get(f"/users/{login}/orgs");
    }

    """204 = member, 404 = not. Verifiable, unlike the `company` string."""
    def is_org_member(org: str, login: str) -> bool {
        r: GhResponse = self.get(f"/orgs/{org}/members/{login}");
        return r.ok;
    }

    """THE WORKHORSE of the email waterfall: one global call across every repo
    this person has ever committed to. per_page=100 is deliberate - a live run
    found a real address only at item 23, and a per_page=5 probe reported the
    same human as 'no email'."""
    def commit_search(login: str) -> GhResponse {
        return self.search(f"/search/commits?q=author:{quote(login)}&per_page=100");
    }

    def repo_commits(full_name: str, login: str) -> GhResponse {
        return self.get(f"/repos/{full_name}/commits?author={quote(login)}&per_page=100");
    }

    def search_repos(q: str, n: int) -> GhResponse {
        return self.search(f"/search/repositories?q={quote(q)}&sort=updated&order=desc&per_page={n}");
    }

    def search_issues(q: str, n: int) -> GhResponse {
        return self.search(f"/search/issues?q={quote(q)}&sort=created&order=desc&per_page={n}");
    }

    def patch_text(full_name: str, sha: str) -> GhResponse {
        return self.get_text(f"{GH_WEB}/{full_name}/commit/{sha}.patch");
    }

    def raw_file(full_name: str, path: str) -> GhResponse {
        return self.get_text(f"{GH_RAW}/{full_name}/HEAD/{path}");
    }

    def stats -> dict[str, int] {
        return {
            "core_calls": self.core_calls,
            "search_calls": self.search_total,
            "cache_hits": self.cache_hits,
            "errors": len(self.errors)
        };
    }
}


glob gh: GithubApi = GithubApi();
