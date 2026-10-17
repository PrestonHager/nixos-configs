"""Download iCloud Photos with icloudpd, upload to Nextcloud Photos via rclone."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

from lib.config import load_env, require_env
from lib.log import MigrationLogger
from lib.nextcloud import files_scan
from lib.rclone import run_rclone
from lib.state import begin_job, fail_job, finish_job

DEFAULT_PHOTOS_DEST = "Photos/iCloud"
DEFAULT_ICLOUD_REMOTE = "icloud"
DEFAULT_NEXTCLOUD_REMOTE = "nextcloud"
DEFAULT_DOWNLOAD_DIR = "photos-staging"


def migrate_photos(
    *,
    dry_run: bool = False,
    album: str | None = None,
    env_file: Path | None = None,
) -> int:
    begin_job("icloud-photos", dry_run=dry_run, album=album)
    try:
        env = load_env(env_file)
        creds = require_env(
            env,
            "RCLONE_CONFIG",
            "NEXTCLOUD_USER",
            "ICLOUD_APPLE_ID",
            "ICLOUD_PASSWORD",
        )
        logger = MigrationLogger(dry_run=dry_run)
        nextcloud_remote = env.get("RCLONE_REMOTE_NEXTCLOUD", DEFAULT_NEXTCLOUD_REMOTE)
        dest_base = env.get("ICLOUD_PHOTOS_DEST", DEFAULT_PHOTOS_DEST).strip("/")
        download_dir = _download_dir(env)

        logger.info(f"iCloud Photos → {nextcloud_remote}:{dest_base}/ (staging: {download_dir})")

        if not dry_run:
            rc = _run_icloudpd(creds, download_dir, album, logger)
            if rc != 0:
                fail_job("icloud-photos", f"icloudpd exit {rc}")
                return rc
        else:
            logger.info("dry-run: skipping icloudpd download")

        upload_src = download_dir if not album else download_dir / album
        upload_dest = dest_base if not album else f"{dest_base}/{album}"

        args = [
            "sync",
            str(upload_src),
            f"{nextcloud_remote}:{upload_dest}",
            "--progress",
            "--stats-one-line",
            "--transfers=4",
            "--checkers=8",
            "--retries=5",
            "--low-level-retries=10",
        ]
        rc = run_rclone(args, config_path=creds["RCLONE_CONFIG"], dry_run=dry_run, log=logger)
        if rc != 0:
            fail_job("icloud-photos", f"rclone exit {rc}")
            return rc

        scan_rc = files_scan(
            creds["NEXTCLOUD_USER"],
            path=upload_dest,
            dry_run=dry_run,
            log=logger,
        )
        finish_job("icloud-photos", success=scan_rc == 0)
        return scan_rc
    except SystemExit as exc:
        fail_job("icloud-photos", str(exc))
        raise
    except Exception as exc:  # noqa: BLE001
        fail_job("icloud-photos", str(exc))
        raise


def _download_dir(env: dict[str, str]) -> Path:
    raw = env.get("ICLOUDPD_DOWNLOAD_DIR", DEFAULT_DOWNLOAD_DIR)
    path = Path(raw).expanduser()
    if not path.is_absolute():
        config_root = Path(env.get("NC_MIGRATE_CONFIG_DIR", Path.home() / ".config" / "nextcloud-migrate"))
        path = config_root / path
    path.mkdir(parents=True, exist_ok=True)
    cookie_dir = path.parent / "icloudpd-cookies"
    cookie_dir.mkdir(parents=True, exist_ok=True)
    return path


def _run_icloudpd(
    creds: dict[str, str],
    download_dir: Path,
    album: str | None,
    logger: MigrationLogger,
) -> int:
    icloudpd = shutil.which("icloudpd")
    if not icloudpd:
        raise SystemExit("icloudpd not found in PATH")

    cookie_dir = download_dir.parent / "icloudpd-cookies"
    cmd = [
        icloudpd,
        "--username",
        creds["ICLOUD_APPLE_ID"],
        "--password",
        creds["ICLOUD_PASSWORD"],
        "--directory",
        str(download_dir),
        "--cookie-directory",
        str(cookie_dir),
        "--set-exif-datetime",
    ]
    if album:
        cmd.extend(["--album", album])

    logger.command(cmd)
    result = subprocess.run(cmd, env=os.environ.copy(), check=False)
    if result.returncode != 0:
        logger.error(f"icloudpd failed (exit {result.returncode})")
    return result.returncode
