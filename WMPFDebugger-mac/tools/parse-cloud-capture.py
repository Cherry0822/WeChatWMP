#!/usr/bin/env python3
"""Parse /tmp/cloud-capture.log (raw hex TLS events) into readable HTTP sessions.

Each log line: <iso-time> <W|R> <ssl-ptr> <hex>
Reconstructs HTTP/1.1 and HTTP/2 (with per-connection HPACK decoding) and prints
method/URL/body per request, plus response status/body.
"""

import binascii
import gzip
import json
import re
import sys
from hpack import Decoder

TYPE_NAME = {0: "DATA", 1: "HEADERS", 2: "PRIORITY", 3: "RST_STREAM", 4: "SETTINGS",
             5: "PUSH_PROMISE", 6: "PING", 7: "GOAWAY", 8: "WINDOW_UPDATE", 9: "CONTINUATION"}

class Conn:
    def __init__(self):
        self.wbuf = b""
        self.rbuf = b""
        self.wdec = Decoder()  # client headers
        self.rdec = Decoder()  # server headers
        self.w_headers = {}    # stream -> header list (pending continuation)
        self.r_headers = {}

def printable(b, n=2000):
    if b[:2] == b"\x1f\x8b":
        try:
            b = gzip.decompress(b)
        except Exception:
            pass
    s = "".join(chr(c) if 0x20 <= c < 0x7f else "." for c in b[:n])
    return s


def hpack_str(x, enc):
    """hpack 4.x 的 decode 结果可能是 bytes 也可能是 str，统一转 str。"""
    if isinstance(x, bytes):
        return x.decode(enc, "replace")
    return str(x)

def parse_events(path):
    events = []
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"^(\S+)\s+([WR])\s+(0x[0-9a-f]+)\s+([0-9a-f]+)$", line.strip())
        if not m:
            continue
        ts, d, ssl, hexs = m.groups()
        try:
            data = binascii.unhexlify(hexs)
        except Exception:
            continue
        events.append((ts, d, ssl, data))
    return events

def frames_of(buf):
    """split buffer into (offset, frame) list; returns frames, leftover"""
    # 跳过 HTTP/2 连接前奏 "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"（24 字节），
    # 否则前奏会把帧边界对齐搞乱，导致整条连接的 HPACK 全部解不出来
    if buf[:24] == b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":
        buf = buf[24:]
    frames = []
    off = 0
    while off + 9 <= len(buf):
        ln = int.from_bytes(buf[off:off+3], "big")
        if off + 9 + ln > len(buf):
            break
        frames.append((off, buf[off:off+9+ln]))
        off += 9 + ln
    return frames, buf[off:]

def main(path):
    conns = {}
    for ts, d, ssl, data in parse_events(path):
        c = conns.setdefault(ssl, Conn())
        buf = c.wbuf if d == "W" else c.rbuf
        buf += data
        frames, leftover = frames_of(buf)
        if d == "W":
            c.wbuf = leftover
        else:
            c.rbuf = leftover
        dec = c.wdec if d == "W" else c.rdec
        hdrs = c.w_headers if d == "W" else c.r_headers

        for off, fr in frames:
            ln = int.from_bytes(fr[0:3], "big")
            ftype = fr[3]
            flags = fr[4]
            sid = int.from_bytes(fr[5:9], "big") & 0x7fffffff
            payload = fr[9:9+ln]
            if ftype == 0x01 or ftype == 0x09:  # HEADERS / CONTINUATION
                hp = payload
                if ftype == 0x01:
                    if flags & 0x08 and hp:
                        hp = hp[1:]
                    if flags & 0x20:
                        hp = hp[5:] if len(hp) >= 5 else b""
                hdrs.setdefault(sid, []).append(hp)
                if flags & 0x04:  # END_HEADERS
                    block = b"".join(hdrs.pop(sid))
                    try:
                        kv = dec.decode(block)
                        h = {hpack_str(k, "latin1"): hpack_str(v, "utf-8") for k, v in kv}
                        method = h.get(":method", "?")
                        path = h.get(":path", "")
                        auth = h.get(":authority", "")
                        print(f"{ts} [{ssl[-4:]}] H2 {method} https://{auth}{path}")
                        for k, v in h.items():
                            if not k.startswith(":"):
                                print(f"    {k}: {v[:300]}")
                    except Exception as ex:
                        print(f"{ts} [{ssl[-4:]}] H2 HEADERS decode fail: {ex}")
            elif ftype == 0x00:  # DATA
                body = payload
                print(f"{ts} [{ssl[-4:]}] H2 DATA sid={sid} len={len(body)} ascii={json.dumps(printable(body, 400))}")
            elif ftype == 0x04:
                # SETTINGS：HEADER_TABLE_SIZE 决定对端编码器可用的动态表大小
                pl = payload
                i = 0
                while i + 6 <= len(pl):
                    k = int.from_bytes(pl[i:i+2], "big")
                    v = int.from_bytes(pl[i+2:i+6], "big")
                    if k == 1:
                        try:
                            if d == "W":
                                c.rdec.max_allowed_table_size = v  # 客户端声明 -> 服务端响应编码器
                            else:
                                c.wdec.max_allowed_table_size = v  # 服务端声明 -> 客户端请求编码器
                        except Exception:
                            pass
                    i += 6
            else:
                print(f"{ts} [{ssl[-4:]}] H2 {TYPE_NAME.get(ftype, hex(ftype))} sid={sid} len={ln}")

        # HTTP/1.1 plaintext detection
        for off, fr in frames:
            pass
        txt = None
        if not frames:
            txt = data
        elif len(frames) == 1 and frames[0][1][3] not in (0x01, 0x09):
            txt = data
        if txt:
            s = txt.decode("latin1", "replace")
            if re.match(r"^(GET|POST|PUT|DELETE|PATCH|HEAD) ", s):
                host = re.search(r"^Host: (.+)$", s, re.M)
                print(f"{ts} [{ssl[-4:]}] H1 REQ {s.splitlines()[0]} host={host.group(1) if host else '?'}")
                body = s.split("\r\n\r\n", 1)
                if len(body) > 1 and body[1].strip():
                    print(f"    body={json.dumps(body[1][:400])}")
            elif s.startswith("HTTP/1.1"):
                print(f"{ts} [{ssl[-4:]}] H1 RESP {s.splitlines()[0]}")
                body = s.split("\r\n\r\n", 1)
                if len(body) > 1 and body[1].strip():
                    print(f"    body={json.dumps(body[1][:400])}")

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "/tmp/cloud-capture.log")
