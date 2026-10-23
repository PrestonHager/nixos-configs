#!/usr/bin/env bash
# Push HTTP probe metrics to Prometheus Pushgateway from an external/WAN perspective.
# Intended to run on crux (192.168.5.6) with outbound Internet; pushes to ace Pushgateway.
#
# Environment:
#   PUSHGATEWAY_URL   Pushgateway base URL (default http://192.168.5.5:9091)
#   DNS_RESOLVER      Optional resolver for public view (e.g. 1.1.1.1); empty = system DNS
#   PROBE_SOURCE      Label value for probe_source (default crux)
#   PROBE_JOB         Pushgateway job name (default external-http-probe)
#   PROBE_TIMEOUT     curl max time in seconds (default 20)
#   EXTERNAL_PROBE_TARGETS  Comma-separated URLs override
set -euo pipefail

PUSHGATEWAY_URL="${PUSHGATEWAY_URL:-http://192.168.5.5:9091}"
DNS_RESOLVER="${DNS_RESOLVER:-1.1.1.1}"
PROBE_SOURCE="${PROBE_SOURCE:-crux}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-20}"
JOB="${PROBE_JOB:-external-http-probe}"

# Publicly reachable ace endpoints, port-forwarded on the WAN address (98.249.78.62
# as of 2026-10; the probe resolves it through DNS_RESOLVER rather than hardcoding it).
# Omit LAN-only vhosts; override with EXTERNAL_PROBE_TARGETS.
#
# crux sits behind the same NAT as ace, and the router does not hairpin, so from crux
# the WAN address is usually unreachable. When it is, the probe cannot say anything
# about the service: it emits probe_wan_path=0 and no probe_success for that target,
# rather than reporting every service down. Alerting:
#   probe_success == 0 (only present when probe_wan_path == 1)  -> real external failure
#   probe_wan_path == 0 for 24h                                 -> probe is blind (hairpin)
DEFAULT_TARGETS=(
  "https://grafana.prestonhager.com/"
  "https://dns.prestonhager.com/"
  "https://cloud.prestonhager.com/"
  "https://panel.prestonhager.com/"
  "https://matrix.prestonhager.com/_matrix/client/versions"
  "https://zitadel.prestonhager.com/"
  "https://jellyfin.prestonhager.com/"
  "https://vault.prestonhager.com/"
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
  local host next raw answer=""
  host="$(printf '%s' "$url" | sed -E 's|^https?://([^/:]+).*|\1|')"
  if [[ -n "$DNS_RESOLVER" ]]; then
    next="$host"
    for _ in 1 2 3 4 5; do
      raw="$(dig +short "@${DNS_RESOLVER}" "$next" 2>/dev/null | head -1 | sed 's/\.$//' || true)"
      if [[ -z "$raw" ]]; then
        break
      fi
      if [[ "$raw" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        answer="$raw"
        break
      fi
      next="$raw"
    done
    printf '%s' "$answer"
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
  if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    resolve_ok=1
  fi

  local curl_args=(
    -sS -o /dev/null
    -w '%{http_code}'
    --max-time "$PROBE_TIMEOUT"
    -L
  )
  # Always pin to the public answer. If the WAN IP is unreachable (no DNS answer, or NAT
  # hairpin failing on the LAN) probe_wan_path is 0 and no probe_success is emitted:
  # the service was never tested. It used to fall back to system DNS, which reached ace
  # over the LAN and reported "external" success.
  wan_path=0
  if [[ "$resolve_ok" -eq 1 ]] && timeout 3 bash -c "exec 3<>/dev/tcp/${ip}/${port}" 2>/dev/null; then
    wan_path=1
    curl_args+=(--resolve "${host}:${port}:${ip}")
  fi

  start="$(date +%s.%N)"
  http_code=0
  curl_ok=1
  if [[ "$wan_path" -eq 1 ]]; then
    set +e
    http_code="$(curl "${curl_args[@]}" "$url" 2>/dev/null)"
    curl_ok=$?
    set -e
  fi
  end="$(date +%s.%N)"
  elapsed="$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.6f", e - s }')"

  success=0
  if [[ "$curl_ok" -eq 0 && "$http_code" =~ ^[23] ]]; then
    success=1
  fi

  local inst esc_host labels
  inst="$(escape_label "$url")"
  esc_host="$(escape_label "$host")"
  labels="instance=\"${inst}\",job=\"${JOB}\",probe_location=\"external\",probe_source=\"${PROBE_SOURCE}\",target=\"${esc_host}\""

  # Only a request that actually went over the WAN path says anything about the
  # service; without it, probe_success would be a hairpin result, not a service result.
  if [[ "$wan_path" -eq 1 ]]; then
    printf 'probe_success{%s} %s\n' "$labels" "$success"
    printf 'probe_duration_seconds{%s} %s\n' "$labels" "$elapsed"
    printf 'probe_http_status_code{%s} %s\n' "$labels" "${http_code:-0}"
  fi
  printf 'probe_dns_resolved{%s} %s\n' "$labels" "$resolve_ok"
  printf 'probe_wan_path{%s} %s\n' "$labels" "$wan_path"
  if [[ -n "$ip" ]]; then
    printf 'probe_dns_answer{%s,answer="%s"} 1\n' "$labels" "$(escape_label "$ip")"
  fi
}

samples="$(mktemp)"
metrics="$(mktemp)"
trap 'rm -f "$samples" "$metrics"' EXIT
for url in "${TARGETS[@]}"; do
  probe_one "$url"
done > "$samples"

# Group samples by family, with a TYPE line only for families that have samples
# (probe_success and friends are absent when no target had a WAN path).
for fam in probe_success probe_duration_seconds probe_http_status_code \
  probe_dns_resolved probe_dns_answer probe_wan_path; do
  awk -v f="${fam}{" 'index($0, f) == 1' "$samples" > "${metrics}.fam"
  if [[ -s "${metrics}.fam" ]]; then
    printf '# TYPE %s gauge\n' "$fam"
    cat "${metrics}.fam"
  fi
  rm -f "${metrics}.fam"
done > "$metrics"

# PUT replaces the whole group. POST would only replace families present in this
# push, so a probe_success series from an earlier WAN-path run would linger forever.
curl -fsS -X PUT --data-binary @"$metrics" \
  "${PUSHGATEWAY_URL%/}/metrics/job/${JOB}/instance/${PROBE_SOURCE}"
