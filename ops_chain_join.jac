"""Joined chain, COMPOSE-ONLY: Lane W's real prospect -> ComposeOutreach.

Deliberately stops before SendOutreach. A live Vapi call to the same human was
in progress when this was run; emailing her mid-call would be worse than an
unproven step. The send path is independently proven in proof_outreach.jac.

Also dumps the full stored About evidence beside the drafted body, so the
grounding gate's verdict can be adjudicated rather than guessed at.
"""
import asyncio;
import from schema { Founder, Prospect, Evidence, EmailThread, HasWarmLead, HasEvidence, Outreach, Identity, Runs, HasLane, Surfaced }
import from outreach { ComposeOutreach }

def counts(label: str) -> None {
    fs = [root --> [?:Founder]];
    warm = [fs ->:HasWarmLead:->];
    surf = [fs ->:Runs:-> ->:HasLane:-> ->:Surfaced:->];
    people: list[Prospect] = [];
    for p in warm + surf { if p not in people { people.append(p); } }
    print("[" + label + "] founders=" + str(len(fs)) + " prospects=" + str(len(people))
          + " evidence=" + str(len([people ->:HasEvidence:->]))
          + " identities=" + str(len([people ->:Identity:->]))
          + " threads=" + str(len([people ->:Outreach:->])));
}

async def main -> None {
    counts("A after Lane W");
    fs = [root --> [?:Founder]];
    warm = [fs ->:HasWarmLead:->];
    if not warm { print("NO WARM LEAD - run lane_w_proof.jac first"); return; }
    b = warm[0];
    print("    prospect:", b.name, "| tier", str(b.tier), "| email", b.email, "|", str(b.email_source));

    print("");
    print("--- FULL STORED EVIDENCE (what the gate compares against) ---");
    for e in [b ->:HasEvidence:->] {
        print("  kind=" + str(e.kind) + "  len=" + str(len(e.quote)) + "  url=" + e.url[:60]);
        print("  QUOTE: " + e.quote);
        print("");
    }

    print("=== ComposeOutreach (compose only; SendOutreach deliberately NOT run) ===");
    res = await (root spawn ComposeOutreach(prospect_id=jid(b)));
    if not res.reports { print("    NO REPORTS"); return; }
    r = res.reports[0] as dict;
    body = str(r.get("body", ""));
    print("    refused     :", r.get("refused", None));
    print("    reason      :", str(r.get("reason", ""))[:200]);
    print("    addressed_as:", r.get("addressed_as", ""));
    print("    subject     :", r.get("subject", ""));
    print("    BODY:");
    print(body);

    print("");
    print("--- ADJUDICATION: is the drafted citation actually in the stored evidence? ---");
    for e in [b ->:HasEvidence:->] {
        q = e.quote.lower();
        # does any 8-word run of the stored quote appear in the body?
        words = q.split();
        hit = "";
        i = 0;
        while i + 8 <= len(words) {
            run = " ".join(words[i:i+8]);
            if run in body.lower() { hit = run; break; }
            i += 1;
        }
        print("  " + str(e.kind) + ": 8-word run present in body? " + str(hit != "") + ("  ->  '" + hit + "'" if hit else ""));
    }
    print("");
    counts("B after compose");
}
with entry:__main__ { asyncio.run(main()); }
