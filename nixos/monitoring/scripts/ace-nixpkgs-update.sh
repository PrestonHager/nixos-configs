#!/usr/bin/env bash
# Nightly nixpkgs update for ace: bump the nixpkgs flake input, build, switch,
# then commit and push flake.lock. Any failure leaves the running system and
# flake.lock as they were and sends one email.
set -euo pipefail

NIXOS_DIR="${ACE_NIXOS_DIR:?}"
PROM="${ACE_NIXPKGS_PROM:?}"
REBUILD_LOCK="/run/ace-service-update-rebuild.lock"
INPUT="nixpkgs"

log() {
  printf '[ace-nixpkgs-update] %s\n' "$*" >&2
}

locked_field() {  # FIELD: rev or lastModified of the locked nixpkgs input
  jq -r --arg i "$INPUT" '.nodes[.nodes.root.inputs[$i]].locked.'"$1" "$NIXOS_DIR/flake.lock"
}

# reboot_required is 1 when the switched-to kernel or initrd differs from the
# booted one: the new kernel only runs after a reboot.
write_metrics() {
  local status="$1" reboot=0 tmp
  if [[ "$(readlink -f /run/booted-system/kernel)" != "$(readlink -f /run/current-system/kernel)" ]] \
    || [[ "$(readlink -f /run/booted-system/initrd)" != "$(readlink -f /run/current-system/initrd)" ]]; then
    reboot=1
  fi
  tmp="${PROM}.$$"
  {
    echo "# HELP ace_nixpkgs_update_success 1 when the last nightly nixpkgs update succeeded (or had nothing to do)."
    echo "# TYPE ace_nixpkgs_update_success gauge"
    echo "ace_nixpkgs_update_success $([[ "$status" == ok ]] && echo 1 || echo 0)"
    echo "# HELP ace_nixpkgs_update_last_run_timestamp_seconds When the nightly nixpkgs update last ran."
    echo "# TYPE ace_nixpkgs_update_last_run_timestamp_seconds gauge"
    echo "ace_nixpkgs_update_last_run_timestamp_seconds $(date +%s)"
    echo "# HELP ace_nixpkgs_input_timestamp_seconds Commit time of the nixpkgs revision in flake.lock."
    echo "# TYPE ace_nixpkgs_input_timestamp_seconds gauge"
    echo "ace_nixpkgs_input_timestamp_seconds{rev=\"$(locked_field rev)\"} $(locked_field lastModified)"
    echo "# HELP ace_reboot_required 1 when the running generation has a kernel or initrd the host has not booted."
    echo "# TYPE ace_reboot_required gauge"
    echo "ace_reboot_required $reboot"
  } > "$tmp"
  chown node_exporter:node_exporter "$tmp" 2>/dev/null || true
  mv "$tmp" "$PROM"
}

fail() {  # SUMMARY LOGFILE
  local summary="$1" logfile="${2:-}" body
  log "FAILED: $summary"
  git -C "$NIXOS_DIR" checkout -- flake.lock nixos/caddy/acme-dns.nix 2>/dev/null || true
  write_metrics failed
  body="$(mktemp)"
  {
    echo "The nightly nixpkgs update on ace failed: ${summary}"
    echo
    echo "ace keeps running its previous generation and flake.lock is unchanged."
    echo "Candidate: nixpkgs ${new_rev:-unknown} (current ${old_rev:-unknown})."
    if [[ -n "$logfile" && -f "$logfile" ]]; then
      echo
      echo "Last 60 log lines:"
      tail -n 60 "$logfile" | sed -E 's/(password|token|secret)=[^ ]*/\1=<redacted>/gi'
    fi
  } > "$body"
  "${ACE_UPDATE_MAIL:?}" --subject "[ace] nightly nixpkgs update failed" --body-file "$body" || true
  rm -f "$body"
  exit 1
}

constrained() {  # same limits as ace-service-update-bump: ace has 31 GiB
  env NIX_BUILD_CORES=12 "$@" -j 4 --option max-jobs 4 --option cores 12
}

build_toplevel() {  # LOGFILE
  constrained nix build --no-link "${NIXOS_DIR}#nixosConfigurations.ace.config.system.build.toplevel" \
    >"$1" 2>&1
}

# A nixpkgs Caddy bump changes the vendor tree of Caddy-with-plugins, so its
# fixed-output hash in nixos/caddy/acme-dns.nix stops matching. Accept the new
# hash only for that derivation, only after a second independent fetch agrees,
# and only if the vendored plugin is the version pinned in acme-dns.nix.
fix_caddy_vendor_hash() {  # LOGFILE
  local logfile="$1" nixfile="${NIXOS_DIR}/nixos/caddy/acme-dns.nix" drv specified got plugin out
  grep -q "hash mismatch in fixed-output derivation '[^']*-caddy-src-with-plugins-" "$logfile" || return 1
  specified="$(grep -A2 "hash mismatch in fixed-output derivation '[^']*-caddy-src-with-plugins-" "$logfile" | sed -n 's/^ *specified: *//p' | head -n 1)"
  got="$(grep -A2 "hash mismatch in fixed-output derivation '[^']*-caddy-src-with-plugins-" "$logfile" | sed -n 's/^ *got: *//p' | head -n 1)"
  [[ "$specified" =~ ^sha256- && "$got" =~ ^sha256- ]] || return 1
  [[ "$(grep -cF "\"${specified}\"" "$nixfile")" == 1 ]] || return 1
  plugin="$(sed -n 's#.*"github.com/caddy-dns/cloudflare@\(v[^"]*\)".*#\1#p' "$nixfile" | head -n 1)"
  [[ -n "$plugin" ]] || return 1

  sed -i "s#\"${specified}\"#\"${got}\"#" "$nixfile"
  drv="$(nix eval --raw "${NIXOS_DIR}#nixosConfigurations.ace.config.services.caddy.package.src.drvPath")" || return 1
  out="$(nix build --no-link --print-out-paths "${drv}^out")" || return 1
  if ! nix build --rebuild --no-link "${drv}^out" >>"$logfile" 2>&1 \
    || ! grep -qx "# github.com/caddy-dns/cloudflare ${plugin}" "${out}/vendor/modules.txt"; then
    git checkout -- "$nixfile"
    return 1
  fi
  log "caddy plugin vendor hash ${specified} -> ${got} (two fetches agree, cloudflare ${plugin})"
  caddy_hash_note="Caddy plugin vendor hash ${specified} -> ${got} (refetched twice, caddy-dns/cloudflare ${plugin})."
}

caddy_hash_note=""

run() {
  cd "$NIXOS_DIR"
  branch="$(git rev-parse --abbrev-ref HEAD)"

  if [[ -n "$(git status --porcelain)" ]]; then
    write_metrics failed
    log "skipping: ${NIXOS_DIR} has uncommitted changes"
    exit 1
  fi
  git fetch -q origin "$branch" || fail "git fetch origin ${branch} failed"
  git merge -q --ff-only "origin/${branch}" || fail "local ${branch} has diverged from origin/${branch}"

  old_rev="$(locked_field rev)"
  nix flake update "$INPUT" 2>&1 | tail -n 3 >&2 || fail "nix flake update ${INPUT} failed"
  new_rev="$(locked_field rev)"
  if [[ "$old_rev" == "$new_rev" ]]; then
    log "nixpkgs already at ${old_rev}"
    write_metrics ok
    exit 0
  fi
  log "nixpkgs ${old_rev} -> ${new_rev}"

  buildlog="$(mktemp)"
  # Build first: a failed build never touches the running system.
  if ! build_toplevel "$buildlog"; then
    fix_caddy_vendor_hash "$buildlog" || fail "build failed" "$buildlog"
    build_toplevel "$buildlog" || fail "build failed after updating the Caddy plugin hash" "$buildlog"
  fi

  previous="$(readlink -f /nix/var/nix/profiles/system)"
  rollback() {
    "${previous}/bin/switch-to-configuration" switch >>"$buildlog" 2>&1 || true
    nix-env -p /nix/var/nix/profiles/system --set "$previous" >>"$buildlog" 2>&1 || true
  }
  if ! constrained nixos-rebuild switch --flake "${NIXOS_DIR}#ace" >"$buildlog" 2>&1; then
    # Units failed to start on the new generation: go back to the old one.
    rollback
    fail "switch failed; rolled back to ${previous##*/}" "$buildlog"
  fi
  # A switch once left ace without its default route (see hosts/ace/default.nix).
  if ! ip -4 route show default | grep -q . \
    || ! curl -fsS -o /dev/null --max-time 20 https://github.com; then
    rollback
    fail "no default route or internet after the switch; rolled back to ${previous##*/}" "$buildlog"
  fi
  rm -f "$buildlog"

  git add flake.lock nixos/caddy/acme-dns.nix
  git -c user.name="Preston Hager" -c user.email="preston@hagerfamily.com" -c commit.gpgsign=false \
    commit -q -m "flake: nightly nixpkgs update

nixpkgs ${old_rev} -> ${new_rev}
${caddy_hash_note}
Built and switched on ace by ace-nixpkgs-update."
  git push -q origin HEAD || { write_metrics failed; log "pushed failed; the commit is local"; exit 1; }
  write_metrics ok
  log "switched ace to nixpkgs ${new_rev}"
}

# Hold the rebuild lock for the whole run so service auto-updates cannot rebuild
# or commit in between, and so homelab-git-drift skips its check meanwhile.
exec 9>"$REBUILD_LOCK"
flock -w 3600 9 || { log "rebuild lock busy for an hour; skipping"; exit 1; }
run
