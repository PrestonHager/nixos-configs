#!/usr/bin/env bash
# Restore nextcloud.yaml from git and append OIDC placeholder. Run on ace as root.
set -euo pipefail
export SOPS_AGE_KEY_FILE=/var/lib/sops/age/keys.txt
cd /home/prestonh/nixos-secrets

git show 6adcd10:secrets/containers/nextcloud.yaml > secrets/containers/nextcloud.yaml
plain=$(nix shell nixpkgs#sops --command sops -d secrets/containers/nextcloud.yaml)
cat >secrets/containers/nextcloud.yaml <<EOF
${plain}

nextcloud-oidc-env: |
  NEXTCLOUD_OIDC_CLIENT_ID=REPLACE_ZITADEL_CLIENT_ID
  NEXTCLOUD_OIDC_CLIENT_SECRET=REPLACE_ZITADEL_CLIENT_SECRET
  ZITADEL_PROJECT_ID=376196450586990901
EOF

nix shell nixpkgs#sops --command sops --encrypt --encrypted-regex '^(data|stringData|nextcloud-.*)$' --in-place secrets/containers/nextcloud.yaml
nix shell nixpkgs#sops --command sops -d secrets/containers/nextcloud.yaml | head -20

git add secrets/containers/nextcloud.yaml
git -c trailer.ifexists=doNothing commit -m 'Restore nextcloud secrets and add OIDC placeholder' --no-gpg-sign || true
git push origin main
