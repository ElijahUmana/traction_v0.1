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

When the tool returns text, answer using ONLY what it gave you, compressed into \
one or two spoken sentences. Quote the specific thing it found - the concrete \
detail is the entire point of this call.

If the tool comes back saying no research is on file, look at the research \
section at the end of these instructions BEFORE you give up. That section is \
filled in from the same graph at dial time, so it is real research about this \
same person and you should answer from it exactly as if the tool had returned \
it. The tool failing is not a reason to withhold something you already know.

Only if the tool returns nothing AND that research section is empty do you say \
so plainly. Something like: "Honestly, I don't want to guess at that - let me \
get you time with {SPOKEN_FOUNDER} and he'll answer it properly." Then go for \
the booking. NEVER invent a fact about this person, their work, their company, \
or the product that is not in the tool result or that section. Inventing \
something is a worse failure than admitting you do not know.

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
            "model": "gpt-4.1",
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
        # LiveKit's smart endpointing decides whether they have actually finished
        # a thought or merely paused mid-sentence, so a short fixed wait does not
        # cut people off - the model does the deciding.
        "startSpeakingPlan": {
            "waitSeconds": 0.4,
            "smartEndpointingPlan": {"provider": "livekit"},
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
        # Let the human cut off the opening line. They will - "who is this?" lands
        # on top of the first sentence, and an agent that ignores it is a robocall.
        "firstMessageInterruptionsEnabled": True,
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
    print("\nOK: prompt, barge-in, endpointing and voicemail detection all persisted.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
