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
    EmailSource, CompletenessTier, IdentityTier
}
import from schema {
    Lane, Prospect, Evidence, Founder, Reasoning, LinkedinProfile,
    Surfaced, HasWarmLead, HasEvidence, Emitted, HasLane, Runs, Identity
}
import from browser.session { new_session }

# Lane W talks to browser.session directly rather than borrowing research.jac's
# LaneBrowser. Not a style choice: research.jac must import LaneW so RunResearch
# can fan it out with the other lanes, and Jac 0.34.7 does not tolerate a cycle
# (verified - a two-module cycle fails at import time, not at use). Same surface,
# so the walker body is unchanged.
obj WarmBrowser {
    has lane_id: str;
    has session_id: str = "";
    has live_url: str = "";
    has last_error: str = "";
    has offline: bool = False;
    has fixture: dict = {};
    has session: any = None;

    def open(context_id: str) -> bool;
    def goto(url: str) -> bool;
    def eval_json(expr: str) -> any;
    def close_session;
}

impl WarmBrowser.open(context_id: str) -> bool {
    if self.offline {
        # Declared test mode only; no path from a real run reaches this.
        self.session_id = "offline";
        return True;
    }
    try {
        # persist=False is load-bearing: the lane reads the canonical login but
        # can never write back to it, so it cannot damage the auth mid-demo.
        self.session = new_session(context_id=context_id, persist=False, proxies=True);
        self.session_id = self.session.session_id;
        self.live_url = self.session.live_url;
        return True;
    } except Exception as e {
        self.last_error = str(e);
        return False;
    }
}

impl WarmBrowser.goto(url: str) -> bool {
    if self.offline {
        return True;
    }
    return self.session.goto(url, settle=2.5);
}

impl WarmBrowser.eval_json(expr: str) -> any {
    if self.offline {
        return self.fixture.get("eval", None);
    }
    try {
        return self.session.eval_json(expr);
    } except Exception as e {
        self.last_error = str(e);
        return None;
    }
}

impl WarmBrowser.close_session {
    if self.session is not None {
        self.session.close();
    }
}

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

  // Section headers AND the sidebar markers. The sidebar ones are load-bearing:
  // section() walks innerText forward until it meets a stop, so when no section
  // header follows About -- which depends entirely on how much of the profile is
  // filled in -- it runs straight on into "More profiles for you" and swallows
  // the recommended-people rail. That put SIX named strangers and their
  // employers (Emma Wu - DE @ Meta, Emma Teng - SSBA @ McKinsey, Aaron Teng,
  // Kijoo Song, Zufan Wu, Victor C.) inside the warm lead's About evidence,
  // attributed to her, with her profile URL as the source. The dashboard
  // renders that string and the model is handed it as "what she wrote".
  const STOPS = ['About','Experience','Education','Activity','Skills','Interests',
                 'Licenses & certifications','Projects','Honors & awards',
                 'Recommendations','People you may know','Volunteering',
                 'More profiles for you','Explore Premium profiles','Show all',
                 'People also viewed','More profiles','Promoted',
                 'Interested in','You might like'];
  // A marker is not always its own line, so the assembled text is cut at the
  // earliest one as well. Line-level stops alone are not enough.
  const CUTS = ['More profiles for you','Explore Premium profiles','Show all',
                'People also viewed','Promoted','Interested in','You might like'];
  const cutChrome = (text) => {
    let end = text.length;
    for (const c of CUTS) {
      const i = text.indexOf(c);
      if (i >= 0 && i < end) { end = i; }
    }
    return text.slice(0, end).trim();
  };
  const section = (label) => {
    const start = lines.indexOf(label);
    if (start < 0) return '';
    const out = [];
    for (let j = start + 1; j < lines.length; j++) {
      if (STOPS.indexOf(lines[j]) >= 0) break;
      out.push(lines[j]);
      if (out.join(' ').length > 1400) break;
    }
    return cutChrome(out.join(' ').trim());
  };

  // innerText ONLY, deliberately.
  //
  // A textContent read was added here on the theory that About was CSS-clamped
  // behind "see more". That theory was wrong -- measured on the real profile,
  // innerText and textContent return the identical 156 characters. What the
  // textContent read DID do was ignore rendering entirely and sweep in the
  // "More profiles for you" sidebar, so the stored About evidence came back as
  //
  //   "...analytics and product management. More profiles for you Emma Wu - 2nd
  //    DE @ Meta ... Emma Teng - 2nd UCLA | SSBA @ McKinsey ..."
  //
  // - five other people's names and job titles filed as things THIS person
  // wrote. Contaminated evidence on the one prospect we email, and third
  // parties' details stored on her node. Reverted.
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
# Contact Info lives behind an overlay route, reachable by URL. Navigating to it
# is a read: no connect request, no message, no reaction, nothing she is
# notified about. A profile view from the founder's own account is normal
# behaviour; anything that touches her notifications is not.
glob CONTACT_JS: str = """
(function(){
  const txt = (document.body.innerText || '').trim();
  const start = txt.search(/contact info/i);
  const slice = start >= 0 ? txt.slice(start, start + 1500) : txt.slice(0, 1200);
  const links = Array.from(document.querySelectorAll('a[href]'))
    .map(a => a.href)
    .filter(h => /github\\.com|twitter\\.com|x\\.com|mailto:|^https?:/i.test(h)
                 && !/linkedin\\.com\\/(feed|mynetwork|jobs|messaging|notifications)/i.test(h))
    .slice(0, 25);
  return {text: slice, links: links, url: location.href.split('?')[0]};
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
    has preferred_name: str = "";
    has warm_email: str = "";
    has hypothesis: str = "";
    has offline: bool = False;
    has fixture: dict = {};

    has browser: any = None;
    # NOT named `reports` — that collides with the built-in walker report
    # channel and silently collects nothing.
    has evidence_written: int = 0;
    has failure: str = "";
    # The harvested text CrossLinkToGithub consumes. It takes text, not a
    # browser — the lane owns the session, the cross-link owns the analysis.
    has contact_info_text: str = "";
    has about_text: str = "";
    has posts_text: str = "";
    has linkedin_company: str = "";

    def attach_evidence(p: Prospect, quote: str, kind: EvidenceKind,
                        url: str, recency: int) -> bool;

    can begin with Lane entry {
        here.doctrine = LANE_W_DOCTRINE;
        here.state = LaneState.LAUNCHING;
        here.keywords = [self.warm_name] if self.warm_name else [];
        here.narrate(LANE_W_DOCTRINE, ReasoningKind.PLAN, time.time());

        if not self.warm_url {
            here.state = LaneState.FAILED;
            self.failure = "no warm-lead LinkedIn URL was supplied at intake";
            here.narrate(
                "No warm lead was named at intake, so there is nobody for this "
                + "lane to research. Saying so rather than searching for the name "
                + "and risking the wrong person.",
                ReasoningKind.MISS, time.time()
            );
            disengage;
        }

        self.browser = WarmBrowser(
            lane_id=str(LaneId.W), offline=self.offline, fixture=self.fixture
        );
        if not self.browser.open(self.context_id) {
            here.state = LaneState.FAILED;
            self.failure = self.browser.last_error;
            here.narrate(
                f"Could not open a browser session: {self.browser.last_error}. "
                + "Lane W is the warm lead - this failure is worth surfacing loudly.",
                ReasoningKind.MISS, time.time()
            );
            disengage;
        }
        # Set the moment the session opens: the dashboard iframe needs this
        # while the lane is still working, not at teardown.
        here.bb_session_id = self.browser.session_id;
        here.live_url = self.browser.live_url;

        # ---- the profile itself -------------------------------------------
        here.state = LaneState.SEARCHING;
        here.current_query = self.warm_url;
        here.narrate(
            f"Opening {self.warm_name or 'the warm lead'}'s profile directly. "
            + "No search needed - we already know exactly who this is.",
            ReasoningKind.PLAN, time.time()
        );

        if not self.browser.goto(self.warm_url) {
            here.state = LaneState.FAILED;
            self.failure = f"could not load {self.warm_url}";
            here.narrate(
                f"Could not load {self.warm_url}. A failed navigation leaves the "
                + "tab on an error page, so nothing read after it would be trustworthy.",
                ReasoningKind.MISS, time.time()
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
        self.about_text = about;
        self.linkedin_company = company;

        if not name {
            here.state = LaneState.FAILED;
            self.failure = "profile page returned no name";
            here.narrate(
                "The profile loaded but no name could be read from it - most "
                + "likely an auth wall rather than a real profile. Refusing to "
                + "write a half-empty dossier on our one critical-path prospect.",
                ReasoningKind.MISS, time.time()
            );
            self.browser.close_session();
            disengage;
        }

        here.narrate(
            f"Read {name}: {headline[:110] if headline else 'no headline'}."
            + (f" At {company}." if company else ""),
            ReasoningKind.OBSERVE, time.time()
        );

        # ---- resolve the EXISTING prospect, never build a second one ------
        # She is attached at intake via Founder -:HasWarmLead:-> Prospect. Two
        # nodes for one human would split her evidence, break dedup, and could
        # make her falsely satisfy is_converged() by looking like she was found
        # from two directions when it is the same person twice - a false
        # positive on the exact claim the demo closes on.
        f = founder_of(here);
        existing: list = [f ->:HasWarmLead:->] if f is not None else [];
        p: Prospect = existing[0] if existing else Prospect(
            name=name, handle="", tier=CompletenessTier.DROPPED
        );
        if existing {
            here.narrate(
                f"{name} is already on the graph as the warm lead. Attaching this "
                + "lane's findings to that same person rather than creating a "
                + "second node for her.",
                ReasoningKind.JUDGE, time.time()
            );
        } elif f is not None {
            f +>:HasWarmLead(note="named at intake"):+> p;
        } else {
            here.narrate(
                "Could not reach the Founder from this lane, so the warm-lead edge "
                + "was not written. The prospect is still reachable from the lane.",
                ReasoningKind.MISS, time.time()
            );
        }

        # Surfaced is what puts her on the dashboard and into RankAndSelect:
        # list_prospects reads Founder -> Run -> Lane -> Surfaced -> Prospect,
        # so HasWarmLead alone would leave her invisible.
        here +>:Surfaced(
            at_rank=1, found_at=time.time(), query="warm lead, named at intake"
        ):+> p;

        p.name = name;
        p.preferred_name = self.preferred_name or self.warm_name or name;
        p.handle = self.warm_url.rstrip("/").split("/")[-1];
        p.headline = headline;
        p.company = company;
        p.linkedin_url = str(profile.get("url") or self.warm_url);
        if self.warm_email {
            p.email = self.warm_email;
            # Known at intake: the one prospect that never needs the waterfall.
            p.email_source = EmailSource.PROVIDED;
            p.email_confidence = 1.0;
            # A = email plus content from one platform. RankAndSelect owns final
            # tiering and may promote to S once GitHub cross-links.
            p.tier = CompletenessTier.A;
        }

        p +>:Identity(
            tier=IdentityTier.VERIFIED, basis="warm lead named at intake",
            confidence=1.0
        ):+> LinkedinProfile(
            url=p.linkedin_url, handle=p.handle, name=name,
            headline=headline, company=company, about=about
        );

        if headline {
            self.attach_evidence(p, headline, EvidenceKind.HEADLINE, p.linkedin_url, -1);
        }
        if about {
            self.attach_evidence(p, about[:600], EvidenceKind.ABOUT, p.linkedin_url, -1);
        }

        # ---- contact info: where a github.com/<login> link often lives -----
        contact_url = self.warm_url.rstrip("/") + "/overlay/contact-info/";
        if self.browser.goto(contact_url) {
            contact: dict = self.browser.eval_json(CONTACT_JS) or {};
            links: list = contact.get("links") or [];
            self.contact_info_text = (str(contact.get("text") or "") + " "
                                      + " ".join([str(x) for x in links])).strip();
            gh = [x for x in links if "github.com" in str(x).lower()];
            if gh {
                here.narrate(
                    f"Their contact info lists {gh[0]} - that is a GitHub handle we "
                    + "can hand straight to the cross-link rather than guessing at.",
                    ReasoningKind.CROSSLINK, time.time()
                );
            }
        } else {
            # A failed goto leaves the tab on an error page, so re-navigate
            # rather than assume position before reading anything else.
            here.narrate(
                "Contact info would not open. Re-navigating to the profile before "
                + "reading further rather than trusting the tab's position.",
                ReasoningKind.MISS, time.time()
            );
            self.browser.goto(self.warm_url);
        }

        # ---- recent activity: what makes the email quotable ----------------
        activity_url = self.warm_url.rstrip("/") + "/recent-activity/all/";
        here.narrate(
            "Now reading their recent activity. A job title tells us what they "
            + "are; what they posted last week tells us what they are dealing with.",
            ReasoningKind.PLAN, time.time()
        );

        if self.browser.goto(activity_url) {
            activity: dict = self.browser.eval_json(ACTIVITY_JS) or {};
            items: list = activity.get("items") or [];
            if items {
                here.narrate(
                    f"{len(items)} recent post{'s' if len(items) != 1 else ''} from "
                    + f"{name}. Reading for something worth quoting back.",
                    ReasoningKind.OBSERVE, time.time()
                );
                bodies: list = [];
                for item in items[:5] {
                    quote: str = str(item.get("text") or "");
                    # The activity page echoes the person's own headline as a
                    # card. It reads like prose, so the JS-side chrome filter
                    # cannot catch it -- only the walker knows what the headline
                    # actually is. Quoting someone's job title back to them as
                    # "something you posted" is exactly the tell we are trying
                    # to avoid.
                    if quote and headline and (
                        quote.strip()[:80] == headline.strip()[:80]
                        or quote.strip() in headline
                        or headline.strip() in quote
                    ) {
                        continue;
                    }
                    if quote and name and quote.strip() == name.strip() {
                        continue;
                    }
                    if quote {
                        bodies.append(quote);
                        self.attach_evidence(
                            p, quote, EvidenceKind.POST, activity_url,
                            age_in_days(str(item.get("meta") or ""))
                        );
                    }
                }
                self.posts_text = "\n\n".join(bodies);
            } else {
                # A quiet profile is a real finding, not a failure. Outreach
                # needs to know it has nothing recent to quote.
                here.narrate(
                    f"{name} has no readable recent activity. The opening line will "
                    + "have to lean on their headline and role instead of a quote.",
                    ReasoningKind.OBSERVE, time.time()
                );
            }
        } else {
            here.narrate(
                "Their activity feed would not load. Continuing with the profile "
                + "evidence already gathered rather than failing the whole lane.",
                ReasoningKind.MISS, time.time()
            );
        }

        # ---- done ----------------------------------------------------------
        # OUTREACH hard-fails rather than send a generic email, so zero evidence
        # on THIS prospect kills the whole back half of the demo. Say so plainly.
        if self.evidence_written == 0 {
            here.state = LaneState.DRY;
            self.failure = "no quotable evidence found for the warm lead";
            here.narrate(
                f"Read {name}'s profile but found nothing quotable. Outreach "
                + "refuses to send a generic email, so this is a hard failure on "
                + "the one prospect the demo depends on.",
                ReasoningKind.MISS, time.time()
            );
        } else {
            here.state = LaneState.DONE;
            here.narrate(
                f"Lane W complete. {self.evidence_written} pieces of evidence on "
                + f"{name}"
                + (f", reachable at {self.warm_email}." if self.warm_email
                   else ", but no email was supplied at intake."),
                ReasoningKind.YIELD, time.time()
            );
        }
        self.browser.close_session();
        report p;
    }
}
