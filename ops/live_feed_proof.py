#!/usr/bin/env python3
"""Live proof of the TRACTION dashboard feed against the real server.

Connects 5 panels (as the real dashboard does), writes to the graph, pumps once
over HTTP->WS, and asserts every panel received the same fresh batch.
Writes the exact frames to /tmp/traction-evidence/ for docs/EVIDENCE.md.
"""
import asyncio
import json
import urllib.request
import websockets

BASE = "http://127.0.0.1:8000"
WS = "ws://127.0.0.1:8000/ws/walker/LiveFeed"
LEGACY = "ws://127.0.0.1:8000/ws/LiveFeed"
OUT = "/tmp/traction-evidence"


def post(path, body):
    req = urllib.request.Request(
        BASE + path, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


async def panel(name, url, got, ready):
    async with websockets.connect(url) as ws:
        ready.set()
        try:
            while True:
                m = json.loads(await asyncio.wait_for(ws.recv(), timeout=7))
                if m.get("type") in ("ping", "pong"):
                    continue
                got.append((name, m))
        except (asyncio.TimeoutError, websockets.ConnectionClosed):
            pass


async def main():
    got = []
    tasks, readies = [], []
    # 4 panels on the canonical route + 1 on the legacy alias, to prove they
    # share one broadcast bus.
    urls = [WS, WS, WS, WS, LEGACY]
    for i, u in enumerate(urls):
        ev = asyncio.Event()
        readies.append(ev)
        tasks.append(asyncio.create_task(panel(f"panel{i+1}", u, got, ev)))
    for ev in readies:
        await asyncio.wait_for(ev.wait(), 15)
    await asyncio.sleep(0.5)

    rounds = []
    async with websockets.connect(WS) as pump:
        for r in range(3):
            post("/walker/SeedRehearsalReasoning", {
                "confirm": "yes", "lane_id": "A",
                "sentence": f"live proof round {r}: lane emitted an observation",
                "kind": "observe"})
            batch = post("/function/feed_since", {"since": 0})["data"]["result"]
            await pump.send(json.dumps({
                "kind": "reasoning_batch", "seq": r,
                "batch": {
                    "next_seq": batch["next_seq"],
                    "reasoning_count": len(batch["reasoning"]),
                    "lane_count": len(batch["lanes"]),
                    "prospect_count": len(batch["prospects"]),
                },
                "note": f"round {r}"}))
            rounds.append(len(batch["reasoning"]))
            await asyncio.sleep(1.2)
        await asyncio.sleep(1.0)

    for t in tasks:
        t.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)

    names = sorted({n for n, _ in got})
    by_seq = {}
    for n, m in got:
        by_seq.setdefault(m["data"]["reports"][0]["seq"], set()).add(n)

    print(f"panels connected      : {len(urls)} (4 canonical + 1 legacy alias)")
    print(f"panels that received  : {len(names)} -> {names}")
    for s in sorted(by_seq):
        print(f"  round {s}: delivered to {len(by_seq[s])}/{len(urls)} panels")
    print(f"reasoning count per round (must strictly climb): {rounds}")
    ok_fanout = all(len(v) == len(urls) for v in by_seq.values()) and len(by_seq) == 3
    ok_fresh = rounds == sorted(rounds) and len(set(rounds)) == len(rounds)
    print("ALL_PANELS_EVERY_ROUND =", ok_fanout)
    print("VALUES_FRESH_NOT_FROZEN =", ok_fresh)

    sample = got[0][1] if got else {}
    with open(f"{OUT}/ws-frame-sample.json", "w") as f:
        json.dump(sample, f, indent=2)
    print(f"wrote {OUT}/ws-frame-sample.json")
    return 0 if (ok_fanout and ok_fresh) else 1


raise SystemExit(asyncio.run(main()))
