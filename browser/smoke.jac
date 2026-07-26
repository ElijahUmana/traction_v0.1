"""Layers 1-3 against a REAL Browserbase browser: REST -> wss -> CDP."""

import from browserbase { Browserbase }
import from cdp { CDP }

with entry {
    bb = Browserbase();
    print("[smoke] creating session...");
    sess = bb.create_session();
    sid = sess["id"];
    connect_url = sess["connectUrl"];
    print(f"[smoke] session={sid}");
    # Print the shape, never the key.
    print(f"[smoke] connectUrl host-part={connect_url.split('?')[0]} query_params={len(connect_url.split('?')[1].split('&')) if '?' in connect_url else 0}");

    try {
        print("[smoke] opening wss (pure-Jac TLS websocket)...");
        cdp = CDP(ws_url=connect_url);
        print("[smoke] WS_UPGRADE_OK=True");

        ver = cdp.call("Browser.getVersion");
        print(f"[smoke] browser={ver.get('product')}");

        page_session = cdp.attach_page();
        print(f"[smoke] ATTACH_OK sessionId={page_session[:12]}...");

        res = cdp.call(
            "Runtime.evaluate",
            {"expression": "1+1", "returnByValue": True},
            session_id=page_session
        );
        value = res["result"]["value"];
        print(f"[smoke] eval 1+1 = {value}");
        print(f"[smoke] CDP_ROUNDTRIP_OK={value == 2}");
        cdp.close();
    } finally {
        print("[smoke] releasing session...");
        bb.release(sid);
        print("[smoke] released");
    }
}
