#!/usr/bin/env bash
# Update technitium.yaml sops with OIDC env and rebuild ace.
set -euo pipefail
CLIENT_ID="${1:?client id}"
CLIENT_SECRET="${2:?client secret}"
SECRETS="${3:-/home/prestonh/nixos-secrets}"
REPO="${4:-/etc/nixos}"

cd "$SECRETS"
TMP=$(mktemp)
nix shell nixpkgs#sops --command sops -d secrets/containers/technitium.yaml > "$TMP"
grep -v '^technitium-oidc-client-' "$TMP" | grep -v '^technitium-oidc-env:' | grep -v '^  TECHNITIUM_OIDC_' > "${TMP}.body" || true
{
  cat "${TMP}.body"
  echo
  echo "technitium-oidc-env: |"
  echo "  TECHNITIUM_OIDC_CLIENT_ID=${CLIENT_ID}"
  echo "  TECHNITIUM_OIDC_CLIENT_SECRET=${CLIENT_SECRET}"
} > "$TMP"
rm -f "${TMP}.body"
cp "$TMP" secrets/containers/technitium.yaml
rm "$TMP"
nix shell nixpkgs#sops --command sops -e -i secrets/containers/technitium.yaml
git add secrets/containers/technitium.yaml
git commit -m "Add Technitium OIDC env for SSO" --no-gpg-sign || true
git push origin main

cd "$REPO"
git pull origin dell-poweredge-r730xd || true
nix flake update nix-secrets
nixos-rebuild switch --flake "$REPO#ace"
rm -f /stor/technitium/.sso-settings.sha256
systemctl restart technitium-sync-sso.service
curl -s http://127.0.0.1:5380/api/sso/status
echo
systemctl status technitium-sync-sso.service --no-pager
