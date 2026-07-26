"""Live end-to-end proof of the conversion loop, driven in-process.

Runs the real walkers against the real services - AgentMail, Anthropic, Google
Calendar - without a server in the way, so the proof is of the walker bodies
themselves rather than of a particular HTTP deployment.

    jac run proof_outreach.jac

Rehearsal only. It sends a real email and creates a real calendar event, then
deletes the event again.
"""

import asyncio;
import time;

import from schema { Prospect, EmailThread, ReplyEvent, CallSession, Booking, Insight, Called }
import from rehearsal { SeedRehearsalProspect }
import from outreach { ComposeOutreach, SendOutreach, OnEmailReply }
import from voice { KbQuery, BookInterview, OnCallEnd, build_dossier }
import from gcal { delete_meeting }
import from svc { cfg }


def line(label: str) -> None {
    print("");
    print("=== " + label + " " + ("=" * (58 - len(label))));
}


def first(reports: list) -> dict {
    if not reports {
        return {};
    }
    return reports[0] as dict;
}


async def main -> None {
    line("1. SEED (rehearsal evidence, supplied not invented)");
    seeded = first((root spawn SeedRehearsalProspect(
        confirm="rehearsal",
        headline="Backend engineer working on agent infrastructure",
        company="Independent",
        linkedin_quote="Every time I add a new tool to my agent the retry logic drifts and I end up debugging timeouts instead of building features.",
        github_artifact="agent-runner - a small harness for retrying flaky tool calls",
        github_login="xingzhizhu"
    )).reports);
    pid = str(seeded.get("prospect_id", ""));
    print("prospect_id :", pid);
    print("name        :", seeded.get("name", ""));
    print("evidence    :", seeded.get("evidence", []));

    line("2. ComposeOutreach - byLLM, grounded in the graph");
    composed = first((await (root spawn ComposeOutreach(prospect_id=pid))).reports);
    print("refused     :", composed.get("refused", None));
    print("subject     :", composed.get("subject", ""));
    print("body        :");
    print(composed.get("body", ""));
    print("cited LI    :", str(composed.get("linkedin_quote", ""))[:70]);
    print("cited GH    :", composed.get("github_artifact", ""));

    line("3. Refusal gate - a prospect with no evidence must NOT produce an email");
    bare = root ++> Prospect(name="No Evidence Person", handle="none", email="nobody@example.com");
    refused = first((await (root spawn ComposeOutreach(prospect_id=jid(bare)))).reports);
    print("refused     :", refused.get("refused", None));
    print("reason      :", str(refused.get("reason", ""))[:150]);

    line("4. SendOutreach - REAL email through AgentMail");
    sent = first((await (root spawn SendOutreach(prospect_id=pid))).reports);
    print("to          :", sent.get("to", ""));
    print("thread_id   :", sent.get("thread_id", ""));
    print("message_id  :", str(sent.get("message_id", ""))[:60]);

    line("5. OnEmailReply - intent parsed out of a reply body");
    parsed = first((root spawn OnEmailReply(
        thread_id=str(sent.get("thread_id", "")),
        from_email=cfg("TEAMMATE_EMAIL", ""),
        text="Yes, this is exactly my problem. Call me now if you can - I am free for the next hour. My number is +1 281 299 1277. Tomorrow at 2pm also works."
    )).reports);
    print("intent      :", parsed.get("intent", ""));
    print("wants_call  :", parsed.get("wants_call", None));
    print("phone       :", parsed.get("phone_number", ""));
    print("times       :", parsed.get("proposed_times", []));
    print("sentiment   :", parsed.get("sentiment", ""));

    line("6. KbQuery - mid-call answer from the graph, hard <50ms budget");
    prospect = jobj(pid) as Prospect;
    dossier = build_dossier(prospect);
    # Attached exactly as ScheduleCall attaches it: under the Prospect, via Called.
    session = prospect +>:Called(initiated_at=time.time()):+> CallSession(
        vapi_call_id="rehearsal-call-1", kb_blob=dossier
    );
    print("dossier len :", len(dossier));
    print("dossier     :", dossier[:180] + "...");
    worst = 0.0;
    for _i in range(5) {
        t0 = time.time();
        answered = first((root spawn KbQuery(
            question="how does this actually help me",
            call_id="rehearsal-call-1"
        )).reports);
        took = (time.time() - t0) * 1000.0;
        if took > worst {
            worst = took;
        }
    }
    print("worst of 5  : " + str(round(worst, 2)) + " ms   (budget 50ms)");
    print("under budget:", worst < 50.0);
    docs = answered.get("documents", []) as list;
    if docs {
        doc: dict = docs[0] as dict;
        print("returned    :", str(doc.get("content", ""))[:110] + "...");
    }

    line("7. BookInterview - REAL Google Calendar event, invites both parties");
    booked = first((await (root spawn BookInterview(
        prospect_id=pid,
        start_time="",
        duration_minutes=20
    ))).reports);
    print("event_id    :", booked.get("event_id", ""));
    print("meet_link   :", booked.get("meet_link", ""));
    print("start       :", booked.get("start", ""));
    print("attendees   :", booked.get("attendees", []));
    spoken = booked.get("results", []) as list;
    if spoken {
        r: dict = spoken[0] as dict;
        print("tool result :", r.get("result", ""));
    }

    line("8. Booking node written to the graph");
    for b in [prospect --> [?:Booking]] {
        print("Booking     :", b.event_id, "|", b.meet_link, "|", b.attendees);
    }

    line("9. OnCallEnd - transcript distilled into Insight nodes");
    ended = first((root spawn OnCallEnd(
        call_id="rehearsal-call-1",
        transcript=(
            "Agent: You wrote that retry logic drifts every time you add a tool. "
            "Xingzhi: Yes, and it is worse because we ship on Fridays so nobody wants to touch it late in the week. "
            "Agent: How big is the team? "
            "Xingzhi: Just three of us, and I own all the agent infrastructure alone. "
            "Agent: Would Tuesday work? "
            "Xingzhi: Tuesday afternoon is fine, mornings I am always in standups."
        )
    )).reports);
    print("insights    :", len(ended.get("insights", []) as list));
    for ins in ended.get("insights", []) as list {
        item: dict = ins as dict;
        print("  - " + str(item.get("claim", "")));
    }

    line("10. CLEANUP - remove the rehearsal calendar event");
    if booked.get("event_id", "") {
        _ = await delete_meeting(str(booked["event_id"]));
        print("deleted     :", booked["event_id"]);
    }

    line("DONE");
}


with entry:__main__ {
    asyncio.run(main());
}
