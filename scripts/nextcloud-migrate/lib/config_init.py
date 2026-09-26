"""Create local config templates for migrations."""

from __future__ import annotations

import os
import shutil
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent.parent


def config_dir() -> Path:
    return Path(
        os.environ.get("NC_MIGRATE_CONFIG_DIR", Path.home() / ".config" / "nextcloud-migrate")
    ).expanduser()


def init_config(*, force: bool = False) -> list[Path]:
    cfg = config_dir()
    cfg.mkdir(parents=True, exist_ok=True)
    state_root = Path(
        os.environ.get("NC_MIGRATE_STATE_DIR", Path.home() / ".local" / "share" / "nextcloud-migrate")
    ).expanduser()
    state_root.mkdir(parents=True, exist_ok=True)
    (state_root / "logs").mkdir(parents=True, exist_ok=True)
    (cfg / "icloudpd-cookies").mkdir(parents=True, exist_ok=True)

    created: list[Path] = []
    for name in ("env.example", "rclone.conf.example", "icloudpd.conf.example"):
        src = SCRIPT_DIR / name
        dest = cfg / name
        if src.is_file() and (force or not dest.exists()):
            shutil.copy(src, dest)
            created.append(dest)

    for name, example in (("env", "env.example"), ("rclone.conf", "rclone.conf.example")):
        dest = cfg / name
        ex = cfg / example
        if not dest.exists() and ex.is_file():
            shutil.copy(ex, dest)
            created.append(dest)

    return created
