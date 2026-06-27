#!/usr/bin/env bash
# Ensure nextcloud-whiteboard-env exists in nix-secrets. Run on ace as root.
set -euo pipefail
cd /home/prestonh/nixos-secrets
git pull origin main
if nix shell nixpkgs#sops --command sops -d secrets/containers/nextcloud.yaml 2>/dev/null | grep -q 'JWT_SECRET_KEY='; then
  echo "nextcloud-whiteboard-env already present"
  exit 0
fi
WHITEBOARDJWT="$(dd if=/dev/urandom bs=24 count=1 2>/dev/null | base64 | tr -dc 'A-Za-z0-9' | fold -w 48 | head -n 1)"
if [ -z "$WHITEBOARDJWT" ]; then
  echo "failed to generate whiteboard JWT secret" >&2
  exit 1
fi
plain="$(mktemp)"
nix shell nixpkgs#sops --command sops -d secrets/containers/nextcloud.yaml >"$plain"
cat >>"$plain" <<EOF

nextcloud-whiteboard-env: |
  JWT_SECRET_KEY=${WHITEBOARDJWT}
  NEXTCLOUD_URL=https://cloud.prestonhager.com
EOF
mv "$plain" secrets/containers/nextcloud.yaml
nix shell nixpkgs#sops --command sops --encrypt --encrypted-regex '^(data|stringData|nextcloud-.*)$' --in-place secrets/containers/nextcloud.yaml
git add secrets/containers/nextcloud.yaml
git commit --no-gpg-sign -m "Add nextcloud-whiteboard-env JWT secret for ace"
git push origin main
echo "nextcloud-whiteboard-env added"
