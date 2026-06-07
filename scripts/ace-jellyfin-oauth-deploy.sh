#!/usr/bin/env bash
# Write Jellyfin OIDC credentials into sops and redeploy ace.
# Usage: ace-jellyfin-oauth-deploy.sh <client_id> <client_secret>
set -euo pipefail

export SOPS_AGE_KEY_FILE=/var/lib/sops/age/keys.txt
SECRETS=/home/prestonh/nixos-secrets
PROJECT_ID='376196450586990901'
CLIENT_ID="${1:?client_id required}"
CLIENT_SECRET="${2:?client_secret required}"

cd "$SECRETS"

cat >secrets/containers/jellyfin.yaml <<EOF
jellyfin-oauth-env: |
  JELLYFIN_OIDC_CLIENT_ID=${CLIENT_ID}
  JELLYFIN_OIDC_CLIENT_SECRET=${CLIENT_SECRET}
  ZITADEL_PROJECT_ID=${PROJECT_ID}
EOF

nix shell nixpkgs#sops --command sops --encrypt --encrypted-regex '^(data|stringData|jellyfin-.*)$' --in-place secrets/containers/jellyfin.yaml

echo '=== Updated jellyfin-oauth secret ==='
nix shell nixpkgs#sops --command sops -d secrets/containers/jellyfin.yaml | grep JELLYFIN_OIDC

git add secrets/containers/jellyfin.yaml
git commit -m "Add Jellyfin OIDC client credentials for Zitadel SSO" --no-gpg-sign || true
git push origin main

cd /etc/nixos
git pull --ff-only || true
nix flake update nix-secrets
nixos-rebuild switch --flake .#ace 2>&1 | tail -40

rm -f /jf/config/.sso-setup-done
systemctl restart jellyfin-sso-setup.service
sleep 10
systemctl is-active jellyfin-sso-setup.service
systemctl is-active podman-jellyfin.service
curl -sS -o /dev/null -w 'jellyfin_http=%{http_code}\n' http://127.0.0.1:8096/System/Info/Public
