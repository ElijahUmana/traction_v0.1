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

# The no-hallucination path. The dossier is blanked FIRST: voice.jac puts the
# research in the system prompt as well as behind the tool, so with a real
# dossier present a model quoting it is being accurate, not inventing. Only with
# nothing in either place does an assertion about this person count as made up.
prompt = prompt.replace(subs["dossier"], "")
t=[{"role":"user","content":"What do you know about me?"}]
r=ask(t)
tu=[c for c in r.get("content",[]) if c["type"]=="tool_use"]
if tu:
    t.append({"role":"assistant","content":r["content"]})
    t.append({"role":"user","content":[{"type":"tool_result","tool_use_id":tu[0]["id"],
        "content":"No research is on file for this call, so nothing specific can be claimed about this person."}]})
    r2=ask(t)
    said=" ".join(c["text"] for c in r2.get("content",[]) if c["type"]=="text").strip()
    invented=any(w in said.lower() for w in ["linkedin","github","headline","you wrote","you built","you posted"])
    honest=any(w in said.lower() for w in ["guess","not sure","don't have","dont have","honestly","can't say","cannot say"])
    ok = honest and not invented
    print(f"  [{'PASS' if ok else 'FAIL'}] empty tool result -> must admit, not invent")
    print(f"         says: {said[:200]!r}")
    results.append(ok)
else:
    print("  [FAIL] empty-tool-result path: no tool call to feed"); results.append(False)

print(f"\n{sum(results)}/{len(results)} passed")
