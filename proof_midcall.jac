"""Proves the walkers parse Vapi's real mid-call tool-call envelope."""
import asyncio;
import time;
import from schema { Prospect, CallSession, Called }
import from rehearsal { SeedRehearsalProspect }
import from voice { KbQuery, BookInterview, build_dossier }
import from gcal { delete_meeting }

def first(r: list) -> dict { if not r { return {}; } return r[0] as dict; }

async def main -> None {
    s = first((root spawn SeedRehearsalProspect(
        confirm="rehearsal", name="Becky Zhu", preferred_name="Becky",
        email="xingzhizhu6@gmail.com", handle="xingzhi-zhu",
        headline="Program Manager @Oracle", company="Oracle",
        linkedin_quote="Hi, this is Xingzhi (Becky) Zhu, UCLA alum double majoring in Business Economics and Statistics and Data Science. I am passionate about turning messy data into decisions people actually act on."
    )).reports);
    pid = str(s.get("prospect_id",""));
    p = jobj(pid) as Prospect;
    # A CallSession exactly as ScheduleCall creates it.
    _ = p +>:Called(initiated_at=time.time()):+> CallSession(
        vapi_call_id="019fa0e2-LIVE", kb_blob=build_dossier(p)
    );

    print("=== A. KbQuery: Vapi tool-call envelope (mid-call question) ===");
    kb = first((root spawn KbQuery(message={
        "type": "tool-calls",
        "call": {"id": "019fa0e2-LIVE"},
        "toolCallList": [{"id": "toolu_ABC123", "function": {
            "name": "answer_from_graph",
            "arguments": {"question": "how does this actually help me"}}}]
    })).reports);
    res = kb.get("results", []) as list;
    r0: dict = res[0] as dict;
    print("  toolCallId echoed :", r0.get("toolCallId",""));
    print("  tool name         :", r0.get("name",""));
    print("  elapsed_ms        :", round(float(kb.get("elapsed_ms",0)),3));
    print("  resolved_by       :", kb.get("resolved_by",""));
    print("  question parsed   :", kb.get("question",""));
    print("  answer (spoken)   :", str(r0.get("result",""))[:120]);

    print("");
    print("=== B. BookInterview: Vapi tool-call envelope (mid-call booking) ===");
    bk = first((await (root spawn BookInterview(message={
        "type": "tool-calls",
        "call": {"id": "019fa0e2-LIVE"},
        "toolCallList": [{"id": "toolu_XYZ789", "function": {
            "name": "book_interview",
            "arguments": {"start_time": "", "duration_minutes": 20}}}]
    }))).reports);
    bres = bk.get("results", []) as list;
    b0: dict = bres[0] as dict;
    print("  toolCallId echoed :", b0.get("toolCallId",""));
    print("  resolved prospect :", bk.get("prospect",""));
    print("  spoken result     :", b0.get("result",""));
    print("  meet_link         :", bk.get("meet_link",""));
    print("  attendees         :", bk.get("attendees",[]));
    ev = str(bk.get("event_id",""));
    if ev { _ = await delete_meeting(ev); print("  cleaned up        :", ev); }
}
with entry:__main__ { asyncio.run(main()); }
