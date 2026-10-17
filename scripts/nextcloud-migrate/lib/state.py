"""Resumable migration state."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def state_dir() -> Path:
    import os

    return Path(
        os.environ.get("NC_MIGRATE_STATE_DIR", Path.home() / ".local" / "share" / "nextcloud-migrate")
    ).expanduser()


def state_file() -> Path:
    return state_dir() / "state.json"


def _now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def load_state() -> dict[str, Any]:
    path = state_file()
    if not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def save_state(state: dict[str, Any]) -> None:
    path = state_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def begin_job(job: str, **meta: Any) -> None:
    state = load_state()
    entry = state.setdefault(job, {})
    entry.update({"status": "running", "started_at": _now(), "last_error": None, **meta})
    save_state(state)


def finish_job(job: str, *, success: bool) -> None:
    state = load_state()
    entry = state.setdefault(job, {})
    entry["status"] = "success" if success else "failed"
    entry["finished_at"] = _now()
    if success:
        entry["last_success"] = _now()
    save_state(state)


def fail_job(job: str, error: str) -> None:
    state = load_state()
    entry = state.setdefault(job, {})
    entry["status"] = "failed"
    entry["finished_at"] = _now()
    entry["last_error"] = error
    save_state(state)
