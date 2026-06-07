# Zitadel on ace

Implementation: `nixos/containers/zitadel.nix`, Caddy `nixos/caddy/zitadel.nix`, secrets `nixos-secrets/secrets/containers/zitadel-config.yaml`.

## Login

| Field | Value |
|-------|-------|
| URL | https://zitadel.prestonhager.com |
| Login name | `admin@prestonhager.com` (username and email are the same) |
| Password | `ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD` in sops (`zitadel-config.yaml`) |

Use the full email address on the login-name step, not `admin` alone.

## First-instance bootstrap

`ZITADEL_FIRSTINSTANCE_*` env vars are consumed only during the initial database setup (`start-from-init`). Changing the password in sops **does not** update an existing admin user. After rotating that secret, reset the admin password (below) or wipe `/zitadel/postgres` and re-init.

## Reset admin password to match sops

On ace, after updating `ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD` in sops and redeploying:

```bash
cd /path/to/nixos-configs
nix shell nixpkgs#nodejs_22 -c node scripts/zitadel-reset-admin-password.js
```

The script reads the password from `/run/secrets/zitadel-env`, authenticates with the login-client key at `/zitadel/login-client/tls.key`, and sets the admin password via the v2 User API.

Verify:

```bash
nix shell nixpkgs#nodejs_22 -c node scripts/zitadel-verify-login.js
```

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| "Could not create session for user" on password step | Wrong password (check `podman logs zitadel` for `Password is invalid`) |
| Login name step works, password fails | Password hash in DB does not match sops — run reset script above |
| `Instance not found` on local API calls | Missing `Host: zitadel.prestonhager.com` header |
| Blank console, `[unknown] Failed to fetch` after login | `environment.json` has `"api":"http://..."` — use `--tlsMode external` and Caddy `h2c://` with `header_up -TE` |
| Login UI `Internal server error` after tlsMode change | `AUDIENCE` must be `https://zitadel.prestonhager.com` (not `http://...:443`) with `--tlsMode external` |

Verify console API URL:

```bash
curl -s https://zitadel.prestonhager.com/ui/console/assets/environment.json | jq .
# api and issuer must both be https://zitadel.prestonhager.com
```

Grafana OAuth admin role mapping is documented in [monitoring-ace.md](./monitoring-ace.md). Nextcloud OIDC SSO is documented in [nextcloud-ace.md](./nextcloud-ace.md).

Useful logs:

```bash
podman logs zitadel-login --tail 50
podman logs zitadel --tail 50
```

## Grafana OAuth admin role

Grafana at https://grafana.prestonhager.com uses the **Home Lab** project OIDC app (`Grafana`, client ID in sops). Users with Zitadel project role `grafana_admin` receive Grafana **Server Admin** on login when OAuth env vars are configured (see `docs/monitoring-ace.md`).

### Assign `grafana_admin` in the console

1. Open https://zitadel.prestonhager.com/ui/console/org/projects
2. Select project **Home Lab**
3. **Roles** → create role `grafana_admin` if it does not exist (display name e.g. *Grafana Admin*)
4. **Authorizations** → find the user → **New grant** → select role `grafana_admin` → save
5. **Applications** → **Grafana** → enable **Assert Roles on Authentication** (ID token and access token role assertion)
6. In Grafana: **Sign out**, then **Sign in with Zitadel** again

Role claims appear in userinfo as `urn:zitadel:iam:org:project:roles` with `grafana_admin` as an object key. Grafana scopes must include `urn:zitadel:iam:org:project:roles` and the project audience scope (configured in sops).

### Verify on ace

```bash
# Zitadel grant for admin user
podman exec zitadel-db psql -U zitadel -d zitadel -c \
  "SELECT roles FROM projections.user_grants5 WHERE user_id=(SELECT id FROM projections.users14 WHERE username='admin@prestonhager.com');"

# Grafana server admin flag after re-login
nix shell nixpkgs#sqlite -c sqlite3 /grafana/data/grafana.db \
  "SELECT email, is_admin FROM user WHERE email='admin@prestonhager.com';"
```

## Nextcloud OAuth admin role

Nextcloud at https://cloud.prestonhager.com uses the **Home Lab** project OIDC app (`Nextcloud`). Users with Zitadel project role `nextcloud_admin` receive Nextcloud **server admin** (via `groups: ["admin"]` complement action → `user_oidc` group provisioning). See [nextcloud-ace.md](./nextcloud-ace.md) for setup, complement action, and verification.
