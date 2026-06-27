#!/usr/bin/env python3
"""Authorize SSH pubkey on Astracap router via serial console."""

from __future__ import annotations

import os
import subprocess
import sys


def main() -> int:
    repo = os.path.dirname(__file__)
    env = os.environ.copy()
    env.setdefault("ASTRACAP_SSH_USER", "prestonh")
    env.setdefault("CISCO_SSH_USER", env["ASTRACAP_SSH_USER"])
    if "ASTRACAP_ENABLE_PASSWORD" in env and "CISCO_ENABLE_PASSWORD" not in env:
        env["CISCO_ENABLE_PASSWORD"] = env["ASTRACAP_ENABLE_PASSWORD"]
    if "ASTRACAP_SERIAL_PORT" in env and "CISCO_SERIAL_PORT" not in env:
        env["CISCO_SERIAL_PORT"] = env["ASTRACAP_SERIAL_PORT"]
    cmd = [
        sys.executable,
        os.path.join(repo, "cisco-authorize-ssh.py"),
        "--username",
        env.get("CISCO_SSH_USER", "prestonh"),
    ]
    if env.get("ASTRACAP_SERIAL_PORT"):
        cmd.extend(["--port", env["ASTRACAP_SERIAL_PORT"]])
    pubkey = env.get("ASTRACAP_PUBKEY")
    if pubkey:
        cmd.extend(["--pubkey", pubkey])
    return subprocess.call(cmd, env=env)


if __name__ == "__main__":
    sys.exit(main())
