#!/usr/bin/env bash
set -euo pipefail
OUT_DIR="/var/lib/node-exporter-textfile"
OUT_FILE="${OUT_DIR}/php_perf.prom"
TMP="${OUT_FILE}.$$"
mkdir -p "$OUT_DIR"
exec_p() { local ctr="$1"; shift; sudo podman exec "$ctr" "$@" 2>/dev/null || return 1; }
write_metric() { echo "$1 $2"; }
{
  echo "# HELP php_perf_check PHP/Laravel performance check (1=ok, 0=bad)"
  echo "# TYPE php_perf_check gauge"
  for spec in "pterodactyl:/var/www/pterodactyl:prod" "pterodactyl-test:/var/www/pterodactyl:test"; do
    IFS=: read -r c panel label <<< "$spec"
    if ! sudo podman ps --format '{{.Names}}' | grep -qx "$c"; then
      write_metric "php_perf_container_up{container=\"${label}\"}" 0
      continue
    fi
    write_metric "php_perf_container_up{container=\"${label}\"}" 1
    for ext in opcache redis pdo_mysql; do
      v=0
      exec_p "$c" php -m | grep -qi "^${ext}$" && v=1 || true
      write_metric "php_perf_extension_loaded{container=\"${label}\",extension=\"${ext}\"}" "$v"
    done
    if exec_p "$c" test -r "${panel}/.env"; then
      for key in CACHE_DRIVER SESSION_DRIVER APP_DEBUG; do
        val="$(exec_p "$c" grep -E "^${key}=" "${panel}/.env" | tail -1 | cut -d= -f2- | tr -d '\r' || echo unset)"
        ok=1
        case "$key" in
          CACHE_DRIVER|SESSION_DRIVER) [[ "$val" == "redis" ]] || ok=0 ;;
          APP_DEBUG) [[ "$val" != "true" ]] || ok=0 ;;
        esac
        write_metric "php_perf_env_ok{container=\"${label}\",key=\"${key}\"}" "$ok"
      done
    fi
  done
} > "$TMP"
mv "$TMP" "$OUT_FILE"
