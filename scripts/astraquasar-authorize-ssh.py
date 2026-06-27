#!/usr/bin/env python3
"""Authorize SSH pubkey on Astraquasar switch via serial console."""

from __future__ import annotations

import os
import subprocess
import sys


def main() -> int:
    repo = os.path.dirname(__file__)
    env = os.environ.copy()
    env.setdefault("ASTRAQUASAR_SSH_USER", "admin")
    env["CISCO_SSH_USER"] = env.get("ASTRAQUASAR_SSH_USER", "admin")
    if "ASTRAQUASAR_ENABLE_PASSWORD" in env:
        env["CISCO_ENABLE_PASSWORD"] = env["ASTRAQUASAR_ENABLE_PASSWORD"]
    elif "ASTRACAP_ENABLE_PASSWORD" in env:
        env["CISCO_ENABLE_PASSWORD"] = env["ASTRACAP_ENABLE_PASSWORD"]
    if "ASTRAQUASAR_SERIAL_PORT" in env:
        env["CISCO_SERIAL_PORT"] = env["ASTRAQUASAR_SERIAL_PORT"]
    cmd = [
        sys.executable,
        os.path.join(repo, "cisco-authorize-ssh.py"),
        "--username",
        env["CISCO_SSH_USER"],
    ]
    port = env.get("CISCO_SERIAL_PORT") or env.get("ASTRAQUASAR_SERIAL_PORT")
    if port:
        cmd.extend(["--port", port])
    pubkey = env.get("ASTRAQUASAR_PUBKEY")
    if pubkey:
        cmd.extend(["--pubkey", pubkey])
    return subprocess.call(cmd, env=env)


if __name__ == "__main__":
    sys.exit(main())
