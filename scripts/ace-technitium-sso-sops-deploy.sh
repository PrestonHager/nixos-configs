#!/usr/bin/env bash
# Update technitium.yaml sops with OIDC env and rebuild ace.
set -euo pipefail
CLIENT_ID="${1:?client id}"
CLIENT_SECRET="${2:?client secret}"
SECRETS="${3:-/home/prestonh/nixos-secrets}"
REPO="${4:-/etc/nixos}"

cd "$SECRETS"
TMP=$(mktemp)
nix shell nixpkgs#sops --command sops -d secrets/containers/technitium.yaml > "$TMP"
grep -q '^technitium-oidc-env:' "$TMP" || cat >>"$TMP" <<EOF

technitium-oidc-env: |
  TECHNITIUM_OIDC_CLIENT_ID=${CLIENT_ID}
  TECHNITIUM_OIDC_CLIENT_SECRET=${CLIENT_SECRET}
EOF
python3 - "$TMP" "$CLIENT_ID" "$CLIENT_SECRET" <<'PY'
import sys
path, cid, secret = sys.argv[1:4]
lines = open(path).read().splitlines()
out = []
in_block = False
replaced = False
for line in lines:
    if line.startswith("technitium-oidc-env:"):
        out.append("technitium-oidc-env: |")
        out.append(f"  TECHNITIUM_OIDC_CLIENT_ID={cid}")
        out.append(f"  TECHNITIUM_OIDC_CLIENT_SECRET={secret}")
        in_block = True
        replaced = True
        continue
    if in_block:
        if line.startswith("  "):
            continue
        in_block = False
    if line.startswith("technitium-oidc-client-"):
        continue
    out.append(line)
if not replaced:
    out.extend([
        "",
        "technitium-oidc-env: |",
        f"  TECHNITIUM_OIDC_CLIENT_ID={cid}",
        f"  TECHNITIUM_OIDC_CLIENT_SECRET={secret}",
    ])
open(path, "w").write("\n".join(out) + "\n")
PY
cp "$TMP" secrets/containers/technitium.yaml
rm "$TMP"
nix shell nixpkgs#sops --command sops -e -i secrets/containers/technitium.yaml
git add secrets/containers/technitium.yaml
git commit -m "Add Technitium OIDC env for SSO" --no-gpg-sign || true
git push origin main

cd "$REPO"
git pull origin dell-poweredge-r730xd || true
nix flake update nix-secrets
nixos-rebuild switch --flake "$REPO#ace"
rm -f /stor/technitium/.sso-settings.sha256
systemctl restart technitium-sync-sso.service
curl -s http://127.0.0.1:5380/api/sso/status
echo
systemctl status technitium-sync-sso.service --no-pager
