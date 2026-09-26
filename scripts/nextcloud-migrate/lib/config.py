"""Load migration credentials from env files (sops-decrypted on ace)."""

from __future__ import annotations

import os
from pathlib import Path


def _parse_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line.removeprefix("export ").strip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def load_env(env_file: Path | None = None) -> dict[str, str]:
    """Merge process env with optional env file (file wins for listed keys)."""
    merged = dict(os.environ)
    if env_file is not None:
        path = env_file
    else:
        default_secret = Path(os.environ.get("MIGRATE_ENV", "/run/secrets/nextcloud-migrate-env"))
        local_cfg = Path.home() / ".config" / "nextcloud-migrate" / "env"
        path = default_secret if default_secret.is_file() else local_cfg
    if path.is_file():
        merged.update(_parse_env_file(path))
    return merged


def require_env(env: dict[str, str], *keys: str) -> dict[str, str]:
    missing = [key for key in keys if not env.get(key)]
    if missing:
        joined = ", ".join(missing)
        raise SystemExit(f"Missing required env: {joined} (set in sops or MIGRATE_ENV)")
    return {key: env[key] for key in keys}
