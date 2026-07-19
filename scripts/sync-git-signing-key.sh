#!/usr/bin/env bash
# Sync Git SSH signing private key from Vaultwarden → ~/.ssh/git_signing_ed25519.
# Vault item: git-signing-ed25519 (SSH key). Never prints private key material.
#
# Usage:
#   export BW_SESSION="$(bw unlock --raw)"   # or: source ~/.config/bitwarden/bw-ssh.sh
#   ./scripts/sync-git-signing-key.sh
#
# On NixOS after home-manager: sync-git-signing-key
set -euo pipefail

ITEM_NAME="${GIT_SIGNING_BW_ITEM:-git-signing-ed25519}"
DEST="${GIT_SIGNING_KEY_PATH:-$HOME/.ssh/git_signing_ed25519}"
SERVER="${BW_SERVER:-https://vault.prestonhager.com}"

if ! command -v bw >/dev/null 2>&1; then
  echo "error: bitwarden-cli (bw) not found" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 required to parse vault JSON" >&2
  exit 1
fi

current="$(bw config server 2>/dev/null || true)"
if [[ "$current" != "$SERVER" ]]; then
  bw config server "$SERVER" >/dev/null
fi

status="$(bw status | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
if [[ "$status" == "unauthenticated" ]]; then
  echo "error: not logged in; run: bw login" >&2
  exit 1
fi
if [[ "$status" == "locked" && -z "${BW_SESSION:-}" ]]; then
  export BW_SESSION="$(bw unlock --raw)"
fi

bw sync >/dev/null

export ITEM_NAME
item_id="$(
  bw list items --search "$ITEM_NAME" | python3 -c '
import json,sys,os
name=os.environ["ITEM_NAME"]
for it in json.load(sys.stdin):
    if it.get("name")==name:
        print(it["id"]); break
'
)"
if [[ -z "$item_id" ]]; then
  echo "error: vault item '$ITEM_NAME' not found" >&2
  exit 1
fi

umask 077
mkdir -p "$(dirname "$DEST")"
bw get item "$item_id" | python3 -c '
import json,sys
item=json.load(sys.stdin)
sk=item.get("sshKey") or {}
priv=sk.get("privateKey") or ""
if not priv:
    raise SystemExit("missing privateKey on SSH key item")
dest=sys.argv[1]
with open(dest,"w",encoding="utf-8") as f:
    f.write(priv if priv.endswith("\n") else priv+"\n")
pub=sk.get("publicKey") or ""
if pub:
    with open(dest+".pub","w",encoding="utf-8") as f:
        f.write(pub if pub.endswith("\n") else pub+"\n")
' "$DEST"
chmod 600 "$DEST"
[[ -f "$DEST.pub" ]] && chmod 644 "$DEST.pub"

fp="$(ssh-keygen -lf "$DEST.pub" 2>/dev/null | awk '{print $2}' || true)"
echo "Synced Git signing key to $DEST"
if [[ -n "$fp" ]]; then
  echo "Fingerprint: $fp"
fi
