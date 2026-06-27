#!/usr/bin/env bash
# Shared helpers for ace-service-auto-update.
set -euo pipefail

ACE_UPDATE_STATE="${ACE_UPDATE_STATE:-/var/lib/ace-service-update}"
ACE_VERSIONS_PROM="${ACE_VERSIONS_PROM:-/var/lib/node-exporter-textfile/ace_versions.prom}"
ACE_NIXOS_DIR="${ACE_NIXOS_DIR:-/etc/nixos}"
ACE_REGISTRY="${ACE_REGISTRY:?ACE_REGISTRY must be set}"

log() {
  printf '[ace-service-update] %s\n' "$*" >&2
}

ensure_state_dirs() {
  mkdir -p \
    "$ACE_UPDATE_STATE"/{approved,denied,locks,pending,log} \
    "$ACE_UPDATE_STATE"
  if [[ ! -f "$ACE_UPDATE_STATE/signing-key" ]]; then
    openssl rand -hex 32 > "$ACE_UPDATE_STATE/signing-key"
    chmod 600 "$ACE_UPDATE_STATE/signing-key"
  fi
}

read_service_metrics() {
  local service="$1"
  local line current latest behind status

  if [[ ! -f "$ACE_VERSIONS_PROM" ]]; then
    return 1
  fi

  line="$(
    grep -E "^ace_service_version_behind\\{service=\"${service}\"" "$ACE_VERSIONS_PROM" 2>/dev/null \
      | head -1 || true
  )"
  if [[ -z "$line" ]]; then
    return 1
  fi

  current="$(printf '%s' "$line" | sed -n 's/.*current="\([^"]*\)".*/\1/p')"
  latest="$(printf '%s' "$line" | sed -n 's/.*latest="\([^"]*\)".*/\1/p')"
  status="$(printf '%s' "$line" | sed -n 's/.*status="\([^"]*\)".*/\1/p')"
  behind="$(printf '%s' "$line" | awk '{print $NF}')"

  printf '%s\n' "$current" "$latest" "$behind" "$status"
}

registry_enabled() {
  local service="$1"
  jq -e --arg s "$service" '.[$s].enabled == true' "$ACE_REGISTRY" >/dev/null 2>&1
}

send_update_email() {
  local subject="$1"
  local body_file="$2"
  "${ACE_UPDATE_MAIL:?}" --subject "$subject" --body-file "$body_file"
}

write_result_email() {
  local service="$1" outcome="$2" current="$3" latest="$4" detail="$5"
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
Ace service auto-update report

Service: ${service}
Outcome: ${outcome}
Current version: ${current}
Target version: ${latest}

${detail}
EOF
  send_update_email "Ace update ${outcome}: ${service}" "$tmp"
  rm -f "$tmp"
}

major_denied_for() {
  local service="$1" latest="$2"
  [[ -f "$ACE_UPDATE_STATE/denied/${service}" ]] \
    && [[ "$(cat "$ACE_UPDATE_STATE/denied/${service}")" == "$latest" ]]
}

major_approved_for() {
  local service="$1" latest="$2"
  [[ -f "$ACE_UPDATE_STATE/approved/${service}" ]] \
    && [[ "$(cat "$ACE_UPDATE_STATE/approved/${service}")" == "$latest" ]]
}

with_service_lock() {
  local service="$1"
  local lock="$ACE_UPDATE_STATE/locks/${service}.lock"
  ensure_state_dirs
  exec 9>"$lock"
  if ! flock -n 9; then
    log "service ${service} update already in progress"
    exit 0
  fi
  "$2" "${@:3}"
}
