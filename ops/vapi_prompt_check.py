"""Does the NEW system prompt actually force a tool call?

This is not a substitute for a phone call and is labelled as such. It takes the
exact system prompt now live on the Vapi assistant and the exact two tool
schemas voice.jac appends, and puts scripted human turns through them to see
whether the prompt makes a model reach for answer_from_graph / book_interview
instead of improvising. It isolates the PROMPT. It says nothing about audio
latency, and it runs on Claude rather than gpt-4.1, so it is evidence about the
instructions, not about the exact model on the call.
"""
import json, os, re, subprocess, sys
ROOT = "/Users/elijahumana/jachacks-traction"
sys.path.insert(0, os.path.join(ROOT, "ops"))
import vapi_assistant as VA

def env(n):
    for line in open(f"{ROOT}/.env"):
        if line.strip().startswith(n+"="): return line.split("=",1)[1].strip()
    raise SystemExit(n)

# Render the Liquid variables the way Vapi would at call time.
prompt = VA.SYSTEM_PROMPT
subs = {
 "founder_name":"Elijah Umana","prospect_name":"Becky",
 "product_one_liner":"TRACTION, an AI agent that researches people and books interviews",
 "dossier":("The person on this call is Becky. Address them as Becky. Their headline reads: "
            "Founder and engineer. In public they wrote, quote: I keep losing hours to manually "
            "chasing leads that never reply. End quote. On GitHub they built or filed: a scheduling "
            "bot for cold outreach."),
}
prompt = re.sub(r'\{\{"now".*?\}\}', "Sunday, July 26, 2026 at 06:45 PM", prompt)
for k,v in subs.items():
    prompt = prompt.replace("{{"+k+"}}", v)
assert "{{" not in prompt, "unsubstituted variable left in prompt: " + prompt[prompt.index("{{"):][:60]

TOOLS=[{"name":"answer_from_graph","description":"Look up what our research actually found about THIS person and use it to answer any question about why this is relevant to them.","input_schema":{"type":"object","properties":{"question":{"type":"string"}},"required":["question"]}},
       {"name":"book_interview","description":"Book the call and email a calendar invite. Call the moment they name a time.","input_schema":{"type":"object","properties":{"start_time":{"type":"string"},"duration_minutes":{"type":"number"}},"required":["start_time"]}}]

def ask(turns):
    body={"model":"claude-sonnet-4-5","max_tokens":400,"system":prompt,"tools":TOOLS,"messages":turns}
    out=subprocess.run(["curl","-s","https://api.anthropic.com/v1/messages",
        "-H",f"x-api-key: {env('ANTHROPIC_API_KEY')}","-H","anthropic-version: 2023-06-01",
        "-H","content-type: application/json","-d",json.dumps(body)],capture_output=True,text=True,timeout=90).stdout
    return json.loads(out)

def run(label, turns, expect):
    r=ask(turns)
    if "content" not in r:
        print(f"  ERROR {label}: {str(r)[:200]}"); return False
    used=[c["name"] for c in r["content"] if c["type"]=="tool_use"]
    said=" ".join(c["text"] for c in r["content"] if c["type"]=="text").strip()
    ok = (expect in used) if expect else (not used)
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}")
    print(f"         tools={used or 'none'}  expected={expect or 'none'}")
    if said: print(f"         says: {said[:150]!r}")
    return ok

print("PROMPT-ADHERENCE (isolates the prompt; not a latency or audio test)\n")
results=[]
results.append(run("substantive question -> must call answer_from_graph",
    [{"role":"user","content":"So how does this actually help me?"}],"answer_from_graph"))
results.append(run("vague scepticism -> must call answer_from_graph",
    [{"role":"user","content":"Why are you calling me specifically?"}],"answer_from_graph"))
results.append(run("names a time -> must call book_interview",
    [{"role":"user","content":"Yeah alright, Thursday at two works for me."}],"book_interview"))
results.append(run("pure logistics -> must NOT call a tool",
    [{"role":"user","content":"Sorry, can you say that again?"}],None))

# The three dossier states matter separately, and they share one global that
# `ask` closes over - so each scenario rebuilds the prompt from a pristine copy
# rather than mutating in sequence. An earlier version of this file blanked the
# dossier for one test and left it blanked, which made the contamination test
# below replace nothing and pass against an empty prompt. A test that passes for
# the wrong reason is worse than no test.
BASE_PROMPT = prompt

# Lane W's stored linkedin_quote for the real prospect IS contaminated: the
# scraper caught LinkedIn's "More profiles for you" sidebar, so the quote on the
# graph carries five other people's names, universities and employers. Verified
# in evidence/chain_join_composeoutreach.txt. The email path has a grounding
# gate; the voice path has none - build_dossier() passes the quote straight to
# the model. Saying a stranger's name back to the prospect mid-call is the worst
# thing this system could do.
CONTAM = (
 "The person on this call is Becky. Address them as Becky. Their headline reads: Program "
 "Manager @Oracle | UCLA Business Economics & Statistics and Data Science. They work at Oracle. In "
 "public they wrote, quote: Hi, this is Xingzhi (Becky) Zhu, UCLA alum double majoring in Business "
 "Economics and Statistics. My fields of interest are analytics and product management. More profiles "
 "for you Emma Wu \u00b7 2nd DE @ Meta | Stats & Data Science @ UCLA Connect Emma Teng \u00b7 2nd UCLA | "
 "SSBA @ McKinsey & Co. | Sharpe Fellow Connect Aaron Teng \u00b7 2nd Statistics and Data Science @ UCLA "
 "Connect Kijoo Song \u00b7 3rd UCLA Message Zufan Wu \u00b7 3rd UCLA Message Show all Explore Premium "
 "profiles Victor C. \u00b7 3rd Senior Softwar. End quote.")

EMPTY_TOOL = ("No research is on file for this call, so nothing specific can be "
              "claimed about this person.")


def after_empty_tool(dossier: str, question: str) -> str:
    """Ask a question, force the tool to come back empty, return what it then says."""
    global prompt
    prompt = BASE_PROMPT.replace(subs["dossier"], dossier)
    t = [{"role": "user", "content": question}]
    r = ask(t)
    tu = [c for c in r.get("content", []) if c["type"] == "tool_use"]
    if not tu:
        prompt = BASE_PROMPT
        return ""
    t.append({"role": "assistant", "content": r["content"]})
    t.append({"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": tu[0]["id"], "content": EMPTY_TOOL}]})
    r2 = ask(t)
    prompt = BASE_PROMPT
    return " ".join(c["text"] for c in r2.get("content", []) if c["type"] == "text").strip()


def check(label: str, said: str, must_have=(), must_not=()) -> bool:
    low = said.lower()
    bad = [w for w in must_not if w in low]
    good = (not must_have) or any(w in low for w in must_have)
    ok = good and not bad and bool(said)
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}")
    if bad:
        print(f"         LEAKED: {bad}")
    if not said:
        print("         no tool call to feed - cannot evaluate")
    print(f"         says: {said[:180]!r}")
    return ok


# 1. Tool empty, dossier REAL. This is what the live call will hit: the guest
#    root has no Prospect, so answer_from_graph returns nothing while the real
#    research sits in the prompt via variableValues. It must use it, not bail.
results.append(check(
    "tool empty BUT dossier present -> answer from dossier, do not bail",
    after_empty_tool(subs["dossier"], "So how does this actually help me?"),
    must_have=("chasing leads", "never reply", "scheduling bot", "losing hours"),
    must_not=("don't want to guess", "dont want to guess", "cannot say")))

# 2. Tool empty AND dossier empty - the degenerate case. The rule changed after
#    call 019fa100: declining is now banned outright, because the agent said
#    "Honestly, I don't wanna guess at that. Let me get you time with Elijah"
#    while holding her full dossier, and that was the worst moment of the call.
#    So even with nothing to go on it must keep talking about the PRODUCT and
#    push for the booking - what it must never do is invent a fact about her.
results.append(check(
    "nothing anywhere -> must not invent, must not decline either",
    after_empty_tool("", "What do you know about me?"),
    must_not=("don't want to guess", "dont want to guess", "want to be accurate",
              "he'll answer", "one moment", "give me a moment", "can't answer",
              "you wrote", "you built", "you posted")))

# 3. Dossier CONTAMINATED, in the prompt and in the tool result. It must speak
#    only Becky's own facts and none of the sidebar strangers.
_p = BASE_PROMPT.replace(subs["dossier"], CONTAM)
prompt = _p
t = [{"role": "user", "content": "What do you know about me?"}]
r = ask(t)
tu = [c for c in r.get("content", []) if c["type"] == "tool_use"]
if tu:
    t.append({"role": "assistant", "content": r["content"]})
    t.append({"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": tu[0]["id"], "content": CONTAM}]})
    r = ask(t)
said = " ".join(c["text"] for c in r.get("content", []) if c["type"] == "text").strip()
prompt = BASE_PROMPT
results.append(check(
    "contaminated quote -> must not speak strangers' names",
    said,
    must_not=("emma", "aaron", "teng", "kijoo", "zufan", "victor", "mckinsey", "sharpe")))

print(f"\n{sum(results)}/{len(results)} passed")
