#!/usr/bin/env python3
"""HTTP handler for major upgrade confirm/deny links.

GET only shows a confirmation page; the change happens on POST. Mail
providers and link scanners fetch every URL in a message with GET, so acting
on GET let a scanner approve (or deny) an upgrade before the recipient saw
it. The signed token is carried in the POST form body.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import html
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
# Largest form body accepted on POST (a token is a few hundred bytes).
MAX_BODY = 8192
ACTIONS = {"confirm", "deny"}


def signing_key() -> bytes:
    key_path = STATE_DIR / "signing-key"
    return key_path.read_text(encoding="utf-8").strip().encode("utf-8")


def verify_token(token: str) -> dict:
    try:
        body, sig = token.rsplit(".", 1)
    except ValueError as exc:
        raise ValueError("malformed token") from exc

    expected = hmac.new(signing_key(), body.encode("ascii", "replace"), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, sig):
        raise ValueError("invalid token signature")

    payload = json.loads(
        base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)).decode("utf-8")
    )
    if int(payload.get("exp", 0)) < int(time.time()):
        raise ValueError("token expired")
    return payload


def html_page(title: str, message: str, form: str = "") -> bytes:
    doc = f"""<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex"><title>{html.escape(title)}</title></head>
<body><h1>{html.escape(title)}</h1><p>{html.escape(message)}</p>{form}</body></html>"""
    return doc.encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    server_version = "ace-service-update/1.1"

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        # Query strings carry the signed token; keep them out of the journal.
        msg = fmt % args
        sys.stderr.write("%s - %s\n" % (self.address_string(), msg.split("?", 1)[0]))

    def send_page(self, code: int, title: str, message: str, form: str = "") -> None:
        body = html_page(title, message, form)
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; form-action 'self'; frame-ancestors 'none'",
        )
        self.end_headers()
        self.wfile.write(body)

    def action_of(self) -> str:
        return urlparse(self.path).path.strip("/").split("/")[-1]

    def check_token(self, action: str, token: str) -> dict | None:
        if not token:
            self.send_page(400, "Invalid link", "missing token")
            return None
        try:
            payload = verify_token(token)
        except (ValueError, KeyError, UnicodeError) as exc:
            # json.JSONDecodeError is a ValueError.
            self.send_page(400, "Invalid link", str(exc))
            return None
        if payload.get("action") != action:
            self.send_page(400, "Invalid link", "token action mismatch")
            return None
        return payload

    def do_GET(self) -> None:  # noqa: N802
        action = self.action_of()
        if action == "health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"ok")
            return
        if action not in ACTIONS:
            self.send_error(404, "not found")
            return

        token = (parse_qs(urlparse(self.path).query).get("token") or [""])[0]
        payload = self.check_token(action, token)
        if payload is None:
            return

        # Read-only: show what the link would do and ask for a POST.
        service, latest = str(payload.get("service")), str(payload.get("latest"))
        verb = "Approve" if action == "confirm" else "Deny"
        form = (
            f'<form method="post" action="/{action}">'
            f'<input type="hidden" name="token" value="{html.escape(token, quote=True)}">'
            f"<button type=\"submit\">{verb} {html.escape(service)} {html.escape(latest)}</button>"
            "</form>"
        )
        self.send_page(
            200,
            f"{verb} major upgrade?",
            f"{verb} the major upgrade of {service} to {latest}? "
            "Nothing changes until you press the button.",
            form,
        )

    def do_POST(self) -> None:  # noqa: N802
        action = self.action_of()
        if action not in ACTIONS:
            self.send_error(404, "not found")
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length < 0 or length > MAX_BODY:
            self.send_error(413, "request body too large")
            return
        ctype = (self.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower()
        if ctype != "application/x-www-form-urlencoded":
            self.send_error(415, "expected a form submission")
            return
        form = parse_qs(self.rfile.read(length).decode("utf-8", "replace"))
        token = (form.get("token") or [""])[0]
        payload = self.check_token(action, token)
        if payload is None:
            return

        service = str(payload.get("service") or "")
        latest = str(payload.get("latest") or "")
        # The service name becomes a file name and part of a unit name.
        if not service or "/" in service or service.startswith(".") or not service.isprintable():
            self.send_page(400, "Invalid link", "bad service name")
            return

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

        sys.stderr.write(f"{self.address_string()} - {action} {service} {latest}\n")
        self.send_page(200, title, message)


def main() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    if not (STATE_DIR / "signing-key").is_file():
        (STATE_DIR / "signing-key").write_text(os.urandom(32).hex(), encoding="utf-8")
        (STATE_DIR / "signing-key").chmod(0o600)

    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
