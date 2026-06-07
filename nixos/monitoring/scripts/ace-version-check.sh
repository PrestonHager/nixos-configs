#!/usr/bin/env bash
# Collect installed vs upstream versions for Ace services; write Prometheus textfile metrics.
set -euo pipefail

OUT_DIR="/var/lib/node-exporter-textfile"
OUT_FILE="${OUT_DIR}/ace_versions.prom"
TMP="${OUT_FILE}.$$"
CACHE_DIR="/var/lib/ace-version-cache"
CACHE_TTL="${ACE_VERSION_CACHE_TTL:-21600}"

mkdir -p "$OUT_DIR" "$CACHE_DIR"

github_latest() {
  local repo="$1"
  local cache="${CACHE_DIR}/github_${repo//\//_}.json"
  local now fetched_at version

  now="$(date +%s)"
  if [[ -f "$cache" ]]; then
    fetched_at="$(jq -r '.fetched_at // 0' "$cache" 2>/dev/null || echo 0)"
    if (( now - fetched_at < CACHE_TTL )); then
      jq -r '.version // empty' "$cache" 2>/dev/null && return 0
    fi
  fi

  version="$(
    curl -fsSL --connect-timeout 10 --max-time 30 \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: ace-version-check" \
      "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
      | jq -r '.tag_name // empty' \
      || true
  )"

  if [[ -z "$version" ]]; then
    version="$(
      curl -fsSL --connect-timeout 10 --max-time 30 \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: ace-version-check" \
        "https://api.github.com/repos/${repo}/tags?per_page=1" 2>/dev/null \
        | jq -r '.[0].name // empty' \
        || true
    )"
  fi

  if [[ -n "$version" ]]; then
    jq -n --arg v "$version" --argjson t "$now" '{version:$v,fetched_at:$t}' > "$cache"
    printf '%s\n' "$version"
    return 0
  fi

  if [[ -f "$cache" ]]; then
    jq -r '.version // empty' "$cache" 2>/dev/null || true
  fi
}

normalize_version() {
  local v="${1:-}"
  v="${v#v}"
  v="${v#V}"
  v="${v%%-*}"
  v="${v%%+*}"
  v="${v%%_stable*}"
  if [[ "$v" == "latest" || "$v" == "stable" || -z "$v" ]]; then
    printf '%s\n' ""
    return 0
  fi
  if [[ "$v" =~ ^([0-9]+(\.[0-9]+){0,2}) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  printf '%s\n' "$v"
}

parse_semver() {
  local v="$1"
  v="$(normalize_version "$v")"
  if [[ -z "$v" ]]; then
    MAJOR="" MINOR="" PATCH=""
    return 1
  fi
  IFS='.' read -r MAJOR MINOR PATCH <<< "${v}."
  MAJOR="${MAJOR:-0}"
  MINOR="${MINOR:-0}"
  PATCH="${PATCH:-0}"
  PATCH="${PATCH%%[^0-9]*}"
  return 0
}

compare_versions() {
  local current="$1" latest="$2"
  local c_maj c_min c_pat l_maj l_min l_pat

  if ! parse_semver "$current"; then
    STATUS="unknown"
    BEHIND=4
    return 0
  fi
  c_maj="$MAJOR" c_min="$MINOR" c_pat="$PATCH"

  if ! parse_semver "$latest"; then
    STATUS="unknown"
    BEHIND=4
    return 0
  fi
  l_maj="$MAJOR" l_min="$MINOR" l_pat="$PATCH"

  if (( c_maj > l_maj )) || { (( c_maj == l_maj )) && (( c_min > l_min )); } \
    || { (( c_maj == l_maj )) && (( c_min == l_min )) && (( c_pat > l_pat )); }; then
    STATUS="current"
    BEHIND=0
    return 0
  fi

  if (( c_maj == l_maj )) && (( c_min == l_min )) && (( c_pat == l_pat )); then
    STATUS="current"
    BEHIND=0
    return 0
  fi

  if (( c_maj < l_maj )); then
    STATUS="major_behind"
    BEHIND=3
    return 0
  fi

  if (( c_min < l_min )); then
    STATUS="minor_behind"
    BEHIND=2
    return 0
  fi

  STATUS="patch_behind"
  BEHIND=1
}

container_tag() {
  local name="$1"
  podman inspect "$name" --format '{{.ImageName}}' 2>/dev/null \
    | awk -F: '{print $NF}' \
    | head -1 \
    || true
}

container_running() {
  podman inspect "$1" --format '{{.State.Running}}' 2>/dev/null | grep -qx true
}

version_from_container_tag() {
  local name="$1"
  local tag
  tag="$(container_tag "$name")"
  normalize_version "$tag"
}

emit_service() {
  local service="$1" current="$2" latest="$3"
  local up_to_date=0

  current="$(normalize_version "$current")"
  latest="$(normalize_version "$latest")"

  if [[ -z "$current" || -z "$latest" ]]; then
    STATUS="unknown"
    BEHIND=4
  else
    compare_versions "$current" "$latest"
  fi

  if [[ "$STATUS" == "current" ]]; then
    up_to_date=1
  fi

  printf 'ace_service_version_info{service="%s",current="%s",latest="%s",status="%s"} 1\n' \
    "$service" "${current:-unknown}" "${latest:-unknown}" "$STATUS"
  printf 'ace_service_up_to_date{service="%s"} %s\n' "$service" "$up_to_date"
  printf 'ace_service_version_behind{service="%s",current="%s",latest="%s",status="%s"} %s\n' \
    "$service" "${current:-unknown}" "${latest:-unknown}" "$STATUS" "$BEHIND"
}

current_grafana() {
  local tag v
  tag="$(container_tag grafana)"
  if [[ "$tag" != "latest" && -n "$(normalize_version "$tag")" ]]; then
    normalize_version "$tag"
    return 0
  fi
  v="$(curl -fsSL --connect-timeout 3 --max-time 10 http://127.0.0.1:8082/api/health 2>/dev/null \
    | jq -r '.version // empty' || true)"
  normalize_version "$v"
}

current_prometheus() {
  local tag v
  tag="$(container_tag prometheus)"
  if [[ "$tag" != "latest" && -n "$(normalize_version "$tag")" ]]; then
    normalize_version "$tag"
    return 0
  fi
  v="$(curl -fsSL --connect-timeout 3 --max-time 10 http://127.0.0.1:9090/api/v1/status/buildinfo 2>/dev/null \
    | jq -r '.data.version // empty' || true)"
  normalize_version "$v"
}

current_nextcloud() {
  local tag v
  tag="$(container_tag nextcloud)"
  if [[ "$tag" != "latest" && -n "$(normalize_version "$tag")" ]]; then
    normalize_version "$tag"
    return 0
  fi
  if container_running nextcloud; then
    v="$(podman exec -u www-data nextcloud php /var/www/html/occ status 2>/dev/null \
      | awk -F': ' '/versionstring/ {print $2; exit}' || true)"
    normalize_version "$v"
    return 0
  fi
  normalize_version "$tag"
}

current_zitadel() {
  version_from_container_tag zitadel
}

current_synapse() {
  version_from_container_tag matrix-synapse
}

current_technitium() {
  version_from_container_tag technitium
}

current_jellyfin() {
  local tag v
  tag="$(container_tag jellyfin)"
  if [[ "$tag" != "latest" && -n "$(normalize_version "$tag")" ]]; then
    normalize_version "$tag"
    return 0
  fi
  v="$(curl -fsSL --connect-timeout 3 --max-time 10 http://127.0.0.1:8096/System/Info/Public 2>/dev/null \
    | jq -r '.Version // empty' || true)"
  normalize_version "$v"
}

current_vaultwarden() {
  version_from_container_tag vaultwarden
}

current_mariadb() {
  local tag v
  tag="$(container_tag nextcloud-db)"
  if [[ "$tag" != "latest" && -n "$(normalize_version "$tag")" ]]; then
    normalize_version "$tag"
    return 0
  fi
  if container_running nextcloud-db; then
    v="$(podman exec nextcloud-db mariadb --version 2>/dev/null | awk '{print $5}' | tr -d ',')"
    normalize_version "$v"
    return 0
  fi
  normalize_version "$tag"
}

current_caddy() {
  local v
  v="$(caddy version 2>/dev/null | awk '{print $1}' || true)"
  normalize_version "$v"
}

current_pterodactyl() {
  local tag v
  tag="$(container_tag pterodactyl)"
  v="$(normalize_version "$tag")"
  if [[ -n "$v" ]]; then
    printf '%s\n' "$v"
    return 0
  fi
  if container_running pterodactyl; then
    v="$(podman exec pterodactyl php /var/www/pterodactyl/artisan --version 2>/dev/null \
      | awk '{print $NF}' || true)"
    normalize_version "$v"
    return 0
  fi
  printf '%s\n' "1.11.11"
}

current_redis() {
  local tag v
  tag="$(container_tag nextcloud-redis)"
  if [[ "$tag" != "latest" && -n "$(normalize_version "$tag")" ]]; then
    normalize_version "$tag"
    return 0
  fi
  if container_running nextcloud-redis; then
    v="$(podman exec nextcloud-redis redis-server --version 2>/dev/null \
      | awk '{print $3}' | tr -d 'v=' || true)"
    normalize_version "$v"
    return 0
  fi
  normalize_version "$tag"
}

current_clamav() {
  local tag v
  tag="$(container_tag nextcloud-clamav)"
  if [[ "$tag" != "stable" && "$tag" != "latest" && -n "$(normalize_version "$tag")" ]]; then
    normalize_version "$tag"
    return 0
  fi
  if container_running nextcloud-clamav; then
    v="$(podman exec nextcloud-clamav clamd --version 2>/dev/null \
      | awk '{print $2}' | tr -d '/ClamAV' || true)"
    normalize_version "$v"
    return 0
  fi
  normalize_version "$tag"
}

current_notify_push() {
  local v
  if ! container_running nextcloud; then
    printf '%s\n' ""
    return 0
  fi
  v="$(podman exec -u www-data nextcloud php /var/www/html/occ app:list 2>/dev/null \
    | awk -F': ' '/notify_push/ {gsub(/[^0-9.].*/, "", $2); print $2; exit}' || true)"
  normalize_version "$v"
}

{
  printf '%s\n' '# HELP ace_version_check_up Whether ace version check ran successfully.'
  printf '%s\n' '# TYPE ace_version_check_up gauge'
  printf '%s\n' 'ace_version_check_up 1'
  printf '%s\n' '# HELP ace_service_version_info Installed vs latest upstream version metadata.'
  printf '%s\n' '# TYPE ace_service_version_info gauge'
  printf '%s\n' '# HELP ace_service_up_to_date Whether service is on latest upstream (1=yes).'
  printf '%s\n' '# TYPE ace_service_up_to_date gauge'
  printf '%s\n' '# HELP ace_service_version_behind Semver lag: 0=current, 1=patch, 2=minor, 3=major, 4=unknown.'
  printf '%s\n' '# TYPE ace_service_version_behind gauge'

  emit_service grafana "$(current_grafana)" "$(github_latest grafana/grafana)"
  emit_service prometheus "$(current_prometheus)" "$(github_latest prometheus/prometheus)"
  emit_service nextcloud "$(current_nextcloud)" "$(github_latest nextcloud/server)"
  emit_service zitadel "$(current_zitadel)" "$(github_latest zitadel/zitadel)"
  emit_service matrix-synapse "$(current_synapse)" "$(github_latest matrix-org/synapse)"
  emit_service technitium "$(current_technitium)" "$(github_latest Technitium/DNS)"
  emit_service jellyfin "$(current_jellyfin)" "$(github_latest jellyfin/jellyfin)"
  emit_service vaultwarden "$(current_vaultwarden)" "$(github_latest dani-garcia/vaultwarden)"
  emit_service mariadb "$(current_mariadb)" "$(github_latest MariaDB/server)"
  emit_service caddy "$(current_caddy)" "$(github_latest caddyserver/caddy)"
  emit_service pterodactyl-panel "$(current_pterodactyl)" "$(github_latest pterodactyl/panel)"
  emit_service redis "$(current_redis)" "$(github_latest redis/redis)"
  emit_service clamav "$(current_clamav)" "$(github_latest Cisco-Talos/clamav-devel)"
  emit_service notify_push "$(current_notify_push)" "$(github_latest nextcloud/notify_push)"
} > "$TMP"

chown node_exporter:node_exporter "$TMP" 2>/dev/null || true
mv "$TMP" "$OUT_FILE"
chown node_exporter:node_exporter "$OUT_FILE" 2>/dev/null || true
