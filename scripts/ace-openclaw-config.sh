#!/usr/bin/env bash
# Configure OpenClaw on ace for local Ollama37 (run on ace as root).
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

run_oc config set gateway.mode local
run_oc config set env.vars.OLLAMA_API_KEY ollama-local

PATCH_FILE=/stor/openclaw/.openclaw/patch-ollama.json
cat >"$PATCH_FILE" <<EOF
{
  models: {
    providers: {
      ollama: {
        baseUrl: "http://127.0.0.1:11434",
        apiKey: "ollama-local",
      },
    },
  },
  agents: {
    defaults: {
      model: "ollama/${MODEL}",
    },
  },
}
EOF
chown openclaw:openclaw "$PATCH_FILE"

run_oc config patch --file "$PATCH_FILE"
run_oc config validate
rm -f "$PATCH_FILE"

echo "Config written to /stor/openclaw/.openclaw/openclaw.json"
cat /stor/openclaw/.openclaw/openclaw.json