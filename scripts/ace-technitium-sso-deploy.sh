#!/usr/bin/env bash
# Deploy Technitium Zitadel SSO on ace: setup app, update sops, rebuild.
set -euo pipefail
REPO="${1:-/etc/nixos}"
SECRETS="${2:-/home/prestonh/nixos-secrets}"

cd "$REPO"
echo "=== Zitadel Technitium OIDC setup ==="
OUT=$(nix shell nixpkgs#nodejs_22 -c node scripts/zitadel-technitium-setup.js)
echo "$OUT"

CLIENT_ID=$(echo "$OUT" | sed -n 's/^technitium-oidc-client-id: //p')
CLIENT_SECRET=$(echo "$OUT" | sed -n 's/^technitium-oidc-client-secret: //p')
if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
  echo "Could not parse OIDC credentials from setup script output." >&2
  exit 1
fi

cd "$SECRETS"
TMP=$(mktemp)
nix shell nixpkgs#sops --command sops -d secrets/containers/technitium.yaml > "$TMP"
grep -q '^technitium-oidc-client-id:' "$TMP" || echo "technitium-oidc-client-id: PLACEHOLDER" >> "$TMP"
grep -q '^technitium-oidc-client-secret:' "$TMP" || echo "technitium-oidc-client-secret: PLACEHOLDER" >> "$TMP"
sed -i "s|^technitium-oidc-client-id:.*|technitium-oidc-client-id: ${CLIENT_ID}|" "$TMP"
sed -i "s|^technitium-oidc-client-secret:.*|technitium-oidc-client-secret: ${CLIENT_SECRET}|" "$TMP"
cp "$TMP" secrets/containers/technitium.yaml
rm "$TMP"
nix shell nixpkgs#sops --command sops -e -i secrets/containers/technitium.yaml
git add secrets/containers/technitium.yaml
git commit -m "Add Technitium OIDC client credentials" --no-gpg-sign || true
git push origin main

cd "$REPO"
nix flake update nix-secrets
nixos-rebuild switch --flake "$REPO#ace"
systemctl restart technitium-sync-sso.service
curl -s http://127.0.0.1:5380/api/sso/status
echo
systemctl status technitium-sync-sso.service --no-pager
