#!/usr/bin/env bash
# Start ace-service-auto-update@SERVICE for each out-of-date tracked service.
set -euo pipefail

ensure_state_dirs

if [[ ! -f "$ACE_VERSIONS_PROM" ]]; then
  log "metrics file missing: ${ACE_VERSIONS_PROM}"
  exit 0
fi

while IFS= read -r line; do
  service="$(printf '%s' "$line" | sed -n 's/.*service="\([^"]*\)".*/\1/p')"
  latest="$(printf '%s' "$line" | sed -n 's/.*latest="\([^"]*\)".*/\1/p')"
  behind="$(printf '%s' "$line" | awk '{print $NF}')"

  [[ -z "$service" ]] && continue
  [[ "$behind" == "0" || "$behind" == "4" ]] && continue

  if ! registry_enabled "$service"; then
    continue
  fi

  if major_denied_for "$service" "$latest"; then
    continue
  fi

  if systemctl is-active --quiet "ace-service-auto-update@${service}.service"; then
    continue
  fi

  log "dispatching ace-service-auto-update@${service}.service (behind=${behind})"
  systemctl start "ace-service-auto-update@${service}.service" || \
    log "failed to start ace-service-auto-update@${service}.service"
done < <(grep -E '^ace_service_version_behind{' "$ACE_VERSIONS_PROM" || true)
