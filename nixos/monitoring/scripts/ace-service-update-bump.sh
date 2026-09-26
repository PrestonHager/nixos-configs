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

if [[ "$SERVICE" == "nextcloud" ]]; then
  if ! podman manifest inspect "docker.io/library/nextcloud:${TARGET}" >/dev/null 2>&1; then
    echo "docker.io/library/nextcloud:${TARGET} is not published on Docker Hub; refusing bump" >&2
    exit 1
  fi
fi

cd "$ACE_NIXOS_DIR"
branch="$(git rev-parse --abbrev-ref HEAD)"

# nixos-rebuild sometimes leaves flake.lock dirty; do not block the next bump.
if git diff --name-only -- flake.lock | grep -qx flake.lock \
  && [[ "$(git diff --name-only | wc -l)" -eq 1 ]]; then
  git checkout -- flake.lock
fi

if ! git fetch origin "$branch"; then
  echo "git fetch origin ${branch} failed" >&2
  exit 1
fi

if ! git rebase --autostash "origin/${branch}"; then
  echo "git rebase onto origin/${branch} failed; resolve ${ACE_NIXOS_DIR} manually" >&2
  git status -sb >&2 || true
  exit 1
fi

tmp="$(mktemp)"
cp "$path" "$tmp"

while IFS= read -r rule; do
  [[ -z "$rule" ]] && continue
  match="$(jq -r '.match' <<<"$rule")"
  suffix="$(jq -r '.suffix' <<<"$rule")"
  prefix="$(jq -r '.prefix // ""' <<<"$rule")"
  version="${prefix}${TARGET}"

  esc_match="${match//\\/\\\\}"
  esc_match="${esc_match//|/\\|}"
  esc_match="${esc_match//&/\\&}"
  esc_suffix="${suffix//\\/\\\\}"
  esc_suffix="${esc_suffix//|/\\|}"
  esc_suffix="${esc_suffix//&/\\&}"
  esc_version="${version//\\/\\\\}"
  esc_version="${esc_version//|/\\|}"
  esc_version="${esc_version//&/\\&}"

  sed -i "s|\(${esc_match}\)[^\"]*|\1${esc_version}|g" "$tmp"
done < <(jq -c --arg s "$SERVICE" '.[$s].bumpRules[]?' "$ACE_REGISTRY")

if [[ "$(cat "$path")" == "$(cat "$tmp")" ]]; then
  rm -f "$tmp"
  already_at_target=0
  while IFS= read -r rule; do
    [[ -z "$rule" ]] && continue
    match="$(jq -r '.match' <<<"$rule")"
    prefix="$(jq -r '.prefix // ""' <<<"$rule")"
    if grep -qF "${match}${prefix}${TARGET}" "$path"; then
      already_at_target=1
      break
    fi
  done < <(jq -c --arg s "$SERVICE" '.[$s].bumpRules[]?' "$ACE_REGISTRY")
  if [[ "$already_at_target" -eq 1 ]]; then
    rebuild_lock="/run/ace-service-update-rebuild.lock"
    rebuild_log="$(mktemp)"
    if flock -w 3600 "$rebuild_lock" \
      env NIX_BUILD_CORES=12 \
      nixos-rebuild switch \
        --flake "${ACE_NIXOS_DIR}#ace" \
        -j 4 \
        --option max-jobs 4 \
        --option cores 12 \
        >"$rebuild_log" 2>&1; then
      rm -f "$rebuild_log"
      printf 'Already at %s in %s; ran nixos-rebuild switch --flake %s#ace\n' \
        "$TARGET" "$NIX_FILE" "$ACE_NIXOS_DIR"
      exit 0
    fi
    cat "$rebuild_log" >&2
    rm -f "$rebuild_log"
    echo "nixos-rebuild switch failed while ${NIX_FILE} already targets ${TARGET}" >&2
    exit 1
  fi
  echo "No version lines changed in ${NIX_FILE} for target ${TARGET}" >&2
  exit 1
fi

mv "$tmp" "$path"

git add "$NIX_FILE"
if git diff --cached --quiet; then
  echo "No git changes after bumping ${NIX_FILE}" >&2
  exit 1
fi

git -c user.name="Preston Hager" -c user.email="preston@hagerfamily.com" \
  -c commit.gpgsign=false \
  commit -m "ace: bump ${SERVICE} to ${TARGET}

Automated patch/minor update triggered by ace-service-auto-update."

if ! git push origin HEAD; then
  echo "git push failed; local commit exists but remote was not updated" >&2
  exit 1
fi

# Constrained rebuild: avoid unconstrained nix memory spikes on ace (31 GiB).
# Serialize with flock so concurrent service bumps cannot collide (nixos-rebuild exit 4).
rebuild_lock="/run/ace-service-update-rebuild.lock"
rebuild_log="$(mktemp)"
if ! flock -w 3600 "$rebuild_lock" \
  env NIX_BUILD_CORES=12 \
  nixos-rebuild switch \
    --flake "${ACE_NIXOS_DIR}#ace" \
    -j 4 \
    --option max-jobs 4 \
    --option cores 12 \
    >"$rebuild_log" 2>&1; then
  cat "$rebuild_log" >&2
  rm -f "$rebuild_log"
  echo "nixos-rebuild switch failed after bumping ${SERVICE} to ${TARGET}" >&2
  exit 1
fi
rm -f "$rebuild_log"

printf 'Updated %s in %s to %s and ran nixos-rebuild switch --flake %s#ace\n' \
  "$SERVICE" "$NIX_FILE" "$TARGET" "$ACE_NIXOS_DIR"
