#!/usr/bin/env bash
# Generate Pterodactyl→Astracap NAT automation SSH key, store in sops, redeploy ace.
# Usage: ace-pterodactyl-router-ssh-deploy.sh [path-to-private-key]
#
# If no key path is given, generates a 2048-bit RSA key at /tmp/pterodactyl-router-ssh-key
# (IOS 15.x rejects 4096-bit keys in ip ssh pubkey-chain).
set -euo pipefail

export SOPS_AGE_KEY_FILE=/var/lib/sops/age/keys.txt
SECRETS=/home/prestonh/nixos-secrets
KEY_PATH="${1:-/tmp/pterodactyl-router-ssh-key}"
PUB_PATH="${KEY_PATH}.pub"

if [ ! -f "$KEY_PATH" ]; then
  echo "Generating 2048-bit RSA key at $KEY_PATH ..."
  ssh-keygen -t rsa -b 2048 -f "$KEY_PATH" -N "" -C "pterodactyl-portforward-nat-automation"
fi

if [ ! -f "$PUB_PATH" ]; then
  echo "Missing public key: $PUB_PATH" >&2
  exit 1
fi

cd "$SECRETS"
TMP="$(mktemp)"
if nix shell nixpkgs#sops --command sops -d secrets/containers/pterodactyl.yaml >"$TMP" 2>/dev/null; then
  :
else
  : >"$TMP"
fi

python3 - "$TMP" "$KEY_PATH" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
key = pathlib.Path(sys.argv[2]).read_text()
lines = path.read_text().splitlines() if path.exists() and path.stat().st_size else []
out = []
skip = False
for line in lines:
    if line.startswith("pterodactyl-router-ssh-key:"):
        skip = True
        continue
    if skip:
        if line.startswith(" ") or line.startswith("\t"):
            continue
        skip = False
    out.append(line)
while out and out[-1] == "":
    out.pop()
out.append("pterodactyl-router-ssh-key: |")
for ln in key.splitlines():
    out.append("  " + ln)
path.write_text("\n".join(out) + "\n")
PY

nix shell nixpkgs#sops --command sops \
  --encrypt \
  --encrypted-regex '^(pterodactyl-router-ssh-key|pterodactyl-password|pterodactyl-env)$' \
  --in-place secrets/containers/pterodactyl.yaml

echo "=== pterodactyl-router-ssh-key fingerprint ==="
ssh-keygen -lf "$PUB_PATH"

git add secrets/containers/pterodactyl.yaml
git commit -m "Add Pterodactyl Astracap NAT automation SSH key (pterofwd)" --no-gpg-sign || true
git push origin main

cd /etc/nixos
git fetch origin dell-poweredge-r730xd
git reset --hard origin/dell-poweredge-r730xd
nix flake update nix-secrets
nixos-rebuild switch --flake .#ace 2>&1 | tail -60

systemctl restart pterodactyl-blueprint-extensions-env.service
systemctl restart pterodactyl-blueprint-extensions-configure.service
systemctl restart podman-pterodactyl.service

echo "=== Public key (authorize on Astracap for user pterofwd) ==="
cat "$PUB_PATH"
