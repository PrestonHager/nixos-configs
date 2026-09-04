#!/usr/bin/env python3
"""HTTP handler for major upgrade confirm/deny links."""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


STATE_DIR = Path(os.environ["ACE_UPDATE_STATE"])
PORT = int(os.environ.get("ACE_UPDATE_HTTP_PORT", "8765"))


def signing_key() -> bytes:
    key_path = STATE_DIR / "signing-key"
    return key_path.read_text(encoding="utf-8").strip().encode("utf-8")


def verify_token(token: str) -> dict:
    try:
        body, sig = token.rsplit(".", 1)
    except ValueError as exc:
        raise ValueError("malformed token") from exc

    expected = hmac.new(signing_key(), body.encode("ascii"), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, sig):
        raise ValueError("invalid token signature")

    payload = json.loads(
        base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)).decode("utf-8")
    )
    if int(payload.get("exp", 0)) < int(time.time()):
        raise ValueError("token expired")
    return payload


def html_page(title: str, message: str) -> bytes:
    doc = f"""<!doctype html>
<html><head><meta charset="utf-8"><title>{title}</title></head>
<body><h1>{title}</h1><p>{message}</p></body></html>"""
    return doc.encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    server_version = "ace-service-update/1.0"

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        action = parsed.path.strip("/").split("/")[-1]
        if action not in {"confirm", "deny", "health"}:
            self.send_error(404, "not found")
            return

        if action == "health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"ok")
            return

        params = parse_qs(parsed.query)
        token = (params.get("token") or [""])[0]
        if not token:
            self.send_error(400, "missing token")
            return

        try:
            payload = verify_token(token)
        except ValueError as exc:
            self.send_response(400)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(html_page("Invalid link", str(exc)))
            return

        if payload.get("action") != action:
            self.send_error(400, "token action mismatch")
            return

        service = payload["service"]
        latest = payload["latest"]
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        (STATE_DIR / "approved").mkdir(exist_ok=True)
        (STATE_DIR / "denied").mkdir(exist_ok=True)

        if action == "confirm":
            (STATE_DIR / "approved" / service).write_text(latest, encoding="utf-8")
            (STATE_DIR / "denied" / service).unlink(missing_ok=True)
            env = os.environ.copy()
            env["ACE_MAJOR_APPROVED"] = "1"
            subprocess.Popen(
                ["systemctl", "start", f"ace-service-auto-update@{service}.service"],
                env=env,
            )
            message = f"Approved major upgrade for {service} to {latest}. Update started on ace."
            title = "Major upgrade approved"
        else:
            (STATE_DIR / "denied" / service).write_text(latest, encoding="utf-8")
            (STATE_DIR / "approved" / service).unlink(missing_ok=True)
            (STATE_DIR / "pending" / service).unlink(missing_ok=True)
            message = f"Denied major upgrade for {service} to {latest}. No changes were made."
            title = "Major upgrade denied"

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(html_page(title, message))


def main() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    if not (STATE_DIR / "signing-key").is_file():
        (STATE_DIR / "signing-key").write_text(os.urandom(32).hex(), encoding="utf-8")
        (STATE_DIR / "signing-key").chmod(0o600)

    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
