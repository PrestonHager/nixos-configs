# Nextcloud on ace

Implementation: `nixos/containers/nextcloud.nix`, Caddy `nixos/caddy/nextcloud.nix`, secrets `nixos-secrets/secrets/containers/nextcloud.yaml` (`nextcloud-environment`, `nextcloud-db-environment`, `nextcloud-oidc-env`, `nextcloud-whiteboard-env`).

## Service

| Field | Value |
|-------|-------|
| URL | https://cloud.prestonhager.com |
| Version | Nextcloud 34 (official container image, pinned in `nextcloud.nix`) |
| Auth | Zitadel OIDC via `user_oidc` app; local login remains available (`?direct=1`) |
| Break-glass local admin | `nextcloud-admin` (password in sops `nextcloud-environment`) |
| Whiteboard WebSocket | `ghcr.io/nextcloud-releases/whiteboard:stable` sidecar in the Nextcloud pod; public URL `https://cloud.prestonhager.com/whiteboard` (Caddy proxies to `127.0.0.1:3002`) |

## Major version upgrade (31 → 34)

Nextcloud requires stepping through each major release (32, 33, 34). Image pin: `docker.io/library/nextcloud:34.0.1` in `nixos/containers/nextcloud.nix`. Sidecars unchanged: MariaDB 11.4, Redis, ClamAV stable, notify_push (same Nextcloud image).

Before upgrading, back up `/stor/nextcloud/data` and `/stor/nextcloud/mysql`.

On ace after `git pull`:

```bash
cd /etc/nixos
chmod +x scripts/ace-nextcloud-major-upgrade.sh
ACE_NC_UPGRADE_CONFIRM=yes scripts/ace-nextcloud-major-upgrade.sh
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

## Zitadel OIDC application

Create or update the **Nextcloud** OIDC app in the **Home Lab** project (`376196450586990901`):

| Setting | Value |
|---------|--------|
| App type | Web |
| Redirect URI | `https://cloud.prestonhager.com/apps/user_oidc/code` |
| Grant types | Authorization Code, Refresh Token |
| Auth method | Basic (client secret) |
| Role assertions | Enabled (ID token + access token) |

Automated setup on ace (admin session API; preferred):

```bash
cd /etc/nixos
nix shell nixpkgs#nodejs_22 -c node scripts/zitadel-nextcloud-console-setup.js
```

Fallback (login-client JWT; may lack project permissions):

```bash
nix shell nixpkgs#nodejs_22 -c node scripts/zitadel-nextcloud-oauth-setup.js
```

Store the printed `NEXTCLOUD_OIDC_CLIENT_ID` and `NEXTCLOUD_OIDC_CLIENT_SECRET` in sops, then redeploy:

```bash
scripts/ace-nextcloud-oauth-deploy.sh <client_id> <client_secret>
```

## Nextcloud admin via Zitadel role

Nextcloud `user_oidc` maps OIDC **groups** to Nextcloud groups. Server admin requires membership in the Nextcloud `admin` group.

Zitadel project roles use a nested object claim (`urn:zitadel:iam:org:project:roles`), which `user_oidc` cannot consume directly. A **Complement Token** action adds a flat `groups` claim.

| Zitadel project role | Nextcloud effect |
|----------------------|------------------|
| `nextcloud_admin` | Added to Nextcloud `admin` group (server admin) on SSO login |
| (no role) | Normal user |

**Important:** Only one Complement Token action may set the `groups` claim. Per-service actions (`jellyfinGroups`, `pterodactylGroups`, etc.) overwrite each other — the last one wins and drops `admin` for Nextcloud. Use the unified `homelabGroups` action instead.

Automated setup on ace:

```bash
cd /etc/nixos
nix shell nixpkgs#nodejs_22 -c node scripts/zitadel-homelab-groups-action.js
```

Verify the token includes `groups: ["admin", ...]`:

```bash
nix shell nixpkgs#nodejs_22 -c node scripts/zitadel-nextcloud-userinfo-test.js
```

Full OIDC diagnostic:

```bash
scripts/ace-nextcloud-oidc-diagnose.sh
```

### Assign `nextcloud_admin` in the Zitadel console

1. Open https://zitadel.prestonhager.com/ui/console/org/projects
2. Select project **Home Lab**
3. **Roles** → create role `nextcloud_admin` if missing (display name *Nextcloud Admin*)
4. **Authorizations** → select user → **New grant** → role `nextcloud_admin` → save
5. **Applications** → **Nextcloud** → enable **Assert Roles on Authentication** (ID token + access token)
6. User signs out of Nextcloud and signs in again via Zitadel

The setup script (`zitadel-nextcloud-oauth-setup.js`) creates the role, app, and admin grant when the login-client API permits it.

## Login (SSO)

1. Open https://cloud.prestonhager.com
2. Click **Sign in with Zitadel** (or use the Zitadel button on the login page)
3. Complete Zitadel login; Nextcloud provisions the user on first login

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
  NEXTCLOUD_OIDC_CLIENT_ID=<from Zitadel Nextcloud app>
  NEXTCLOUD_OIDC_CLIENT_SECRET=<from Zitadel Nextcloud app>
  ZITADEL_PROJECT_ID=376196450586990901

nextcloud-whiteboard-env: |
  JWT_SECRET_KEY=<random 48-char secret; must match whiteboard app jwt_secret_key>
  NEXTCLOUD_URL=https://cloud.prestonhager.com
```

`MAX_UPLOAD_FILE_SIZE` (collaboration server WebSocket payload cap, in **megabytes**) is set in Nix (`100`), not sops. The whiteboard app admin limit is `occ config:app:set whiteboard max_file_size --value=100` (applied by `nextcloud-occ-maintain.service`).

The whiteboard JWT secret is auto-generated on first ace bootstrap if missing (`scripts/ace-bootstrap-secrets.sh`). After sops changes:

```bash
cd /etc/nixos
nix flake update nix-secrets
nixos-rebuild switch --flake .#ace
systemctl restart nextcloud-oidc-config.service
```

## What NixOS automates

On deploy, `nextcloud-oidc-config.service`:

- Installs and enables the `user_oidc` app
- Configures provider `zitadel` (discovery, scopes, group provisioning for `admin` group)
- Sets login button label **Sign in with Zitadel**
- Keeps local login enabled (`allow_multiple_user_backends`)

`nextcloud-occ-maintain.service` also installs/enables the **whiteboard** app and sets `collabBackendUrl` + `jwt_secret_key` from `nextcloud-whiteboard-env`.

The Nextcloud pod resolves `zitadel.prestonhager.com` → `192.168.5.5` (Caddy on ace) for OIDC discovery from inside the container.

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
| Second factor (2FA) | Optional | `twofactor_totp`, `twofactor_nextcloud_notification`, and `twofactor_backupcodes` are installed. Zitadel already provides MFA; enforcing NC 2FA for OIDC users is optional. To enforce for all local users: `occ twofactorauth:enforce --group=admin` (or per-group). |
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
# Provider configured
podman exec -u www-data nextcloud php /var/www/html/occ user_oidc:provider zitadel

# Zitadel grant for admin user
podman exec zitadel-db psql -U zitadel -d zitadel -c \
  "SELECT roles FROM projections.user_grants5 WHERE user_id=(SELECT id FROM projections.users14 WHERE username='admin@prestonhager.com');"

# OIDC discovery reachable from Nextcloud container
podman exec nextcloud curl -sS -o /dev/null -w '%{http_code}\n' \
  https://zitadel.prestonhager.com/.well-known/openid-configuration

# After SSO login: admin group membership
podman exec -u www-data nextcloud php /var/www/html/occ group:listadmin
```

After logging in via Zitadel as `admin@prestonhager.com`, the user should appear in `group:listadmin` and have access to **Settings → Administration**.

See also [zitadel-ace.md](./zitadel-ace.md) for Zitadel console access and [monitoring-ace.md](./monitoring-ace.md) for the Grafana OAuth pattern.
