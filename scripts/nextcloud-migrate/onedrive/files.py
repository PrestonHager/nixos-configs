"""Migrate general OneDrive files to Nextcloud Files."""

from __future__ import annotations

from pathlib import Path

from lib.config import load_env, require_env
from lib.log import MigrationLogger
from lib.nextcloud import files_scan
from lib.rclone import run_rclone

DEFAULT_FILES_DEST = "OneDrive"
DEFAULT_FILES_EXCLUDES = [
    "Pictures/**",
    "Photos/**",
    "Camera Roll/**",
]


def migrate_files(
    *,
    dry_run: bool = False,
    path: str | None = None,
    env_file: Path | None = None,
) -> int:
    env = load_env(env_file)
    creds = require_env(
        env,
        "RCLONE_CONFIG",
        "NEXTCLOUD_USER",
    )
    logger = MigrationLogger(dry_run=dry_run)
    source = path or env.get("ONEDRIVE_FILES_PATH", "")
    dest = env.get("ONEDRIVE_FILES_DEST", DEFAULT_FILES_DEST).strip("/")
    excludes = _split_csv(env.get("ONEDRIVE_FILES_EXCLUDE", "")) or DEFAULT_FILES_EXCLUDES

    logger.info(f"OneDrive files → nextcloud:{dest}/")
    if source:
        logger.info(f"source path: onedrive:{source}")

    args = [
        "copy",
        f"onedrive:{source}",
        f"nextcloud:{dest}",
        "--progress",
        "--stats-one-line",
        "--transfers=4",
        "--checkers=8",
        "--fast-list",
    ]
    for pattern in excludes:
        args.extend(["--exclude", pattern])

    rc = run_rclone(args, config_path=creds["RCLONE_CONFIG"], dry_run=dry_run, log=logger)
    if rc != 0:
        return rc

    return files_scan(
        creds["NEXTCLOUD_USER"],
        path=dest,
        dry_run=dry_run,
        log=logger,
    )


def _split_csv(value: str) -> list[str]:
    return [part.strip() for part in value.split(",") if part.strip()]
