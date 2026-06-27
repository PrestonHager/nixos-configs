#!/usr/bin/env python3
"""Create pterofwd user and authorize SSH pubkey on Astracap via SSH (enable + config)."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time

DEFAULT_KEY = os.path.expanduser(r"~\.ssh\id_rsa_astracap")
DEFAULT_PUBKEY = ""
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


def run_ios_config(identity: str, enable_pw: str, username: str, pubkey_path: str, privilege: int) -> int:
    with open(pubkey_path, encoding="utf-8") as f:
        pubkey_line = f.read().strip()
    parts = pubkey_line.split(None, 2)
    if len(parts) < 2:
        print(f"Invalid pubkey: {pubkey_path}", file=sys.stderr)
        return 2
    key_data = parts[1]

    lines = [
        "enable",
        enable_pw,
        "terminal length 0",
        "configure terminal",
        f"username {username} privilege {privilege}",
        "ip ssh pubkey-chain",
        f"username {username}",
        "key-string",
    ]
    for i in range(0, len(key_data), 64):
        lines.append(key_data[i : i + 64])
    lines.extend(["", "exit", "exit", "end", "write memory", "exit"])

    script = "\n".join(lines) + "\n"
    proc = subprocess.Popen(
        ssh_base(identity),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    assert proc.stdin is not None
    proc.stdin.write(script)
    proc.stdin.close()

    output = proc.stdout.read() if proc.stdout else ""
    code = proc.wait(timeout=120)
    if "key-hash" not in output and "key-string" not in output and code != 0:
        print(output)
        print("Pubkey install may have failed.", file=sys.stderr)
        return 1
    print(f"SSH pubkey authorized for {username} on {DEFAULT_HOST}.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Authorize pterofwd SSH key on Astracap via SSH")
    parser.add_argument("--identity", default=os.environ.get("ASTRACAP_IDENTITY", DEFAULT_KEY))
    parser.add_argument("--pubkey", default=os.environ.get("PTEROFWD_PUBKEY", DEFAULT_PUBKEY), required=False)
    parser.add_argument("--username", default=os.environ.get("CISCO_SSH_USER", DEFAULT_USER))
    parser.add_argument("--privilege", type=int, default=15)
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

    return run_ios_config(args.identity, enable_pw, args.username, args.pubkey, args.privilege)


if __name__ == "__main__":
    sys.exit(main())
