# Matrix on ace

Implementation: `nixos/containers/matrix.nix`, Caddy `nixos/caddy/matrix.nix`, secrets `nixos-secrets/secrets/containers/matrix.yaml` (`matrix-db-env`, `matrix-secrets`, `matrix-oauth-env`).

## Service

| Field | Value |
|-------|-------|
| URL | https://matrix.prestonhager.com |
| Server name | `matrix.prestonhager.com` |
| Auth | Zitadel OIDC (SSO only for normal users) |
| Image | `matrixdotorg/synapse:v1.127.0` |
| Backend (on ace) | http://127.0.0.1:6167 |

## Zitadel OIDC application

Create or update the **Matrix** OIDC app in the **Home Lab** project (same project as Grafana):

| Setting | Value |
|---------|--------|
| App type | Web |
| Redirect URI | `https://matrix.prestonhager.com/_synapse/client/oidc/callback` |
| Grant types | Authorization Code, Refresh Token |
| Auth method | PKCE (no client secret; Synapse `pkce_method: always`) |
| Role assertions | Enabled (ID token + access token) |

Automated setup on ace:

```bash
cd /etc/nixos
nix shell nixpkgs#nodejs_22 -c node scripts/zitadel-matrix-oauth-setup.js
```

Store the printed `SYNAPSE_OIDC_CLIENT_ID` and `SYNAPSE_OIDC_CLIENT_SECRET` in sops (`matrix-oauth-env` key in `secrets/containers/matrix.yaml`), then redeploy:

```bash
scripts/ace-matrix-oauth-deploy.sh <client_id> <client_secret>
```

## Matrix admin via Zitadel role

Synapse does not map OIDC roles to server admin natively. A custom Python module (`nixos/containers/matrix/zitadel_oidc_mapper.py`) syncs admin on each SSO login.

| Zitadel project role | Synapse effect |
|----------------------|----------------|
| `matrix_admin` | Server admin (`admin=1` in Synapse DB) |
| (no role) | Normal user |

### Assign `matrix_admin` in the Zitadel console

1. Open https://zitadel.prestonhager.com/ui/console/org/projects
2. Select project **Home Lab**
3. **Roles** → create role `matrix_admin` if missing (display name *Matrix Admin*)
4. **Authorizations** → select user → **New grant** → role `matrix_admin` → save
5. **Applications** → **Matrix** → enable **Assert Roles on Authentication**
6. User signs out of Matrix clients and signs in again via Zitadel SSO

Role claims appear in userinfo as:

```json
"urn:zitadel:iam:org:project:roles": {
  "matrix_admin": { "376196450586990901": "prestonhager.com" }
}
```

Required OIDC scopes (configured in `homeserver.yaml`):

- `openid`, `profile`, `email`
- `urn:zitadel:iam:org:project:roles`
- `urn:zitadel:iam:org:project:id:<PROJECT_ID>:aud`

## Element login (SSO)

1. Open https://app.element.io (or another Element client)
2. **Sign in** → **Edit** homeserver → set `https://matrix.prestonhager.com`
3. Choose **Continue with Zitadel** (or **Sign in with SSO**)
4. Complete Zitadel login; Element returns logged in

Direct SSO URL (for testing):

```
https://matrix.prestonhager.com/_matrix/client/v3/login/sso/redirect?redirectUrl=https%3A%2F%2Fapp.element.io%2F
```

## Sops secrets

`secrets/containers/matrix.yaml` keys:

```yaml
matrix-db-env: |
  POSTGRES_USER=synapse
  POSTGRES_PASSWORD=...
  POSTGRES_DB=synapse

matrix-secrets: |
  SYNAPSE_REGISTRATION_SHARED_SECRET=...
  SYNAPSE_MACAROON_SECRET_KEY=...
  SYNAPSE_FORM_SECRET=...

matrix-oauth-env: |
  SYNAPSE_OIDC_CLIENT_ID=<from Zitadel Matrix app>
  SYNAPSE_OIDC_CLIENT_SECRET=<from Zitadel Matrix app>
  ZITADEL_PROJECT_ID=376196450586990901
```

After sops changes:

```bash
cd /etc/nixos
nix flake update nix-secrets
nixos-rebuild switch --flake .#ace
systemctl restart matrix-synapse-init.service podman-matrix-synapse.service
```

## Verification on ace

```bash
# SSO redirect (expect 302 to Zitadel)
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  'http://127.0.0.1:6167/_matrix/client/v3/login/sso/redirect?redirectUrl=https%3A%2F%2Fapp.element.io%2F'

# Synapse health
curl -sS http://127.0.0.1:6167/_matrix/client/versions

# Check admin flag after SSO login (replace localpart)
podman exec matrix-db psql -U synapse -d synapse -c \
  "SELECT name, admin FROM users WHERE name LIKE '@admin%';"
```

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| SSO button missing in Element | `oidc_providers` not in `homeserver.yaml`; rerun `matrix-synapse-init` |
| Redirect URI mismatch | Zitadel app redirect must exactly match `/_synapse/client/oidc/callback` |
| Login works but not admin | User lacks `matrix_admin` grant or role assertions disabled on Matrix app |
| Token/userinfo errors from Synapse | Container cannot reach Zitadel — check `--add-host=zitadel.prestonhager.com:host-gateway` |
| `ImportError: zitadel_oidc_mapper` | `PYTHONPATH=/oidc` and volume mount of `nixos/containers/matrix/` |

See also [zitadel-ace.md](./zitadel.md) and [monitoring-ace.md](./monitoring.md) for shared Zitadel patterns.
