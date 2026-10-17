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
