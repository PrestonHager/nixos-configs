#!/usr/bin/env bash
# Write Nextcloud OIDC credentials into sops and redeploy ace.
# Usage: ace-nextcloud-oauth-deploy.sh <client_id> <client_secret>
set -euo pipefail

export SOPS_AGE_KEY_FILE=/var/lib/sops/age/keys.txt
SECRETS=/home/prestonh/nixos-secrets
PROJECT_ID='376196450586990901'
CLIENT_ID="${1:?client_id required}"
CLIENT_SECRET="${2:?client_secret required}"

cd "$SECRETS"

plain=$(mktemp)
nix shell nixpkgs#sops --command sops -d secrets/containers/nextcloud.yaml >"$plain"

get_env_val() {
  local key="$1"
  awk -v k="$key" -F= '$0 ~ "^" k "=" { sub("^" k "=", ""); print; exit }' "$plain"
}

MARIADB_ROOT_PASSWORD=$(get_env_val MARIADB_ROOT_PASSWORD)
MARIADB_PASSWORD=$(get_env_val MARIADB_PASSWORD)
NEXTCLOUD_ADMIN_PASSWORD=$(get_env_val NEXTCLOUD_ADMIN_PASSWORD)
SMTP_PASSWORD=$(get_env_val SMTP_PASSWORD)

# sops stores keys under nextcloud-environment; fall back to flat lines
if [ -z "$MARIADB_ROOT_PASSWORD" ]; then
  MARIADB_ROOT_PASSWORD=$(nix shell nixpkgs#sops --command sops -d secrets/containers/nextcloud.yaml | awk -F= '/MARIADB_ROOT_PASSWORD=/{print $2; exit}')
fi
if [ -z "$MARIADB_PASSWORD" ]; then
  MARIADB_PASSWORD=$(nix shell nixpkgs#sops --command sops -d secrets/containers/nextcloud.yaml | awk -F= '/MARIADB_PASSWORD=/{print $2; exit}')
fi
if [ -z "$NEXTCLOUD_ADMIN_PASSWORD" ]; then
  NEXTCLOUD_ADMIN_PASSWORD=$(nix shell nixpkgs#sops --command sops -d secrets/containers/nextcloud.yaml | awk -F= '/NEXTCLOUD_ADMIN_PASSWORD=/{print $2; exit}')
fi
if [ -z "${SMTP_PASSWORD:-}" ]; then
  SMTP_PASSWORD=$(nix shell nixpkgs#sops --command sops -d secrets/containers/nextcloud.yaml | awk -F= '/SMTP_PASSWORD=/{print $2; exit}')
fi

for v in MARIADB_ROOT_PASSWORD MARIADB_PASSWORD NEXTCLOUD_ADMIN_PASSWORD; do
  if [ -z "${!v}" ]; then
    echo "missing $v in nextcloud.yaml" >&2
    exit 1
  fi
done

smtp_line=""
if [ -n "${SMTP_PASSWORD:-}" ]; then
  smtp_line="SMTP_PASSWORD=${SMTP_PASSWORD}"
fi

cat >secrets/containers/nextcloud.yaml <<EOF
nextcloud-environment: |
  MARIADB_ROOT_PASSWORD=${MARIADB_ROOT_PASSWORD}
  MARIADB_PASSWORD=${MARIADB_PASSWORD}
  NEXTCLOUD_ADMIN_PASSWORD=${NEXTCLOUD_ADMIN_PASSWORD}
  ${smtp_line}

nextcloud-db-environment: |
  MARIADB_ROOT_PASSWORD=${MARIADB_ROOT_PASSWORD}
  MARIADB_PASSWORD=${MARIADB_PASSWORD}

nextcloud-oidc-env: |
  NEXTCLOUD_OIDC_CLIENT_ID=${CLIENT_ID}
  NEXTCLOUD_OIDC_CLIENT_SECRET=${CLIENT_SECRET}
  ZITADEL_PROJECT_ID=${PROJECT_ID}
EOF

rm -f "$plain"

nix shell nixpkgs#sops --command sops --encrypt --encrypted-regex '^(data|stringData|nextcloud-.*)$' --in-place secrets/containers/nextcloud.yaml

echo '=== Updated nextcloud-oidc secret ==='
nix shell nixpkgs#sops --command sops -d secrets/containers/nextcloud.yaml | grep -E '^(NEXTCLOUD_OIDC|ZITADEL_PROJECT)'

git add secrets/containers/nextcloud.yaml
git commit -m "Add Nextcloud OIDC client credentials for Zitadel SSO" --no-gpg-sign || true
git push origin main

cd /etc/nixos
git pull --ff-only || true
nix flake update nix-secrets
nixos-rebuild switch --flake .#ace 2>&1 | tail -40

systemctl restart pod-nextcloud.service
sleep 10
systemctl restart podman-nextcloud.service
sleep 15
systemctl restart nextcloud-oidc-config.service
sleep 5
systemctl is-active nextcloud-oidc-config.service
podman exec -u www-data nextcloud php /var/www/html/occ user_oidc:provider zitadel 2>/dev/null | head -20 || true
