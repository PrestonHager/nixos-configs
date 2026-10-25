# Backups on ace

Implementation: `nixos/backup.nix`. Password: `restic-password` in `nixos-secrets/secrets/hosts/ace/backup.yaml`.

| | |
|---|---|
| Schedule | nightly 03:30 (±15 min), `restic-backups-local.timer` |
| Repository | `/stor/backup/restic` (restic, on the second disk `sda`) |
| Retention | 7 daily, 4 weekly, 6 monthly |
| Alert | *Ace backup stale*: no successful run for 36 h |
| Offsite | **not yet**: a second repository is needed to survive losing the machine |

## What is backed up

Before each snapshot, `homelab-db-dumps` writes to `/stor/backup/dumps/`:

| Dump | How |
|---|---|
| `mediawiki-db`, `pterodactyl-db`, `pterodactyl-test-db` | `mariadb-dump` as root of the application databases plus accounts (`--system=users --insert-ignore`; accounts are skipped on any instance where that option fails). Not `--all-databases`: see [Restore tests](#restore-tests) |
| `nextcloud-db` | `mariadb-dump --databases nextcloud` with the credentials from Nextcloud's `config.php` (the env passwords no longer match) |
| `coolify-db`, `matrix-db`, `zitadel-db` | `pg_dumpall` |
| `vaultwarden.sqlite3` | SQLite online `.backup` (consistent while running) |

A failed dump fails the whole run, so stale dumps are never snapshotted silently.

Files: the dumps, `/vw-data` (minus the live DB and icon cache), `/stor/nextcloud/data`, `/mw/images`, `/mw/html/LocalSettings.php`, `/jf/config`, `/stor/coolify/app`, `/zitadel/login-client`, `/pterodactyl/secrets`, `/stor/technitium`. The NixOS configuration itself lives in git.

## Using the repository

```bash
export RESTIC_REPOSITORY=/stor/backup/restic RESTIC_PASSWORD_FILE=/run/secrets/restic-password
restic snapshots
restic ls latest /stor/backup/dumps
restic restore latest --target /tmp/restore --include /stor/backup/dumps/matrix-db.sql.gz
systemctl start restic-backups-local     # run a backup now
journalctl -u restic-backups-local -e    # last run's log
```

## Restoring a database

Stop the app first, then load the dump into the database container:

```bash
# MariaDB (all-databases dump)
systemctl stop podman-pterodactyl
zcat pterodactyl-db.sql.gz | podman exec -i pterodactyl-db sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"'

# Postgres (pg_dumpall)
systemctl stop podman-matrix-synapse
zcat matrix-db.sql.gz | podman exec -i matrix-db sh -c 'psql -U "$POSTGRES_USER" -d postgres'

# Vaultwarden
systemctl stop podman-vaultwarden
cp vaultwarden.sqlite3 /vw-data/db.sqlite3 && rm -f /vw-data/db.sqlite3-wal /vw-data/db.sqlite3-shm
```

Restart the app afterwards. For containers in a pod (Pterodactyl, MediaWiki), restart the app container after its database so it rejoins the pod network.

## Restore tests

On 2026-10-25 every dump was restored into a throwaway, network-less container, with table counts compared against the live datadirs. That test found that the old `--all-databases` MariaDB dumps could not be restored as made:

- The MediaWiki and test-panel dumps aborted at line 23 on `CREATE DATABASE` for the server-internal `#mysql50##binlog_cache_files` datadir entry.
- Restores into another MariaDB version failed on `mysql.proc`.

With the current format, all six MariaDB dumps restore with zero errors on their own version and on 12.3.3, and every table count matches. The Postgres dumps restore cleanly on their own versions and on 17.

Repeat the test after changing dump options: `scripts/backup-restore-test-mariadb.sh` (optionally with a MariaDB version, to rehearse a series move) exits non-zero on any error or table-count mismatch.

```bash
# plain restore of one dump into a scratch MariaDB, no network
podman run -d --rm --name rt --network none -e MARIADB_ROOT_PASSWORD=rt docker.io/library/mariadb:11.4.13
zcat /stor/backup/dumps/mediawiki-db.sql.gz | podman exec -i rt mariadb -uroot -prt   # must print no ERROR
podman rm -f rt
```

## Known issues

- `nextcloud-db`'s `MARIADB_ROOT_PASSWORD` and `MARIADB_PASSWORD` (from nix-secrets) do not match the live database. Fix by setting the database's passwords to the sops values, or by updating sops to the live values, then drop the `config.php` workaround in `backup.nix`.
- MariaDB containers run with `MARIADB_AUTO_UPGRADE=1` so system tables are upgraded after a major bump (the 11.7 → 12.3 bump had left `mysql.proc` stale, which broke routine dumps).

