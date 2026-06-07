# Zitadel on ace

Implementation: `nixos/containers/zitadel.nix`, Caddy `nixos/caddy/zitadel.nix`, secrets `nixos-secrets/secrets/containers/zitadel-config.yaml`.

## Login

| Field | Value |
|-------|-------|
| URL | https://zitadel.prestonhager.com |
| Login name | `admin@prestonhager.com` (username and email are the same) |
| Password | `ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD` in sops (`zitadel-config.yaml`) |

Use the full email address on the login-name step, not `admin` alone.

## Email (SMTP)

Zitadel sends mail through the same **iCloud SMTP relay** as Nextcloud.

| Setting | Value |
|---------|-------|
| Host | `smtp.mail.me.com:587` (host must include port) |
| TLS | STARTTLS (`true`) |
| Auth user | `prestonhager@icloud.com` (same as Nextcloud; iCloud relay login) |
| From address | `admin@prestonhager.com` |
| From name | `Zitadel` |
| Password | `SMTP_PASSWORD` in `nixos-secrets/secrets/containers/nextcloud.yaml` (shared iCloud app-specific password; injected at runtime by `zitadel-container-env`) |

Non-secret SMTP env vars are set in `nixos/containers/zitadel.nix`. The password is **not** duplicated in `zitadel-config.yaml`.

`ZITADEL_DEFAULTINSTANCE_SMTPCONFIGURATION_*` env vars apply only during first init (`start-from-init`). On an already-running instance, configure SMTP via the Admin API after deploy:

```bash
cd /etc/nixos
nix shell nixpkgs#nodejs_22 -c node scripts/zitadel-smtp-setup.js
```

The script reads `SMTP_PASSWORD` from `/run/secrets/nextcloud-environment`, sets domain policy `smtpSenderAddressMatchesInstanceDomain=false` (required because the sender domain is `prestonhager.com`, not `zitadel.prestonhager.com`), creates or updates the SMTP provider, and sends a test email.

### Verify email

1. **API test** — output from `zitadel-smtp-setup.js` should end with `SMTP test email sent`; check the `admin@prestonhager.com` inbox.
2. **Console** — https://zitadel.prestonhager.com/ui/console/instance/settings → **Email Provider** → confirm host `smtp.mail.me.com:587`, sender `admin@prestonhager.com`, and use **Test** if available.
3. **Password reset** — trigger a password reset for a test user and confirm delivery.

### Manual console steps (if API script fails)

1. Instance → **Domain Settings** → disable **SMTP Sender Address matches Instance Domain**.
2. Instance → **Email Provider** → add SMTP: host `smtp.mail.me.com:587`, TLS on, user `prestonhager@icloud.com`, password from sops `SMTP_PASSWORD`, sender `admin@prestonhager.com`.
3. Activate the provider and send a test email.

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

Grafana OAuth admin role mapping is documented in [monitoring-ace.md](./monitoring-ace.md). Nextcloud OIDC SSO is documented in [nextcloud-ace.md](./nextcloud-ace.md). Jellyfin OIDC SSO is documented in [jellyfin-ace.md](./jellyfin-ace.md).

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
