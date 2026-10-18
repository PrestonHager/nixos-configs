#!/usr/bin/env bash
set -euo pipefail
OUT_DIR="/var/lib/node-exporter-textfile"
OUT_FILE="${OUT_DIR}/ace_health.prom"
TMP="${OUT_FILE}.$$"
HEALTH="/home/prestonh/server-health.sh"
CONFIG="/home/prestonh/server-health.conf"
mkdir -p "$OUT_DIR"
if [[ ! -x "$HEALTH" ]]; then
  printf '%s\n' 'ace_health_exporter_up 0' > "$TMP"
  mv "$TMP" "$OUT_FILE"
  exit 0
fi
json="$("$HEALTH" --json --config "$CONFIG" 2>/dev/null || echo '{"warnings":0,"critical":0,"findings":[]}')"
warnings="$(printf '%s' "$json" | jq -r '(.warnings // 0) | tostring' | head -1)"
critical="$(printf '%s' "$json" | jq -r '(.critical // 0) | tostring' | head -1)"
{
  printf '%s\n' '# HELP ace_health_exporter_up Whether ace health exporter ran successfully.'
  printf '%s\n' '# TYPE ace_health_exporter_up gauge'
  printf '%s\n' 'ace_health_exporter_up 1'
  printf '%s\n' '# HELP ace_health_warnings Number of warning findings from server-health.sh'
  printf '%s\n' '# TYPE ace_health_warnings gauge'
  printf 'ace_health_warnings %s\n' "$warnings"
  printf '%s\n' '# HELP ace_health_critical Number of critical findings from server-health.sh'
  printf '%s\n' '# TYPE ace_health_critical gauge'
  printf 'ace_health_critical %s\n' "$critical"
  printf '%s\n' '# HELP ace_health_finding Active health finding (1=present)'
  printf '%s\n' '# TYPE ace_health_finding gauge'
  printf '%s' "$json" | jq -r '.findings[]? | "ace_health_finding{level=\"\(.level)\",component=\"\(.component)\",message=\"\(.message | gsub("\""; "\\\""))\"} 1"' 2>/dev/null || true
} > "$TMP"
chown node_exporter:node_exporter "$TMP" 2>/dev/null || true
mv "$TMP" "$OUT_FILE"
chown node_exporter:node_exporter "$OUT_FILE" 2>/dev/null || true
