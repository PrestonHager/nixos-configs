# Matrix on ace

Implementation: `nixos/containers/matrix.nix`, Caddy `nixos/caddy/matrix.nix`, secrets `nixos-secrets/secrets/containers/matrix.yaml` (`matrix-db-env`, `matrix-secrets`, `matrix-oauth-env`).

## Service

| Field | Value |
|-------|-------|
| URL | https://matrix.prestonhager.com |
| Server name | `matrix.prestonhager.com` |
| Auth | Keycloak OIDC (realm `homelab`, client `matrix`; SSO only for normal users) |
| Image | `matrixdotorg/synapse` v1.164.2 (digest-pinned in `matrix.nix`) |
| Backend (on ace) | http://127.0.0.1:6167 |

## Keycloak OIDC client

Keycloak realm `homelab` ([keycloak-ace.md](./keycloak-ace.md)), client **`matrix`**, declared in `nixos/containers/matrix.nix` as `homelab.keycloak.clients.matrix`. `keycloak-realm-sync` creates and updates it on every switch:

| Setting | Value |
|---------|--------|
| Client ID | `matrix` (confidential, standard flow; Synapse also sends PKCE) |
| Redirect URI | `https://matrix.prestonhager.com/_synapse/client/oidc/callback` |
| Secret | `KEYCLOAK_CLIENT_SECRET` in `matrix-oauth-env`. In Zitadel the app was PKCE-only with no secret, so this one is new |
| Synapse `idp_id` | `keycloak`, so the IdP is `oidc-keycloak` in the client API and in `user_external_ids` |
| Scopes | `openid profile email`; the client's default `groups` scope adds a flat `groups` claim |

`matrix-synapse-init.service` writes the `oidc_providers` block into `homeserver.yaml`.

Synapse calls Keycloak server-side (discovery, token, JWKS). Podman copies ace's `/etc/hosts` into the pod, and there `local-service-hosts.nix` points every Caddy vhost at `127.0.0.1`, which inside the pod is the pod itself. So `pod-matrix` pins `keycloak.prestonhager.com` to `192.168.5.5` (Caddy on ace) with `--add-host`. Because `--add-host` only applies when a pod is created, `pod-matrix` recreates a pod that lacks the pin, which restarts Synapse and its database. Caddy lets the podman bridge reach only Keycloak's back-channel endpoints (`nixos/caddy/keycloak.nix`). Without the pin, Synapse logs `Error while preloading OIDC provider 'oidc-keycloak'` (connection refused) and SSO login fails.

Keycloak is LAN/tailnet/VPN only, so **new SSO logins work only from home or over the VPN**. Signed-in clients keep working anywhere, and federation does not involve Keycloak.

## Accounts and linking

Synapse finds the account for an SSO login in `user_external_ids` by `(auth_provider, external_id)`, where `external_id` is the Keycloak `sub` (`subject_claim: sub`). A new user's localpart comes from `preferred_username` (lower-cased, anything after `@` dropped). `allow_existing_users` stays off. A login whose localpart is already taken by an unlinked account would get a new `@name1`, so **link existing accounts before their first Keycloak login**:

```bash
sub=<Keycloak user id of the user>   # admin console -> Users -> the user -> ID
podman exec matrix-db psql -U synapse -d synapse -c \
  "INSERT INTO user_external_ids (auth_provider, external_id, user_id) VALUES ('oidc-keycloak', '$sub', '@name:matrix.prestonhager.com');"
```

Recorded before the move (2026-11-04). It was the only account on the server:

| MXID | Zitadel link (`oidc-zitadel`) | Keycloak link (`oidc-keycloak`) | Admin before |
|------|------------------------------|--------------------------------|--------------|
| `@prestonh:matrix.prestonhager.com` | `376197075085302069` | Keycloak sub of `prestonh` (inserted before the switch) | no |

The old `oidc-zitadel` row is left in place. It does nothing once Zitadel is no longer a provider.

Login rate limits: `homeserver.yaml` sets `rc_login.address` and `rc_login.account` to a burst of 10, then one per 20 s, instead of the defaults (burst 5, then one per ~5.5 min). This is safe because no Matrix account has a password, and each login needs a fresh SSO round-trip. It lets back-to-back test runs log in from ace. `rc_login.failed_attempts`, which limits wrong passwords, keeps its default.

## Matrix admin from the Keycloak group

Synapse has no native OIDC-group -> admin mapping. `nixos/containers/matrix/keycloak_oidc_mapper.py` provides it:

- `KeycloakOidcMappingProvider` (Jinja mapper) records on every login whether the `groups` claim contains `matrix_admin`.
- `KeycloakAdminModule` (`on_user_login`) then sets or clears the Synapse admin flag.

| Keycloak group | Synapse effect |
|----------------|----------------|
| `matrix_admin` | Server admin (`admin=1`), applied at the next SSO login |
| (none) | Normal user; admin is removed at the next SSO login |

Membership is managed in the Keycloak admin console ([keycloak-users.md](./keycloak-users.md)).

## Element login (SSO)

1. Open https://app.element.io (or another Element client)
2. **Sign in** → **Edit** homeserver → set `https://matrix.prestonhager.com`
3. Choose **Continue with Keycloak**
4. Complete the Keycloak login; Element returns logged in

Direct SSO URL (for testing):

```
https://matrix.prestonhager.com/_matrix/client/v3/login/sso/redirect/oidc-keycloak?redirectUrl=https%3A%2F%2Fapp.element.io%2F
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
  KEYCLOAK_CLIENT_SECRET=<client secret; keycloak-realm-sync sets the Keycloak client to it>
```

After sops changes:

```bash
cd /etc/nixos
nix flake update nix-secrets
bash scripts/ace-rebuild.sh   # restarts matrix-synapse-init, Synapse and keycloak-realm-sync
```

## Verification on ace

```bash
# SSO redirect (expect 302 to Keycloak)
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  'http://127.0.0.1:6167/_matrix/client/v3/login/sso/redirect/oidc-keycloak?redirectUrl=https%3A%2F%2Fapp.element.io%2F'

# Synapse health
curl -sS http://127.0.0.1:6167/_matrix/client/versions

# Links and admin flags
podman exec matrix-db psql -U synapse -d synapse -c \
  "SELECT u.name, u.admin, e.auth_provider, e.external_id FROM users u LEFT JOIN user_external_ids e ON e.user_id = u.name ORDER BY 1;"
```

## Regression test

```bash
bash /etc/nixos/tests/sso/run.sh matrix
```

It checks the client and federation endpoints and that `oidc-keycloak` is the only SSO provider. It runs the SSO redirect flow three times as `sso-regression`: loginToken accepted by `/login`, a stable MXID, admin granted and then revoked through `matrix_admin`. It also checks that `@prestonh` is linked to prestonh's Keycloak sub and that the real MXIDs are unchanged. The test MXID `@sso-regression` is kept, because Synapse never frees a localpart. It ends each run without admin and with no access tokens.

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| SSO button missing in Element | `oidc_providers` not in `homeserver.yaml`; rerun `matrix-synapse-init` |
| Redirect URI mismatch | `homelab.keycloak.clients.matrix.redirectUris`; check that `journalctl -u keycloak-realm-sync` shows it applied |
| Login works but not admin | User is not in the `matrix_admin` group, or has not logged in via SSO since being added |
| Login creates `@name1` | The existing `@name` was not linked first; see [Accounts and linking](#accounts-and-linking) |
| `Error while preloading OIDC provider` / connection refused | `keycloak.prestonhager.com` resolves to `127.0.0.1` in the pod: check `podman exec matrix-synapse getent hosts keycloak.prestonhager.com` lists `192.168.5.5` first; `systemctl restart pod-matrix` recreates the pod with the pin |
| 403 from Keycloak on token/userinfo | Path missing from the back-channel carve-out in `nixos/caddy/keycloak.nix` |
| `M_LIMIT_EXCEEDED` from `/login` | Synapse's per-account login rate limit (a few logins in a burst); wait `retry_after_ms`. The SSO test waits it out once |
| `ImportError: keycloak_oidc_mapper` | `PYTHONPATH=/oidc` and volume mount of `nixos/containers/matrix/` |

See also [keycloak-ace.md](./keycloak-ace.md).
