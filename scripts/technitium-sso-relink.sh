#!/usr/bin/env bash
# One-off for the Zitadel -> Keycloak move (docs/dns-ace.md): relink the
# Technitium SSO account `prestonh` from its Zitadel sub to its Keycloak user
# id. Technitium matches SSO accounts by sub only and has no API to change it.
#
#   bash scripts/technitium-sso-relink.sh <keycloak-user-id>
#   bash scripts/technitium-sso-relink.sh <id> --dry-run <copy-of-auth.config>
#
# Get the id from the admin API (homelab-config token):
#   /admin/realms/homelab/users?username=prestonh&exact=true -> .[0].id
# Live run: backs up auth.config (+ sha256), stops Technitium (LAN DNS is down
# for the restart), rewrites the one record, starts it, and waits up to 60 s
# for 192.168.5.5 to answer; otherwise restores the backup and starts again.
set -euo pipefail
NEW=$1
OLD=376197075085302069 # prestonh's Zitadel sub, seen in auth.config
CFG=/stor/technitium/auth.config
DIG=$(command -v dig || echo "$(nix build --no-link --print-out-paths nixpkgs#bind.dnsutils)/bin/dig")

[[ "$NEW" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { echo "not a Keycloak user id: $NEW" >&2; exit 1; }

# Exactly one `\x08prestonh <type byte> \x12 <old sub>` record, and the old
# sub nowhere else. Prints the match count.
count() {
  OLD=$OLD perl -0777 -ne 'my $n = () = /\x08prestonh.\x12\Q$ENV{OLD}\E/gs; my $m = () = /\Q$ENV{OLD}\E/g; print "$n $m\n"' "$1"
}
edit() { # edit <in> <out>
  OLD=$OLD NEW=$NEW perl -0777 -pe 's/(\x08prestonh.)\x12\Q$ENV{OLD}\E/$1 . chr(length $ENV{NEW}) . $ENV{NEW}/se' "$1" > "$2"
}

if [ "${2:-}" = --dry-run ]; then
  [ "$(count "$3")" = "1 1" ] || { echo "dry-run: expected one occurrence, got $(count "$3")" >&2; exit 1; }
  edit "$3" "$3.relinked"
  NEW=$NEW perl -0777 -ne 'exit(/\x08prestonh.\x24\Q$ENV{NEW}\E/s ? 0 : 1)' "$3.relinked"
  echo "dry-run ok: $(stat -c %s "$3") -> $(stat -c %s "$3.relinked") bytes"
  exit 0
fi

ts=$(date +%Y%m%d-%H%M%S)
bak=/stor/technitium/auth.config.pre-keycloak-$ts
cp -a "$CFG" "$bak"; sha256sum "$bak" > "$bak.sha256"
[ "$(count "$CFG")" = "1 1" ] || { echo "abort: expected one occurrence, got $(count "$CFG")" >&2; exit 1; }

dns_up() {
  for _ in $(seq 1 60); do
    [ "$("$DIG" @192.168.5.5 grafana.prestonhager.com +short +time=1 +tries=1 2>/dev/null)" = 192.168.5.5 ] && return 0
    sleep 1
  done
  return 1
}

echo "stopping technitium"
systemctl stop podman-technitium
# Technitium saves auth.config on shutdown; check again on the stopped copy.
cp -a "$CFG" "$bak.at-stop"
if [ "$(count "$CFG")" != "1 1" ]; then
  echo "abort: occurrence changed at stop; starting unchanged" >&2
  systemctl start podman-technitium; dns_up; exit 1
fi
edit "$CFG" "$CFG.new"
chmod --reference="$CFG" "$CFG.new"; mv -f "$CFG.new" "$CFG"
systemctl start podman-technitium
if dns_up; then
  echo "DNS answering; relinked prestonh to $NEW (backup $bak)"
else
  echo "DNS not answering in 60 s: restoring $bak.at-stop" >&2
  systemctl stop podman-technitium
  cp -a "$bak.at-stop" "$CFG"
  systemctl start podman-technitium
  dns_up && echo "restored, DNS answering" >&2
  exit 1
fi
