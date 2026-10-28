"""rclone execution helpers."""

from __future__ import annotations

import os
import subprocess

from .log import MigrationLogger


def run_rclone(
    args: list[str],
    *,
    config_path: str | None = None,
    dry_run: bool = False,
    log: MigrationLogger | None = None,
) -> int:
    logger = log or MigrationLogger(dry_run=dry_run)
    _refuse_root_sync(args)
    cmd = ["rclone", *args]
    if dry_run and "--dry-run" not in args:
        cmd.append("--dry-run")
    env = os.environ.copy()
    if config_path:
        env["RCLONE_CONFIG"] = config_path
    logger.command(cmd)
    if dry_run and "--dry-run" in cmd:
        logger.info("rclone dry-run (no changes applied)")
    result = subprocess.run(cmd, env=env, check=False)
    if result.returncode != 0:
        logger.error(f"rclone failed (exit {result.returncode})")
    return result.returncode


def _refuse_root_sync(args: list[str]) -> None:
    """rclone sync deletes destination files missing from the source. An empty or "/"
    destination path (e.g. ICLOUD_FILES_DEST="/", which strip("/") turns into "")
    would mirror over the whole remote, so refuse."""
    positional = [a for a in args if not a.startswith("-")]
    if not positional or positional[0] != "sync":
        return
    if len(positional) < 3:
        raise SystemExit("rclone sync needs a source and a destination")
    dest = positional[2]
    remote, sep, path = dest.partition(":")
    # "remote:path"; a one-letter "remote" is a Windows drive, i.e. a local path.
    dest_path = path if sep and len(remote) > 1 else dest
    if dest_path.strip().strip("/") == "":
        raise SystemExit(f"refusing rclone sync to the root of {dest!r}; set a destination folder")
