#!/usr/bin/env bash
# Phase 3 stub — block IP via Technitium blocklist API (manual).
# Usage: TECHNITIUM_API_TOKEN=... block-ip-technitium.sh 203.0.113.50 "ssh brute force"
set -euo pipefail
IP="${1:?source IP required}"
REASON="${2:-manual block}"
API="${TECHNITIUM_API_URL:-http://127.0.0.1:5380}"
TOKEN="${TECHNITIUM_API_TOKEN:?set TECHNITIUM_API_TOKEN from sops}"

curl -sf -X POST "$API/api/blocklist/add" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"ip\":\"$IP\",\"comment\":\"$REASON\"}" \
  && logger -t homelab-response "Technitium blocklist add $IP ($REASON)"

echo "Blocked $IP in Technitium (verify in dns.prestonhager.com admin UI)."
