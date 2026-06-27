#!/usr/bin/env python3
"""Authorize an SSH public key on Cisco IOS via serial console."""

from __future__ import annotations

import argparse
import os
import sys
import time

try:
    import serial
except ImportError:
    print("Install pyserial: pip install pyserial", file=sys.stderr)
    sys.exit(1)

DEFAULT_PORT = "COM6"
DEFAULT_BAUD = 9600
DEFAULT_PUBKEY = os.path.expanduser(r"~\.ssh\id_rsa_astracap.pub")


def drain(s: serial.Serial, timeout: float = 0.5) -> str:
    end = time.time() + timeout
    buf: list[str] = []
    while time.time() < end:
        waiting = s.in_waiting
        if waiting:
            buf.append(s.read(waiting).decode("utf-8", "replace"))
            end = time.time() + 0.2
        else:
            time.sleep(0.05)
    return "".join(buf)


def prompt_tail(text: str) -> str:
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    return lines[-1] if lines else ""


def send_line(s: serial.Serial, cmd: str = "", wait: float = 0.8) -> str:
    s.write((cmd + "\r\n").encode())
    time.sleep(wait)
    return drain(s, 0.4)


def reset_console(s: serial.Serial) -> None:
    s.write(b"\x03")
    time.sleep(0.4)
    drain(s, 0.5)
    send_line(s, "", 0.5)


def ensure_privileged(s: serial.Serial, enable_pw: str) -> bool:
    enable_pw = enable_pw.strip()
    reset_console(s)
    out = send_line(s, "", 0.5)
    if prompt_tail(out).endswith("#"):
        return True
    if not enable_pw:
        return False
    out = send_line(s, "enable", 0.8)
    if "Password" in out or prompt_tail(out).endswith(">"):
        out = send_line(s, enable_pw, 1.2)
    else:
        out = send_line(s, enable_pw, 1.2)
    if "Access denied" in out or "Bad secrets" in out:
        return False
    return prompt_tail(out).endswith("#")


def authorize_pubkey(
    port: str,
    baud: int,
    pubkey_path: str,
    username: str,
    enable_pw: str,
    *,
    create_user: bool = False,
    privilege: int = 15,
) -> int:
    with open(pubkey_path, encoding="utf-8") as f:
        pubkey_line = f.read().strip()
    parts = pubkey_line.split(None, 2)
    if len(parts) < 2:
        print(f"Invalid pubkey file: {pubkey_path}", file=sys.stderr)
        return 2
    key_data = parts[1]

    with serial.Serial(port, baud, timeout=2) as s:
        drain(s, 0.5)
        if not ensure_privileged(s, enable_pw):
            print("Could not reach privileged mode.", file=sys.stderr)
            return 1

        send_line(s, "terminal length 0", 0.5)
        send_line(s, "configure terminal", 0.8)
        if create_user:
            send_line(s, f"username {username} privilege {privilege}", 0.8)
        send_line(s, "ip ssh pubkey-chain", 0.8)
        send_line(s, f"username {username}", 0.8)
        send_line(s, "key-string", 0.8)
        for i in range(0, len(key_data), 64):
            send_line(s, key_data[i : i + 64], 0.6)
        send_line(s, "", 0.5)
        send_line(s, "exit", 0.5)
        send_line(s, "exit", 0.5)
        send_line(s, "end", 0.8)
        send_line(s, "write memory", 1.0)
        drain(s, 10.0)

        if not ensure_privileged(s, enable_pw):
            print("Lost privileged mode after config.", file=sys.stderr)
            return 1
        verify = send_line(s, "show running-config | include key-", 0.8)
        if "key-hash" not in verify and "key-string" not in verify:
            print("Pubkey config not found in running-config.", file=sys.stderr)
            return 1

    print(f"SSH pubkey authorized for {username} on {port}.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Add SSH pubkey to Cisco IOS via console")
    parser.add_argument("--port", default=os.environ.get("CISCO_SERIAL_PORT", DEFAULT_PORT))
    parser.add_argument("--baud", type=int, default=DEFAULT_BAUD)
    parser.add_argument("--pubkey", default=DEFAULT_PUBKEY)
    parser.add_argument(
        "--username",
        default=os.environ.get("CISCO_SSH_USER", "prestonh"),
    )
    parser.add_argument(
        "--create-user",
        action="store_true",
        help="Create IOS local username before installing pubkey",
    )
    parser.add_argument(
        "--privilege",
        type=int,
        default=int(os.environ.get("CISCO_SSH_PRIVILEGE", "15")),
    )
    args = parser.parse_args()

    enable_pw = (os.environ.get("CISCO_ENABLE_PASSWORD") or os.environ.get(
        "ASTRACAP_ENABLE_PASSWORD", ""
    )).strip()
    return authorize_pubkey(
        args.port,
        args.baud,
        args.pubkey,
        args.username,
        enable_pw,
        create_user=args.create_user,
        privilege=args.privilege,
    )


if __name__ == "__main__":
    sys.exit(main())
