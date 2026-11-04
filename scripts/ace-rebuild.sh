#!/usr/bin/env bash
# Rebuild ace the safe way, for people and agents alike:
#   - capped jobs and cores (docs/ace-rebuild-freeze-rca.md: unconstrained
#     builds have frozen ace);
#   - serialized with the same lock the nightly nixpkgs and service updates
#     hold, so two rebuilds never overlap.
#
#   bash scripts/ace-rebuild.sh            switch
#   bash scripts/ace-rebuild.sh test       any nixos-rebuild action
#
# It builds /etc/nixos as it is on disk, including other people's
# uncommitted changes: check `git -C /etc/nixos status` first.
set -euo pipefail
action="${1:-switch}"
lock=/run/ace-service-update-rebuild.lock

echo "waiting for the ace rebuild lock ($lock)..." >&2
exec 9>"$lock"
flock -w 3600 9 || { echo "rebuild lock busy for an hour; giving up" >&2; exit 1; }

NIX_BUILD_CORES=2 nixos-rebuild "$action" --flake /etc/nixos#ace \
  -j 2 --option max-jobs 2 --option cores 2
