# Keycloak on ace

Keycloak is the identity provider for **server logins** (see `docs/sso-login.md`). Zitadel keeps serving the web apps (Grafana, Nextcloud, Jellyfin, ...) until each one moves over.

| | |
|---|---|
| URL | https://keycloak.prestonhager.com (LAN, tailnet and WireGuard only) |
| Realm | `homelab` (issuer `https://keycloak.prestonhager.com/realms/homelab`) |
| Admin console | https://keycloak.prestonhager.com/admin/master/console/ |
| Implementation | `nixos/containers/keycloak.nix`, Caddy `nixos/caddy/keycloak.nix`, shared names `nixos/auth/keycloak-lib.nix` |
| Containers | `keycloak` (26.8.0) and `keycloak-db` (postgres 17) in `keycloak-pod`; HTTP on `127.0.0.1:9280`, management on `127.0.0.1:9281` |
| Data | `/keycloak/postgres`, dumped nightly with the other databases (`nixos/backup.nix`) |

## Secrets

| sops file (nixos-secrets) | Key | Contents | Readable by |
|---|---|---|---|
| `secrets/containers/keycloak.yaml` | `keycloak-env` | `KC_DB_PASSWORD`, `KC_BOOTSTRAP_ADMIN_PASSWORD`, `PRESTONH_INITIAL_PASSWORD` | ace |
| `secrets/containers/keycloak.yaml` | `keycloak-db-env` | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` | ace |
| `secrets/sssd-keycloak.yaml` | `sssd-keycloak-env` | `SSSD_CLIENT_SECRET` | ace, crux, elara, mars |

A new host with Keycloak logins needs its age key added to the `secrets/sssd-keycloak.yaml` rule in `.sops.yaml`, then `sops updatekeys secrets/sssd-keycloak.yaml`.

## Realm import

On first start `--import-realm` creates the `homelab` realm from the Nix attrset in `nixos/containers/keycloak.nix`. `${VAR}` placeholders in it are filled from the container environment. **The import runs only while the realm does not exist.** After that the database is the source of truth: changing the Nix realm does nothing on a running instance, so make the change in the console as well.

The import creates:

- **Groups:** `srv-all`, `srv-<host>` for ace, mars, crux, elara, nova and zenith, plus `sudo-full` and `sudo-rebuild`.
- **`opkssh` client:** public, standard flow, localhost redirect URIs. It has its own `groups` mapper (flat names), so other clients never see the group list.
- **`sssd` client:** confidential, secret `SSSD_CLIENT_SECRET`, with the device authorization grant. Its service account has `view-users`, `query-users` and `query-groups` from `realm-management`.
- **User `prestonh`:** in `srv-all` and `sudo-full`. Its temporary password is `PRESTONH_INITIAL_PASSWORD`, and TOTP setup is required at first login.
- **Realm settings:** no self-registration, no username editing (the opkssh policy trusts `preferred_username`), no email login, brute-force protection on.

## First deploy

1. Commit and push `nixos-secrets`, then `cd /etc/nixos && nix flake update nix-secrets`.
2. `sudo nixos-rebuild switch --flake /etc/nixos#ace`
3. Check the import:

   ```bash
   podman logs keycloak 2>&1 | grep -iE 'import|realm|started'
   curl -s https://keycloak.prestonhager.com/realms/homelab/.well-known/openid-configuration | jq -r .issuer
   ```

4. Check that the client secret placeholder was filled (expect `Bearer`):

   ```bash
   sudo sh -c '. /run/secrets/sssd-keycloak-env; curl -s -d grant_type=client_credentials -d client_id=sssd \
     --data-urlencode client_secret="$SSSD_CLIENT_SECRET" \
     https://keycloak.prestonhager.com/realms/homelab/protocol/openid-connect/token' | jq -r .token_type
   ```

5. **Replace the bootstrap admin.** Log in to the admin console as `tmp-admin` with `KC_BOOTSTRAP_ADMIN_PASSWORD`:

   ```bash
   sudo grep KC_BOOTSTRAP_ADMIN_PASSWORD /run/secrets/keycloak-env
   ```

   In the `master` realm, create your own admin user, give it the `admin` role, set a password and TOTP. Then log in as that user and delete `tmp-admin`.
6. **First login as prestonh.** Open https://keycloak.prestonhager.com/realms/homelab/account and sign in with `PRESTONH_INITIAL_PASSWORD`; Keycloak makes you set a new password and TOTP and fill in your profile (email).

## Managing access

All of this happens in the admin console under the `homelab` realm: **Users** and **Groups**.

- **New person:** Users → Add user. The username becomes their Linux login name: lowercase, no spaces, and not the name of a local account (`root`, `phadmin`, `nginx`, ...). Give them a temporary password on the Credentials tab.
- **Which servers:** add them to `srv-all` (every enrolled host) or to `srv-<host>` groups.
- **Sudo:** add them to `sudo-full` (all commands), `sudo-rebuild` (only where `homelab.sso.rebuildFlake` is set), or a group named in `homelab.sso.sudoRules`.
- **New group:** Groups → Create group. Never reuse a local group name such as `wheel`, `docker` or `users`: the local group wins and the grant is silently lost.

## Troubleshooting

| Symptom | Check |
|---|---|
| Realm missing after start | `podman logs keycloak`: the import aborts on invalid JSON or an unresolved placeholder |
| `invalid_client` from SSSD | The secret in the realm differs from `sssd-keycloak-env`. Reset it in Clients → sssd → Credentials, or update sops to match |
| Redirect loop or http:// URLs | `KC_HOSTNAME` must be `https://keycloak.prestonhager.com` and Caddy must send `X-Forwarded-Proto` (it does by default) |

```bash
podman logs keycloak --tail 50
curl -s http://127.0.0.1:9281/health/ready
```
