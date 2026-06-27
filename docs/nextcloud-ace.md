# Nextcloud on ace

Implementation: `nixos/containers/nextcloud.nix`, Caddy `nixos/caddy/nextcloud.nix`, secrets `nixos-secrets/secrets/containers/nextcloud.yaml` (`nextcloud-environment`, `nextcloud-db-environment`, `nextcloud-oidc-env`).

## Service

| Field | Value |
|-------|-------|
| URL | https://cloud.prestonhager.com |
| Version | Nextcloud 34 (official container image, pinned in `nextcloud.nix`) |
| Auth | Zitadel OIDC via `user_oidc` app; local login remains available (`?direct=1`) |
| Break-glass local admin | `nextcloud-admin` (password in sops `nextcloud-environment`) |

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
```

After sops changes:

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

The Nextcloud pod resolves `zitadel.prestonhager.com` → `192.168.5.5` (Caddy on ace) for OIDC discovery from inside the container.

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
