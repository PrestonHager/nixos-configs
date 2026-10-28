#!/usr/bin/env bash
# Restore-test the MariaDB dumps on ace: a plain restore (no --force) of each dump
# into a throwaway, network-less container, then compare table counts with the
# live datadir. Run as root on ace. Nothing touches the live databases.
#
#   scripts/backup-restore-test-mariadb.sh [DUMP_DIR] [MARIADB_VERSION]
#
# DUMP_DIR defaults to /stor/backup/dumps. MARIADB_VERSION overrides each
# instance's own version, e.g. 12.3.3 to rehearse a move to that series.
set -uo pipefail

dumps="${1:-/stor/backup/dumps}"
declare -A src=(
  [nextcloud-db]=/stor/nextcloud/mysql
  [pterodactyl-db]=/pterodactyl/data
  [pterodactyl-test-db]=/pterodactyl-test/data
  [mediawiki-db]=/mw/data
)
declare -A ver=(
  [nextcloud-db]=12.3.3 [pterodactyl-db]=12.3.3
  [pterodactyl-test-db]=11.4.13 [mediawiki-db]=11.4.13
)
if [[ -n "${2:-}" ]]; then
  for k in "${!ver[@]}"; do ver[$k]="$2"; done
fi

# "db=tables ..." for the application databases in a datadir
count_tables() {
  find "$1" -mindepth 2 -maxdepth 2 \( -name '*.frm' -o -name db.opt \) 2>/dev/null \
    | awk -F/ '{print $(NF-1), ($NF == "db.opt") ? 0 : 1}' \
    | grep -vE '^(mysql|performance_schema|sys) ' \
    | awk '{a[$1] += $2} END {for (k in a) printf "%s=%s ", k, a[k]}'
}

failed=0
for name in $(printf '%s\n' "${!ver[@]}" | sort); do
  v="${ver[$name]}"
  ctr="restore-test-$name"
  datadir="$(mktemp -d /tmp/restore-test-mariadb.XXXXXX)"
  podman rm -f "$ctr" >/dev/null 2>&1
  podman run -d --rm --name "$ctr" --network none -v "$datadir":/var/lib/mysql:Z \
    -e MARIADB_ROOT_PASSWORD=rt "docker.io/library/mariadb:$v" >/dev/null
  timeout 120 bash -c "until podman exec $ctr mariadb -uroot -prt -e 'select 1' >/dev/null 2>&1; do sleep 2; done"

  err="$(zcat "$dumps/$name.sql.gz" | podman exec -i "$ctr" mariadb -uroot -prt 2>&1 | grep -m1 ERROR | cut -c1-100)"
  podman exec "$ctr" sh -c 'kill -TERM 1' >/dev/null 2>&1
  podman wait "$ctr" >/dev/null 2>&1

  live="$(count_tables "${src[$name]}")"
  restored="$(count_tables "$datadir")"
  result=MATCH
  if [[ -n "$err" || "$live" != "$restored" ]]; then
    result=FAIL
    failed=1
  fi
  printf '%-28s %-8s %-5s live=[%s] restored=[%s]\n' "$name" "$v" "$result" "$live" "$restored"
  [[ -n "$err" ]] && printf '    %s\n' "$err"
  rm -rf -- "${datadir:?}"
done
exit "$failed"
