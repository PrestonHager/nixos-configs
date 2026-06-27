#!/usr/bin/env python3
"""Create pterofwd user and authorize SSH pubkey on Astracap via SSH (enable + config)."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time

DEFAULT_KEY = os.path.expanduser(r"~\.ssh\id_rsa_astracap")
DEFAULT_USER = "pterofwd"
DEFAULT_HOST = "192.168.5.1"
DEFAULT_SSH_USER = "prestonh"


def ssh_base(identity: str) -> list[str]:
    return [
        "ssh",
        "-tt",
        "-i",
        identity,
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "IdentityAgent=none",
        "-o",
        "KexAlgorithms=+diffie-hellman-group14-sha1",
        "-o",
        "HostKeyAlgorithms=+ssh-rsa",
        "-o",
        "PubkeyAcceptedAlgorithms=+ssh-rsa",
        "-o",
        "StrictHostKeyChecking=accept-new",
        f"{DEFAULT_SSH_USER}@{DEFAULT_HOST}",
    ]


def send(proc: subprocess.Popen[str], cmd: str, delay: float = 1.0) -> str:
    assert proc.stdin is not None
    assert proc.stdout is not None
    proc.stdin.write(cmd + "\n")
    proc.stdin.flush()
    time.sleep(delay)
    chunk = ""
    while proc.stdout.readable():
        try:
            part = proc.stdout.read1(4096).decode("utf-8", "replace")
        except Exception:
            break
        if not part:
            break
        chunk += part
        if proc.stdout in (None,):
            break
    return chunk


def run_ios_config(
    identity: str,
    enable_pw: str,
    username: str,
    pubkey_path: str,
    privilege: int,
    *,
    create_user: bool = True,
) -> int:
    with open(pubkey_path, encoding="utf-8") as f:
        pubkey_line = f.read().strip()
    parts = pubkey_line.split(None, 2)
    if len(parts) < 2:
        print(f"Invalid pubkey: {pubkey_path}", file=sys.stderr)
        return 2
    key_data = parts[1]

    proc = subprocess.Popen(
        ssh_base(identity),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=0,
        text=True,
    )
    out: list[str] = []

    def step(cmd: str, delay: float = 1.2) -> None:
        out.append(send(proc, cmd, delay))

    step("enable", 0.8)
    step(enable_pw, 1.5)
    step("terminal length 0", 0.8)
    step("configure terminal", 1.0)
    if create_user:
        step(f"username {username} privilege {privilege}", 1.0)
    step("ip ssh pubkey-chain", 1.0)
    step(f"username {username}", 1.0)
    step("key-string", 1.2)
    for i in range(0, len(key_data), 64):
        step(key_data[i : i + 64], 0.8)
    step("", 1.0)
    step("exit", 0.8)
    step("exit", 0.8)
    step("end", 1.0)
    step("write memory", 3.0)
    step("exit", 0.8)

    if proc.stdin:
        proc.stdin.close()
    output = "".join(out)
    proc.wait(timeout=30)

    if "key-hash" not in output and "key-string" not in output:
        print(output)
        print("Pubkey install failed — no key-hash in router output.", file=sys.stderr)
        return 1
    print(f"SSH pubkey authorized for {username} on {DEFAULT_HOST}.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Authorize pterofwd SSH key on Astracap via SSH")
    parser.add_argument("--identity", default=os.environ.get("ASTRACAP_IDENTITY", DEFAULT_KEY))
    parser.add_argument("--pubkey", default=os.environ.get("PTEROFWD_PUBKEY", ""))
    parser.add_argument("--username", default=os.environ.get("CISCO_SSH_USER", DEFAULT_USER))
    parser.add_argument("--privilege", type=int, default=15)
    parser.add_argument(
        "--no-create-user",
        action="store_true",
        help="Only add pubkey to an existing IOS username",
    )
    args = parser.parse_args()

    if not args.pubkey:
        print("Set --pubkey or PTEROFWD_PUBKEY", file=sys.stderr)
        return 2

    enable_pw = (
        os.environ.get("CISCO_ENABLE_PASSWORD")
        or os.environ.get("ASTRACAP_ENABLE_PASSWORD", "")
    ).strip()
    if not enable_pw:
        print("Set CISCO_ENABLE_PASSWORD", file=sys.stderr)
        return 2

    return run_ios_config(
        args.identity,
        enable_pw,
        args.username,
        args.pubkey,
        args.privilege,
        create_user=not args.no_create_user,
    )


if __name__ == "__main__":
    sys.exit(main())
