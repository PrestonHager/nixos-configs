#!/usr/bin/env bash
# Write Pterodactyl OIDC + oauth2-proxy cookie secret into sops and redeploy ace.
# Usage: ace-pterodactyl-oauth-deploy.sh <client_id> <client_secret>
set -euo pipefail

export SOPS_AGE_KEY_FILE=/var/lib/sops/age/keys.txt
SECRETS=/home/prestonh/nixos-secrets
PROJECT_ID='376196450586990901'
CLIENT_ID="${1:?client_id required}"
CLIENT_SECRET="${2:?client_secret required}"
COOKIE_SECRET="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"

cd "$SECRETS"

if [ -f secrets/containers/pterodactyl-oauth.yaml ]; then
  existing_cookie=$(nix shell nixpkgs#sops --command sops -d secrets/containers/pterodactyl-oauth.yaml 2>/dev/null \
    | awk -F= '/^OAUTH2_PROXY_COOKIE_SECRET=/{print $2; exit}' || true)
  if [ -n "${existing_cookie:-}" ] && [ "${existing_cookie}" != "REPLACE_COOKIE_SECRET" ]; then
    COOKIE_SECRET="$existing_cookie"
  fi
fi

cat >secrets/containers/pterodactyl-oauth.yaml <<EOF
pterodactyl-oauth-env: |
  PTERODACTYL_OIDC_CLIENT_ID=${CLIENT_ID}
  PTERODACTYL_OIDC_CLIENT_SECRET=${CLIENT_SECRET}
  OAUTH2_PROXY_COOKIE_SECRET=${COOKIE_SECRET}
  ZITADEL_PROJECT_ID=${PROJECT_ID}
EOF

nix shell nixpkgs#sops --command sops --encrypt --encrypted-regex '^(data|stringData|pterodactyl-oauth-env)$' --in-place secrets/containers/pterodactyl-oauth.yaml

echo '=== Updated pterodactyl-oauth secret ==='
nix shell nixpkgs#sops --command sops -d secrets/containers/pterodactyl-oauth.yaml | grep -E '^(PTERODACTYL_OIDC|OAUTH2_PROXY_COOKIE|ZITADEL_PROJECT)' | sed 's/SECRET=.*/SECRET=***/'

git add secrets/containers/pterodactyl-oauth.yaml
git commit -m "Add Pterodactyl OIDC client credentials for Zitadel SSO" --no-gpg-sign || true
git push origin main

cd /etc/nixos
git pull --ff-only || true
nix flake update nix-secrets
nixos-rebuild switch --flake .#ace 2>&1 | tail -50

systemctl restart pterodactyl-oauth2-proxy.service
systemctl restart pterodactyl-patch-header-auth.service
systemctl is-active pterodactyl-oauth2-proxy.service
