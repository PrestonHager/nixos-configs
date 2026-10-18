#!/usr/bin/env python3
"""Email major-upgrade approval requests with confirm/deny links."""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import subprocess
import sys
import time
import tempfile
from pathlib import Path


def signing_key(state_dir: Path) -> bytes:
    key_path = state_dir / "signing-key"
    if not key_path.is_file():
        key_path.parent.mkdir(parents=True, exist_ok=True)
        key_path.write_text(os.urandom(32).hex(), encoding="utf-8")
        key_path.chmod(0o600)
    return key_path.read_text(encoding="utf-8").strip().encode("utf-8")


def make_token(
    *,
    state_dir: Path,
    service: str,
    current: str,
    latest: str,
    action: str,
    ttl_seconds: int = 72 * 3600,
) -> str:
    payload = {
        "service": service,
        "current": current,
        "latest": latest,
        "action": action,
        "exp": int(time.time()) + ttl_seconds,
    }
    body = base64.urlsafe_b64encode(json.dumps(payload, separators=(",", ":")).encode("utf-8")).decode("ascii")
    sig = hmac.new(signing_key(state_dir), body.encode("ascii"), hashlib.sha256).hexdigest()
    return f"{body}.{sig}"


def load_warnings(registry: Path, service: str) -> list[str]:
    data = json.loads(registry.read_text(encoding="utf-8"))
    entry = data.get(service, {})
    return list(entry.get("majorWarnings") or [])


def send_via_helper(mail_cmd: str, subject: str, body: str, html: str) -> None:
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False, suffix=".txt") as body_file:
        body_file.write(body)
        body_path = body_file.name
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False, suffix=".html") as html_file:
        html_file.write(html)
        html_path = html_file.name
    try:
        subprocess.run(
            [mail_cmd, "--subject", subject, "--body-file", body_path, "--html-file", html_path],
            check=True,
        )
    finally:
        Path(body_path).unlink(missing_ok=True)
        Path(html_path).unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--service", required=True)
    parser.add_argument("--current", required=True)
    parser.add_argument("--latest", required=True)
    parser.add_argument("--status", required=True)
    args = parser.parse_args()

    state_dir = Path(os.environ["ACE_UPDATE_STATE"])
    registry = Path(os.environ["ACE_REGISTRY"])
    public_base = os.environ["ACE_UPDATE_PUBLIC_URL"].rstrip("/")
    mail_cmd = os.environ["ACE_UPDATE_MAIL"]

    confirm = make_token(
        state_dir=state_dir,
        service=args.service,
        current=args.current,
        latest=args.latest,
        action="confirm",
    )
    deny = make_token(
        state_dir=state_dir,
        service=args.service,
        current=args.current,
        latest=args.latest,
        action="deny",
    )

    warnings = load_warnings(registry, args.service)
    warning_lines = "\n".join(f"- {item}" for item in warnings) or "- Review upstream release notes before approving."

    body = f"""Major upgrade approval required on ace

Service: {args.service}
Current version: {args.current}
Target version: {args.latest}
Status: {args.status}

Potential issues:
{warning_lines}

Approve major upgrade:
{public_base}/confirm?token={confirm}

Deny major upgrade:
{public_base}/deny?token={deny}

These links expire in 72 hours. Patch and minor updates continue to run automatically.
"""

    html = f"""<html><body>
<h2>Major upgrade approval required on ace</h2>
<p><strong>Service:</strong> {args.service}<br>
<strong>Current:</strong> {args.current}<br>
<strong>Target:</strong> {args.latest}<br>
<strong>Status:</strong> {args.status}</p>
<h3>Potential issues</h3>
<ul>{''.join(f'<li>{item}</li>' for item in warnings)}</ul>
<p>
  <a href="{public_base}/confirm?token={confirm}">Approve major upgrade</a><br>
  <a href="{public_base}/deny?token={deny}">Deny major upgrade</a>
</p>
<p><em>Links expire in 72 hours. Patch and minor updates still run automatically.</em></p>
</body></html>"""

    send_via_helper(
        mail_cmd,
        subject=f"Ace major update approval: {args.service} {args.current} -> {args.latest}",
        body=body,
        html=html,
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001
        print(f"ace-service-update-confirm-mail: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
