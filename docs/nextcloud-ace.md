# Nextcloud on ace

Implementation: `nixos/containers/nextcloud.nix`, Caddy `nixos/caddy/nextcloud.nix`, secrets `nixos-secrets/secrets/containers/nextcloud.yaml` (`nextcloud-environment`, `nextcloud-db-environment`, `nextcloud-oidc-env`, `nextcloud-whiteboard-env`).

## Service

| Field | Value |
|-------|-------|
| URL | https://cloud.prestonhager.com |
| Version | Nextcloud **35.0.2** (official container image, pinned as `nextcloudImage` in `nextcloud.nix`) |
| Auth | Keycloak OIDC (realm `homelab`, client `nextcloud`) via `user_oidc` app; local login remains available (`?direct=1`) |
| Break-glass local admin | `nextcloud-admin` (password in sops `nextcloud-environment`) |
| Whiteboard WebSocket | `ghcr.io/nextcloud-releases/whiteboard` **v2.1.2** sidecar (pinned by digest) in the Nextcloud pod; public URL `https://cloud.prestonhager.com/whiteboard` (Caddy proxies to `127.0.0.1:3002`) |

## Major version upgrade (34 → 35, 2026-10-24)

Bumped `nextcloudImage` to `35.0.2`, the whiteboard collaboration server to v2.1.2 (Nextcloud 35 needs whiteboard app 2.x, and the 2.x app needs a 2.x server) and ClamAV to 1.5.4, in one commit, after a fresh restic snapshot. The container entrypoint runs the core upgrade on start.

Before bumping, check that every enabled app has a release for the new major:

```bash
curl -s https://apps.nextcloud.com/api/v1/platform/35.0.2/apps.json -o /tmp/nc.json
podman exec -u www-data nextcloud php occ app:list --shipped=false
# for each enabled app: jq '[.[]|select(.id=="APP")|.releases[].version][0]' /tmp/nc.json
```

`digitalsignage` has no Nextcloud 35 release (its `max-version` is 34), so the upgrade disabled it. Re-enable it once a compatible release is published.

**App store updates unpacked into a nested folder.** During this upgrade the updater extracted `integration_youtube`, `cospend`, `files_antivirus` and `user_saml` as `custom_apps/APP/APP/`, on top of the old files. The leftover `appinfo/` was missing, so every `occ` call failed (`Cannot redeclare class …` or `Could not resolve …\ConfigLexicon`), Nextcloud stayed in maintenance mode, and `nextcloud-occ-maintain.service` failed. Find and fix such apps with:

```bash
podman exec nextcloud sh -c 'cd /var/www/html/custom_apps; for d in */; do d=${d%/}; [ -f "$d/appinfo/info.xml" ] || echo "broken: $d"; done'
# for each broken APP whose nested copy is complete:
podman exec -u www-data nextcloud sh -c 'cd /var/www/html/custom_apps && mv APP APP.broken && mv APP.broken/APP APP && mv APP.broken /tmp/'
podman exec -u www-data nextcloud php occ upgrade --no-interaction
systemctl restart nextcloud-occ-maintain.service
```

After the upgrade, `occ` reports schema differences that are not from this upgrade: leftover `memories_*` indexes (the Memories app is disabled), `oc_files_antivirus.fileid` type, and `oc_share_external.id` autoincrement.

## Major version upgrade (31 → 34)

Nextcloud requires stepping through each major release (32, 33, 34). Image pin: `docker.io/library/nextcloud:34.0.1` in `nixos/containers/nextcloud.nix`. Sidecars unchanged: MariaDB 11.4, Redis, ClamAV stable, notify_push (same Nextcloud image).

Before upgrading, back up `/stor/nextcloud/data` and `/stor/nextcloud/mysql`.

The stepping script `scripts/ace-nextcloud-major-upgrade.sh` was removed in commit `572c200`. To run it again on ace, recover it first:

```bash
cd /etc/nixos
git show 572c200^:scripts/ace-nextcloud-major-upgrade.sh > /tmp/ace-nextcloud-major-upgrade.sh
ACE_NC_UPGRADE_CONFIRM=yes bash /tmp/ace-nextcloud-major-upgrade.sh
```

If Docker Hub has not published `34.0.1` yet, the script falls back to `34.0.0` (Docker tags use major versions like `32`, `33`, not patch tags like `32.0.12`). After the `34.0.1` image is published, pull and rebuild:

```bash
cd /etc/nixos
git pull
nixos-rebuild switch --flake .#ace
podman exec -u www-data nextcloud php /var/www/html/occ upgrade --no-interaction
```

```bash
podman exec -u www-data nextcloud php /var/www/html/occ status
curl -sS https://cloud.prestonhager.com/status.php
systemctl is-active podman-nextcloud podman-nextcloud-db podman-nextcloud-redis
```

## SSO (Keycloak)

Nextcloud logs in through Keycloak (`https://keycloak.prestonhager.com`, realm `homelab`). Everything is declared in `nixos/containers/nextcloud.nix`:

| Piece | Where |
|-------|-------|
| Keycloak client `nextcloud` (redirect `https://cloud.prestonhager.com/apps/user_oidc/code`, secret `KEYCLOAK_CLIENT_SECRET` from `nextcloud-oidc-env`) | `homelab.keycloak.clients.nextcloud`, applied by `keycloak-realm-sync` |
| Client role `nextcloud` / `admin`, granted to group `nextcloud_admin` | `homelab.keycloak.realmSettings.roles` + `groupSettings.nextcloud_admin` |
| `user_oidc` provider `keycloak` | `nextcloud-oidc-config.service` |

### Account identity

`user_oidc` provider `keycloak` maps the uid from `preferred_username` with **unique-uid off** (no provider prefix, no hash). A Keycloak user therefore lands on the Nextcloud account with the same name: Keycloak `prestonh` → Nextcloud `prestonh`, `dylanh` → `dylanh`. The Zitadel provider used the same mapping, so the switch kept every account and its files.

`oc_user_oidc` links a uid to `(provider_id, sub)`. Rows written before that link existed (prestonh, dylanh) have it NULL; `user_oidc` backfills it on the next login, under whichever provider is used. A user already linked to an old provider is still found by uid, so deleting the old `zitadel` provider (which `nextcloud-oidc-config` does) leaves accounts alone.

Never rename a Keycloak username that has a Nextcloud account, and never set `--unique-uid=1` or `provider-based-id`: either gives the user a new, empty account. Keycloak usernames must not collide with local accounts (`nextcloud-admin`).

### Admin

Nextcloud server admin = membership in the Nextcloud `admin` group. The Keycloak client `nextcloud` has `groupsClaim = false` and a client-role mapper instead, so its `groups` claim holds only the client's roles: `["admin"]` for members of the Keycloak group **`nextcloud_admin`**, otherwise empty. The provider provisions groups with whitelist `/^admin$/`, so each SSO login adds or removes exactly the `admin` group and leaves every other Nextcloud group alone.

To make someone a Nextcloud admin: Keycloak admin console → realm `homelab` → Users → user → Groups → join `nextcloud_admin`, then the user signs out of Nextcloud and back in. Removing them from the group drops admin at their next login.

The local break-glass account `nextcloud-admin` (Database backend, email `admin@prestonhager.com`) never logs in through SSO, so SSO never changes its `admin` membership.

### Tests

```bash
bash tests/sso/run.sh nextcloud
```

`tests/sso/nextcloud.test.sh` logs in as `sso-regression` (member of `nextcloud_admin` through `homelab.keycloak.testUser.groups`) and checks: it lands logged in, the uid is `sso-regression` on a second login with no duplicate or hashed account, it gets Nextcloud `admin`, it loses `admin` when removed from `nextcloud_admin`, and prestonh, dylanh and nextcloud-admin keep their uid, backend and groups. It deletes the test user's Nextcloud account at the end.

## Login (SSO)

1. Open https://cloud.prestonhager.com
2. Click **Sign in with Keycloak**
3. Complete the Keycloak login (LAN, tailnet or VPN only); Nextcloud provisions the user on first login

Local login (break-glass):

```
https://cloud.prestonhager.com/login?direct=1
```

## Sops secrets

`secrets/containers/nextcloud.yaml` keys:

```yaml
nextcloud-environment: |
  MARIADB_ROOT_PASSWORD=...
  MARIADB_PASSWORD=...
  NEXTCLOUD_ADMIN_PASSWORD=...
  SMTP_PASSWORD=...   # optional

nextcloud-db-environment: |
  MARIADB_ROOT_PASSWORD=...
  MARIADB_PASSWORD=...

nextcloud-oidc-env: |
  KEYCLOAK_CLIENT_SECRET=<client secret; Keycloak is set to it by keycloak-realm-sync>

nextcloud-whiteboard-env: |
  JWT_SECRET_KEY=<random 48-char secret; must match whiteboard app jwt_secret_key>
  NEXTCLOUD_URL=https://cloud.prestonhager.com
```

`MAX_UPLOAD_FILE_SIZE` (collaboration server WebSocket payload cap, in **megabytes**) is set in Nix (`100`), not sops. The whiteboard app admin limit is `occ config:app:set whiteboard max_file_size --value=100` (applied by `nextcloud-occ-maintain.service`).

The whiteboard JWT secret used to be generated by `scripts/ace-bootstrap-secrets.sh`, which was removed in commit `572c200` (recover with `git show 572c200^:scripts/ace-bootstrap-secrets.sh`). If it is missing, `nextcloud-occ-maintain.service` logs `JWT_SECRET_KEY missing from nextcloud-whiteboard-env` and skips whiteboard config; add a random secret to sops by hand. After sops changes:

```bash
cd /etc/nixos
nix flake update nix-secrets
nixos-rebuild switch --flake .#ace
systemctl restart nextcloud-oidc-config.service
```

## What NixOS automates

On deploy, `nextcloud-oidc-config.service`:

- Installs and enables the `user_oidc` app
- Configures provider `keycloak` (discovery, scopes `openid profile email`, uid from `preferred_username` with unique-uid off, group provisioning for the `admin` group)
- Deletes the old `zitadel` provider if it is still there (accounts stay)
- Sets login button label **Sign in with Keycloak**
- Keeps local login enabled (`allow_multiple_user_backends`)

`nextcloud-occ-maintain.service` also installs/enables the **whiteboard** app and sets `collabBackendUrl` + `jwt_secret_key` from `nextcloud-whiteboard-env`.

The Nextcloud pod pins `keycloak.prestonhager.com` → `192.168.5.5` (Caddy on ace) with `--add-host` (`pod-nextcloud`). Podman copies ace's `/etc/hosts` into the container, and there `local-service-hosts.nix` points every Caddy vhost at `127.0.0.1`, which inside the pod is the pod itself: without the pin, user_oidc fails with "Could not reach the provider". Keycloak is LAN-only; Caddy lets the podman bridge (`10.88.0.0/16`) reach only the back-channel endpoints (discovery, token, certs, userinfo), see `nixos/caddy/keycloak.nix`.

## Whiteboard real-time collaboration

The **whiteboard** app (Excalidraw-based) needs a separate WebSocket server for live multi-user editing. Basic whiteboard use works without it; the admin overview warning clears once configured.

| Setting | Value |
|---------|-------|
| Container | `nextcloud-whiteboard` in the `nextcloud` pod |
| Image | `ghcr.io/nextcloud-releases/whiteboard:stable` |
| Internal port | `3002` (localhost only; Caddy terminates TLS) |
| Public URL | `https://cloud.prestonhager.com/whiteboard` |
| Nextcloud `collabBackendUrl` | `https://cloud.prestonhager.com/whiteboard` |
| Shared secret | `JWT_SECRET_KEY` in sops `nextcloud-whiteboard-env` → app `jwt_secret_key` |
| Max image size (app) | `max_file_size` = `100` (MB); must be ≤ collaboration server `MAX_UPLOAD_FILE_SIZE` |
| WebSocket payload cap | `MAX_UPLOAD_FILE_SIZE` = `100` (MB) on `nextcloud-whiteboard` container |
| Caddy body limit | `request_body max_size 100MB` on `/whiteboard/*` (main vhost stays unlimited for large file sync) |

Verification:

```bash
systemctl is-active podman-nextcloud-whiteboard
curl -sS -o /dev/null -w '%{http_code}\n' https://cloud.prestonhager.com/whiteboard/
podman exec -u www-data nextcloud php occ config:app:get whiteboard collabBackendUrl
podman exec -u www-data nextcloud php occ config:app:get whiteboard jwt_secret_key
podman exec -u www-data nextcloud php occ config:app:get whiteboard max_file_size
podman exec nextcloud-whiteboard printenv MAX_UPLOAD_FILE_SIZE
```

Admin **Settings → Administration → Whiteboard → Advanced** should show no warning that max image size exceeds the WebSocket payload limit. Overview should no longer show the whiteboard WebSocket URL warning.

## Administration overview warnings

Reference for **Settings → Administration → Overview** items on ace (single-node homelab).

| Warning | Status | Notes |
|---------|--------|-------|
| Errors in logs | Fixed (Jun 2026) | Historical noise from NC34 upgrade; see [Log errors](#log-errors) below. Truncate `data/nextcloud.log` after fixes to reset the counter. |
| Mimetype migrations | Fixed on deploy | `nextcloud-occ-config.service` runs `occ maintenance:repair --include-expensive` once (marker `/stor/nextcloud/.occ-expensive-repair-done`). Re-run manually after major upgrades: `occ maintenance:repair --include-expensive`. |
| Server ID (`serverid`) | Fixed on deploy | Single-node: `occ config:system:set serverid --type=integer --value=0`. Distinct from `instanceid` (auto-generated at install). |
| Email server | Configured | iCloud SMTP via sops `SMTP_PASSWORD` in `nextcloud-environment`; `mail_test_wizard_completed=yes` set after first successful test. Optional — many homelabs skip outbound mail. |
| AppAPI deploy daemon | Optional / ignore | `app_api` is bundled with NC34 but Ex-Apps (Talk bot, etc.) are not used. Safe to dismiss unless you install Ex-Apps and need a HaRP/daemon. |
| Second factor (2FA) | Optional | `twofactor_totp`, `twofactor_nextcloud_notification`, and `twofactor_backupcodes` are installed. Keycloak handles MFA for SSO users; enforcing NC 2FA for OIDC users is optional. To enforce for all local users: `occ twofactorauth:enforce --group=admin` (or per-group). |
| Whiteboard WebSocket | Fixed on deploy | See [Whiteboard real-time collaboration](#whiteboard-real-time-collaboration). |

### Log errors

Top causes in `data/nextcloud.log` since the NC 31→34 upgrade (June 2026):

| Count (approx.) | App | Message | Resolution |
|-----------------|-----|---------|------------|
| ~780 | `cloudmigrate` | `registerCommand()` undefined on NC34 | Fixed in `apps/cloudmigrate` — `Application.php` no longer registers OCC commands via bootstrap. Historical entries only after redeploy. |
| ~960 | `user_oidc` | `allow_multiple_user_backends` AppConfig type conflict (integer vs string) | Fixed: delete key, re-set with `--type=string`. Nix `nextcloud-oidc-config.service` applies this on deploy. |

After confirming no new errors:

```bash
podman exec nextcloud truncate -s 0 /var/www/html/data/nextcloud.log
```

Active monitoring probes (`Blackbox-Exporter` hitting `/login` every ~30s) previously amplified log volume from the `user_oidc` warning.

## Verification on ace

```bash
occ() { podman exec -u www-data nextcloud php /var/www/html/occ "$@"; }
occ user_oidc:provider keycloak --output=json   # mappingUid preferred_username, uniqueUid false
occ group:info admin 2>/dev/null || occ group:list --output=json
# OIDC discovery reachable from the Nextcloud container (expect 200)
podman exec nextcloud curl -sS -o /dev/null -w '%{http_code}\n' \
  https://keycloak.prestonhager.com/realms/homelab/.well-known/openid-configuration
bash tests/sso/run.sh nextcloud
```

See also [keycloak-ace.md](./keycloak-ace.md) for the realm and [monitoring-ace.md](./monitoring.md) for the Grafana OAuth pattern.
