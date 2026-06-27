#!/usr/bin/env bash
# Ensure nextcloud-whiteboard-env exists in nix-secrets. Run on ace as root.
set -euo pipefail
cd /home/prestonh/nixos-secrets
git pull origin main
if nix shell nixpkgs#sops --command sops -d secrets/containers/nextcloud.yaml 2>/dev/null | grep -q 'JWT_SECRET_KEY='; then
  echo "nextcloud-whiteboard-env already present"
  exit 0
fi
WHITEBOARDJWT="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 48)"
cat >>secrets/containers/nextcloud.yaml <<EOF

nextcloud-whiteboard-env: |
  JWT_SECRET_KEY=${WHITEBOARDJWT}
  NEXTCLOUD_URL=https://cloud.prestonhager.com
EOF
nix shell nixpkgs#sops --command sops -e -i secrets/containers/nextcloud.yaml
git add secrets/containers/nextcloud.yaml
git commit -m "Add nextcloud-whiteboard-env JWT secret for ace"
git push origin main
echo "nextcloud-whiteboard-env added"
