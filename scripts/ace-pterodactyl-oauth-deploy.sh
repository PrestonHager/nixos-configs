#!/usr/bin/env bash
# Write Pterodactyl OIDC credentials into sops and redeploy ace (Blueprint Social Login SSO).
# Usage: ace-pterodactyl-oauth-deploy.sh <client_id> <client_secret>
set -euo pipefail

export SOPS_AGE_KEY_FILE=/var/lib/sops/age/keys.txt
SECRETS=/home/prestonh/nixos-secrets
PROJECT_ID='376196450586990901'
CLIENT_ID="${1:?client_id required}"
CLIENT_SECRET="${2:?client_secret required}"

cd "$SECRETS"

cat >secrets/containers/pterodactyl-oauth.yaml <<EOF
pterodactyl-oauth-env: |
  PTERODACTYL_OIDC_CLIENT_ID=${CLIENT_ID}
  PTERODACTYL_OIDC_CLIENT_SECRET=${CLIENT_SECRET}
  ZITADEL_PROJECT_ID=${PROJECT_ID}
EOF

nix shell nixpkgs#sops --command sops --encrypt --encrypted-regex '^(data|stringData|pterodactyl-oauth-env)$' --in-place secrets/containers/pterodactyl-oauth.yaml

echo '=== Updated pterodactyl-oauth secret ==='
nix shell nixpkgs#sops --command sops -d secrets/containers/pterodactyl-oauth.yaml | grep -E '^(PTERODACTYL_OIDC|ZITADEL_PROJECT)' | sed 's/SECRET=.*/SECRET=***/'

git add secrets/containers/pterodactyl-oauth.yaml
git commit -m "Add Pterodactyl OIDC client credentials for Zitadel SSO" --no-gpg-sign || true
git push origin main

cd /etc/nixos
git pull --ff-only || true
nix flake update nix-secrets
nixos-rebuild switch --flake .#ace 2>&1 | tail -50

systemctl restart pterodactyl-sso-configure.service
systemctl is-active pterodactyl-sso-configure.service
