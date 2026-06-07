#!/usr/bin/env bash
# Add shared renderer token to grafana-oauth sops secret. Run on ace as root or with sudo.
set -euo pipefail

export SOPS_AGE_KEY_FILE=/var/lib/sops/age/keys.txt
TOKEN="${1:-$(tr -dc 'A-Za-z0-9+/=' </dev/urandom | head -c 44)}"
SECRETS=/home/prestonh/nixos-secrets

cd "$SECRETS"
nix shell nixpkgs#sops --command sops -d secrets/containers/grafana-oauth.yaml > /tmp/grafana-oauth-dec.yaml

if grep -q '^  GF_RENDERING_RENDERER_TOKEN=' /tmp/grafana-oauth-dec.yaml; then
  sed -i "s|^  GF_RENDERING_RENDERER_TOKEN=.*|  GF_RENDERING_RENDERER_TOKEN=${TOKEN}|" /tmp/grafana-oauth-dec.yaml
else
  printf '  GF_RENDERING_RENDERER_TOKEN=%s\n' "$TOKEN" >> /tmp/grafana-oauth-dec.yaml
fi

if grep -q '^  AUTH_TOKEN=' /tmp/grafana-oauth-dec.yaml; then
  sed -i "s|^  AUTH_TOKEN=.*|  AUTH_TOKEN=${TOKEN}|" /tmp/grafana-oauth-dec.yaml
else
  printf '  AUTH_TOKEN=%s\n' "$TOKEN" >> /tmp/grafana-oauth-dec.yaml
fi

cp /tmp/grafana-oauth-dec.yaml secrets/containers/grafana-oauth.yaml
nix shell nixpkgs#sops --command sops --encrypt --encrypted-regex '^(data|stringData|grafana-oauth-env)$' --in-place secrets/containers/grafana-oauth.yaml
rm /tmp/grafana-oauth-dec.yaml

echo "=== renderer token vars in secret ==="
nix shell nixpkgs#sops --command sops -d secrets/containers/grafana-oauth.yaml | grep -E 'GF_RENDERING_RENDERER_TOKEN|AUTH_TOKEN'
