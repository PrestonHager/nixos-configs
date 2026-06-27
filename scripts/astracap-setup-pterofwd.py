#!/usr/bin/env python3
"""Create pterofwd user and authorize Port Forward automation SSH key on Astracap."""

from __future__ import annotations

import os
import subprocess
import sys


def main() -> int:
    repo = os.path.dirname(__file__)
    env = os.environ.copy()
    env.setdefault("ASTRACAP_SSH_USER", "pterofwd")
    env.setdefault("CISCO_SSH_USER", env["ASTRACAP_SSH_USER"])
    if "ASTRACAP_ENABLE_PASSWORD" in env and "CISCO_ENABLE_PASSWORD" not in env:
        env["CISCO_ENABLE_PASSWORD"] = env["ASTRACAP_ENABLE_PASSWORD"]
    if "ASTRACAP_SERIAL_PORT" in env and "CISCO_SERIAL_PORT" not in env:
        env["CISCO_SERIAL_PORT"] = env["ASTRACAP_SERIAL_PORT"]

    pubkey = env.get("PTEROFWD_PUBKEY")
    if not pubkey:
        print("Set PTEROFWD_PUBKEY to the public key file path.", file=sys.stderr)
        return 2

    cmd = [
        sys.executable,
        os.path.join(repo, "cisco-authorize-ssh.py"),
        "--username",
        env.get("CISCO_SSH_USER", "pterofwd"),
        "--pubkey",
        pubkey,
        "--create-user",
        "--privilege",
        str(env.get("CISCO_SSH_PRIVILEGE", "15")),
    ]
    if env.get("ASTRACAP_SERIAL_PORT"):
        cmd.extend(["--port", env["ASTRACAP_SERIAL_PORT"]])
    return subprocess.call(cmd, env=env)


if __name__ == "__main__":
    sys.exit(main())
