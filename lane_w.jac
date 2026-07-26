"""Lane W — deep research on the one warm lead named at intake.

Every other lane is a search problem: generate candidates, widen, filter. Lane W
is the opposite. The prospect is already known, so there is nothing to discover
and no ladder to climb — the entire job is to go one level deeper on a single
human than a search lane ever could, because this is the one whose dossier
actually reaches the email, the call and the booking.

That difference drives three design choices:
  - No widening ladder. A dry Lane W is a hard failure, not a signal to widen.
  - Depth over breadth: profile AND recent activity, so outreach can quote
    something the person actually said rather than their job title.
  - Guaranteed identity. Name and email come from intake, so the email gate is
    passed by construction (EmailSource.PROVIDED) and never guessed.

Lives in its own module so it cannot collide with in-flight edits to the A/B/C
lanes in research.jac.
"""

import time;
import from contracts {
    LaneId, LaneState, ReasoningKind, EvidenceKind, EvidenceSource,
    EmailSource, CompletenessTier
}
import from schema {
    Lane, Prospect, Evidence, Founder, Reasoning,
    Surfaced, HasWarmLead, HasEvidence, Emitted, HasLane, Runs
}
import from research { LaneBrowser }

glob LANE_W_DOCTRINE: str =
    "Lane W. One named warm lead, already trusted. Not searching - reading them "
    + "properly, so the first email can quote what they actually said.";

# Profile facts in one round trip. Every field has fallbacks because LinkedIn
# rotates class names constantly; structure and aria labels outlive them.
# Profile facts in one round trip.
#
# NOT class selectors. Probed live 2026-07-26: LinkedIn now serves profile pages
# with ZERO <h1>, no <main>, and no .pv-top-card — every structural selector the
# obvious implementation reaches for returns nothing, while document.title and
# the rendered text carry the facts perfectly. Title and text order are what
# survive their redesigns; class names are what churn.
glob PROFILE_JS: str = """
(function(){
  const lines = (document.body.innerText || '').split('\\n')
                  .map(s => s.trim()).filter(Boolean);
  const title = document.title || '';
  let name = title.split('|')[0].trim();
  if (!name || /linkedin/i.test(name)) {
    const h1 = document.querySelector('h1');
    name = h1 ? (h1.innerText || '').trim() : '';
  }

  // The headline is the first substantive line after the name, skipping the
  // chrome LinkedIn interleaves (follower counts, action buttons).
  const noise = /^(Contact info|More|Message|Follow|Following|Connect|Open to|Add profile section|Enhance profile|\\d+(,\\d+)* (followers|connections)|\\d+(st|nd|rd|th) degree connection)$/i;
  let headline = '';
  const at = lines.indexOf(name);
  if (at >= 0) {
    for (let j = at + 1; j < Math.min(at + 6, lines.length); j++) {
      const c = lines[j];
      if (c && c !== name && c.length > 3 && !noise.test(c)) { headline = c; break; }
    }
  }

  const STOPS = ['About','Experience','Education','Activity','Skills','Interests',
                 'Licenses & certifications','Projects','Honors & awards',
                 'Recommendations','People you may know','Volunteering'];
  const section = (label) => {
    const start = lines.indexOf(label);
    if (start < 0) return '';
    const out = [];
    for (let j = start + 1; j < lines.length; j++) {
      if (STOPS.indexOf(lines[j]) >= 0) break;
      out.push(lines[j]);
      if (out.join(' ').length > 1400) break;
    }
    return out.join(' ').trim();
  };

  const about = section('About');
  const expLines = [];
  const eStart = lines.indexOf('Experience');
  if (eStart >= 0) {
    for (let j = eStart + 1; j < lines.length && expLines.length < 6; j++) {
      if (STOPS.indexOf(lines[j]) >= 0) break;
      if (lines[j].length > 2) expLines.push(lines[j]);
    }
  }

  // "SWE Intern @ Uber | CS + AI @ Minerva" -> Uber
  let company = '';
  const m = headline.match(/@\\s*([A-Za-z0-9.&'\\- ]{2,40})/);
  if (m) company = m[1].trim().replace(/\\s*\\|.*$/, '').trim();

  return {name: name, headline: headline, about: about.slice(0, 1200),
          company: company, experience: expLines,
          url: location.href.split('?')[0], title: title,
          line_count: lines.length};
})()
""";

# Recent posts and comments. This is what makes an opening line specific.
glob ACTIVITY_JS: str = """
(function(){
  const out = [];
  // LinkedIn's activity page interleaves post bodies with UI furniture. Quoting
  // "2 months ago - Edited - Visible to anyone" back at a prospect is worse than
  // quoting nothing, so chrome is rejected explicitly, not length-filtered.
  const CHROME = [
    /^\\d+\\s*(mo|month|week|day|hour|minute|w|d|h|m)s?\\s*(ago)?\\b/i,
    /visible to anyone/i, /^(edited|promoted|sponsored)$/i,
    /^(like|comment|repost|send|follow|following|connect)$/i,
    /^\\d+(,\\d+)*\\s*(followers|connections|reactions|comments|impressions)/i,
    /feed post number/i, /^activity$/i, /^see all/i, /loaded \\d+ /i,
    /^(new|show more|show all)/i
  ];
  const isChrome = t => CHROME.some(re => re.test(t));
  // A real post body reads like prose: enough words, not mostly separators.
  const isProse = t => {
    const words = t.split(/\\s+/).filter(Boolean);
    if (words.length < 12) return false;
    return (t.match(/\\u2022/g) || []).length <= 2;
  };
  const seen = new Set();
  const push = (t, meta) => {
    const body = (t || '').trim();
    if (!body || body.length < 60 || isChrome(body) || !isProse(body)) return;
    const key = body.slice(0, 60);
    if (seen.has(key) || out.length >= 8) return;
    seen.add(key);
    out.push({text: body.slice(0, 400), meta: meta || ''});
  };
  const stamp = t => (t.match(/\\b(\\d+\\s*(mo|[dwhm])\\b|\\d+ (day|week|month|hour)s? ago)/i) || [''])[0];

  document.querySelectorAll(
    'div.feed-shared-update-v2, li.profile-creator-shared-feed-update__container, div.occludable-update'
  ).forEach(card => {
    const txt = (card.innerText || '').trim();
    const body = txt.split('\\n').map(l => l.trim())
                    .filter(l => l.length > 60 && !isChrome(l) && isProse(l))[0] || '';
    push(body, stamp(txt));
  });

  if (!out.length) {
    // Card classes have churned again. Fall back to rendered text, with the same
    // chrome and prose gates so the fallback cannot lower the quality bar.
    const lines = (document.body.innerText || '').split('\\n').map(s => s.trim());
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].length > 60) {
        push(lines[i], stamp(lines.slice(Math.max(0, i - 4), i + 1).join(' ')));
      }
    }
  }
  return {items: out, count: out.length, url: location.href.split('?')[0]};
})()
""";

"""Turn LinkedIn's relative stamps ("3d", "2 weeks ago") into days, or -1."""
def age_in_days(meta: str) -> int;

"""Walk Lane <- HasLane <- ResearchRun <- Runs <- Founder to reach the founder."""
def founder_of(lane: Lane) -> Founder | None;


walker LaneW {
    """Deep-reads the one warm lead. Guaranteed-yield: dry here is a failure."""

    has context_id: str = "";
    has warm_url: str = "";
    has warm_name: str = "";
    has warm_email: str = "";
    has hypothesis: str = "";
    has offline: bool = False;
    has fixture: dict = {};

    has browser: any = None;
    has seq: int = 0;
    # NOT named `reports` — that collides with the built-in walker report
    # channel and silently collects nothing.
    has evidence_written: int = 0;
    has prospect: any = None;
    has failure: str = "";

    def narrate(here: Lane, sentence: str, kind: ReasoningKind);
    def attach_evidence(p: Prospect, quote: str, kind: EvidenceKind,
                        url: str, recency: int) -> bool;

    can begin with Lane entry {
        here.doctrine = LANE_W_DOCTRINE;
        here.state = LaneState.LAUNCHING;
        here.keywords = [self.warm_name] if self.warm_name else [];

        self.narrate(here, LANE_W_DOCTRINE, ReasoningKind.PLAN);

        if not self.warm_url {
            here.state = LaneState.FAILED;
            self.failure = "no warm-lead LinkedIn URL was supplied at intake";
            self.narrate(
                here,
                "No warm lead was named at intake, so there is nobody for this "
                + "lane to research. Saying so rather than inventing one.",
                ReasoningKind.MISS
            );
            disengage;
        }

        self.browser = LaneBrowser(
            lane_id=str(LaneId.W), offline=self.offline, fixture=self.fixture
        );
        if not self.browser.open(self.context_id) {
            here.state = LaneState.FAILED;
            self.failure = self.browser.last_error;
            self.narrate(
                here,
                f"Could not open a browser session: {self.browser.last_error}. "
                + "Lane W is the warm lead - this failure is worth surfacing loudly.",
                ReasoningKind.MISS
            );
            disengage;
        }
        here.bb_session_id = self.browser.session_id;
        here.live_url = self.browser.live_url;

        # ---- the profile itself -------------------------------------------
        here.state = LaneState.SEARCHING;
        here.current_query = self.warm_url;
        self.narrate(
            here,
            f"Opening {self.warm_name or 'the warm lead'}'s profile directly. "
            + "No search needed - we already know exactly who this is.",
            ReasoningKind.PLAN
        );

        if not self.browser.goto(self.warm_url) {
            here.state = LaneState.FAILED;
            self.failure = f"could not load {self.warm_url}";
            self.narrate(
                here,
                f"Could not load {self.warm_url}. A failed navigation leaves the "
                + "tab on an error page, so nothing below would be trustworthy.",
                ReasoningKind.MISS
            );
            self.browser.close_session();
            disengage;
        }

        here.state = LaneState.READING;
        profile: dict = self.browser.eval_json(PROFILE_JS) or {};
        name: str = str(profile.get("name") or self.warm_name or "");
        headline: str = str(profile.get("headline") or "");
        about: str = str(profile.get("about") or "");
        company: str = str(profile.get("company") or "");

        if not name {
            here.state = LaneState.FAILED;
            self.failure = "profile page returned no name";
            self.narrate(
                here,
                "The profile loaded but no name could be read from it - most "
                + "likely an auth wall rather than a real profile. Refusing to "
                + "write a half-empty dossier.",
                ReasoningKind.MISS
            );
            self.browser.close_session();
            disengage;
        }

        self.narrate(
            here,
            f"Read {name}: {headline[:110] if headline else 'no headline'}."
            + (f" At {company}." if company else ""),
            ReasoningKind.OBSERVE
        );

        # ---- create the prospect ------------------------------------------
        handle = self.warm_url.rstrip("/").split("/")[-1];
        p = here +>:Surfaced(
            at_rank=1, found_at=time.time(), query="warm lead, named at intake"
        ):+> Prospect(
            name=name,
            handle=handle,
            headline=headline,
            company=company,
            linkedin_url=str(profile.get("url") or self.warm_url),
            email=self.warm_email,
            # Known at intake. This is the one prospect that never needs the
            # email waterfall, so it can never fail the gate.
            email_source=EmailSource.PROVIDED if self.warm_email else EmailSource.NONE,
            email_confidence=1.0 if self.warm_email else 0.0,
            # A = email plus content from one platform. RankAndSelect owns the
            # final tiering and may promote to S once GitHub cross-links.
            tier=CompletenessTier.A if self.warm_email else CompletenessTier.DROPPED
        );
        self.prospect = p;

        # The warm-lead edge hangs off the Founder, not the Lane, because it
        # outlives any single research run.
        f = founder_of(here);
        if f is not None {
            f +>:HasWarmLead(note="named at intake"):+> p;
        } else {
            self.narrate(
                here,
                "Could not reach the Founder node from this lane, so the warm-lead "
                + "edge was not written. The prospect still exists and is reachable "
                + "from the lane.",
                ReasoningKind.MISS
            );
        }

        if headline {
            self.attach_evidence(p, headline, EvidenceKind.HEADLINE, self.warm_url, -1);
        }
        if about {
            self.attach_evidence(p, about[:600], EvidenceKind.ABOUT, self.warm_url, -1);
        }

        # ---- recent activity — the part that makes outreach specific -------
        activity_url = self.warm_url.rstrip("/") + "/recent-activity/all/";
        self.narrate(
            here,
            "Now reading their recent activity. A job title tells us what they "
            + "are; what they posted last week tells us what they are dealing with.",
            ReasoningKind.PLAN
        );

        if self.browser.goto(activity_url) {
            activity: dict = self.browser.eval_json(ACTIVITY_JS) or {};
            items: list = activity.get("items") or [];
            if items {
                self.narrate(
                    here,
                    f"{len(items)} recent post{'s' if len(items) != 1 else ''} from "
                    + f"{name}. Reading for something worth quoting back.",
                    ReasoningKind.OBSERVE
                );
                for item in items[:5] {
                    quote: str = str(item.get("text") or "");
                    if quote {
                        self.attach_evidence(
                            p, quote, EvidenceKind.POST, activity_url,
                            age_in_days(str(item.get("meta") or ""))
                        );
                    }
                }
            } else {
                # Not a failure. A quiet profile is a real finding, and outreach
                # should know it has nothing recent to quote.
                self.narrate(
                    here,
                    f"{name} has no readable recent activity. The opening line will "
                    + "have to lean on their headline and role instead of a quote.",
                    ReasoningKind.OBSERVE
                );
            }
        } else {
            self.narrate(
                here,
                "Their activity feed would not load. Continuing with the profile "
                + "evidence already gathered rather than failing the whole lane.",
                ReasoningKind.MISS
            );
        }

        # ---- done ----------------------------------------------------------
        here.state = LaneState.DONE if self.evidence_written > 0 else LaneState.DRY;
        self.narrate(
            here,
            f"Lane W complete. {self.evidence_written} pieces of evidence on {name}"
            + (f", reachable at {self.warm_email}." if self.warm_email
               else ", but no email was supplied at intake."),
            ReasoningKind.YIELD if self.evidence_written > 0 else ReasoningKind.MISS
        );
        self.browser.close_session();
        report p;
    }
}
