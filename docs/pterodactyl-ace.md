# Pterodactyl on ace

Implementation: `nixos/containers/pterodactyl.nix`, `nixos/containers/pterodactyl-oauth.nix`, Caddy `nixos/caddy/pterodactyl.nix`, secrets `nixos-secrets/secrets/containers/pterodactyl-oauth.yaml`.

## Service

| Field | Value |
|-------|-------|
| URL | https://panel.prestonhager.com |
| Version | Pterodactyl Panel 1.11.11 |
| Auth | Zitadel OIDC via **oauth2-proxy** + header-auth middleware (production panel only) |
| Break-glass local login | `/auth/login` (bypasses forward_auth) |

Stock Pterodactyl (v1.11 and v1.12) has **no native OAuth/OIDC**. The large in-panel OAuth PR ([#3774](https://github.com/pterodactyl/panel/pull/3774)) was closed without merge; maintainer Dane Everitt directed users to [oauth2-proxy](https://github.com/oauth2-proxy/oauth2-proxy) instead. Header-based auth ([#5271](https://github.com/pterodactyl/panel/pull/5271)) is open but not merged — ace ships a local copy of that middleware. SSO here uses oauth2-proxy in front of Caddy with that header-auth patch.

**There is no in-panel OAuth provider config** like Nextcloud or Jellyfin. Visiting the panel homepage auto-redirects unauthenticated users to Zitadel; a visible **Sign in with Zitadel** button appears only on the break-glass login page (`/auth/login`).

## Zitadel OIDC application

Create or update the **Pterodactyl** OIDC app in the **Home Lab** project (`376196450586990901`):

| Setting | Value |
|---------|--------|
| App type | Web |
| Redirect URI | `https://panel.prestonhager.com/oauth2/callback` |
| Grant types | Authorization Code, Refresh Token |
| Auth method | Basic (client secret) |
| Role assertions | Enabled (ID token + access token) |

Automated setup on ace (admin session API):

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

Zitadel project roles use a nested object claim. A **Complement Token** action adds a flat `groups` claim for oauth2-proxy.

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

Normal flow (no button on homepage — immediate redirect):

1. Open https://panel.prestonhager.com — Caddy `forward_auth` → oauth2-proxy → Zitadel
2. Or use https://panel.prestonhager.com/oauth2/start?rd=/
3. Or https://panel.prestonhager.com/auth/zitadel (redirect alias)

Break-glass local login: https://panel.prestonhager.com/auth/login

The break-glass page shows a **Sign in with Zitadel** button (blade patch in `nixos/containers/pterodactyl/auth-core.blade.php`) above the username/password form. Most users never see this page because `/` redirects to Zitadel automatically.

## Alternatives considered

| Approach | Verdict |
|----------|---------|
| Upgrade to v1.12 for native OAuth | No — v1.12 has security/fixes only, no OAuth |
| Blueprint + Social Login extension | Not adopted — adds framework patch layer, paid/community OAuth inside panel would duplicate oauth2-proxy, higher update risk |
| oauth2-proxy + header-auth (current) | Best fit — same pattern maintainers recommend, works with Zitadel roles via `groups` claim |

## Verification on ace

```bash
systemctl is-active pterodactyl-oauth2-proxy.service
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4180/oauth2/sign_in
grep AUTH_HEADER /pterodactyl/html/.env
```

After SSO login as `admin@prestonhager.com`:

```bash
podman exec pterodactyl-db mariadb -upterodactyl -p"$DB_PASS" panel \
  -e "SELECT email, root_admin FROM users WHERE email='admin@prestonhager.com';"
```

See also [zitadel-ace.md](./zitadel-ace.md) and [nextcloud-ace.md](./nextcloud-ace.md).
