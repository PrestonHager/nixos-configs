#!/usr/bin/env bash
# Collect installed vs upstream versions for Ace services; write Prometheus textfile metrics.
set -euo pipefail

# Overridable so the functions can be sourced and tested without touching the
# live textfile or cache (see the guard at the bottom).
OUT_DIR="${ACE_VERSION_OUT_DIR:-/var/lib/node-exporter-textfile}"
OUT_FILE="${OUT_DIR}/ace_versions.prom"
TMP="${OUT_FILE}.$$"
CACHE_DIR="${ACE_VERSION_CACHE_DIR:-/var/lib/ace-version-cache}"
CACHE_TTL="${ACE_VERSION_CACHE_TTL:-21600}"

# Stable versions among the strings on stdin, sorted ascending. Strips the usual
# tag prefixes, then keeps only plain X.Y or X.Y.Z (no -rc, -beta, +build, tokumx-).
stable_versions() {
  sed -E 's#^(v|V|release/|release-v|Release/|Release-v|clamav-|CLAMAV-)##' \
    | awk '/^[0-9]+\.[0-9]+(\.[0-9]+)?$/' \
    | sort -uV
}

highest_stable() {
  stable_versions | tail -n 1
}

# Same, but strictly X.Y.Z. For registries whose tag lists mix in floating
# tags such as "12.3" or "13" that would otherwise outrank the real releases.
highest_stable_strict() {
  awk '/^[0-9]+\.[0-9]+\.[0-9]+$/' | sort -V | tail -n 1
}

# Highest version on stdin in release series $1, e.g. "16" or "11.4" (stdin
# sorted ascending).
highest_in_series() {
  awk -v p="$1." 'index($0 ".", p) == 1' | tail -n 1
}

# series_of VERSION DEPTH: the release series a version belongs to. DEPTH 1 is
# the major (most projects); 2 is major.minor, for projects whose minor releases
# are the upgrade unit (MariaDB 11.4 -> 11.8 changes LTS series, MediaWiki
# 1.45 -> 1.46 needs matching extension branches).
series_of() {
  parse_semver "$1" || return 1
  if [[ "${2:-1}" == "2" ]]; then
    printf '%s.%s\n' "$MAJOR" "$MINOR"
  else
    printf '%s\n' "$MAJOR"
  fi
}

github_api() {
  curl -fsSL --connect-timeout 10 --max-time 30 \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: ace-version-check" \
    "https://api.github.com/$1" 2>/dev/null
}

# Highest stable release among the 100 most recent, falling back to tags for
# repos that publish none. Not releases/latest: that is simply the most recently
# published release, which is often a backport (Nextcloud's said 33.0.10 while
# 34.0.3 ran and 35.0.2 was out; Prometheus LTS point releases do the same).
# Overall-highest rather than same-major on purpose, so a new major still shows
# up as major_behind.
fetch_github_versions() {
  local repo="$1" v
  v="$(github_api "repos/${repo}/releases?per_page=100" \
    | jq -r '.[] | select((.draft | not) and (.prerelease | not)) | .tag_name' \
    | stable_versions || true)"
  if [[ -z "$v" ]]; then
    v="$(github_api "repos/${repo}/tags?per_page=100" | jq -r '.[].name' | stable_versions || true)"
  fi
  printf '%s\n' "$v"
}

fetch_github_stable() {
  fetch_github_versions "$1" | tail -n 1
}

# Version tags of a Docker Hub image, e.g. library/mariadb, sorted ascending. Used
# where the GitHub repo has no usable releases (MariaDB/server's tags start with
# tokumx-*, postgres/postgres uses REL_16_14) or where the image is what we run.
# FORMAT "xyz" keeps strict X.Y.Z (skips floating "12.3"/"13" tags); "xy" keeps
# X.Y (Postgres). NAME narrows the listing to tags containing it, e.g. "16.".
fetch_dockerhub_versions() {
  local repo="$1" format="${2:-xyz}" name="${3:-}" re
  case "$format" in
    xy) re='^[0-9]+[.][0-9]+$' ;;
    *) re='^[0-9]+[.][0-9]+[.][0-9]+$' ;;
  esac
  curl -fsSL --connect-timeout 10 --max-time 30 \
    "https://hub.docker.com/v2/repositories/${repo}/tags?page_size=100&ordering=last_updated&name=${name}" 2>/dev/null \
    | jq -r '.results[].name' \
    | awk -v re="$re" '$0 ~ re' | sort -uV || true
}

fetch_dockerhub_stable() {
  fetch_dockerhub_versions "$1" "${2:-xyz}" | tail -n 1
}

# cached_latest KEY CMD...: run CMD at most once per CACHE_TTL; on failure, serve
# the last good value.
cached_latest() {
  local key="$1"; shift
  local cache="${CACHE_DIR}/latest_${key//\//_}.json"
  local now fetched_at version

  now="$(date +%s)"
  if [[ -f "$cache" ]]; then
    fetched_at="$(jq -r '.fetched_at // 0' "$cache" 2>/dev/null || echo 0)"
    if (( now - fetched_at < CACHE_TTL )); then
      jq -r '.version // empty' "$cache" 2>/dev/null && return 0
    fi
  fi

  version="$("$@" || true)"
  version="$(normalize_version "$version")"
  if [[ -n "$version" ]]; then
    jq -n --arg v "$version" --argjson t "$now" '{version:$v,fetched_at:$t}' > "$cache"
    printf '%s\n' "$version"
    return 0
  fi

  if [[ -f "$cache" ]]; then
    jq -r '.version // empty' "$cache" 2>/dev/null || true
  fi
}

# One cached release list per repo serves both the overall and the same-major
# lookups, which keeps under GitHub's 60 unauthenticated requests per hour.
github_latest() {
  cached_list "gh_$1" fetch_github_versions "$1" | tail -n 1
}

dockerhub_latest() {
  cached_latest "hub_$1_${2:-xyz}" fetch_dockerhub_stable "$1" "${2:-xyz}"
}

# cached_list KEY CMD...: like cached_latest, for a newline-separated list.
cached_list() {
  local key="$1"; shift
  local cache="${CACHE_DIR}/list_${key//\//_}.txt" list

  if [[ -f "$cache" ]] && (( $(date +%s) - $(stat -c %Y "$cache") < CACHE_TTL )); then
    cat "$cache"
    return 0
  fi
  list="$("$@" || true)"
  if [[ -n "$list" ]]; then
    printf '%s\n' "$list" > "$cache"
    printf '%s\n' "$list"
    return 0
  fi
  [[ -f "$cache" ]] && cat "$cache"
  return 0
}

# Latest release in CURRENT's release series: the update that can be taken
# without a major (or series) upgrade.
github_latest_in_series() {
  local repo="$1" current="$2" depth="${3:-1}" series
  series="$(series_of "$current" "$depth")" || return 0
  cached_list "gh_$repo" fetch_github_versions "$repo" | highest_in_series "$series"
}

dockerhub_latest_in_series() {
  local repo="$1" format="$2" current="$3" depth="${4:-1}" series
  series="$(series_of "$current" "$depth")" || return 0
  cached_list "hub_${repo}_${format}_${series}" fetch_dockerhub_versions "$repo" "$format" "${series}." \
    | highest_in_series "$series"
}

normalize_version() {
  local v="${1:-}"
  v="${v#v}"
  v="${v#V}"
  v="${v#release/}"
  v="${v#release-v}"
  v="${v#Release/}"
  v="${v#Release-v}"
  v="${v#clamav-}"
  v="${v#CLAMAV-}"
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
  printf '%s\n' ""
}

container_image_ref() {
  local name="$1" image
  image="$(podman ps -a --filter "name=^${name}$" --format '{{.Image}}' 2>/dev/null | head -1 || true)"
  if [[ -z "$image" ]]; then
    image="$(podman inspect "$name" --format '{{.ImageName}}' 2>/dev/null | head -1 || true)"
  fi
  printf '%s\n' "$image"
}

container_image_raw_tag() {
  local name="$1" image="${2:-}"
  if [[ -z "$image" ]]; then
    image="$(container_image_ref "$name")"
  fi
  if [[ "$image" == *@* ]]; then
    printf '%s\n' "latest"
    return 0
  fi
  printf '%s\n' "${image##*:}"
}

container_tag() {
  normalize_version "$(container_image_raw_tag "$1")"
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

container_running() {
  podman inspect "$1" --format '{{.State.Running}}' 2>/dev/null | grep -qx true
}

version_from_container_tag() {
  container_tag "$1"
}

container_image_id() {
  podman inspect "$1" --format '{{.Image}}' 2>/dev/null || true
}

# image_version NAME [ENVVAR]: the container's tag version; for digest pins, the
# version its image declares in ENVVAR (official images set PG_VERSION,
# MARIADB_VERSION=1:11.4.12+maria~ubu2404, VALKEY_VERSION, REDIS_VERSION,
# NODE_VERSION). OCI version labels are not used generically: Coolify's is its
# base image's.
image_version() {
  local name="$1" var="${2:-}" img v
  v="$(container_tag "$name")"
  if [[ -n "$v" || -z "$var" ]]; then
    printf '%s\n' "$v"
    return 0
  fi
  img="$(container_image_id "$name")"
  [[ -n "$img" ]] || return 0
  v="$(podman image inspect "$img" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | sed -n "s/^${var}=//p" | head -n 1)"
  normalize_version "${v#*:}"
}

image_label_version() {
  local img
  img="$(container_image_id "$1")"
  [[ -n "$img" ]] || return 0
  normalize_version "$(podman image inspect "$img" \
    --format '{{index .Labels "org.opencontainers.image.version"}}' 2>/dev/null || true)"
}

github_tag_shas() {
  github_api "repos/$1/tags?per_page=100" | jq -r '.[] | "\(.name) \(.commit.sha)"'
}

# emit_service SERVICE CURRENT LATEST [LATEST_IN_SERIES]
# LATEST_IN_SERIES is the newest release in CURRENT's release series (see
# series_of); behind_in_series says what can be taken without a major or series
# upgrade, also for held or major-behind services.
emit_service() {
  local service="$1" current="$2" latest="$3" in_series="${4:-}"
  local up_to_date=0 in_series_behind=4

  current="$(normalize_version "$current")"
  latest="$(normalize_version "$latest")"
  in_series="$(normalize_version "$in_series")"

  if [[ -n "$current" && -n "$in_series" ]]; then
    compare_versions "$current" "$in_series"
    in_series_behind="$BEHIND"
  fi

  if [[ -z "$current" || -z "$latest" ]]; then
    STATUS="unknown"
    BEHIND=4
  else
    compare_versions "$current" "$latest"
  fi

  if [[ "$STATUS" == "current" ]]; then
    up_to_date=1
  fi

  printf 'ace_service_version_info{service="%s",current="%s",latest="%s",latest_in_series="%s",status="%s"} 1\n' \
    "$service" "${current:-unknown}" "${latest:-unknown}" "${in_series:-unknown}" "$STATUS"
  printf 'ace_service_up_to_date{service="%s"} %s\n' "$service" "$up_to_date"
  printf 'ace_service_version_behind{service="%s",current="%s",latest="%s",status="%s"} %s\n' \
    "$service" "${current:-unknown}" "${latest:-unknown}" "$STATUS" "$BEHIND"
  printf 'ace_service_version_behind_in_series{service="%s",current="%s",latest_in_series="%s"} %s\n' \
    "$service" "${current:-unknown}" "${in_series:-unknown}" "$in_series_behind"
  emit_hold "$service" "$current"
}

# A registry "holdMajor" keeps a service on one major release on purpose (see its
# "holdReason"). The major-version alert skips services with this metric.
emit_hold() {
  local service="$1" current="$2" hold
  [[ -n "${ACE_REGISTRY:-}" && -f "$ACE_REGISTRY" ]] || return 0
  hold="$(jq -r --arg s "$service" '.[$s].holdMajor // empty' "$ACE_REGISTRY")"
  [[ -n "$hold" ]] || return 0
  parse_semver "$current" || return 0
  [[ "$MAJOR" == "$hold" ]] || return 0
  printf 'ace_service_version_held{service="%s",major="%s"} 1\n' "$service" "$hold"
}

current_grafana() {
  local raw tag v
  raw="$(container_image_raw_tag grafana)"
  tag="$(normalize_version "$raw")"
  if [[ "$raw" != "latest" && -n "$tag" ]]; then
    printf '%s\n' "$tag"
    return 0
  fi
  v="$(curl -fsSL --connect-timeout 3 --max-time 10 http://127.0.0.1:8082/api/health 2>/dev/null \
    | jq -r '.version // empty' || true)"
  normalize_version "$v"
}

current_prometheus() {
  local raw tag v
  raw="$(container_image_raw_tag prometheus)"
  tag="$(normalize_version "$raw")"
  if [[ "$raw" != "latest" && -n "$tag" ]]; then
    printf '%s\n' "$tag"
    return 0
  fi
  v="$(curl -fsSL --connect-timeout 3 --max-time 10 http://127.0.0.1:9090/api/v1/status/buildinfo 2>/dev/null \
    | jq -r '.data.version // empty' || true)"
  if [[ -n "$v" ]]; then
    normalize_version "$v"
    return 0
  fi
  if container_running prometheus; then
    v="$(podman exec prometheus prometheus --version 2>/dev/null | head -1 | awk '{print $3}' || true)"
  fi
  normalize_version "$v"
}

current_nextcloud() {
  local raw tag v
  raw="$(container_image_raw_tag nextcloud)"
  tag="$(normalize_version "$raw")"
  if [[ "$raw" != "latest" && -n "$tag" ]]; then
    printf '%s\n' "$tag"
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

nextcloud_docker_latest() {
  local release="$1" major minor patch candidate

  release="$(normalize_version "$release")"
  [[ -n "$release" ]] || return 1

  if podman manifest inspect "docker.io/library/nextcloud:${release}" >/dev/null 2>&1; then
    printf '%s\n' "$release"
    return 0
  fi

  if ! parse_semver "$release"; then
    return 1
  fi
  major="$MAJOR" minor="$MINOR" patch="$PATCH"

  for (( candidate_patch = patch; candidate_patch >= 0; candidate_patch-- )); do
    candidate="${major}.${minor}.${candidate_patch}"
    if podman manifest inspect "docker.io/library/nextcloud:${candidate}" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if podman manifest inspect "docker.io/library/nextcloud:${major}" >/dev/null 2>&1; then
    printf '%s\n' "${major}"
    return 0
  fi

  return 1
}

current_zitadel() {
  version_from_container_tag zitadel
}

current_synapse() {
  # Pinned by digest; the synapse image labels itself with its version.
  local v
  v="$(container_tag matrix-synapse)"
  [[ -n "$v" ]] || v="$(image_label_version matrix-synapse)"
  printf '%s\n' "$v"
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

current_pterodactyl_mariadb() {
  local tag v
  tag="$(container_tag pterodactyl-db)"
  if [[ "$tag" != "latest" && -n "$(normalize_version "$tag")" ]]; then
    normalize_version "$tag"
    return 0
  fi
  if container_running pterodactyl-db; then
    v="$(podman exec pterodactyl-db mariadb --version 2>/dev/null | awk '{print $5}' | tr -d ',')"
    normalize_version "$v"
    return 0
  fi
  normalize_version "$tag"
}

current_pterodactyl_redis() {
  local tag v
  tag="$(container_tag pterodactyl-redis)"
  if [[ "$tag" != "latest" && -n "$(normalize_version "$tag")" ]]; then
    normalize_version "$tag"
    return 0
  fi
  if container_running pterodactyl-redis; then
    v="$(podman exec pterodactyl-redis redis-server --version 2>/dev/null \
      | awk '{print $3}' | tr -d 'v=' || true)"
    normalize_version "$v"
    return 0
  fi
  normalize_version "$tag"
}

current_nextcloud_mariadb() {
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
  local v caddy_bin="${CADDY:-caddy}"
  v="$("$caddy_bin" version 2>/dev/null | sed -n '1s/^v\?\([^ ]*\).*/\1/p' || true)"
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
  # Not running (for example during boot): unknown, never a guess. A made-up
  # old version once made auto-update rebuild ace in the middle of boot.
  printf '%s\n' ""
}

current_nextcloud_redis() {
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

current_nextcloud_clamav() {
  local tag v
  tag="$(container_tag nextcloud-clamav)"
  if [[ "$tag" != "stable" && "$tag" != "latest" && -n "$(normalize_version "$tag")" ]]; then
    normalize_version "$tag"
    return 0
  fi
  if container_running nextcloud-clamav; then
    v="$(podman exec nextcloud-clamav clamd --version 2>/dev/null \
      | sed -n 's/^ClamAV \([0-9.]*\)\/.*/\1/p' || true)"
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

# Monitor-only services (registry rows with enabled=false): tracked here so
# Grafana shows the lag, never auto-updated.

current_grafana_image_renderer() {
  # Pinned by digest, no version label or env; --version prints the commit,
  # which maps to a release tag.
  local v sha
  v="$(container_tag grafana-image-renderer)"
  if [[ -n "$v" ]] || ! container_running grafana-image-renderer; then
    printf '%s\n' "$v"
    return 0
  fi
  sha="$(podman exec grafana-image-renderer grafana-image-renderer --version 2>/dev/null \
    | awk '{print $3}' | cut -d+ -f1 || true)"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 0
  v="$(cached_list "ghtags_grafana/grafana-image-renderer" github_tag_shas grafana/grafana-image-renderer \
    | awk -v s="$sha" '$2 == s {print $1; exit}')"
  normalize_version "$v"
}

current_pushgateway() {
  local v
  v="$(container_tag pushgateway)"
  if [[ -z "$v" ]] && container_running pushgateway; then
    v="$(podman exec pushgateway /bin/pushgateway --version 2>&1 | awk 'NR==1 {print $3}' || true)"
  fi
  normalize_version "$v"
}

current_wg_portal() {
  version_from_container_tag wg-portal
}

current_mediawiki() {
  # localhost/mediawiki-redis:<version>, built from the pinned upstream image.
  version_from_container_tag mediawiki
}

current_nextcloud_whiteboard() {
  local v=""
  # Runs the floating :stable tag; the app reports its version in package.json.
  if container_running nextcloud-whiteboard; then
    v="$(podman exec nextcloud-whiteboard cat package.json 2>/dev/null | jq -r '.version // empty' || true)"
  fi
  normalize_version "$v"
}

current_coolify() {
  local v=""
  # Pinned by digest, so the tag says nothing. COOLIFY_VERSION is what the app
  # reports; config/constants.php carries the same default.
  if container_running coolify; then
    v="$(podman exec coolify printenv COOLIFY_VERSION 2>/dev/null || true)"
    if [[ -z "$v" ]]; then
      v="$(podman exec coolify cat /var/www/html/config/constants.php 2>/dev/null \
        | sed -nE "s/.*COOLIFY_VERSION'\) \?: '([^']+)'.*/\1/p" | head -n 1 || true)"
    fi
  fi
  normalize_version "$v"
}

track_gh() {  # SERVICE CURRENT OWNER/REPO [SERIES_DEPTH]
  local current
  current="$(normalize_version "$2")"
  emit_service "$1" "$current" "$(github_latest "$3")" \
    "$(github_latest_in_series "$3" "$current" "${4:-1}")"
}

track_hub() {  # SERVICE CURRENT NAMESPACE/IMAGE [FORMAT] [SERIES_DEPTH]
  local current format="${4:-xyz}"
  current="$(normalize_version "$2")"
  emit_service "$1" "$current" "$(dockerhub_latest "$3" "$format")" \
    "$(dockerhub_latest_in_series "$3" "$format" "$current" "${5:-1}")"
}

main() {
mkdir -p "$OUT_DIR" "$CACHE_DIR"
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

  track_gh grafana "$(current_grafana)" grafana/grafana
  track_gh prometheus "$(current_prometheus)" prometheus/prometheus
  nc_current="$(normalize_version "$(current_nextcloud)")"
  emit_service nextcloud "$nc_current" \
    "$(nextcloud_docker_latest "$(github_latest nextcloud/server)" || true)" \
    "$(nextcloud_docker_latest "$(github_latest_in_series nextcloud/server "$nc_current")" || true)"
  track_gh zitadel "$(current_zitadel)" zitadel/zitadel
  track_gh zitadel-login "$(image_version zitadel-login)" zitadel/zitadel
  # matrix-org/synapse is archived; development moved to element-hq.
  track_gh matrix-synapse "$(current_synapse)" element-hq/synapse
  track_gh technitium "$(current_technitium)" TechnitiumSoftware/DnsServer
  track_gh jellyfin "$(current_jellyfin)" jellyfin/jellyfin
  track_gh vaultwarden "$(current_vaultwarden)" dani-garcia/vaultwarden
  track_gh caddy "$(current_caddy)" caddyserver/caddy
  track_gh pterodactyl-panel "$(current_pterodactyl)" pterodactyl/panel
  track_gh nextcloud-clamav "$(current_nextcloud_clamav)" Cisco-Talos/clamav
  track_gh notify_push "$(current_notify_push)" nextcloud/notify_push

  # Databases and caches. MariaDB/server has no GitHub releases and its tags
  # start with tokumx-*, postgres/postgres tags look like REL_16_14: the Docker
  # Hub image is what runs. Postgres versions are X.Y.
  track_hub nextcloud-mariadb "$(current_nextcloud_mariadb)" library/mariadb xyz 2
  track_hub pterodactyl-mariadb "$(current_pterodactyl_mariadb)" library/mariadb xyz 2
  track_hub pterodactyl-test-mariadb "$(image_version pterodactyl-test-db MARIADB_VERSION)" library/mariadb xyz 2
  track_hub mediawiki-mariadb "$(image_version mediawiki-db MARIADB_VERSION)" library/mariadb xyz 2
  track_hub matrix-postgres "$(image_version matrix-db PG_VERSION)" library/postgres xy
  track_hub zitadel-postgres "$(image_version zitadel-db PG_VERSION)" library/postgres xy
  track_hub coolify-postgres "$(image_version coolify-db PG_VERSION)" library/postgres xy
  track_gh nextcloud-redis "$(current_nextcloud_redis)" redis/redis
  track_gh coolify-redis "$(image_version coolify-redis REDIS_VERSION)" redis/redis
  # pterodactyl-redis runs Valkey (BSD Redis fork) since 2026-10-19.
  track_gh pterodactyl-redis "$(current_pterodactyl_redis)" valkey-io/valkey
  track_gh pterodactyl-test-redis "$(image_version pterodactyl-test-redis VALKEY_VERSION)" valkey-io/valkey
  track_gh mediawiki-redis "$(image_version mediawiki-redis VALKEY_VERSION)" valkey-io/valkey

  # Monitor-only.
  track_gh grafana-image-renderer "$(current_grafana_image_renderer)" grafana/grafana-image-renderer
  track_gh pushgateway "$(current_pushgateway)" prometheus/pushgateway
  track_gh wg-portal "$(current_wg_portal)" h44z/wg-portal
  track_gh nextcloud-whiteboard "$(current_nextcloud_whiteboard)" nextcloud/whiteboard
  track_gh coolify "$(current_coolify)" coollabsio/coolify
  track_hub mediawiki "$(current_mediawiki)" library/mediawiki xyz 2
} > "$TMP"

chown node_exporter:node_exporter "$TMP" 2>/dev/null || true
mv "$TMP" "$OUT_FILE"
chown node_exporter:node_exporter "$OUT_FILE" 2>/dev/null || true
}

# Run only when executed; `source` it to test the functions on their own.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
