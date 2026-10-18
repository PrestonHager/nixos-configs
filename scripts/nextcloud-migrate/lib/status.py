"""JSON status output for migrate.py status."""

from __future__ import annotations

import json
import os
from pathlib import Path

from lib.config import load_env
from lib.config_init import config_dir
from lib.nextcloud import webdav_url
from lib.state import load_state, state_dir


def print_status(*, env_file: Path | None = None) -> int:
    env = load_env(env_file)
    cfg = config_dir()
    user = env.get("NEXTCLOUD_USER", "")
    base = env.get("NEXTCLOUD_URL", "https://cloud.prestonhager.com")
    payload = {
        "config_dir": str(cfg),
        "state_dir": str(state_dir()),
        "env_file": str(env_file or os.environ.get("MIGRATE_ENV", "/run/secrets/nextcloud-migrate-env")),
        "rclone_config": env.get("RCLONE_CONFIG", str(cfg / "rclone.conf")),
        "nextcloud_webdav": webdav_url(base, user) if user else None,
        "icloud_files_dest": env.get("ICLOUD_FILES_DEST", "iCloud Drive"),
        "icloud_photos_dest": env.get("ICLOUD_PHOTOS_DEST", "Photos/iCloud"),
        "state": load_state(),
    }
    print(json.dumps(payload, indent=2))
    return 0
