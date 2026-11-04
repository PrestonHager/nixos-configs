# Major upgrades plan (drafted 2026-10-25)

Plan for the major-version upgrades that the [2026-10-24 review](./config-review.md) left out because they are not drop-in. **Nothing here has been executed.** Backups for all of it were taken and restore-tested on 2026-10-25 (see [Backups taken](#backups-taken-for-this-plan)).

## Summary

| # | Service | Running | Target | Urgency | Window |
|---|---|---|---|---|---|
| 1 | Jellyfin | 10.11.11 | **12.4** with the MaxRink SSO plugin fork 6.1.0.0 (staging test passed 2026-11-04) | **High:** 10.11 has had no release since 2026-06-06 and is internet-facing | Next free evening, after a staging test |
| 2 | MediaWiki | 1.45.6 | **1.47 LTS** (skip 1.46) | **Deadline:** 1.45 ends December 2026 | After the 2026-11-03 Loftia launch, once 1.47.0 is out (due November 2026) |
| 3 | Postgres (Matrix, Zitadel) | 16.15 | **17** | Low: 16 is supported to 2028-11 | Any quiet hour in the next six months |
| 4 | Node (animal-search) | — | — | Not on ace any more: the app moved to Coolify on 2026-10-25 and its image is built upstream | — |
| 5 | Valkey (Pterodactyl, MediaWiki, test panel) | 8.1.10 | **9.1** | Low: 8.1 still gets fixes | With the next panel maintenance |
| — | MariaDB (all six) | 11.4 / 12.3 LTS | **Stay on LTS**; optionally consolidate 11.4 → 12.3 | None | Optional |
| — | Postgres (Coolify) | 15.19 | Follow Coolify upstream | Before 15 ends (2027-11) | When Coolify moves |
| — | Redis (Coolify) | 7.4.12 | Follow Coolify upstream | None | When Coolify moves |

Ground rules for every step:

- One service per window. Take a fresh `systemctl start restic-backups-local` immediately before; the nightly dumps are restore-tested.
- Pin the new version in nix and rebuild. Never `podman pull` floating tags.
- Write down the rollback before starting: the old pin, the backup path, and how to restore.
- The nightly nixpkgs update (04:30) and service auto-updates share the rebuild lock. Avoid starting a window around 04:30.

---

## 1. Jellyfin 10.11 → 12.4

**Status 2026-11-04:** staging test passed on a copy of production (`uptest-jellyfin-12`, `jellyfin:12.4` at `sha256:fea863d0cd9e…`, MaxRink SSO-Auth 6.1.0.0). All 39 migrations applied without errors (one migration removed 125 duplicate path entries), users, libraries and plugins came up, and `/sso/OID/start/zitadel` redirected to Zitadel using the unchanged `SSO-Auth.xml`. The nix change is on branch `test/jellyfin-12`. SSO login with a real browser was not tested in staging (no staging vhost), so check it right after cut-over.

**Why it can't be a pin bump.**

- The SSO plugin used for Zitadel login (`9p4/jellyfin-plugin-sso` 4.0.0.4) targets ABI 10.11, and its repository was archived in May 2026. It will never get a 12 build.
- Jellyfin 12.0 changed the authentication-provider API (`IAuthenticationProvider.HasPassword` removed).
- The 12.0 migration rewrites the database and cannot be rolled back without a restore.

**Replacement plugin.**

- [`MaxRink/jellyfin-plugin-sso`](https://github.com/MaxRink/jellyfin-plugin-sso) v6.x targets ABI 12.0. It reads Zitadel's object-keyed role claim (`roleClaim` accepts JSON-object-keyed roles) and publishes zips with SHA-256 files, so it can be hash-pinned like today's plugin.
- [`Buco7854/jellyfin-plugin-sso`](https://github.com/Buco7854/jellyfin-plugin-sso) v5.x is the fallback.
- Both are GPL-3.0 forks of the original, active in October 2026.

**Pre-checks (done 2026-10-25):**

- No two usernames differ only by case (3 users). 12.0 refuses to migrate if they do.
- All other installed plugins have ABI 12 releases: AniDB 13, AniList 15, Open Subtitles 25, Playback Reporting 19, Reports 20.
- No `/emby/` or `/mediabrowser/` requests in the last three days of Jellyfin logs; 12.0 removes those routes. Old third-party TV apps that use them would stop working.

**Steps:**

1. **Staging (no effect on production).**
   - Copy `/jf/config` to `/jf/staging-config` from the backup set.
   - Run `jellyfin:12.3` as a second container on `127.0.0.1:8097` with `/jf/media` mounted read-only.
   - Install the fork's zip (hash-pinned) and remove the 10.11 plugin folders.
   - Give staging a temporary LAN-only vhost (for example `jellyfin-staging.prestonhager.com` → `127.0.0.1:8097`). Add its `/sso/OID/redirect/zitadel` URL to the Zitadel Jellyfin app's redirect URIs; remove it afterwards.
   - Check: SSO login for an admin and a user, role mapping (`jellyfin_admin`, `jellyfin_user`), playback, and a full library scan (12.0 requires one).
2. **Nix changes (one commit):**
   - `jellyfinVersion = "12.4"`.
   - `ssoPluginVersion` and URL pointing at the fork, with a new hash.
   - Update `jellyfin-sso-setup` for the fork's config file name if it differs (`SSO-Auth.xml` today).
   - Remove `holdMajor` from the update registry.
3. **Cut-over.**
   - Fresh backup.
   - Stop Jellyfin and delete the non-bundled plugin folders, as the 12.0 notes require.
   - Rebuild. Watch the migration in `journalctl -u podman-jellyfin`; it runs a path check over the whole library.
   - Reinstall the ABI 12 plugins, then run a full library scan.
   - Expect downtime of 30–60 minutes, plus the scan.
4. **Verify:**
   - `/health` returns 200.
   - SSO login works.
   - A TV client on `192.168.5.5:8096` can log in.
   - The version check shows 12.4, and no held metric remains.

**Rollback:**

- Pin 10.11.11 and the old plugin back.
- Stop Jellyfin and restore `/jf/config` from `pre-major-20261025/jellyfin/config.tar.gz`.
- Copy `jellyfin.db` and `playback_reporting.db` from the same folder into `/jf/config/data/`.
- Rebuild.

---

## 2. MediaWiki 1.45 → 1.47 LTS

**Why 1.47, not 1.46.**

| Release | Supported until |
|---|---|
| 1.45 | December 2026 |
| 1.46 | July 2027 |
| 1.47 LTS (due November 2026) | November 2029 |

MediaWiki supports upgrading straight from 1.39 or newer, so 1.45 → 1.47 is one step. That avoids a second upgrade six months after the Loftia launch.

**Compatibility (checked against 1.46; recheck for 1.47):**

- Every non-bundled extension has a `REL1_46` branch: Wikibase, CreateUserPage, CSS, Interwiki, NewUserMessage, OAuth, StopForumSpam, UserMerge. Use the `REL1_47` branches when they exist.
- Citizen declares `MediaWiki >= 1.43`. The deployed copy is 3.0.0 and upstream is 3.24.0, so update it in the same window. The custom Loftia skin declares `>= 1.43`; test it.
- None of the settings that 1.46 removes or changes are set in `LocalSettings.php`, `LaunchSettings.php` or `PrelaunchSettings.php` (`$wgSVGConverter`, `$wgLogos['1.5x']`, `$wgAPIRequestLog`, `$wgBlockTargetMigrationStage`, `$wgEnableSpecialMute`, `$wgEnableUserEmailMuteList`, `$wgThumbLimits`).

**Steps (the method used for 1.45.6 on 2026-10-24):**

1. Download the signed 1.47.x tarball and verify it with gpg.
2. Stage `/mw/mediawiki-1.47.x` from the tarball, plus:
   - the three settings files;
   - the eight non-bundled extensions at `REL1_47`;
   - the Citizen (latest) and Loftia skins;
   - `resources/assets/{assets,loftia.png,loftia-logo-colored.png}`.
3. Smoke-test against the live database from a throwaway container in the `mediawiki` pod.
   - The `upgrade.loftiawiki.org` staging pod cannot reach the database, because it lives at `127.0.0.1` inside the production pod.
   - Use `podman run --pod mediawiki` with the phpredis install from `mediawiki-docker.nix`, then `php -S 127.0.0.1:8899`.
   - Check Main_Page, Special:Version, Special:UserLogin, `load.php` (no `/* exception */`) and `api.php`.
4. Make the wiki read-only (`$wgReadOnly`). Stop `podman-mediawiki`. Move `html` → `html.bak-1.45.6` and the staged tree → `html`.
5. Set `version` and `dockerImage` to 1.47 (`nix-prefetch-docker`). Rebuild. Run `php maintenance/run.php update --quick` in the container. Lift read-only.

**Rollback:**

- Move `html.bak-1.45.6` back and pin 1.45.6.
- Restore the `mediawiki` database from that window's dump: schema changes from `update.php` are not reversible.

---

## 3. Postgres 16 → 17 (Matrix, Zitadel)

**Why 17, not 18.** Synapse's CI tests Postgres 14 and 17. Zitadel documents 14–18. 17 is the newest version both test, and it is supported to 2029-11. Nextcloud is not involved (it uses MariaDB).

**Method: dump and restore.** On-disk data is small (Zitadel 106 MB, Matrix 72 MB; dumps 8 MB and 0.3 MB).

**Rehearsed 2026-11-04** on `postgres:17.11-alpine` (`sha256:266d3c25…`), in containers on an `--internal` podman network (no egress):

- `pg_dumpall` took under 1 s per database; `psql` restore 2.8 s (Zitadel) and 1.7 s (Matrix). The only errors were `role "postgres"/"synapse" already exists` and `database "zitadel"/"synapse" already exists`, both from the entrypoint creating `POSTGRES_USER`/`POSTGRES_DB`. Harmless: the pre-created database has the same owner and locale.
- Row counts of every table matched production exactly (Zitadel 145 tables, Matrix 176). `\l` matched: Zitadel `en_US.utf8`, Matrix `C`/`C` (from `POSTGRES_INITDB_ARGS`).
- Zitadel v4.20.1 with `start-from-init` reused the existing instance: the same instance id, 3 users, "user already exists, skipping creation", and only the usual repeatable-migration events added. `/debug/healthz` and `/debug/ready` returned 200, and OIDC discovery for `zitadel.prestonhager.com` worked.
- Synapse v1.164.2 applied the v95 schema delta without error. `/_matrix/client/versions` returned 200, users, rooms and events matched production, and no background updates were left.

**Do not rebuild onto an empty data directory** (this was the old plan's step 4). All four app containers are `autoStart` and the rebuild starts them. On an empty database, Zitadel's `start-from-init` would create a new first instance and Synapse a new schema, and the dump would then conflict with them. Restore into the new directory with a one-off container first, then rebuild.

**Steps (both databases in one window, about 10 minutes of downtime; do not start near 04:30):**

1. **Backup.** Run `systemctl start restic-backups-local` and wait for it. `mkdir -p /stor/backup/pre-pg17`.
2. **Stop the apps**, Matrix first, since its logins go through Zitadel: `systemctl stop podman-matrix-synapse podman-zitadel-login podman-zitadel`.
3. **Dump** from the still-running 16 containers:
   ```sh
   podman exec zitadel-db sh -c 'pg_dumpall -U "$POSTGRES_USER"' > /stor/backup/pre-pg17/zitadel.sql
   podman exec matrix-db  sh -c 'pg_dumpall -U "$POSTGRES_USER"' > /stor/backup/pre-pg17/matrix.sql
   ```
   Check that both end with `PostgreSQL database cluster dump complete`.
4. **Stop the DBs and move the data aside:**
   ```sh
   systemctl stop podman-zitadel-db podman-matrix-db
   mv /zitadel/postgres /zitadel/postgres-pg16
   mv /matrix/postgres  /matrix/postgres-pg16
   install -d -m 0700 -o postgres -g postgres /zitadel/postgres /matrix/postgres   # uid/gid 70, as in the modules
   ```
5. **Restore into 17 with one-off containers.** Use `--network none` and the same sops env files. Matrix also needs the initdb args for `C` collation:
   ```sh
   PG17=docker.io/library/postgres@sha256:266d3c257594e195b309ae9d1805e54c788f1d7b375f56bf6c367aac6c917e7b
   podman run -d --name pg17-restore-zitadel --network none --env-file /run/secrets/zitadel-db-env \
     -v /zitadel/postgres:/var/lib/postgresql/data $PG17
   podman run -d --name pg17-restore-matrix --network none --env-file /run/secrets/matrix-db-env \
     -e POSTGRES_INITDB_ARGS="--encoding=UTF-8 --lc-collate=C --lc-ctype=C" \
     -v /matrix/postgres:/var/lib/postgresql/data $PG17
   # wait for the second "database system is ready to accept connections" (after the init restart)
   podman exec -i pg17-restore-zitadel sh -c 'psql -U "$POSTGRES_USER" -d postgres' < /stor/backup/pre-pg17/zitadel.sql >/dev/null 2> /stor/backup/pre-pg17/zitadel.err
   podman exec -i pg17-restore-matrix  sh -c 'psql -U "$POSTGRES_USER" -d postgres' < /stor/backup/pre-pg17/matrix.sql  >/dev/null 2> /stor/backup/pre-pg17/matrix.err
   cat /stor/backup/pre-pg17/*.err   # expect only the role/database "already exists" lines
   podman exec pg17-restore-matrix psql -U synapse -l   # synapse must be C / C
   podman stop pg17-restore-zitadel pg17-restore-matrix && podman rm pg17-restore-zitadel pg17-restore-matrix
   ```
6. **Rebuild** with the 17.11 pin in `zitadel.nix` and `matrix.nix`. The `*-postgres-datadir` units re-chown the directories to 70, and the DBs start on the restored data. The apps start after them: `dependsOn` orders Zitadel after its DB, and Synapse after its DB and Zitadel. If an app is still inactive afterwards, run `systemctl start podman-zitadel podman-zitadel-login podman-matrix-synapse`.
7. **Verify:**
   - `podman exec zitadel-db postgres --version` and the same for `matrix-db` show 17.11.
   - `journalctl -u podman-zitadel` shows "user already exists, skipping creation" and `setup completed`, with no new instance.
   - `curl -s http://127.0.0.1:9080/debug/ready` returns `ok`, and a browser login through Zitadel works.
   - `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:6167/_matrix/client/versions` returns 200. Log in to Matrix through SSO and send a message.
   - The version-check dashboard shows both on 17.11. It reads `PG_VERSION` from the running image, so the registry needs no change.
8. After a week without problems, delete `/zitadel/postgres-pg16` and `/matrix/postgres-pg16`. Keep `/stor/backup/pre-pg17/`.

**Rollback** (anything written after the dump is lost):

- Stop the apps and DBs, as in steps 2 and 4.
- `mv /zitadel/postgres /zitadel/postgres-pg17-failed && mv /zitadel/postgres-pg16 /zitadel/postgres`, and the same for `/matrix`.
- Revert the pin commit (16.15, `sha256:f4610795…`) and rebuild.
- If Synapse 1.164.2 ran before the dump, the `-pg16` data is already at schema 95, so keep that Synapse. Otherwise the old directory is still at 94, and either Synapse version works.

**Coolify's Postgres 15** stays on what Coolify ships (`postgres:15-alpine` in its v4.6.0 compose). 15 is supported to 2027-11; revisit when Coolify moves, or by mid-2027.

---

## 4. Node 22 → 26 LTS (animal-search)

**Superseded (2026-10-25):** the Podman deployment on ace was removed; Animal Search now runs on Coolify (mars) from an image its own repository builds (`node:22-slim` in its Dockerfile). The Node upgrade belongs in that repository. The notes below are kept for reference.

- Node 26 becomes LTS on 2026-10-28 and is supported to 2029-04. 22 ends 2027-04-30.
- The release's direct requirements allow it: Astro needs Node `>=22.12.0` and sharp `>=20.9.0`.
- The image must stay glibc (`node:26-slim`, not alpine), because sharp's binaries are glibc-only.

**Steps:**

1. **CI first.** The group-5 workflow must build releases with Node 26: `setup-node`, or the runner image. The AL2023 runner image bakes in Node 20, and `nodeRuntimes` allows only `node20`/`node24`.
2. Deploy a Node-26-built release to **staging** and switch staging's image to `node:26-slim` (pin by digest). Check the site and API.
3. Production: same image change, then a normal deploy through the inbox contract.

**Rollback:** pin `node:22.23.4-slim` back. Releases are kept under `releases/`, and the current one is archived in the backup set.

---

## 5. Valkey 8.1 → 9.1

- Valkey 9's behaviour changes are small: auth is checked before command existence, and MULTI error messages include the command's full name.
- The data is cache, sessions and Pterodactyl's queue.
- The 2026-10-25 RDB copies load on 9.1.2 with identical key counts (panel 1158, test panel 1119, MediaWiki 2245).
- **Rehearsed on 2026-11-04 with 9.1.3-alpine** (`sha256:bf09d58e…fae0b`), on copies of that day's live `dump.rdb` and the production command lines (`requirepass` file, `--bind 127.0.0.1 --save 59 1 --loglevel warning`; the test panel has no password):
  - No config warnings at startup. Every key loads, and a checksum over every key, type and value matches 8.1.10 on all three (panel 3576, test panel 3574, MediaWiki 879 keys at that moment).
  - phpredis 6.3.0 from `hydrodactyl-runtime:v6.4.2` ran the same script against 8.1.10 and 9.1.3: AUTH, Laravel session and cache calls, a lock release in Lua, MULTI/EXEC, pipelines, WATCH/CAS, the Laravel queue Lua scripts (push, pop through EVALSHA, migrate, size), BLPOP/BRPOP, and MediaWiki-style serialized objects. The output is identical, except that an unknown command sent before AUTH now returns `NOAUTH` instead of `unknown command`. No app sends commands before AUTH.
  - The panel image's `redis-cli` 8.10.2 health checks (PING with `REDISCLI_AUTH`, FLUSHALL on the test panel) work.
- 9.x writes RDB format 80. **8.1.10 refuses to start on it** ("Can't handle RDB format version 80"), so a rollback must move the file aside. Sessions are lost and users sign in again.

**Steps:**

1. Panel: `php artisan down`, then let the queue drain (`php artisan queue:work --stop-when-empty`, or wait for the worker).
2. Pin `valkey/valkey:9.1.3-alpine` (`sha256:bf09d58e96d6b4524a15396b65b242bbe18beebbcc15a04d8ee75ddac62fae0b`) in `pterodactyl.nix`, `pterodactyl-test.nix` and `mediawiki.nix`. Rebuild. Restart each app container after its Valkey so it rejoins the pod network. Then `php artisan up`.
3. Check the panel (login, server list, a console), the test panel, and a wiki page edit.

**Rollback:** pin 8.1.x again. Stop the Valkey, move the 9.x `dump.rdb` aside (or restore the archived 8.1 one from `kv/`), then rebuild. Otherwise 8.x will not start.

---

## MariaDB: stay on LTS

- **13.0 is a rolling release, and Nextcloud does not support it.**
  - MariaDB 13.0 has no fixed support period. The LTS series are 11.4 (to 2029-05), 11.8 (to 2030-02) and 12.3 (to 2029-06).
  - Nextcloud 35 supports MariaDB 10.11, 11.4, 11.8 and 12.3 only.
  - Nothing should move to 13.0.
- **Version check.** `ace-version-check` compares MariaDB against the newest tag, so every instance shows "major behind" for 13.0. Change the MariaDB rows to compare against the newest **LTS** series, so the dashboard shows real lag.
- **Optional consolidation.** Moving the 11.4 instances (MediaWiki, test panel) to 12.3 would mean one MariaDB image. Restoring their dumps into 12.3.3 was rehearsed on 2026-10-25 with no errors, and table counts matched. In place: bump the pin; `MARIADB_AUTO_UPGRADE=1` runs `mariadb-upgrade`. Not needed for support reasons.

## Redis (Coolify): follow upstream

Coolify v4.6.0 ships `redis:7-alpine`. The archived RDB loads on Redis 8.10.2 (215 keys), so moving later is easy, but keep Coolify's pin until Coolify moves.

---

## Backups taken for this plan

`/stor/backup/pre-major-20261025/` (477 MB, `SHA256SUMS` verified), also in restic as a snapshot tagged `pre-major`:

| Path | Contents | Verified |
|---|---|---|
| `db/` | Every database dump from 2026-10-25, plus `vaultwarden.sqlite3` | MariaDB: a plain restore into the same version has 0 errors, and table counts match the live datadirs (Nextcloud 249, panel 52, test panel 58, MediaWiki 98). Also clean into 12.3.3. Postgres: clean into 17 (Matrix, Zitadel) and 15 (Coolify) |
| `db-legacy-format/` | The same dumps in the old `--all-databases` format | Restore needs the two fixes below |
| `jellyfin/` | Online `.backup` copies of `jellyfin.db` and `playback_reporting.db`, `config.tar.gz` (plugins, settings, metadata), and the 10.11.11 `jellyfin.nix` | `integrity_check` ok |
| `kv/` | `dump.rdb` of the Pterodactyl, test-panel and MediaWiki Valkey and of Coolify's Redis | Load on their current versions, and on Valkey 9.1 / Redis 8.10 |
| `mediawiki/` | `html-1.45.6.tar.gz` (code and settings) and `images.tar.gz` | — |
| `animal-search/` | The live production release | — |
| `MANIFEST.txt` | Git revision, running images and versions at the time | — |

The 1.45.3 MediaWiki tree from the 2026-10-24 upgrade is also at `/mw/html.bak-1.45.3` and `/stor/backup/mediawiki-html-1.45.3-20261024.tar.gz`.

**Everything is on ace's own disks.** There is still no off-site copy (see the review). Copy `pre-major-20261025/` somewhere else before step 1.

### Backup fixes found by the restore test

The test showed the nightly MariaDB dumps were not restorable as made:

- The MediaWiki and test-panel dumps aborted at line 23. `--all-databases` dumped the server-internal `#mysql50##binlog_cache_files` datadir entry as a database, and its `CREATE DATABASE` fails.
- Dumps restored into another MariaDB version failed on the version-specific `mysql.proc`.

Since 2026-10-25, `nixos/backup.nix` dumps the application databases plus accounts (`--system=users --insert-ignore`). It skips accounts where `--system=users` fails (the animal-search instances, whose accounts come from the container env anyway). All six dumps now restore with zero errors. See [Backups](../ace/backups.md).
