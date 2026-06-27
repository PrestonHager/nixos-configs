"""Migrate iCloud Drive to Nextcloud Files via rclone."""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

from lib.config import load_env, require_env
from lib.log import MigrationLogger
from lib.nextcloud import files_scan
from lib.rclone import run_rclone
from lib.state import begin_job, fail_job, finish_job

DEFAULT_FILES_DEST = "iCloud Drive"
DEFAULT_ICLOUD_REMOTE = "icloud"
DEFAULT_NEXTCLOUD_REMOTE = "nextcloud"


def migrate_files(
    *,
    dry_run: bool = False,
    since: str | None = None,
    env_file: Path | None = None,
) -> int:
    begin_job("icloud-files", dry_run=dry_run, since=since)
    try:
        env = load_env(env_file)
        creds = require_env(env, "RCLONE_CONFIG", "NEXTCLOUD_USER")
        logger = MigrationLogger(dry_run=dry_run)
        icloud_remote = env.get("RCLONE_REMOTE_ICLOUD", DEFAULT_ICLOUD_REMOTE)
        nextcloud_remote = env.get("RCLONE_REMOTE_NEXTCLOUD", DEFAULT_NEXTCLOUD_REMOTE)
        dest = env.get("ICLOUD_FILES_DEST", DEFAULT_FILES_DEST).strip("/")

        logger.info(f"iCloud Drive ({icloud_remote}:) → {nextcloud_remote}:{dest}/")

        args = [
            "sync",
            f"{icloud_remote}:",
            f"{nextcloud_remote}:{dest}",
            "--progress",
            "--stats-one-line",
            "--transfers=4",
            "--checkers=8",
            "--retries=5",
            "--low-level-retries=10",
        ]
        if since:
            args.extend(["--max-age", _since_to_max_age(since)])

        rc = run_rclone(args, config_path=creds["RCLONE_CONFIG"], dry_run=dry_run, log=logger)
        if rc != 0:
            fail_job("icloud-files", f"rclone exit {rc}")
            return rc

        scan_rc = files_scan(
            creds["NEXTCLOUD_USER"],
            path=dest,
            dry_run=dry_run,
            log=logger,
        )
        finish_job("icloud-files", success=scan_rc == 0)
        return scan_rc
    except SystemExit as exc:
        fail_job("icloud-files", str(exc))
        raise
    except Exception as exc:  # noqa: BLE001
        fail_job("icloud-files", str(exc))
        raise


def _since_to_max_age(since: str) -> str:
    raw = since.strip()
    for fmt in ("%Y-%m-%d", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M:%SZ"):
        try:
            dt = datetime.strptime(raw, fmt).replace(tzinfo=timezone.utc)
            break
        except ValueError:
            continue
    else:
        raise SystemExit(f"Unsupported --since date: {since!r} (use YYYY-MM-DD)")
    age = datetime.now(timezone.utc) - dt
    if age.total_seconds() <= 0:
        return "1s"
    days = max(1, int(age.total_seconds() // 86400) + 1)
    return f"{days}d"
