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
  # SMTP password is not stored here — zitadel.nix injects it from nextcloud SMTP_PASSWORD.
EOF
cat > secrets/containers/grafana-oauth.yaml <<EOF
grafana-oauth-env: |
  GF_AUTH_GENERIC_OAUTH_ENABLED=true
  GF_AUTH_GENERIC_OAUTH_NAME=Zitadel
  GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP=true
  GF_AUTH_GENERIC_OAUTH_CLIENT_ID=REPLACE_ZITADEL_CLIENT_ID
  GF_AUTH_GENERIC_OAUTH_SCOPES=openid profile email urn:zitadel:iam:org:project:roles urn:zitadel:iam:org:project:id:REPLACE_PROJECT_ID:aud
  GF_AUTH_GENERIC_OAUTH_AUTH_URL=https://zitadel.prestonhager.com/oauth/v2/authorize
  GF_AUTH_GENERIC_OAUTH_TOKEN_URL=https://zitadel.prestonhager.com/oauth/v2/token
  GF_AUTH_GENERIC_OAUTH_API_URL=https://zitadel.prestonhager.com/oidc/v1/userinfo
  GF_AUTH_GENERIC_OAUTH_USE_PKCE=true
  GF_AUTH_GENERIC_OAUTH_ALLOW_ASSIGN_GRAFANA_ADMIN=true
  GF_AUTH_GENERIC_OAUTH_EMAIL_ATTRIBUTE_PATH=email
  GF_AUTH_GENERIC_OAUTH_SKIP_ORG_ROLE_SYNC=false
  GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH=contains(keys("urn:zitadel:iam:org:project:roles"), 'grafana_admin') && 'GrafanaAdmin' || 'Viewer'
  GRAFANA_ALERT_EMAILS=preston@hagerfamily.com
EOF
nix shell nixpkgs#sops --command sops -e -i secrets/containers/zitadel-config.yaml
nix shell nixpkgs#sops --command sops -e -i secrets/containers/grafana-oauth.yaml

if [ ! -f secrets/containers/matrix.yaml ]; then
  MATRIXPG=$(gen_pass 24)
  REGSECRET=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 48)
  MACAROON=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 48)
  FORM=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 48)
  cat > secrets/containers/matrix.yaml <<EOF
matrix-db-env: |
  POSTGRES_USER=synapse
  POSTGRES_PASSWORD=${MATRIXPG}
  POSTGRES_DB=synapse

matrix-secrets: |
  SYNAPSE_REGISTRATION_SHARED_SECRET=${REGSECRET}
  SYNAPSE_MACAROON_SECRET_KEY=${MACAROON}
  SYNAPSE_FORM_SECRET=${FORM}
EOF
  nix shell nixpkgs#sops --command sops -e -i secrets/containers/matrix.yaml
fi

if ! nix shell nixpkgs#sops --command sops -d secrets/containers/matrix.yaml 2>/dev/null | grep -q '^SYNAPSE_OIDC_CLIENT_ID='; then
  cat >>secrets/containers/matrix.yaml <<'EOF'

matrix-oauth-env: |
  SYNAPSE_OIDC_CLIENT_ID=REPLACE_ZITADEL_CLIENT_ID
  SYNAPSE_OIDC_CLIENT_SECRET=REPLACE_ZITADEL_CLIENT_SECRET
  ZITADEL_PROJECT_ID=REPLACE_PROJECT_ID
EOF
  nix shell nixpkgs#sops --command sops -e -i secrets/containers/matrix.yaml
fi

if [ -f secrets/containers/nextcloud.yaml ] \
  && ! nix shell nixpkgs#sops --command sops -d secrets/containers/nextcloud.yaml 2>/dev/null | grep -q '^NEXTCLOUD_OIDC_CLIENT_ID='; then
  cat >>secrets/containers/nextcloud.yaml <<'EOF'

nextcloud-oidc-env: |
  NEXTCLOUD_OIDC_CLIENT_ID=REPLACE_ZITADEL_CLIENT_ID
  NEXTCLOUD_OIDC_CLIENT_SECRET=REPLACE_ZITADEL_CLIENT_SECRET
  ZITADEL_PROJECT_ID=376196450586990901
EOF
  nix shell nixpkgs#sops --command sops -e -i secrets/containers/nextcloud.yaml
fi

if [ -f secrets/containers/nextcloud.yaml ] \
  && ! nix shell nixpkgs#sops --command sops -d secrets/containers/nextcloud.yaml 2>/dev/null | grep -q '^JWT_SECRET_KEY='; then
  WHITEBOARDJWT=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 48)
  cat >>secrets/containers/nextcloud.yaml <<EOF

nextcloud-whiteboard-env: |
  JWT_SECRET_KEY=${WHITEBOARDJWT}
  NEXTCLOUD_URL=https://cloud.prestonhager.com
EOF
  nix shell nixpkgs#sops --command sops -e -i secrets/containers/nextcloud.yaml
fi

if [ ! -f secrets/containers/jellyfin.yaml ]; then
  cat > secrets/containers/jellyfin.yaml <<'EOF'
jellyfin-oauth-env: |
  JELLYFIN_OIDC_CLIENT_ID=REPLACE_ZITADEL_CLIENT_ID
  JELLYFIN_OIDC_CLIENT_SECRET=REPLACE_ZITADEL_CLIENT_SECRET
  ZITADEL_PROJECT_ID=376196450586990901
EOF
  nix shell nixpkgs#sops --command sops -e -i secrets/containers/jellyfin.yaml
fi

git add secrets/containers/zitadel-config.yaml secrets/containers/grafana-oauth.yaml
if [ -f secrets/containers/matrix.yaml ]; then
  git add secrets/containers/matrix.yaml
fi
if [ -f secrets/containers/nextcloud.yaml ]; then
  git add secrets/containers/nextcloud.yaml
fi
if [ -f secrets/containers/jellyfin.yaml ]; then
  git add secrets/containers/jellyfin.yaml
fi
git commit --trailer "Co-authored-by: Cursor <cursoragent@cursor.com>" -m "Add encrypted container secrets for ace (Zitadel, Grafana OAuth, Matrix)" --no-gpg-sign || true
git push origin main
echo "ZITADEL_ADMIN_PASSWORD=${ADMINPASS}"