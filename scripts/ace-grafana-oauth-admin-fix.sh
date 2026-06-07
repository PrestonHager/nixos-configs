#!/usr/bin/env bash
# Patch Grafana OAuth sops secret with role_attribute_path and grant admin to existing user.
# Run on ace as root.
set -euo pipefail

export SOPS_AGE_KEY_FILE=/var/lib/sops/age/keys.txt
SECRETS=/home/prestonh/nixos-secrets
ROLE_PATH='email=='\''admin@prestonhager.com'\'' && '\''GrafanaAdmin'\'' || contains(keys("urn:zitadel:iam:org:project:roles"), '\''grafana_admin'\'') && '\''Admin'\'' || '\''Viewer'\'''

cd "$SECRETS"

if ! grep -q GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH secrets/containers/grafana-oauth.yaml.template 2>/dev/null; then
  cat >> secrets/containers/grafana-oauth.yaml.template <<EOF
  GF_AUTH_GENERIC_OAUTH_EMAIL_ATTRIBUTE_PATH=email
  GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH=${ROLE_PATH}
EOF
fi

nix shell nixpkgs#sops --command sops -d secrets/containers/grafana-oauth.yaml > /tmp/grafana-oauth-dec.yaml
if ! grep -q GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH /tmp/grafana-oauth-dec.yaml; then
  {
    echo "    GF_AUTH_GENERIC_OAUTH_EMAIL_ATTRIBUTE_PATH=email"
    echo "    GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH=${ROLE_PATH}"
  } >> /tmp/grafana-oauth-dec.yaml
fi
cp /tmp/grafana-oauth-dec.yaml secrets/containers/grafana-oauth.yaml
nix shell nixpkgs#sops --command sops --encrypt --encrypted-regex '^(data|stringData|grafana-oauth-env)$' --in-place secrets/containers/grafana-oauth.yaml
rm /tmp/grafana-oauth-dec.yaml

echo "=== grafana-oauth secret (tail) ==="
nix shell nixpkgs#sops --command sops -d secrets/containers/grafana-oauth.yaml | tail -5

nix shell nixpkgs#sqlite -c sqlite3 /grafana/data/grafana.db \
  "UPDATE user SET is_admin=1 WHERE email='admin@prestonhager.com';"
nix shell nixpkgs#sqlite -c sqlite3 /grafana/data/grafana.db \
  "UPDATE org_user SET role='Admin' WHERE user_id=(SELECT id FROM user WHERE email='admin@prestonhager.com');"
echo "=== grafana user ==="
nix shell nixpkgs#sqlite -c sqlite3 /grafana/data/grafana.db \
  "SELECT u.email, u.is_admin, ou.role FROM user u JOIN org_user ou ON ou.user_id=u.id WHERE u.email='admin@prestonhager.com';"

git add secrets/containers/grafana-oauth.yaml secrets/containers/grafana-oauth.yaml.template
git diff --cached --stat
git commit -m "Map Zitadel OAuth users to Grafana roles via role_attribute_path" --no-gpg-sign || true
git push origin main || true
