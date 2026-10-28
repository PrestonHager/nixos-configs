#!/usr/bin/env bash
# Lay the homelab addons into a Hydrodactyl source tree.
#
#   install-addons.sh <panel-dir> <dnsrecords-src> <portforward-src>
#
# Used by nixos/containers/hydrodactyl-panel.nix (and by hand for local
# builds). The DNS and port-forward PHP comes straight from the former
# Blueprint extension repos (flake inputs) at the same namespace/path
# Blueprint used, so their tables and settings carry over untouched.
set -euo pipefail

panel=$1
dns=$2
portforward=$3
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

cd "$panel"
patch -p1 --forward --no-backup-if-mismatch < "$here/patches/0001-homelab-addon-hooks.patch"

cp -r "$here/app/Addons" app/Addons
cp "$here/config/homelab.php" config/homelab.php
cp -r "$here/resources/scripts/addons" resources/scripts/addons
cp "$here"/database/migrations/*.php database/migrations/

mkdir -p app/BlueprintFramework/Extensions
cp -r "$dns/app" app/BlueprintFramework/Extensions/dnsrecords
cp -r "$portforward/app" app/BlueprintFramework/Extensions/portforward
cp "$dns"/database/migrations/*.php database/migrations/
cp "$portforward"/database/migrations/*.php database/migrations/

chmod -R u+w app/Addons app/BlueprintFramework config/homelab.php resources/scripts/addons database/migrations
