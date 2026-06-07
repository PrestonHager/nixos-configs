#!/usr/bin/env bash
# Update Grafana OAuth sops secret with role mapping and Zitadel role scopes.
# Run on ace as root.
set -euo pipefail

export SOPS_AGE_KEY_FILE=/var/lib/sops/age/keys.txt
SECRETS=/home/prestonh/nixos-secrets
PROJECT_ID='376196450586990901'

cd "$SECRETS"

CLIENT_ID=$(nix shell nixpkgs#sops --command sops -d secrets/containers/grafana-oauth.yaml | awk -F= '/GF_AUTH_GENERIC_OAUTH_CLIENT_ID=/{print $2}')
CLIENT_SECRET=$(nix shell nixpkgs#sops --command sops -d secrets/containers/grafana-oauth.yaml | awk -F= '/GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=/{print $2}')
RENDERER_TOKEN=$(nix shell nixpkgs#sops --command sops -d secrets/containers/grafana-oauth.yaml | awk -F= '/GF_RENDERING_RENDERER_TOKEN=/{print $2}')

write_oauth_yaml() {
  local dest="$1"
  cat >"$dest" <<EOF
grafana-oauth-env: |
  GF_AUTH_GENERIC_OAUTH_ENABLED=true
  GF_AUTH_GENERIC_OAUTH_NAME=Zitadel
  GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP=true
  GF_AUTH_GENERIC_OAUTH_CLIENT_ID=${CLIENT_ID}
  GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=${CLIENT_SECRET}
  GF_AUTH_GENERIC_OAUTH_SCOPES=openid profile email urn:zitadel:iam:org:project:roles urn:zitadel:iam:org:project:id:${PROJECT_ID}:aud
  GF_AUTH_GENERIC_OAUTH_AUTH_URL=https://zitadel.prestonhager.com/oauth/v2/authorize
  GF_AUTH_GENERIC_OAUTH_TOKEN_URL=https://zitadel.prestonhager.com/oauth/v2/token
  GF_AUTH_GENERIC_OAUTH_API_URL=https://zitadel.prestonhager.com/oidc/v1/userinfo
  GF_AUTH_GENERIC_OAUTH_USE_PKCE=true
  GF_AUTH_GENERIC_OAUTH_ALLOW_ASSIGN_GRAFANA_ADMIN=true
  GF_AUTH_GENERIC_OAUTH_EMAIL_ATTRIBUTE_PATH=email
  GF_AUTH_GENERIC_OAUTH_SKIP_ORG_ROLE_SYNC=false
  GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH=contains(keys("urn:zitadel:iam:org:project:roles"), 'grafana_admin') && 'GrafanaAdmin' || 'Viewer'
  GF_RENDERING_RENDERER_TOKEN=${RENDERER_TOKEN:-REPLACE_RENDERER_TOKEN}
  AUTH_TOKEN=${RENDERER_TOKEN:-REPLACE_RENDERER_TOKEN}
EOF
}

write_template() {
  cat >secrets/containers/grafana-oauth.yaml.template <<'EOF'
# Copy to secrets/containers/grafana-oauth.yaml and encrypt with sops on ace.
# Create a Zitadel OIDC application first (Web app, PKCE, redirect URI below).

grafana-oauth-env: |
  GF_AUTH_GENERIC_OAUTH_ENABLED=true
  GF_AUTH_GENERIC_OAUTH_NAME=Zitadel
  GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP=true
  GF_AUTH_GENERIC_OAUTH_CLIENT_ID=REPLACE_ZITADEL_CLIENT_ID
  GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=REPLACE_ZITADEL_CLIENT_SECRET
  GF_AUTH_GENERIC_OAUTH_SCOPES=openid profile email urn:zitadel:iam:org:project:roles urn:zitadel:iam:org:project:id:REPLACE_PROJECT_ID:aud
  GF_AUTH_GENERIC_OAUTH_AUTH_URL=https://zitadel.prestonhager.com/oauth/v2/authorize
  GF_AUTH_GENERIC_OAUTH_TOKEN_URL=https://zitadel.prestonhager.com/oauth/v2/token
  GF_AUTH_GENERIC_OAUTH_API_URL=https://zitadel.prestonhager.com/oidc/v1/userinfo
  GF_AUTH_GENERIC_OAUTH_USE_PKCE=true
  GF_AUTH_GENERIC_OAUTH_ALLOW_ASSIGN_GRAFANA_ADMIN=true
  GF_AUTH_GENERIC_OAUTH_EMAIL_ATTRIBUTE_PATH=email
  GF_AUTH_GENERIC_OAUTH_SKIP_ORG_ROLE_SYNC=false
  GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH=contains(keys("urn:zitadel:iam:org:project:roles"), 'grafana_admin') && 'GrafanaAdmin' || 'Viewer'
  GF_RENDERING_RENDERER_TOKEN=REPLACE_RENDERER_TOKEN
  AUTH_TOKEN=REPLACE_RENDERER_TOKEN
EOF
}

write_template
write_oauth_yaml secrets/containers/grafana-oauth.yaml
nix shell nixpkgs#sops --command sops --encrypt --encrypted-regex '^(data|stringData|grafana-oauth-env)$' --in-place secrets/containers/grafana-oauth.yaml

echo '=== Updated grafana-oauth secret ==='
nix shell nixpkgs#sops --command sops -d secrets/containers/grafana-oauth.yaml | grep -E 'GF_AUTH_GENERIC_OAUTH_(ALLOW_ASSIGN|ROLE_ATTRIBUTE|SCOPES|EMAIL|SKIP)'

cd /etc/nixos
nixos-rebuild switch --flake .#ace 2>&1 | tail -30
systemctl restart podman-grafana.service
sleep 4
systemctl is-active podman-grafana.service
echo '=== live secret ==='
grep -E 'GF_AUTH_GENERIC_OAUTH_(ALLOW_ASSIGN|ROLE_ATTRIBUTE|SCOPES|EMAIL|SKIP)' /run/secrets/grafana-oauth-env
