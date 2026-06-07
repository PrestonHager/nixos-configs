#!/usr/bin/env bash
# Fix technitium-oidc-client-id sops type (must be str, not int). Run on ace as root.
set -euo pipefail
export SOPS_AGE_KEY_FILE=/var/lib/sops/age/keys.txt
cd /home/prestonh/nixos-secrets

plain=$(nix shell nixpkgs#sops --command sops -d secrets/containers/technitium.yaml)
admin=$(printf '%s\n' "$plain" | awk -F': ' '/^technitium-admin-password:/{print $2; exit}')
client_id=$(printf '%s\n' "$plain" | awk -F': ' '/^technitium-oidc-client-id:/{print $2; exit}')
client_secret=$(printf '%s\n' "$plain" | awk -F': ' '/^technitium-oidc-client-secret:/{print $2; exit}')

cat >secrets/containers/technitium.yaml <<EOF
technitium-admin-password: ${admin}
technitium-oidc-client-id: "${client_id}"
technitium-oidc-client-secret: ${client_secret}
EOF

nix shell nixpkgs#sops --command sops --encrypt --encrypted-regex '^(technitium-.*)$' --in-place secrets/containers/technitium.yaml
git add secrets/containers/technitium.yaml
git -c trailer.ifexists=doNothing commit -m 'Fix technitium OIDC client id secret type' --no-gpg-sign || true
git push origin main
