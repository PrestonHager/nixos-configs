#!/usr/bin/env bash
# Bump pinned versions in nix files, commit, push, and rebuild ace.
set -euo pipefail

SERVICE=""
NIX_FILE=""
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) SERVICE="$2"; shift 2 ;;
    --nix-file) NIX_FILE="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$SERVICE" && -n "$NIX_FILE" && -n "$TARGET" ]] || {
  echo "usage: ace-service-update-bump --service NAME --nix-file PATH --target VERSION" >&2
  exit 1
}

ACE_NIXOS_DIR="${ACE_NIXOS_DIR:-/etc/nixos}"
ACE_REGISTRY="${ACE_REGISTRY:?ACE_REGISTRY must be set}"
TARGET="${TARGET#v}"

path="${ACE_NIXOS_DIR}/${NIX_FILE}"
[[ -f "$path" ]] || { echo "missing nix file: $path" >&2; exit 1; }

tmp="$(mktemp)"
cp "$path" "$tmp"

while IFS= read -r rule; do
  [[ -z "$rule" ]] && continue
  match="$(jq -r '.match' <<<"$rule")"
  suffix="$(jq -r '.suffix' <<<"$rule")"
  prefix="$(jq -r '.prefix // ""' <<<"$rule")"
  version="${prefix}${TARGET}"

  awk -v m="$match" -v s="$suffix" -v v="$version" '
    index($0, m) == 1 {
      print m v s
      next
    }
    { print }
  ' "$tmp" > "${tmp}.new"
  mv "${tmp}.new" "$tmp"
done < <(jq -c --arg s "$SERVICE" '.[$s].bumpRules[]?' "$ACE_REGISTRY")

if cmp -s "$path" "$tmp"; then
  rm -f "$tmp"
  echo "No version lines changed in ${NIX_FILE} for target ${TARGET}" >&2
  exit 1
fi

mv "$tmp" "$path"

cd "$ACE_NIXOS_DIR"
if ! git pull --rebase origin "$(git rev-parse --abbrev-ref HEAD)"; then
  echo "git pull --rebase failed; resolve /etc/nixos manually" >&2
  exit 1
fi

git add "$NIX_FILE"
if git diff --cached --quiet; then
  echo "No git changes after bumping ${NIX_FILE}" >&2
  exit 1
fi

git commit -m "ace: bump ${SERVICE} to ${TARGET}

Automated patch/minor update triggered by ace-service-auto-update."

if ! git push origin HEAD; then
  echo "git push failed; local commit exists but remote was not updated" >&2
  exit 1
fi

if ! nixos-rebuild switch --flake "${ACE_NIXOS_DIR}#ace"; then
  echo "nixos-rebuild switch failed after bumping ${SERVICE} to ${TARGET}" >&2
  exit 1
fi

printf 'Updated %s in %s to %s and ran nixos-rebuild switch --flake %s#ace\n' \
  "$SERVICE" "$NIX_FILE" "$TARGET" "$ACE_NIXOS_DIR"
