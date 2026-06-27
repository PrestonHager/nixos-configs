#!/usr/bin/env python3
"""Enable local pubkey SSH login on Cisco IOS (vty + username)."""

from __future__ import annotations

import argparse
import importlib.util
import os
import subprocess
import sys


def load_module():
    path = os.path.join(os.path.dirname(__file__), "cisco-authorize-ssh.py")
    spec = importlib.util.spec_from_file_location("cisco_authorize_ssh", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", default=os.environ.get("CISCO_SERIAL_PORT", "COM6"))
    parser.add_argument("--username", default=os.environ.get("CISCO_SSH_USER", "admin"))
    args = parser.parse_args()

    enable_pw = (
        os.environ.get("CISCO_ENABLE_PASSWORD")
        or os.environ.get("ASTRACAP_ENABLE_PASSWORD", "")
    ).strip()
    if not enable_pw:
        enable_pw = subprocess.check_output(
            [
                "powershell",
                "-NoProfile",
                "-File",
                os.path.join(os.path.dirname(__file__), "get-cisco-enable.ps1"),
            ],
            text=True,
        ).strip()

    mod = load_module()
    import serial  # noqa: F401

    cmds = [
        "terminal length 0",
        "configure terminal",
        f"username {args.username} privilege 15",
        "line vty 0 15",
        "transport input ssh",
        "login local",
        "exit",
        "ip ssh version 2",
        "end",
        "write memory",
    ]

    with serial.Serial(args.port, 9600, timeout=2) as s:
        mod.drain(s, 0.5)
        if not mod.ensure_privileged(s, enable_pw):
            print("Could not reach privileged mode.", file=sys.stderr)
            return 1
        for cmd in cmds:
            mod.send_line(s, cmd, 1.0 if cmd != "write memory" else 0.5)
        mod.drain(s, 12.0)

    print(f"Local pubkey SSH login enabled for {args.username} on {args.port}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
