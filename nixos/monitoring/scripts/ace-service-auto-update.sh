#!/usr/bin/env bash
# Upgrade a single Ace service when patch/minor versions are behind, or major when approved.
set -euo pipefail

SERVICE="${1:?service name required}"
ACE_MAJOR_APPROVED="${ACE_MAJOR_APPROVED:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ace-service-update-common.sh
source "$SCRIPT_DIR/ace-service-update-common.sh"

run_update() {
  local service="$1"
  local current latest behind status strategy nix_file tmp detail exit_code

  if ! registry_enabled "$service"; then
    log "service ${service} is not enabled for auto-update"
    exit 0
  fi

  mapfile -t metrics < <(read_service_metrics "$service") || {
    log "no version metrics for ${service}; run ace-version-check first"
    exit 1
  }
  current="${metrics[0]}"
  latest="${metrics[1]}"
  behind="${metrics[2]}"
  status="${metrics[3]}"

  if [[ "$behind" == "0" ]]; then
    log "${service} is already current (${current})"
    exit 0
  fi

  if [[ "$behind" == "4" ]]; then
    log "${service} version status unknown (current=${current}, latest=${latest})"
    exit 1
  fi

  strategy="$(jq -r --arg s "$service" '.[$s].strategy // "nix-bump"' "$ACE_REGISTRY")"

  if [[ "$behind" == "3" ]]; then
    if major_denied_for "$service" "$latest"; then
      log "major upgrade for ${service} to ${latest} was denied"
      exit 0
    fi
    if [[ "$ACE_MAJOR_APPROVED" != "1" ]] && ! major_approved_for "$service" "$latest"; then
      pending_file="$ACE_UPDATE_STATE/pending/${service}"
      if [[ -f "$pending_file" ]] && [[ "$(cat "$pending_file")" == "$latest" ]]; then
        log "major upgrade approval already sent for ${service} (${latest})"
        exit 0
      fi
      log "major upgrade pending approval for ${service} (${current} -> ${latest})"
      "${ACE_UPDATE_CONFIRM_MAIL:?}" \
        --service "$service" \
        --current "$current" \
        --latest "$latest" \
        --status "$status"
      mkdir -p "$ACE_UPDATE_STATE/pending"
      printf '%s\n' "$latest" > "$pending_file"
      exit 0
    fi
  fi

  log "updating ${service}: ${current} -> ${latest} (${status}, strategy=${strategy})"
  detail=""
  exit_code=0

  case "$strategy" in
    nix-bump)
      nix_file="$(jq -r --arg s "$service" '.[$s].nixFile' "$ACE_REGISTRY")"
      if [[ -z "$nix_file" || "$nix_file" == "null" ]]; then
        detail="Missing nixFile in registry for ${service}"
        write_result_email "$service" "FAILED" "$current" "$latest" "$detail"
        exit 1
      fi
      if ! detail="$("${ACE_UPDATE_BUMP:?}" \
        --service "$service" \
        --nix-file "$nix_file" \
        --target "$latest")"; then
        write_result_email "$service" "FAILED" "$current" "$latest" "$detail"
        exit 1
      fi
      ;;
    podman-pull)
      local container image
      container="$(jq -r --arg s "$service" '.[$s].containerName' "$ACE_REGISTRY")"
      image="$(jq -r --arg s "$service" '.[$s].image' "$ACE_REGISTRY")"
      if ! detail="$(podman pull "$image" 2>&1)"; then
        write_result_email "$service" "FAILED" "$current" "$latest" "$detail"
        exit 1
      fi
      if ! systemctl restart "podman-${container}.service" 2>&1; then
        detail="podman pull succeeded but restart of podman-${container}.service failed"
        write_result_email "$service" "FAILED" "$current" "$latest" "$detail"
        exit 1
      fi
      detail="Pulled ${image} and restarted podman-${container}.service"
      ;;
    occ-app)
      local container app
      container="$(jq -r --arg s "$service" '.[$s].containerName' "$ACE_REGISTRY")"
      app="$(jq -r --arg s "$service" '.[$s].appName' "$ACE_REGISTRY")"
      if ! detail="$(podman exec -u www-data "$container" php /var/www/html/occ app:update "$app" 2>&1)"; then
        write_result_email "$service" "FAILED" "$current" "$latest" "$detail"
        exit 1
      fi
      ;;
    *)
      detail="Unsupported strategy ${strategy} for ${service}"
      write_result_email "$service" "FAILED" "$current" "$latest" "$detail"
      exit 1
      ;;
  esac

  while IFS= read -r unit; do
    [[ -z "$unit" ]] && continue
    if systemctl start "$unit"; then
      detail="${detail}
Started ${unit}"
    else
      detail="${detail}
Warning: ${unit} failed to start"
      exit_code=1
    fi
  done < <(jq -r --arg s "$service" '.[$s].postUpgradeUnits[]? // empty' "$ACE_REGISTRY")

  systemctl start ace-version-check.service || true
  sleep 2
  mapfile -t post_metrics < <(read_service_metrics "$service" || true)
  if [[ "${#post_metrics[@]}" -ge 3 && "${post_metrics[2]}" == "0" ]]; then
    rm -f \
      "$ACE_UPDATE_STATE/approved/${service}" \
      "$ACE_UPDATE_STATE/denied/${service}" \
      "$ACE_UPDATE_STATE/pending/${service}"
    write_result_email "$service" "SUCCESS" "$current" "$latest" "$detail"
    exit 0
  fi

  if [[ "$exit_code" -ne 0 ]]; then
    write_result_email "$service" "FAILED" "$current" "$latest" "$detail"
    exit 1
  fi

  write_result_email "$service" "SUCCESS" "$current" "$latest" "$detail"
}

with_service_lock "$SERVICE" run_update "$SERVICE"
