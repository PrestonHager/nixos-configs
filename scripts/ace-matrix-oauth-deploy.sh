#!/usr/bin/env bash
# Write Matrix OIDC credentials into sops and redeploy ace.
# Usage: ace-matrix-oauth-deploy.sh <client_id> [client_secret]
set -euo pipefail

export SOPS_AGE_KEY_FILE=/var/lib/sops/age/keys.txt
SECRETS=/home/prestonh/nixos-secrets
PROJECT_ID='376196450586990901'
CLIENT_ID="${1:?client_id required}"
CLIENT_SECRET="${2:-}"

cd "$SECRETS"

plain=$(mktemp)
nix shell nixpkgs#sops --command sops -d secrets/containers/matrix.yaml >"$plain"

get_env_val() {
  local key="$1"
  awk -v k="$key" -F= '$0 ~ k"=" { sub("^[[:space:]]*" k "=", ""); print; exit }' "$plain"
}

POSTGRES_USER=$(get_env_val POSTGRES_USER)
POSTGRES_PASSWORD=$(get_env_val POSTGRES_PASSWORD)
POSTGRES_DB=$(get_env_val POSTGRES_DB)
REG=$(get_env_val SYNAPSE_REGISTRATION_SHARED_SECRET)
MAC=$(get_env_val SYNAPSE_MACAROON_SECRET_KEY)
FORM=$(get_env_val SYNAPSE_FORM_SECRET)

for v in POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB REG MAC FORM; do
  if [ -z "${!v}" ]; then
    echo "missing $v in matrix.yaml" >&2
    exit 1
  fi
done

cat >secrets/containers/matrix.yaml <<EOF
matrix-db-env: |
  POSTGRES_USER=${POSTGRES_USER}
  POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
  POSTGRES_DB=${POSTGRES_DB}

matrix-secrets: |
  SYNAPSE_REGISTRATION_SHARED_SECRET=${REG}
  SYNAPSE_MACAROON_SECRET_KEY=${MAC}
  SYNAPSE_FORM_SECRET=${FORM}

matrix-oauth-env: |
  SYNAPSE_OIDC_CLIENT_ID=${CLIENT_ID}
  SYNAPSE_OIDC_CLIENT_SECRET=${CLIENT_SECRET}
  ZITADEL_PROJECT_ID=${PROJECT_ID}
EOF

rm -f "$plain"

nix shell nixpkgs#sops --command sops --encrypt --encrypted-regex '^(data|stringData|matrix-.*)$' --in-place secrets/containers/matrix.yaml

echo '=== Updated matrix-oauth secret ==='
nix shell nixpkgs#sops --command sops -d secrets/containers/matrix.yaml | grep -E '^(SYNAPSE_OIDC|ZITADEL_PROJECT)'

git add secrets/containers/matrix.yaml
git commit -m "Add Matrix OIDC client credentials for Zitadel SSO" --no-gpg-sign || true
git push origin main

cd /etc/nixos
git pull --ff-only || true
nix flake update nix-secrets
nixos-rebuild switch --flake .#ace 2>&1 | tail -40

systemctl restart matrix-synapse-init.service
systemctl restart podman-matrix-synapse.service
sleep 5
systemctl is-active podman-matrix-synapse.service
curl -sS -o /dev/null -w 'sso_redirect_http=%{http_code}\n' \
  'http://127.0.0.1:6167/_matrix/client/v3/login/sso/redirect?redirectUrl=https%3A%2F%2Fapp.element.io%2F'
