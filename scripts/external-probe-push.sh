#!/usr/bin/env bash
# Push HTTP probe metrics to Prometheus Pushgateway from an external perspective.
# Run from any host with outbound HTTPS; defaults target ace Pushgateway on LAN.
#
# Environment:
#   PUSHGATEWAY_URL   Pushgateway base URL (default http://192.168.5.5:9091)
#   DNS_RESOLVER      Optional resolver for public view (e.g. 1.1.1.1); empty = system DNS
#   PROBE_SOURCE      Label value for probe_source (default external-script)
#   PROBE_TIMEOUT     curl max time in seconds (default 20)
set -euo pipefail

PUSHGATEWAY_URL="${PUSHGATEWAY_URL:-http://192.168.5.5:9091}"
DNS_RESOLVER="${DNS_RESOLVER:-}"
PROBE_SOURCE="${PROBE_SOURCE:-external-script}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-20}"
JOB="${PROBE_JOB:-external-http-probe}"

# Hostnames expected to resolve publicly (Cloudflare / WAN). LAN-only names omitted.
DEFAULT_TARGETS=(
  "https://grafana.prestonhager.com/"
  "https://dns.prestonhager.com/"
  "https://cloud.prestonhager.com/"
  "https://panel.prestonhager.com/"
  "https://matrix.prestonhager.com/"
  "https://zitadel.prestonhager.com/"
  "https://jellyfin.prestonhager.com/"
  "https://vault.prestonhager.com/"
  "https://wg.prestonhager.com/"
  "https://loftiawiki.org/"
)

if [[ -n "${EXTERNAL_PROBE_TARGETS:-}" ]]; then
  IFS=',' read -r -a TARGETS <<< "${EXTERNAL_PROBE_TARGETS}"
else
  TARGETS=("${DEFAULT_TARGETS[@]}")
fi

escape_label() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

resolve_host() {
  local url="$1"
  local host port
  host="$(printf '%s' "$url" | sed -E 's|^https?://([^/:]+).*|\1|')"
  port="$(printf '%s' "$url" | sed -nE 's|^https://([^/:]+)(:([0-9]+))?.*|\3|p')"
  [[ -z "$port" ]] && port=443
  if [[ -n "$DNS_RESOLVER" ]]; then
    dig +short "@${DNS_RESOLVER}" "$host" A 2>/dev/null | head -1
  else
    getent ahosts "$host" 2>/dev/null | awk '/STREAM/ { print $1; exit }'
  fi
}

probe_one() {
  local url="$1"
  local host ip port start end elapsed http_code curl_ok success resolve_ok
  host="$(printf '%s' "$url" | sed -E 's|^https?://([^/:]+).*|\1|')"
  port="$(printf '%s' "$url" | sed -nE 's|^https://([^/:]+)(:([0-9]+))?.*|\3|p')"
  [[ -z "$port" ]] && port=443

  ip="$(resolve_host "$url" || true)"
  resolve_ok=0
  [[ -n "$ip" ]] && resolve_ok=1

  local curl_args=(
    -sS -o /dev/null
    -w '%{http_code}'
    --max-time "$PROBE_TIMEOUT"
    -L
  )
  if [[ -n "$ip" ]]; then
    curl_args+=(--resolve "${host}:${port}:${ip}")
  fi

  start="$(date +%s.%N)"
  set +e
  http_code="$(curl "${curl_args[@]}" "$url" 2>/dev/null)"
  curl_ok=$?
  set -e
  end="$(date +%s.%N)"
  elapsed="$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.6f", e - s }')"

  success=0
  if [[ "$curl_ok" -eq 0 && "$http_code" =~ ^[23] ]]; then
    success=1
  fi
  if [[ "$resolve_ok" -eq 0 ]]; then
    success=0
    http_code="${http_code:-0}"
  fi

  local inst esc_host esc_url
  inst="$(escape_label "$url")"
  esc_host="$(escape_label "$host")"

  cat <<EOF
probe_success{instance="${inst}",job="${JOB}",probe_location="external",probe_source="${PROBE_SOURCE}",vhost="${esc_host}"} ${success}
probe_duration_seconds{instance="${inst}",job="${JOB}",probe_location="external",probe_source="${PROBE_SOURCE}",vhost="${esc_host}"} ${elapsed}
probe_http_status_code{instance="${inst}",job="${JOB}",probe_location="external",probe_source="${PROBE_SOURCE}",vhost="${esc_host}"} ${http_code:-0}
probe_dns_resolved{instance="${inst}",job="${JOB}",probe_location="external",probe_source="${PROBE_SOURCE}",vhost="${esc_host}"} ${resolve_ok}
EOF
  if [[ -n "$ip" ]]; then
    printf 'probe_dns_answer{instance="%s",job="%s",probe_location="external",probe_source="%s",vhost="%s",answer="%s"} 1\n' \
      "$inst" "$JOB" "$PROBE_SOURCE" "$esc_host" "$(escape_label "$ip")"
  fi
}

metrics="$(mktemp)"
trap 'rm -f "$metrics"' EXIT
{
  echo '# TYPE probe_success gauge'
  echo '# TYPE probe_duration_seconds gauge'
  echo '# TYPE probe_http_status_code gauge'
  echo '# TYPE probe_dns_resolved gauge'
  echo '# TYPE probe_dns_answer gauge'
  for url in "${TARGETS[@]}"; do
    probe_one "$url"
  done
} > "$metrics"

curl -fsS --data-binary @"$metrics" \
  "${PUSHGATEWAY_URL%/}/metrics/job/${JOB}/instance/${PROBE_SOURCE}"
