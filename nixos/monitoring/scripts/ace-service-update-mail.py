#!/usr/bin/env python3
"""Send Ace service update emails via the shared iCloud SMTP credentials."""
from __future__ import annotations

import argparse
import email.message
import os
import smtplib
import sys
from pathlib import Path


def load_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def smtp_config() -> tuple[str, str, str, str]:
    nc_env = Path(os.environ["ACE_NEXTCLOUD_ENV"])
    grafana_env = Path(os.environ["ACE_GRAFANA_ENV"])
    nc = load_env_file(nc_env)
    gf = load_env_file(grafana_env)

    password = nc.get("SMTP_PASSWORD", "")
    recipients = gf.get("GRAFANA_ALERT_EMAILS", "")
    if not password:
        raise SystemExit("SMTP_PASSWORD missing from nextcloud-environment")
    if not recipients:
        raise SystemExit("GRAFANA_ALERT_EMAILS missing from grafana-oauth-env")

    return (
        "smtp.mail.me.com",
        "587",
        "prestonhager@icloud.com",
        password,
    ), recipients, "admin@prestonhager.com", "Grafana Ace Alerts"


def send_mail(subject: str, body: str, html: str | None = None) -> None:
    (host, port, user, password), recipients, from_addr, from_name = smtp_config()
    msg = email.message.EmailMessage()
    msg["Subject"] = subject
    msg["From"] = f"{from_name} <{from_addr}>"
    msg["To"] = recipients
    msg.set_content(body)
    if html:
        msg.add_alternative(html, subtype="html")

    with smtplib.SMTP(host, int(port), timeout=60) as smtp:
        smtp.starttls()
        smtp.login(user, password)
        smtp.send_message(msg)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--subject", required=True)
    parser.add_argument("--body-file", required=True)
    parser.add_argument("--html-file")
    args = parser.parse_args()

    body = Path(args.body_file).read_text(encoding="utf-8")
    html = Path(args.html_file).read_text(encoding="utf-8") if args.html_file else None
    send_mail(args.subject, body, html)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001
        print(f"ace-service-update-mail: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
