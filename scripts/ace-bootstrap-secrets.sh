#!/usr/bin/env bash
set -euo pipefail
git config --global --add safe.directory /home/prestonh/nixos-secrets
cd /home/prestonh/nixos-secrets
git pull origin main

# Zitadel default password policy requires upper, lower, digit, and symbol.
gen_pass() {
  local len="$1"
  local core
  core="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$((len - 4))")"
  printf '%sAa1!' "$core"
}

MASTERKEY=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
PGPASS=$(gen_pass 24)
ZITPASS=$(gen_pass 24)
ADMINPASS=$(gen_pass 20)
cat > secrets/containers/zitadel-config.yaml <<EOF
zitadel-db-env: |
  POSTGRES_USER=postgres
  POSTGRES_PASSWORD=${PGPASS}
  POSTGRES_DB=zitadel

zitadel-env: |
  ZITADEL_MASTERKEY=${MASTERKEY}
  ZITADEL_EXTERNALSECURE=true
  ZITADEL_EXTERNALDOMAIN=zitadel.prestonhager.com
  ZITADEL_EXTERNALPORT=443
  ZITADEL_TLS_ENABLED=false
  ZITADEL_DATABASE_POSTGRES_HOST=127.0.0.1
  ZITADEL_DATABASE_POSTGRES_PORT=5432
  ZITADEL_DATABASE_POSTGRES_DATABASE=zitadel
  ZITADEL_DATABASE_POSTGRES_USER_USERNAME=zitadel
  ZITADEL_DATABASE_POSTGRES_USER_PASSWORD=${ZITPASS}
  ZITADEL_DATABASE_POSTGRES_USER_SSL_MODE=disable
  ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME=postgres
  ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD=${PGPASS}
  ZITADEL_DATABASE_POSTGRES_ADMIN_SSL_MODE=disable
  ZITADEL_FIRSTINSTANCE_ORG_NAME=Preston Hager
  ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME=admin@prestonhager.com
  ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD=${ADMINPASS}
  ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORDCHANGE_REQUIRED=false
EOF
cat > secrets/containers/grafana-oauth.yaml <<EOF
grafana-oauth-env: |
  GF_AUTH_GENERIC_OAUTH_ENABLED=true
  GF_AUTH_GENERIC_OAUTH_NAME=Zitadel
  GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP=true
  GF_AUTH_GENERIC_OAUTH_CLIENT_ID=REPLACE_ZITADEL_CLIENT_ID
  GF_AUTH_GENERIC_OAUTH_SCOPES=openid profile email
  GF_AUTH_GENERIC_OAUTH_AUTH_URL=https://zitadel.prestonhager.com/oauth/v2/authorize
  GF_AUTH_GENERIC_OAUTH_TOKEN_URL=https://zitadel.prestonhager.com/oauth/v2/token
  GF_AUTH_GENERIC_OAUTH_API_URL=https://zitadel.prestonhager.com/oidc/v1/userinfo
  GF_AUTH_GENERIC_OAUTH_USE_PKCE=true
  GF_AUTH_GENERIC_OAUTH_ALLOW_ASSIGN_GRAFANA_ADMIN=true
EOF
nix shell nixpkgs#sops --command sops -e -i secrets/containers/zitadel-config.yaml
nix shell nixpkgs#sops --command sops -e -i secrets/containers/grafana-oauth.yaml
git add secrets/containers/zitadel-config.yaml secrets/containers/grafana-oauth.yaml
git commit --trailer "Co-authored-by: Cursor <cursoragent@cursor.com>" -m "Add encrypted Zitadel and Grafana OAuth secrets for ace" --no-gpg-sign
git push origin main
echo "ZITADEL_ADMIN_PASSWORD=${ADMINPASS}"