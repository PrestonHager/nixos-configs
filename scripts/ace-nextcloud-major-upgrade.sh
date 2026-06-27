#!/usr/bin/env bash
# Step Nextcloud through major versions (31 -> 32 -> 33 -> 34) on ace.
# Run as root on ace after git pull. Requires /etc/nixos checkout at target branch.
#
# Nextcloud cannot skip major releases; this script temporarily pins intermediate
# image tags, rebuilds, and runs occ upgrade between each step.
#
# Usage: ace-nextcloud-major-upgrade.sh [--dry-run]
set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

NIX_FILE="/etc/nixos/nixos/containers/nextcloud.nix"
if [[ ! -f "$NIX_FILE" ]]; then
  echo "ace-nextcloud-major-upgrade: $NIX_FILE not found" >&2
  exit 1
fi

current_version() {
  podman exec -u www-data nextcloud php /var/www/html/occ status 2>/dev/null \
    | awk -F': ' '/versionstring/{print $2; exit}'
}

resolve_target_34() {
  if podman manifest inspect docker.io/library/nextcloud:34.0.1 >/dev/null 2>&1; then
    echo "34.0.1"
    return
  fi
  if podman manifest inspect docker.io/library/nextcloud:34.0.0 >/dev/null 2>&1; then
    echo "ace-nextcloud-major-upgrade: 34.0.1 image not published yet; using 34.0.0" >&2
    echo "34.0.0"
    return
  fi
  echo "ace-nextcloud-major-upgrade: no Nextcloud 34 image found on Docker Hub" >&2
  exit 1
}

set_image_tag() {
  local ver="$1"
  sed -i "s|nextcloudImage = \"docker.io/library/nextcloud:[^\"]*\"|nextcloudImage = \"docker.io/library/nextcloud:${ver}\"|" "$NIX_FILE"
}

run_cron() {
  local i
  for i in 1 2 3; do
    podman exec -u www-data nextcloud php /var/www/html/cron.php 2>/dev/null || true
    sleep 5
  done
}

step_upgrade() {
  local ver="$1"
  echo "=== Stepping to Nextcloud ${ver} ==="
  if $DRY_RUN; then
    echo "[dry-run] would pin ${ver} and nixos-rebuild switch --flake .#ace"
    return 0
  fi

  set_image_tag "$ver"
  cd /etc/nixos
  nixos-rebuild switch --flake .#ace

  systemctl restart nextcloud-occ-maintain.service || true
  if systemctl is-failed --quiet nextcloud-occ-maintain.service; then
    echo "ace-nextcloud-major-upgrade: nextcloud-occ-maintain failed on ${ver}" >&2
    journalctl -u nextcloud-occ-maintain.service -n 40 --no-pager >&2 || true
    exit 1
  fi

  podman exec -u www-data nextcloud php /var/www/html/occ upgrade --no-interaction || true
  run_cron
  echo "Now at: $(current_version)"
  podman exec -u www-data nextcloud php /var/www/html/occ status
}

main() {
  local start target_34 ver
  start="$(current_version || echo unknown)"
  echo "Current Nextcloud: ${start}"
  echo "Backup reminder: ensure /stor/nextcloud (data + mysql) is backed up before continuing."
  if $DRY_RUN; then
    echo "[dry-run] no changes will be made"
  elif [[ "${ACE_NC_UPGRADE_CONFIRM:-}" != "yes" ]]; then
    echo "Set ACE_NC_UPGRADE_CONFIRM=yes to proceed."
    exit 1
  fi

  target_34="$(resolve_target_34)"
  for ver in 32 33 "$target_34"; do
    major="${ver%%.*}"
    current_major="${start%%.*}"
    if [[ "$current_major" -ge "$major" ]]; then
      echo "Skipping ${ver} (already at major ${current_major}+)"
      continue
    fi
    step_upgrade "$ver"
    start="$(current_version)"
  done

  if ! $DRY_RUN; then
    cd /etc/nixos
    git checkout HEAD -- nixos/containers/nextcloud.nix 2>/dev/null || true
    nixos-rebuild switch --flake .#ace
    systemctl restart nextcloud-occ-maintain.service || true
    echo "Final version: $(current_version)"
  fi
}

main "$@"
