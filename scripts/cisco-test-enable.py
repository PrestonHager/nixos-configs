#!/usr/bin/env python3
"""Try enable passwords on Cisco serial console without printing secrets."""

from __future__ import annotations

import argparse
import subprocess
import sys
import time

try:
    import serial
except ImportError:
    print("Install pyserial", file=sys.stderr)
    sys.exit(1)


def load_pw(script: str) -> str:
    out = subprocess.check_output(
        ["powershell", "-NoProfile", "-File", script],
        text=True,
    )
    return out.strip()


def drain(s: serial.Serial, timeout: float = 0.5) -> str:
    end = time.time() + timeout
    buf: list[str] = []
    while time.time() < end:
        if s.in_waiting:
            buf.append(s.read(s.in_waiting).decode("utf-8", "replace"))
            end = time.time() + 0.2
        else:
            time.sleep(0.05)
    return "".join(buf)


def send(s: serial.Serial, cmd: str = "", wait: float = 0.8) -> str:
    s.write((cmd + "\r\n").encode())
    time.sleep(wait)
    return drain(s, 0.4)


def try_enable(s: serial.Serial, password: str) -> bool:
    send(s, "", 0.3)
    out = send(s, "enable", 0.8)
    if "Password" not in out and not out.rstrip().endswith(">"):
        return out.rstrip().endswith("#")
    out = send(s, password, 1.2)
    lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
    if not lines:
        return False
    return lines[-1].endswith("#") and "denied" not in out.lower()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", default="COM6")
    args = parser.parse_args()
    repo = __import__("pathlib").Path(__file__).resolve().parent
    candidates = [
        ("enable-script", str(repo / "get-cisco-enable.ps1")),
        ("vty-script", str(repo / "get-cisco-vty-password.ps1")),
    ]
    with serial.Serial(args.port, 9600, timeout=2) as s:
        drain(s, 0.5)
        for label, script in candidates:
            try:
                pw = load_pw(script)
            except subprocess.CalledProcessError:
                print(f"{label}: script failed")
                continue
            ok = try_enable(s, pw)
            print(f"{label}: {'OK' if ok else 'FAIL'}")
            if ok:
                send(s, "disable", 0.5)
                return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
