# Pterodactyl on ace

Implementation: `nixos/containers/pterodactyl.nix`, `nixos/containers/pterodactyl-oauth.nix`, Caddy `nixos/caddy/pterodactyl.nix`, secrets `nixos-secrets/secrets/containers/pterodactyl-oauth.yaml`.

## Service

| Field | Value |
|-------|-------|
| URL | https://panel.prestonhager.com |
| Version | Pterodactyl Panel 1.11.11 |
| Auth | Zitadel OIDC via **oauth2-proxy** + header-auth middleware (production panel only) |
| Break-glass local login | `/auth/login` (bypasses forward_auth) |

Stock Pterodactyl v1.11 does **not** support native `OAUTH_CLIENT_ID` env vars. SSO uses oauth2-proxy in front of Caddy with a small header-auth middleware patch (based on pterodactyl/panel#5271).

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

1. Open https://panel.prestonhager.com — unauthenticated users are redirected to oauth2-proxy → Zitadel
2. Or use https://panel.prestonhager.com/oauth2/start?rd=/
3. Or https://panel.prestonhager.com/auth/zitadel (redirect alias)

Local login (break-glass): https://panel.prestonhager.com/auth/login

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
