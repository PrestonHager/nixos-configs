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

sed_escape() {
  local s="${1//\\/\\\\}"
  s="${s//|/\\|}"
  printf '%s' "${s//&/\\&}"
}

# Rules with "digestImage" pin <image>@sha256:<digest> followed by a
# "<comment><version>" note; resolve the digest of <image>:<prefix><TARGET>.
# Resolved digests, keyed by rule index, for the already-at-target check.
declare -A rule_digest=()

tmp="$(mktemp)"
cp "$path" "$tmp"

rule_idx=0
while IFS= read -r rule; do
  [[ -z "$rule" ]] && continue
  match="$(jq -r '.match' <<<"$rule")"
  prefix="$(jq -r '.prefix // ""' <<<"$rule")"
  digest_image="$(jq -r '.digestImage // ""' <<<"$rule")"
  version="${prefix}${TARGET}"
  esc_match="$(sed_escape "$match")"

  if [[ -n "$digest_image" ]]; then
    comment="$(jq -r '.comment // ""' <<<"$rule")"
    if ! digest="$(skopeo inspect --format '{{.Digest}}' "docker://${digest_image}:${version}")" \
      || [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      echo "could not resolve digest for ${digest_image}:${version}; refusing bump" >&2
      exit 1
    fi
    rule_digest[$rule_idx]="$digest"
    if [[ -n "$comment" ]]; then
      sed -i "s|\(${esc_match}\)sha256:[0-9a-f]*\(.*$(sed_escape "$comment")\)[^[:space:]]*|\1${digest}\2${TARGET}|g" "$tmp"
    else
      sed -i "s|\(${esc_match}\)sha256:[0-9a-f]*|\1${digest}|g" "$tmp"
    fi
  else
    sed -i "s|\(${esc_match}\)[^\"]*|\1$(sed_escape "$version")|g" "$tmp"
  fi
  rule_idx=$((rule_idx + 1))
done < <(jq -c --arg s "$SERVICE" '.[$s].bumpRules[]?' "$ACE_REGISTRY")

if [[ "$(cat "$path")" == "$(cat "$tmp")" ]]; then
  rm -f "$tmp"
  already_at_target=0
  rule_idx=0
  while IFS= read -r rule; do
    [[ -z "$rule" ]] && continue
    match="$(jq -r '.match' <<<"$rule")"
    prefix="$(jq -r '.prefix // ""' <<<"$rule")"
    if [[ -n "${rule_digest[$rule_idx]:-}" ]]; then
      needle="${match}${rule_digest[$rule_idx]}"
    else
      needle="${match}${prefix}${TARGET}"
    fi
    rule_idx=$((rule_idx + 1))
    if grep -qF "$needle" "$path"; then
      already_at_target=1
      break
    fi
  done < <(jq -c --arg s "$SERVICE" '.[$s].bumpRules[]?' "$ACE_REGISTRY")
  if [[ "$already_at_target" -eq 1 ]] && git diff --quiet HEAD -- "$NIX_FILE"; then
    # Pinned and committed already, so the running system has it: the version
    # metric that triggered this run is stale (e.g. read while the container was
    # still starting). Do not rebuild for it; one such rebuild ran mid-boot and
    # left units unstarted.
    printf 'Already at %s in %s and committed; nothing to do\n' "$TARGET" "$NIX_FILE"
    exit 0
  fi
  if [[ "$already_at_target" -ne 1 ]]; then
    echo "No version lines changed in ${NIX_FILE} for target ${TARGET}" >&2
    exit 1
  fi
  # At the target but uncommitted: an earlier run rebuilt from a dirty tree
  # without committing. Commit it below so /etc/nixos does not drift.
else
  mv "$tmp" "$path"
fi

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
