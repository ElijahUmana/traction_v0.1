#!/usr/bin/env python3
"""Configure the Vapi assistant TRACTION actually calls people with.

Why this file exists
--------------------
The assistant on this account was a stock Vapi sample - "Riley, an appointment
scheduling voice assistant for Wellness Partners, a multi-specialty health
clinic". That is not a guess: call 019fa0e2-6cc5-766a-a197-80eadccc22a6 stored
the system prompt it actually ran with, and it is the clinic template verbatim.
`voice.jac` overrides `firstMessage` and appends the two mid-call tools at call
time, which is exactly why "Hi, Becky" sounded right and nothing after it was
ever proven - the moment the human says a word, the model is steering off a
health-clinic receptionist prompt that has never heard of the tools.

Everything here is Vapi-side configuration. It touches no Jac. The tools stay
OFF the assistant on purpose: voice.jac appends them per call through
`assistantOverrides["tools:append"]`, and declaring them here as well would
hand the model two copies of every tool.

    ops/vapi_assistant.py            show the live config diffed against target
    ops/vapi_assistant.py --apply    PATCH it, then read it back and verify
"""
import json
import os
import sys
import urllib.error
import urllib.request

ASSISTANT_ID = "4534de4a-eff5-4c58-ae66-916faf724249"
BASE = "https://api.vapi.ai"


def env(name: str) -> str:
    """Read a key from .env without importing a dependency for it."""
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    with open(os.path.join(here, ".env"), encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line.startswith(f"{name}="):
                return line.split("=", 1)[1].strip().strip('"')
    raise SystemExit(f"{name} is not set in .env")


# The founder's surname is the one word in the script a stranger cannot guess,
# and the first live call rendered "Umana" as "Yamana". TTS reads whatever the
# model writes, so the fix is to make the model write the sounds. This mirrors
# SPOKEN_NAME in .env, which voice.jac uses for the opening line only - past the
# first sentence the model is on its own, which is what this covers.
SPOKEN_FOUNDER = "Elijah Oo-MAH-nah"

SYSTEM_PROMPT = f"""\
You are the voice of TRACTION, an AI outreach agent calling on behalf of \
{{{{founder_name}}}}. You are on a live phone call with {{{{prospect_name}}}}, \
who replied to an email from us minutes ago and agreed to a call.

Right now it is {{{{"now" | date: "%A, %B %d, %Y at %I:%M %p", "America/Los_Angeles"}}}} \
in California. Use this to resolve anything they say about time.

## Pronunciation
When you say the founder's name out loud, always write it as "{SPOKEN_FOUNDER}". \
Never write "Umana" - the speech engine mispronounces it. Say "TRACTION" as a \
normal English word.

## How you speak
This is a phone call, not an essay. One or two sentences per turn. Under thirty \
words. No lists, no headings, no bullet points, no emoji - every character you \
write is spoken aloud.
Use contractions. Sound like a competent person who respects their time, not a \
script. Never say "as an AI language model". Ask one question at a time, then \
stop talking and let them answer.
If they interrupt you, stop and listen. Do not finish your sentence.

## What you are calling about
{{{{founder_name}}}} is building: {{{{product_one_liner}}}}
You are calling to book a short interview with {{{{prospect_name}}}} - that is \
the only outcome that matters on this call.

## THE TOOL RULE - this is the most important instruction here
You have a tool called `answer_from_graph`. It reads the research our system \
actually did on this specific person: what they wrote publicly, what they built, \
why they were ranked first.

Call `answer_from_graph` BEFORE you answer any question about substance. That \
includes, and is not limited to: "how does this help me", "why are you calling \
me", "what do you know about me", "what is this", "who are you", "why me", \
"what does he do", "how did you find me", and any scepticism or pushback.

You may answer WITHOUT the tool only for pure logistics - what time works, \
confirming you heard a time correctly, or saying goodbye.

## YOU ALWAYS HAVE ENOUGH. NEVER DECLINE TO ANSWER.
The research section at the end of these instructions is filled in before the \
call from our graph. It is always there, and it is always about the person you \
are speaking to right now. **You therefore always have enough to answer.**

Answer every question directly and confidently, from that research plus what \
you know about the product. Connect their actual background to what \
{{{{founder_name}}}} built.

These are BANNED. Never say them, in any wording:
- "I don't want to guess"
- "I want to be accurate"
- "Let me get you time with him and he'll answer that properly"
- "I can't answer that" / "I'm not sure" / "I don't have that"
- Any deferral of a question to the founder
- Any filler that buys time: "one moment", "give me a moment", "give me a \
second", "let me check", "bear with me", "hold on"

Deferring a question is a failure. So is dead air. Answer immediately, in one \
or two short sentences, and keep moving toward the booking.

If `answer_from_graph` returns nothing, an error, or "no result" - which \
happens, and is not your problem - **just answer from the research section \
below as though the tool had returned it.** Do not mention the tool, do not \
mention a lookup, do not apologise. The prospect must never be able to tell \
that anything failed.

The ONE thing you must never do is state a specific fact about this person - a \
job, an employer, a school, something they wrote - that does not appear in the \
research below or in a tool result. Everything present there, use freely and \
confidently. Beyond it, talk about the product instead of inventing detail.

## The research section is scraped, and it carries junk
The research at the end of these instructions is scraped from LinkedIn. It \
often has page furniture glued onto the end of it - phrases like "More profiles \
for you", "Show all", "Explore Premium profiles", "Connect", "Message" - and \
after those phrases come OTHER PEOPLE'S names, job titles and employers, \
scraped from a sidebar. Those people are strangers. They have nothing to do \
with this call.

Treat everything from the first such phrase onward as garbage. Never read it \
out. The only names you may ever say on this call are {{{{prospect_name}}}} and \
the founder's. If you are about to say any other person's name, a university, \
or an employer that came from that trailing text, stop - it is scraper \
residue, not research. Quoting a stranger's name back at someone is the single \
most damaging thing you could do on this call.

## Say their name properly, and lead with the reason
Their name is {{{{prospect_name}}}}. Say it in full, exactly as written. Never \
shorten it, never clip it, never substitute a nickname - "Beck" instead of \
"Becky" is the kind of thing that makes a call sound automated.

Do NOT open by asking for a time. On the first exchange, give ONE sentence \
saying why you are calling THEM specifically, grounded in the research below - \
the thing they wrote, the work they do. Then ask for a time. A booking request \
with no reason attached is a robocall, and it gives them nothing to react to.

## Booking
The moment they name any time that works - "Thursday at two", "tomorrow \
afternoon", "how about Monday morning" - call `book_interview` immediately. Do \
not ask them to confirm a time they just gave you.
Resolve what they said into an ISO 8601 datetime with the California offset, \
against the current date above. If they only give a vague part of a day, pick \
the sensible hour: morning is 10am, afternoon is 2pm, evening is 5pm. Default \
the meeting to 30 minutes.
Read a time back only when you genuinely could not tell what they meant.

## If it is a bad time
If they say now is not good, do not push. Ask for one time later this week that \
would work, book that, and let them go.

## Ending
Once the booking is confirmed, say the invite is on its way to their email, \
thank them by name, and say goodbye. Do not keep selling after you have won.

## Research on this specific person
{{{{dossier}}}}
"""


def target() -> dict:
    return {
        "name": "TRACTION Outreach",
        "firstMessage": (
            "Hi, this is an AI assistant calling on behalf of "
            f"{SPOKEN_FOUNDER}. Is now still a good time?"
        ),
        "model": {
            "provider": "openai",
            # Measured on call 019fa100: median turn latency 1.80s. gpt-4.1's
            # time-to-first-token is the largest single slice of that, and this
            # call needs speed far more than it needs reasoning depth - the hard
            # thinking already happened in the graph. gpt-4.1-mini keeps
            # OpenAI's tool-calling behaviour (both tools fired correctly and
            # unprompted at 1.80s median) at a materially faster first token.
            "model": "gpt-4.1-mini",
            # 0.5 on a booking call buys nothing but variance. The demo needs the
            # same behaviour every rehearsal, and low temperature also makes the
            # model far more willing to emit a tool call instead of improvising
            # an answer it does not have.
            "temperature": 0.2,
            # A hard ceiling on how long any single turn can run. The prompt asks
            # for under thirty words; this makes a rambling turn impossible
            # rather than merely discouraged.
            "maxTokens": 180,
            "messages": [{"role": "system", "content": SYSTEM_PROMPT}],
        },
        "voice": {"provider": "vapi", "voiceId": "Elliot"},
        "transcriber": {
            "provider": "deepgram",
            "model": "nova-3",
            "language": "en",
            # The three words this call turns on that generic English ASR gets
            # wrong: the founder's surname, the prospect's name, the product.
            "keyterm": ["Umana", "Becky", "Traction"],
            # Without this, "Thursday at two" can transcribe as prose and the
            # model has to guess. Smart formatting renders times, dates and
            # phone numbers as numerals, which is what the booking tool needs.
            "smartFormat": True,
            "endpointing": 150,
        },
        # waitSeconds is the pause after the human stops before the agent starts.
        # Measured at 0.4 on call 019fa100: turn latency min 1.51s, median 1.80s,
        # max 1.90s across four turns. Halved to 0.2, and the LiveKit wait
        # function is steepened so that a confident end-of-turn is acted on much
        # sooner. The default is 20 + 500*sqrt(x) + 2500*x^3; this pays roughly
        # half that at every confidence level, while still scaling with
        # uncertainty so a mid-sentence pause is not treated as a finished turn.
        "startSpeakingPlan": {
            "waitSeconds": 0.2,
            "smartEndpointingPlan": {
                "provider": "livekit",
                "waitFunction": "20 + 250 * sqrt(x) + 1200 * x^3",
            },
        },
        # Barge-in. numWords 0 means voice activity alone stops the agent, rather
        # than waiting for two words to be transcribed first - the difference
        # between an agent that yields and one that talks through you.
        "stopSpeakingPlan": {
            "numWords": 0,
            "voiceSeconds": 0.3,
            "backoffSeconds": 1.0,
        },
        # The previous call reached a full mailbox and monologued at it. Detection
        # is audio-based so it costs no answer delay, and with a voicemailMessage
        # set Vapi leaves it and hangs up instead of running the whole script.
        "voicemailDetection": {
            "provider": "vapi",
            "backoffPlan": {
                "startAtSeconds": 5.0,
                "frequencySeconds": 5.0,
                "maxRetries": 6,
            },
        },
        "voicemailMessage": (
            f"Hi, this is an assistant calling for {SPOKEN_FOUNDER} about the "
            "email you replied to. I'll follow up by email instead. Thanks."
        ),
        # The last thing spoken on every call, and the field that caught me out.
        # Overwriting firstMessage and the system prompt is not enough: the stock
        # template's endCallMessage survived both, and on call 019fa108 the final
        # words the prospect heard were "Thank you for scheduling with Wellness
        # Partners. Your appointment is confirmed." A clinic sign-off is bad
        # anywhere; as the closing line in front of judges it is the worst
        # possible placement.
        #
        # It must stay generic and must not claim anything. This string plays
        # unconditionally whenever the assistant ends the call - including calls
        # where nobody booked, where they said no, and where the booking tool
        # failed. So it cannot name a prospect (it would call the next one
        # "Becky") and it cannot promise an invite (019fa108 already told her an
        # invite was coming when no booking existed). Whether a booking happened
        # is known to the model, not to this field, so the model says that line
        # and this one only says goodbye.
        "endCallMessage": "Thanks so much for your time. Speak soon.",
        # Let the human cut off the agent - but NOT during the opening line.
        # On 019fa108 the opener died mid-word at "...calling on", 2.7s in, and
        # she never heard why we were calling; she then asked "Hello?" into the
        # gap. That is the cost of numWords 0: any 0.3s of sound, including line
        # noise or a reflexive "hello", stops the agent. Aggressive barge-in is
        # right for the body of the call - it is proven working, three real
        # overlaps on that same call - but the first sentence is the only one
        # carrying WHY we are calling, so it has to survive to the end of itself.
        "firstMessageInterruptionsEnabled": False,
        "backgroundDenoisingEnabled": True,
        # Lets the model hang up itself once the booking is done, instead of
        # sitting on a dead line until the silence timeout fires.
        "endCallFunctionEnabled": True,
        "endCallPhrases": ["goodbye", "talk to you soon", "bye for now"],
        "silenceTimeoutSeconds": 30,
        "maxDurationSeconds": 420,
        "serverMessages": ["end-of-call-report"],
    }


def api(method: str, path: str, body: dict | None = None) -> dict:
    req = urllib.request.Request(
        f"{BASE}{path}",
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={
            "Authorization": f"Bearer {env('VAPI_API_KEY')}",
            "Content-Type": "application/json",
            # Cloudflare sits in front of api.vapi.ai and answers the default
            # Python-urllib agent with a 403 "error code: 1010" that looks
            # exactly like a bad API key. It is not - it is the user agent.
            "User-Agent": "traction-ops/1.0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode()
        # Vapi returns the offending field names in the body. Surfacing that
        # verbatim is the difference between one iteration and five.
        raise SystemExit(f"HTTP {exc.code} on {method} {path}\n{detail}")


def summarise(cfg: dict) -> dict:
    """The fields that decide whether this call converses or flounders."""
    prompt = ""
    for msg in (cfg.get("model") or {}).get("messages") or []:
        if msg.get("role") == "system":
            prompt = msg.get("content", "")
    return {
        "name": cfg.get("name"),
        "prompt_identity": prompt[:70].replace("\n", " "),
        "prompt_chars": len(prompt),
        "mentions_answer_from_graph": "answer_from_graph" in prompt,
        "mentions_book_interview": "book_interview" in prompt,
        "model": (cfg.get("model") or {}).get("model"),
        "temperature": (cfg.get("model") or {}).get("temperature"),
        "maxTokens": (cfg.get("model") or {}).get("maxTokens"),
        "transcriber": (cfg.get("transcriber") or {}).get("model"),
        "smartFormat": (cfg.get("transcriber") or {}).get("smartFormat"),
        "keyterm": (cfg.get("transcriber") or {}).get("keyterm"),
        "startSpeakingPlan": cfg.get("startSpeakingPlan"),
        "stopSpeakingPlan": cfg.get("stopSpeakingPlan"),
        "voicemailDetection": (cfg.get("voicemailDetection") or {}).get("provider"),
        "firstMessageInterruptionsEnabled": cfg.get("firstMessageInterruptionsEnabled"),
        "endCallFunctionEnabled": cfg.get("endCallFunctionEnabled"),
        "backgroundDenoisingEnabled": cfg.get("backgroundDenoisingEnabled"),
        "silenceTimeoutSeconds": cfg.get("silenceTimeoutSeconds"),
        "maxDurationSeconds": cfg.get("maxDurationSeconds"),
    }


def main() -> int:
    live = api("GET", f"/assistant/{ASSISTANT_ID}")
    print("=== BEFORE ===")
    print(json.dumps(summarise(live), indent=2))

    if "--apply" not in sys.argv:
        print("\n(dry run - pass --apply to PATCH)")
        return 0

    api("PATCH", f"/assistant/{ASSISTANT_ID}", target())
    # Read back rather than trusting the PATCH response: Vapi silently drops
    # fields it does not recognise, so the only proof a setting took is fetching
    # it again.
    after = api("GET", f"/assistant/{ASSISTANT_ID}")
    print("\n=== AFTER (read back from the API) ===")
    print(json.dumps(summarise(after), indent=2))

    missing = [
        key
        for key in ("startSpeakingPlan", "stopSpeakingPlan", "voicemailDetection")
        if not after.get(key)
    ]
    if missing:
        print(f"\n!! these did NOT persist: {missing}")
        return 1

    # Sweep the WHOLE object for stock-template text rather than checking the
    # fields I remembered. endCallMessage survived every earlier patch precisely
    # because it was never on that list, and it is spoken last on every call.
    # Any string field can carry the template, so any string field gets checked.
    def strings(obj, path=""):
        if isinstance(obj, dict):
            for k, v in obj.items():
                yield from strings(v, f"{path}.{k}")
        elif isinstance(obj, list):
            for i, v in enumerate(obj):
                yield from strings(v, f"{path}[{i}]")
        elif isinstance(obj, str):
            yield path, obj

    stock = [
        (p, v[:120])
        for p, v in strings(after)
        if any(w in v for w in ("Wellness Partners", "Riley", "multi-specialty"))
    ]
    if stock:
        print("\n!! STOCK TEMPLATE TEXT IS STILL LIVE ON THIS ASSISTANT:")
        for p, v in stock:
            print(f"   {p} = {v!r}")
        return 1

    print("\nOK: prompt, barge-in, endpointing and voicemail detection all persisted.")
    print("OK: no Wellness Partners / Riley text anywhere on the assistant.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
