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
| `mediawiki-db`, `pterodactyl-db`, `pterodactyl-test-db`, `animal-search-{production,staging}-db` | `mariadb-dump --all-databases` as root |
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

## Known issues

- `nextcloud-db`'s `MARIADB_ROOT_PASSWORD` and `MARIADB_PASSWORD` (from nix-secrets) do not match the live database. Fix by setting the database's passwords to the sops values, or by updating sops to the live values, then drop the `config.php` workaround in `backup.nix`.
- MariaDB containers run with `MARIADB_AUTO_UPGRADE=1` so system tables are upgraded after a major bump (the 11.7 → 12.3 bump had left `mysql.proc` stale, which broke routine dumps).

