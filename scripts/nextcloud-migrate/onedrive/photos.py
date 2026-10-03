"""Migrate OneDrive camera roll / Pictures into Nextcloud Photos."""

from __future__ import annotations

from pathlib import Path

from lib.config import load_env, require_env
from lib.log import MigrationLogger
from lib.nextcloud import files_scan
from lib.rclone import run_rclone

# OneDrive personal → Nextcloud Photos app directory layout.
# Nextcloud Photos indexes files under the user's Photos/ folder.
DEFAULT_PHOTO_MAPPINGS: tuple[tuple[str, str], ...] = (
    ("Pictures/Camera Roll", "Photos/Camera Roll"),
    ("Pictures", "Photos"),
    ("Photos", "Photos"),
    ("Camera Roll", "Photos/Camera Roll"),
)


def migrate_photos(
    *,
    dry_run: bool = False,
    env_file: Path | None = None,
) -> int:
    env = load_env(env_file)
    creds = require_env(
        env,
        "RCLONE_CONFIG",
        "NEXTCLOUD_USER",
    )
    logger = MigrationLogger(dry_run=dry_run)
    mappings = _photo_mappings(env.get("ONEDRIVE_PHOTO_MAPPINGS", ""))
    logger.info("OneDrive photos → Nextcloud Photos/")

    exit_code = 0
    for source, dest in mappings:
        logger.info(f"mapping onedrive:{source} → nextcloud:{dest}")
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
        if source == "Pictures":
            args.extend(["--exclude", "Camera Roll/**"])
        rc = run_rclone(args, config_path=creds["RCLONE_CONFIG"], dry_run=dry_run, log=logger)
        if rc != 0:
            exit_code = rc

    scan_rc = files_scan(
        creds["NEXTCLOUD_USER"],
        path="Photos",
        dry_run=dry_run,
        log=logger,
    )
    return exit_code or scan_rc


def _photo_mappings(raw: str) -> list[tuple[str, str]]:
    if not raw.strip():
        return list(DEFAULT_PHOTO_MAPPINGS)
    mappings: list[tuple[str, str]] = []
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        if ":" not in item:
            raise SystemExit(
                f"Invalid ONEDRIVE_PHOTO_MAPPINGS entry {item!r}; use source:dest pairs"
            )
        source, dest = item.split(":", 1)
        mappings.append((source.strip(), dest.strip()))
    return mappings
