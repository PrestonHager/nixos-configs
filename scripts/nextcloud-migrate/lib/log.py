"""Dry-run aware logging for migration commands."""

from __future__ import annotations

import sys
from datetime import datetime, timezone


class MigrationLogger:
    def __init__(self, *, dry_run: bool = False) -> None:
        self.dry_run = dry_run

    def _emit(self, level: str, message: str) -> None:
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        prefix = "[DRY-RUN] " if self.dry_run else ""
        print(f"{stamp} {level} {prefix}{message}", file=sys.stderr)

    def info(self, message: str) -> None:
        self._emit("INFO", message)

    def warn(self, message: str) -> None:
        self._emit("WARN", message)

    def error(self, message: str) -> None:
        self._emit("ERROR", message)

    def command(self, cmd: list[str]) -> None:
        rendered = " ".join(_shell_quote(part) for part in _redact(cmd))
        self.info(f"command: {rendered}")


_SECRET_FLAGS = {"--password", "--pass", "--token", "--client-secret"}


def _redact(cmd: list[str]) -> list[str]:
    """Hide values of secret flags (--password X, --password=X) in logged commands."""
    out: list[str] = []
    hide_next = False
    for part in cmd:
        if hide_next:
            out.append("***")
            hide_next = False
            continue
        flag, sep, _ = part.partition("=")
        if flag in _SECRET_FLAGS:
            if sep:
                out.append(f"{flag}=***")
            else:
                out.append(part)
                hide_next = True
            continue
        out.append(part)
    return out


def _shell_quote(value: str) -> str:
    if not value:
        return "''"
    if all(ch not in " \t\n'\"\\$`" for ch in value):
        return value
    return "'" + value.replace("'", "'\"'\"'") + "'"
