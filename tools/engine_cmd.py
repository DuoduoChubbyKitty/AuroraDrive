#!/usr/bin/env python3
"""engine_cmd.py — 直接向后台引擎 socket 发命令（诊断用，绕过 GUI 点击）

用法: python3 tools/engine_cmd.py start
      python3 tools/engine_cmd.py set_capture_mode window 12345
      python3 tools/engine_cmd.py stop
"""
import json
import socket
import sys
import os
import time

SOCK = os.path.expanduser("~/Library/Application Support/AuroraDrive/engine.sock")


def send(payload: dict, read_reply_s: float = 2.0) -> None:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3.0)
    s.connect(SOCK)
    line = json.dumps(payload) + "\n"
    s.sendall(line.encode())
    print(f"[sent] {line.strip()}")
    deadline = time.time() + read_reply_s
    buf = b""
    s.settimeout(0.5)
    while time.time() < deadline:
        try:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
        except socket.timeout:
            continue
        except Exception as e:
            print(f"[recv error] {e}")
            break
    if buf:
        for l in buf.decode(errors="replace").splitlines()[:20]:
            print(f"[recv] {l}")
    s.close()

def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    cmd = sys.argv[1]
    if cmd == "set_capture_mode":
        if len(sys.argv) < 4:
            print("需要: set_capture_mode <fullscreen|window> [windowID]")
            return 2
        kind = sys.argv[2]
        payload = {"type": "set_capture_mode", "mode": kind}
        if kind == "window":
            payload["windowID"] = int(sys.argv[3])
        send(payload)
    else:
        send({"type": cmd})
    return 0


if __name__ == "__main__":
    sys.exit(main())
