#!/usr/bin/env python3
"""Try vault note passwords on Cisco serial console (no secret output)."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

try:
    import serial
except ImportError:
    sys.exit(1)


def vault_passwords() -> list[tuple[str, str]]:
    ps = r"""
$env:Path = "$env:APPDATA\npm;" + $env:Path
Get-Content "$env:USERPROFILE\.cursor\warden-mcp.env" | ForEach-Object {
  if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
    Set-Item -Path "env:$($matches[1])" -Value $matches[2]
  }
}
$env:BW_SESSION = (bw unlock --passwordenv BW_PASSWORD --raw 2>&1 | Select-Object -Last 1)
$item = bw get item 38fa259d-4474-4641-b751-d3628dc13338 2>&1 | ConvertFrom-Json
$out = @()
foreach ($line in ($item.notes -split "`r?`n")) {
  if ($line -match '^([^:=]+)\s*[:=]\s*(.+)$') {
    $out += [PSCustomObject]@{ label = $matches[1].Trim(); value = $matches[2].Trim() }
  }
}
Remove-Item Env:BW_SESSION -ErrorAction SilentlyContinue
$out | ConvertTo-Json -Compress
"""
    raw = subprocess.check_output(["powershell", "-NoProfile", "-Command", ps], text=True)
    data = json.loads(raw)
    if isinstance(data, dict):
        data = [data]
    return [(d["label"], d["value"]) for d in data]


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


def tail_prompt(text: str) -> str:
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    return lines[-1] if lines else ""


def try_enable(s: serial.Serial, password: str) -> bool:
    send(s, "", 0.3)
    out = send(s, "enable", 0.8)
    if "Password" in out or tail_prompt(out).endswith(">"):
        out = send(s, password, 1.5)
    return tail_prompt(out).endswith("#") and "denied" not in out.lower()


def try_login_enable(s: serial.Serial, login_pw: str, enable_pw: str) -> bool:
    send(s, "", 0.3)
    out = send(s, login_pw, 0.8)
    if "Username" in out or tail_prompt(out).endswith(">"):
        out = send(s, login_pw, 0.8)
    if not tail_prompt(out).endswith(">"):
        return False
    return try_enable(s, enable_pw)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", default="COM6")
    args = parser.parse_args()
    labels = vault_passwords()
    pw_by_label = {k: v for k, v in labels}

    with serial.Serial(args.port, 9600, timeout=2) as s:
        drain(s, 0.5)
        print("prompt:", tail_prompt(drain(s, 0.2)))
        for label, pw in labels:
            ok = try_enable(s, pw)
            print(f"enable with [{label}]: {'OK' if ok else 'FAIL'}")
            if ok:
                os.environ["CISCO_ENABLE_PASSWORD"] = pw
                print(f"USE_LABEL={label}")
                send(s, "disable", 0.5)
                return 0
            send(s, "disable", 0.5)

        login = pw_by_label.get("User login (prestonh)")
        if login:
            for label, pw in labels:
                if label.startswith("User login"):
                    continue
                ok = try_login_enable(s, login, pw)
                print(f"login+enable [{label}]: {'OK' if ok else 'FAIL'}")
                if ok:
                    print(f"USE_LABEL={label}")
                    return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
