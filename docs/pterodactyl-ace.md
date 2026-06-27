# Pterodactyl on ace

Implementation: `nixos/containers/pterodactyl.nix`, `nixos/containers/pterodactyl-blueprint.nix`, `nixos/containers/pterodactyl-sso.nix`, Caddy `nixos/caddy/pterodactyl.nix`, secrets `nixos-secrets/secrets/containers/pterodactyl-oauth.yaml`.

## Service

| Field | Value |
|-------|-------|
| URL | https://panel.prestonhager.com |
| Version | Pterodactyl Panel **1.11.11** (official `pterodactyl/panel` stock) |
| Extensions | **Blueprint** (`beta-2026-05`+) + **Social Login** community extension |
| Auth | Zitadel OIDC via **Blueprint Social Login** + `socialiteproviders/zitadel` |
| Break-glass local login | `/auth/login` (username/password) |

Production uses the **official** Pterodactyl panel (`release/v1.11.11`). The prior **PrestonHager/panel** `feat/plugin-manager` fork is removed from production and kept only on the test panel (`test.panel.prestonhager.com`).

Stock Pterodactyl (v1.11 and v1.12) has **no native OAuth/OIDC**. SSO is provided in-panel by the free [Blueprint Social Login](https://github.com/blueprint-community/extension-sociallogin) extension with the [SocialiteProviders Zitadel](https://socialiteproviders.com/Zitadel/) driver.

The previous **oauth2-proxy + forward_auth + HeaderAuthentication middleware** approach is **removed** from production Caddy and panel code.

## Removed custom fork features (production)

The PrestonHager `feat/plugin-manager` fork added roughly 1,800 lines across 56 files. Removed from production:

| Area | What was removed |
|------|------------------|
| Git remote | `PrestonHager/panel` → `pterodactyl/panel` official |
| Plugin manager | `app/Services/Plugins/*`, plugin API v3 routes, admin plugin designer UI |
| Panel update scripts | Custom `scripts/panel-update.sh`, `scripts/panel-update-container.sh` |
| React plugin host | `PluginClientTabHost`, dashboard/server router plugin tabs |
| Docs | `docs/plugins/*`, `docs/panel-updates.md` fork docs |
| SSO patches (old) | `HeaderAuthentication` middleware, `auth.php` header guard, oauth2-proxy forward_auth, break-glass Zitadel blade banner |

## Zitadel OIDC application

Create or update the **Pterodactyl** OIDC app in the **Home Lab** project (`376196450586990901`):

| Setting | Value |
|---------|--------|
| App type | Web |
| Redirect URIs | `https://panel.prestonhager.com/extensions/sociallogin/callback` (primary), `https://panel.prestonhager.com/oauth2/callback` (legacy oauth2-proxy), `https://test.panel.prestonhager.com/extensions/sociallogin/callback` (test panel) |
| Grant types | Authorization Code, Refresh Token |
| Auth method | Basic (client secret) |
| Role assertions | Enabled (ID token + access token) |

Automated setup on ace (admin session API). Updates redirect URIs via the dedicated `oidc_config` endpoint (the generic app PUT no longer persists OIDC redirect changes on Zitadel v4):

```bash
cd /etc/nixos
nix shell nixpkgs#nodejs_22 -c node scripts/zitadel-pterodactyl-console-setup.js
```

Store credentials in sops, then redeploy:

```bash
scripts/ace-pterodactyl-oauth-deploy.sh <client_id> <client_secret>
```

## Panel admin via Zitadel role

| Zitadel project role | Panel effect |
|----------------------|--------------|
| `pterodactyl_admin` | Panel root admin (`root_admin=1`) on SSO login |
| (no role) | Normal user |

Zitadel project roles use a nested object claim. A **Complement Token** action adds a flat `groups` claim read by the Social Login callback patch.

### MANUAL: Complement Token action in Zitadel console

1. Open https://zitadel.prestonhager.com/ui/console/org/actions
2. **New action** → flow **Complement Token** → name `pterodactylGroups`
3. Triggers: **Pre Userinfo creation**, **Pre access token creation**
4. Script (also printed by setup script):

```javascript
function pterodactylGroups(ctx, api) {
  if (!ctx.v1.user || !ctx.v1.user.grants || !ctx.v1.user.grants.grants) {
    return;
  }
  const groups = [];
  for (const grant of ctx.v1.user.grants.grants) {
    const roleKeys = grant.roleKeys || [];
    if (roleKeys.includes('pterodactyl_admin')) {
      groups.push('pterodactyl_admin');
      break;
    }
  }
  api.v1.claims.setClaim('groups', groups);
}
```

5. **Flows** → **Complement Token** → add `pterodactylGroups` to the flow
6. Save and activate

### Assign `pterodactyl_admin` in the Zitadel console

1. **Home Lab** project → **Roles** → create `pterodactyl_admin` if missing
2. **Authorizations** → user → grant `pterodactyl_admin`
3. **Applications** → **Pterodactyl** → enable **Assert Roles on Authentication**

## Login (SSO)

Primary SSO URL:

**https://panel.prestonhager.com/extensions/sociallogin/redirect/zitadel**

Users visiting `/auth/login` see Social Login provider buttons (including Zitadel) when the extension is configured. Break-glass local login remains at `/auth/login` for username/password.

## Alternatives considered

| Approach | Verdict |
|----------|---------|
| Upgrade to v1.12 for native OAuth | No — v1.12 has security/fixes only, no OAuth |
| PrestonHager plugin-manager fork | Removed from prod — replaced by Blueprint extension ecosystem |
| oauth2-proxy + header-auth (previous) | Removed — replaced by in-panel Blueprint Social Login |
| Blueprint + Social Login + Zitadel (current) | **Adopted** — free community extension, native login UI, Zitadel via SocialiteProviders |

## Deploy sequence (production)

On ace after pulling config changes:

```bash
cd /etc/nixos
nixos-rebuild switch --flake .#ace
```

Systemd oneshots run in order:

1. `pterodactyl-stock-reset.service` — revert `/pterodactyl/html` to official `release/v1.11.11`
2. `pterodactyl-blueprint-install.service` — install Blueprint + Social Login extension
3. `pterodactyl-sso-configure.service` — configure Zitadel OIDC provider and admin role sync

## Verification on ace

```bash
systemctl is-active pterodactyl-stock-reset pterodactyl-blueprint-install pterodactyl-sso-configure
test -f /pterodactyl/html/.blueprint && echo blueprint-ok
test -f /pterodactyl/html/blueprint.sh && echo blueprint-sh-ok
grep ZITADEL_CLIENT_ID /pterodactyl/html/.env
curl -sS -o /dev/null -w '%{http_code}\n' https://panel.prestonhager.com/auth/login
```

After SSO login as `admin@prestonhager.com`:

```bash
podman exec pterodactyl-db mariadb -upterodactyl -p"$DB_PASS" panel \
  -e "SELECT email, root_admin FROM users WHERE email='admin@prestonhager.com';"
```

See also [zitadel-ace.md](./zitadel-ace.md) and [nextcloud-ace.md](./nextcloud-ace.md).
