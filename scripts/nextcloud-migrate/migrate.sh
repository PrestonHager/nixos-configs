#!/usr/bin/env bash
# Thin wrapper so migrate.py can be invoked as migrate.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${ROOT}/migrate.py" "$@"
