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

Useful logs:

```bash
podman logs zitadel-login --tail 50
podman logs zitadel --tail 50
```
