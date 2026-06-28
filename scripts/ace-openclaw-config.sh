#!/usr/bin/env bash
# Configure OpenClaw on ace for local Ollama (run on ace as root).
set -euo pipefail

OPENCLAW="${OPENCLAW:-$(grep -oP '/nix/store/[^ ]+/bin/openclaw' /etc/systemd/system/openclaw-gateway.service 2>/dev/null || true)}"
OPENCLAW="${OPENCLAW:-$(command -v openclaw)}"
if [ -z "$OPENCLAW" ] || [ ! -x "$OPENCLAW" ]; then
  echo "openclaw binary not found" >&2
  exit 1
fi
MODEL="${1:-gemma2:2b}"

run_oc() {
  sudo -u openclaw HOME=/stor/openclaw OLLAMA_API_KEY=ollama-local "$OPENCLAW" "$@"
}

was_active=0
if systemctl is-active --quiet openclaw-gateway; then
  was_active=1
  systemctl stop openclaw-gateway
fi

run_oc config set gateway.mode local
run_oc config set env.vars.OLLAMA_API_KEY ollama-local
run_oc config set gateway.auth.mode trusted-proxy
run_oc config unset gateway.auth.token 2>/dev/null || true

PATCH_FILE=$(mktemp)
cat >"$PATCH_FILE" <<EOF
{
  "gateway": {
    "trustedProxies": ["127.0.0.1"],
    "auth": {
      "mode": "trusted-proxy",
      "trustedProxy": {
        "userHeader": "x-auth-request-email",
        "allowLoopback": true,
        "requiredHeaders": ["x-forwarded-proto", "x-forwarded-host"]
      }
    },
    "controlUi": {
      "allowedOrigins": ["https://ai.prestonhager.com"]
    }
  },
  "models": {
    "providers": {
      "ollama": {
        "baseUrl": "http://127.0.0.1:11434",
        "apiKey": "ollama-local",
        "api": "ollama"
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "ollama/${MODEL}"
      }
    }
  }
}
EOF
chown openclaw:openclaw "$PATCH_FILE"
chmod 600 "$PATCH_FILE"

run_oc config patch --file "$PATCH_FILE"
run_oc config validate
rm -f "$PATCH_FILE"

echo "Config written to /stor/openclaw/.openclaw/openclaw.json"
cat /stor/openclaw/.openclaw/openclaw.json

if [ "$was_active" -eq 1 ] || [ "${START_GATEWAY:-1}" = "1" ]; then
  systemctl start openclaw-gateway
fi