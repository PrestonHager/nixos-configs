#!/usr/bin/env python3
"""Unified CLI for cloud → Nextcloud migrations (OneDrive, iCloud)."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from icloud import files as icloud_files  # noqa: E402
from icloud import photos as icloud_photos  # noqa: E402
from lib.config_init import init_config  # noqa: E402
from lib.status import print_status  # noqa: E402
from onedrive import files as onedrive_files  # noqa: E402
from onedrive import photos as onedrive_photos  # noqa: E402


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="nextcloud-migrate",
        description="Migrate cloud storage into Nextcloud on ace via rclone WebDAV.",
    )
    parser.add_argument(
        "--env-file",
        type=Path,
        default=None,
        help="Env file (default: MIGRATE_ENV or /run/secrets/nextcloud-migrate-env)",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    config = sub.add_parser("config", help="Configuration helpers")
    config_sub = config.add_subparsers(dest="config_cmd", required=True)
    init_cmd = config_sub.add_parser("init", help="Create ~/.config/nextcloud-migrate templates")
    init_cmd.add_argument("--force", action="store_true", help="Overwrite example files")
    init_cmd.set_defaults(handler=_config_init)

    status_cmd = sub.add_parser("status", help="Show paths and last run state (JSON)")
    status_cmd.set_defaults(handler=_status)

    onedrive = sub.add_parser("onedrive", help="Migrate from Microsoft OneDrive")
    onedrive_sub = onedrive.add_subparsers(dest="onedrive_cmd", required=True)

    od_files = onedrive_sub.add_parser("files", help="Copy general OneDrive files")
    od_files.add_argument("--dry-run", action="store_true")
    od_files.add_argument("--path", default=None, help="OneDrive source path")
    od_files.set_defaults(handler=_onedrive_files)

    od_photos = onedrive_sub.add_parser("photos", help="Copy Camera Roll / Pictures")
    od_photos.add_argument("--dry-run", action="store_true")
    od_photos.set_defaults(handler=_onedrive_photos)

    icloud = sub.add_parser("icloud", help="Migrate from Apple iCloud")
    icloud_sub = icloud.add_subparsers(dest="icloud_cmd", required=True)

    ic_files = icloud_sub.add_parser("files", help="Sync iCloud Drive via rclone")
    ic_files.add_argument("--dry-run", action="store_true")
    ic_files.add_argument("--since", metavar="DATE", help="Only files newer than YYYY-MM-DD")
    ic_files.set_defaults(handler=_icloud_files)

    ic_photos = icloud_sub.add_parser("photos", help="icloudpd download → rclone → Photos/")
    ic_photos.add_argument("--dry-run", action="store_true")
    ic_photos.add_argument("--album", help="Sync a single shared album")
    ic_photos.set_defaults(handler=_icloud_photos)

    return parser


def _config_init(args: argparse.Namespace) -> int:
    created = init_config(force=args.force)
    if created:
        print("Created:")
        for path in created:
            print(f"  {path}")
    else:
        from lib.config_init import config_dir

        print(f"Config already present under {config_dir()}")
    print("\nEdit env and rclone.conf, then: migrate.py icloud files --dry-run")
    return 0


def _status(args: argparse.Namespace) -> int:
    return print_status(env_file=args.env_file)


def _onedrive_files(args: argparse.Namespace) -> int:
    return onedrive_files.migrate_files(
        dry_run=args.dry_run,
        path=args.path,
        env_file=args.env_file,
    )


def _onedrive_photos(args: argparse.Namespace) -> int:
    return onedrive_photos.migrate_photos(
        dry_run=args.dry_run,
        env_file=args.env_file,
    )


def _icloud_files(args: argparse.Namespace) -> int:
    return icloud_files.migrate_files(
        dry_run=args.dry_run,
        since=args.since,
        env_file=args.env_file,
    )


def _icloud_photos(args: argparse.Namespace) -> int:
    return icloud_photos.migrate_photos(
        dry_run=args.dry_run,
        album=args.album,
        env_file=args.env_file,
    )


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    handler = getattr(args, "handler", None)
    if handler is None:
        parser.print_help()
        return 2
    return handler(args)


if __name__ == "__main__":
    raise SystemExit(main())
