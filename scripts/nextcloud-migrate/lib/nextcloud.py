"""Nextcloud WebDAV helpers and occ files:scan wrapper."""

from __future__ import annotations

import subprocess
from urllib.parse import quote

from .log import MigrationLogger


def webdav_url(base_url: str, username: str) -> str:
    base = base_url.rstrip("/")
    user = quote(username)
    return f"{base}/remote.php/dav/files/{user}/"


def files_scan(
    user: str,
    *,
    path: str | None = None,
    dry_run: bool = False,
    log: MigrationLogger | None = None,
    occ_bin: list[str] | None = None,
) -> int:
    """Run occ files:scan for a user or subtree after rclone upload."""
    logger = log or MigrationLogger(dry_run=dry_run)
    cmd = list(occ_bin or _default_occ_bin())
    cmd.extend(["/var/www/html/occ", "files:scan"])
    if path:
        cmd.extend(["--path", f"{user}/files/{path.lstrip('/')}"])
    cmd.append(user)
    logger.command(cmd)
    if dry_run:
        logger.info("skipping occ files:scan (dry-run)")
        return 0
    result = subprocess.run(cmd, check=False)
    if result.returncode != 0:
        logger.error(f"occ files:scan failed (exit {result.returncode})")
    else:
        logger.info("occ files:scan completed")
    return result.returncode


def _default_occ_bin() -> list[str]:
    return ["podman", "exec", "-u", "www-data", "nextcloud", "php"]
