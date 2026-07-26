"""RFC 6455 conformance for the Jac frame codec — no network required.

    jac run traction/browser/ws_frame_test.jac
"""

import struct;
import from browser.ws { build_frame, mask_payload, OP_TEXT, OP_BINARY, OP_PING }

"""Decode a client frame back into (fin, opcode, payload) to close the loop."""
def decode_client_frame(raw: bytes) -> tuple[bool, int, bytes] {
    b0 = raw[0];
    b1 = raw[1];
    fin = (b0 & 0x80) != 0;
    opcode = b0 & 0x0F;
    masked = (b1 & 0x80) != 0;
    ln = b1 & 0x7F;
    off = 2;
    if ln == 126 {
        ln = struct.unpack("!H", raw[off:off + 2])[0];
        off += 2;
    } elif ln == 127 {
        ln = struct.unpack("!Q", raw[off:off + 8])[0];
        off += 8;
    }
    mask = raw[off:off + 4] if masked else bytes();
    off += 4 if masked else 0;
    body = raw[off:off + ln];
    if masked {
        body = mask_payload(body, mask);
    }
    return (fin, opcode, body);
}

with entry {
    failures = 0;

    # ---- RFC 6455 §5.7, the canonical masked "Hello" ----------------------
    # "A single-frame masked text message" is specified byte for byte:
    #   0x81 0x85 0x37 0xfa 0x21 0x3d 0x7f 0x9f 0x4d 0x51 0x58
    expected = bytes([0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d,
                      0x7f, 0x9f, 0x4d, 0x51, 0x58]);
    got = build_frame("Hello".encode(), OP_TEXT, bytes([0x37, 0xfa, 0x21, 0x3d]));
    ok = got == expected;
    failures += 0 if ok else 1;
    print(f"  {'ok  ' if ok else 'FAIL'} RFC 6455 §5.7 masked 'Hello' vector");
    if not ok {
        print(f"       want {expected.hex()}");
        print(f"       got  {got.hex()}");
    }

    # ---- masking is involutive --------------------------------------------
    key = bytes([0xDE, 0xAD, 0xBE, 0xEF]);
    body = "the quick brown fox jumps over the lazy dog".encode();
    ok = mask_payload(mask_payload(body, key), key) == body;
    failures += 0 if ok else 1;
    print(f"  {'ok  ' if ok else 'FAIL'} masking twice restores the payload");

    # ---- a bad key must be rejected, not silently truncated ---------------
    rejected = False;
    try {
        mask_payload(body, bytes([1, 2, 3]));
    } except ValueError {
        rejected = True;
    }
    failures += 0 if rejected else 1;
    print(f"  {'ok  ' if rejected else 'FAIL'} 3-byte mask rejected");

    # ---- the length ladder: 7-bit / 16-bit / 64-bit ------------------------
    # Boundaries are where websocket implementations actually break.
    for (size, want_marker, want_header) in [
        (0, 0, 6), (5, 5, 6), (125, 125, 6),        # 7-bit
        (126, 126, 8), (65535, 126, 8),             # 16-bit extension
        (65536, 127, 14), (200000, 127, 14)         # 64-bit extension
    ] {
        frame = build_frame(bytes(size), OP_BINARY, key);
        marker = frame[1] & 0x7F;
        masked_flag = (frame[1] & 0x80) != 0;
        (fin, opcode, decoded) = decode_client_frame(frame);
        ok = (marker == want_marker and len(frame) == want_header + size
              and masked_flag and fin and opcode == OP_BINARY
              and len(decoded) == size);
        failures += 0 if ok else 1;
        print(f"  {'ok  ' if ok else 'FAIL'} len {size:>6}  ->  marker {marker:>3}, "
              f"{want_header}-byte header, MASK set, round-trips");
    }

    # ---- round-trip through the decoder, including non-ASCII --------------
    for text in ["", "a", "Hello, World!", "héllo wörld — em dash & 你好",
                 "x" * 70000] {
        frame = build_frame(text.encode(), OP_TEXT, key);
        (fin, opcode, decoded) = decode_client_frame(frame);
        ok = fin and opcode == OP_TEXT and decoded.decode() == text;
        failures += 0 if ok else 1;
        label = text[:28] + ("…" if len(text) > 28 else "");
        print(f"  {'ok  ' if ok else 'FAIL'} round-trip {len(text.encode()):>6} bytes  {label!r}");
    }

    # ---- control frame opcode survives ------------------------------------
    (fin, opcode, decoded) = decode_client_frame(build_frame(bytes(), OP_PING, key));
    ok = fin and opcode == OP_PING and decoded == bytes();
    failures += 0 if ok else 1;
    print(f"  {'ok  ' if ok else 'FAIL'} empty PING frame");

    print(f"\n[frames] failures={failures}");
    print(f"[frames] FRAME_CODEC_OK={failures == 0}");
}
