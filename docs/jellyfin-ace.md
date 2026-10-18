# Jellyfin on ace

Implementation: `nixos/containers/jellyfin.nix`, Caddy `nixos/caddy/jellyfin.nix`, secrets `nixos-secrets/secrets/containers/jellyfin.yaml` (`jellyfin-oauth-env`).

## Service

| Field | Value |
|-------|-------|
| URL | https://jellyfin.prestonhager.com |
| Version | Jellyfin **10.11.11** (official container image, pinned as `jellyfinVersion`) |
| Auth | Zitadel OIDC via **SSO Authentication** plugin (`9p4/jellyfin-plugin-sso` **4.0.0.4**, hash-pinned, installed to `plugins/SSO Authentication_4.0.0.4`) |
| Upgrade hold | Stay on **10.11.x**: there is no SSO plugin build for Jellyfin 12 yet, and upgrading would break Zitadel login. Bump only after a plugin release targets the new ABI |
| SSO login URL | https://jellyfin.prestonhager.com/sso/OID/start/zitadel |
| Break-glass local admin | `preston-admin` (existing local account) |

## Zitadel OIDC application

Create or update the **Jellyfin** OIDC app in the **Home Lab** project (`376196450586990901`):

| Setting | Value |
|---------|--------|
| App type | Web |
| Redirect URIs | `https://jellyfin.prestonhager.com/sso/OID/redirect/zitadel`, `https://jellyfin.prestonhager.com/sso/OID/r/zitadel` |
| Grant types | Authorization Code, Refresh Token |
| Auth method | Basic (client secret) |
| Role assertions | Enabled (ID token + access token) |

The Zitadel setup scripts (`zitadel-jellyfin-console-setup.js`, preferred, admin session API; `zitadel-jellyfin-oauth-setup.js`, login-client JWT fallback) and `ace-jellyfin-oauth-deploy.sh` were removed in commit `572c200`. Create the app in the Zitadel console, or recover a script:

```bash
cd /etc/nixos
git show 572c200^:scripts/zitadel-jellyfin-console-setup.js > /tmp/zitadel-jellyfin-console-setup.js
nix shell nixpkgs#nodejs_22 -c node /tmp/zitadel-jellyfin-console-setup.js
```

Store the `JELLYFIN_OIDC_CLIENT_ID` and `JELLYFIN_OIDC_CLIENT_SECRET` in sops (`jellyfin-oauth-env`, see [Sops secrets](#sops-secrets)) and rebuild ace. `jellyfin-sso-setup.service` (`nixos/containers/jellyfin.nix`) then installs the plugin and writes its configuration from that secret.

## Jellyfin roles via Zitadel

The SSO plugin reads a flat **`groups`** claim. Zitadel project roles use a nested object claim, so a **Complement Token** action maps roles to `groups` (same pattern as Nextcloud).

| Zitadel project role | Jellyfin effect |
|----------------------|-----------------|
| `jellyfin_admin` | Jellyfin administrator |
| `jellyfin_user` | Authenticated user with library access (`EnableAllFolders`) |

**Important:** Do not grant both `jellyfin_admin` and `jellyfin_user` to the same user — the SSO plugin returns "Check permissions" when multiple matching `groups` claims are present. Preston receives `jellyfin_admin` only (`jellyfin_admin` is also listed under plugin `Roles` for access).

### Automated: Complement Token action

`scripts/zitadel-jellyfin-groups-action.js` was removed in commit `572c200`; no Nix unit replaces it. Use the console steps below, or recover the script and run it on ace after roles/grants are configured:

```bash
cd /etc/nixos
git show 572c200^:scripts/zitadel-jellyfin-groups-action.js > /tmp/zitadel-jellyfin-groups-action.js
nix shell nixpkgs#nodejs_22 -c node /tmp/zitadel-jellyfin-groups-action.js
```

The script:

- Creates or updates the `jellyfinGroups` action (ID `376332016783726901` on ace)
- Attaches it to **Complement Token** triggers (Pre Userinfo + Pre access token)
- Ensures `prestonh` has `jellyfin_admin` only and `dylanh` has `jellyfin_user` only

The action must read **`grant.roles`** (not `grant.roleKeys`) — Zitadel's complement-token context exposes roles under `roles`. Do **not** request the OIDC `groups` scope in the Jellyfin plugin; the complement action sets the claim and requesting the scope can block `setClaim`.

### MANUAL: Complement Token action (console fallback)

1. Open https://zitadel.prestonhager.com/ui/console/org/actions
2. **New action** → flow **Complement Token** → name `jellyfinGroups`
3. Triggers: **Pre Userinfo creation**, **Pre access token creation**
4. Script:

```javascript
function jellyfinGroups(ctx, api) {
  if (!ctx.v1.user || !ctx.v1.user.grants || ctx.v1.user.grants.count === 0) {
    return;
  }
  const groups = [];
  for (const grant of ctx.v1.user.grants.grants) {
    const roles = grant.roles || grant.roleKeys || [];
    for (const role of roles) {
      if (role === 'jellyfin_admin') {
        groups.push('jellyfin_admin');
        break;
      }
      if (role === 'jellyfin_user') {
        groups.push('jellyfin_user');
      }
    }
  }
  if (groups.length > 0) {
    api.v1.claims.setClaim('groups', groups);
  }
}
```

5. **Flows** → **Complement Token** → add `jellyfinGroups` to the flow
6. Save and activate

### Zitadel users and grants

| Person | Zitadel username | User ID | Home Lab role |
|--------|------------------|---------|---------------|
| Preston | `prestonh` | `376197075085302069` | `jellyfin_admin` |
| Dylan | `dylanh` | `376328957357726005` | `jellyfin_user` |

The (now removed) setup script created roles and grants when the login-client API permitted it; otherwise add them in the console. Verify in **Authorizations** if grants are missing.

## Login (SSO)

1. Open https://jellyfin.prestonhager.com
2. Click **Sign in with Zitadel** (login disclaimer button)
3. Or go directly to https://jellyfin.prestonhager.com/sso/OID/start/zitadel

On first SSO login, Jellyfin provisions the user. Existing local user `prestonh` is linked via canonical username mapping.

## Sops secrets

`secrets/containers/jellyfin.yaml`:

```yaml
jellyfin-oauth-env: |
  JELLYFIN_OIDC_CLIENT_ID=<from Zitadel Jellyfin app>
  JELLYFIN_OIDC_CLIENT_SECRET=<from Zitadel Jellyfin app>
  ZITADEL_PROJECT_ID=376196450586990901
```

After sops changes:

```bash
cd /etc/nixos
nix flake update nix-secrets
nixos-rebuild switch --flake .#ace
rm -f /jf/config/.sso-setup-done
systemctl restart jellyfin-sso-setup.service
# Re-apply the jellyfinGroups action if needed (console, or the recovered script above)
systemctl restart podman-jellyfin.service
```

## Container networking

Jellyfin runs with `--add-host=zitadel.prestonhager.com:host-gateway` so server-side OIDC discovery and token exchange reach Caddy on the host (same pattern as Grafana and Nextcloud).

## Verification on ace

```bash
# SSO plugin loaded (expect 404 before plugin, 302/200 after)
curl -sS -o /dev/null -w 'sso_start_http=%{http_code}\n' \
  'http://127.0.0.1:8096/sso/OID/start/zitadel'

# Zitadel grants
podman exec zitadel-db psql -U zitadel -d zitadel -c \
  "SELECT u.username, g.roles FROM projections.user_grants5 g JOIN projections.users14 u ON u.id=g.user_id WHERE g.project_id='376196450586990901' AND g.roles::text LIKE '%jellyfin%';"

# Jellyfin admin flag after SSO login
nix shell nixpkgs#sqlite -c sqlite3 /jf/config/data/jellyfin.db \
  "SELECT Username, CAST(IsAdministrator AS TEXT) FROM Users;"
```

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| `redirect_uri` mismatch | Add both `/sso/OID/redirect/zitadel` and `/sso/OID/r/zitadel` in Zitadel app |
| "Check permissions" on login | Missing `groups` claim (complement action uses `grant.roleKeys` instead of `grant.roles`, or action not on Complement Token flow), user has both `jellyfin_admin` and `jellyfin_user`, or OIDC `groups` scope requested (blocks `setClaim`) — fix the `jellyfinGroups` action ([console steps](#manual-complement-token-action-console-fallback)) |
| OIDC discovery timeout | Missing `host-gateway` for `zitadel.prestonhager.com` on the container |
| Plugin not loaded | Run `systemctl restart jellyfin-sso-setup.service`; check `/jf/config/plugins/SSO Authentication_4.0.0.4/` (Jellyfin loads `plugins/<Name>_<version>/`) |
| SSO button missing on login page | `branding.xml` LoginDisclaimer HTML must be XML entity-escaped (raw `<form>` tags break parsing); check `podman logs jellyfin` for `Error loading configuration file: branding.xml` |

Useful logs:

```bash
journalctl -u jellyfin-sso-setup.service -n 50
podman logs jellyfin --tail 100 | grep -i sso
```
