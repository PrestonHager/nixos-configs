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

## Realm settings from Nix (keycloak-realm-sync)

`nixos/containers/keycloak-realm.nix` keeps part of the realm in step with Nix on every switch, through keycloak-config-cli:

- groups (`homelab.keycloak.groups`);
- the `groups` client scope (flat `groups` claim);
- each service's client (`homelab.keycloak.clients.<name>`, declared in the service's own module, with its secret taken from that service's sops file);
- realm email;
- the `sso-regression` test user.

It never deletes anything, and it never touches user accounts or group membership. Those stay in the admin console (`docs/keycloak-users.md`).

```bash
systemctl status keycloak-realm-sync
journalctl -u keycloak-realm-sync -b
systemctl restart keycloak-realm-sync   # re-apply now
```

### One-time: the homelab-config client

The sync logs in as `homelab-config`, a service account that is `realm-admin` of **homelab only**: it can't see or change `master`. An admin creates it once:

1. Admin console → realm **homelab** → Clients → **Create client**. Client ID `homelab-config`, Next.
2. Turn **Client authentication** on and **Service accounts roles** on. Turn off Standard flow and Direct access grants. Next, Save.
3. **Service accounts roles** tab → Assign role → filter by clients → `realm-management` **realm-admin** → Assign.
4. **Credentials** tab → copy the client secret.
5. Put it in sops, on ace in `/home/prestonh/nixos-secrets`:

   ```bash
   read -rs s && printf '"KEYCLOAK_CONFIG_CLIENT_SECRET=%s\\n"' "$s" \
     | SOPS_AGE_KEY_FILE=/var/lib/sops/age/keys.txt sops set --value-stdin \
         secrets/containers/keycloak.yaml '["keycloak-config-env"]'; unset s
   ```

6. Commit and push nixos-secrets, `nix flake update nix-secrets` in `/etc/nixos`, then `bash scripts/ace-rebuild.sh`.

Until then the secret is `REPLACE_ME` and the sync skips with a log line.

### Email

Realm email uses the same iCloud SMTP relay and sender Zitadel used: `smtp.mail.me.com:587` with STARTTLS, login `prestonhager@icloud.com`, from `admin@prestonhager.com`, display name "Homelab". The password is `SMTP_PASSWORD` from the Nextcloud sops env file, as for Zitadel. It covers verify-email, password reset (once enabled in the realm), and admin-triggered emails such as Users → the user → **Credentials → Credential reset**. Test it with Realm settings → Email → **Test connection**, which mails the admin's own address.

## Regression tests

`tests/sso/run.sh` logs in to each Keycloak-backed service as the `sso-regression` user and checks the outcome. The user has a password and no TOTP (`SSO_REGRESSION_PASSWORD` in sops), and stays **disabled** except while `run.sh` runs. Each service has a `tests/sso/<service>.test.sh`; the groups the test user needs come from `homelab.keycloak.testUser.groups` in the service's module.

```bash
bash tests/sso/run.sh            # everything
bash tests/sso/run.sh grafana    # one service
```

## Managing access

Adding users and granting server, sudo and folder access is a step-by-step flow in `docs/keycloak-users.md`.

## Sign in with Google

The login page has a **Google** button. A Google login **only links to an existing user with the same email**. A Google account whose email no user has is refused ("does not exist. Please contact your administrator") and no account is created. After Google, Keycloak still asks for the user's TOTP.

How the provider is set up:

| Piece | Setting |
|---|---|
| Identity provider | `google`, trust email on, no token storage |
| First broker login flow | `google-link-existing`: *Detect existing broker user* → *Automatically set existing user*, both required. No user creation, no profile review |
| Post broker login flow | `google-require-otp`: *OTP Form*, required (`homelab.keycloak.google.requireOtp = false` drops it) |

`keycloak-realm-sync` applies all of this from `homelab.keycloak.google` in `nixos/containers/keycloak.nix`. The Google client ID and secret come from sops (`keycloak-google-env`). **While either is `REPLACE_ME`, the sync leaves Google out, so there is no button.** The flows were tested against a throwaway Keycloak 26.8.0 with a second realm standing in for Google: a matching email was linked, an unknown email was refused with no user created, and TOTP was enforced afterwards. The sync was also checked to create the button and to be safe to re-run.

### Setup

1. **Google OAuth client** (https://console.cloud.google.com, any project):
   1. *APIs & Services → OAuth consent screen*: type **External**, app name "Homelab", scopes `openid`, `email`, `profile`. Either **publish** the app (these basic scopes need no Google verification) or add each user as a test user.
   2. *Credentials → Create credentials → OAuth client ID*: type **Web application**. Authorized redirect URI:

      ```text
      https://keycloak.prestonhager.com/realms/homelab/broker/google/endpoint
      ```

   3. Copy the client ID and secret.
2. **sops**, on ace in `/home/prestonh/nixos-secrets`:

   ```bash
   read -r id && read -rs secret && printf '"GOOGLE_CLIENT_ID=%s\\nGOOGLE_CLIENT_SECRET=%s\\n"' "$id" "$secret" \
     | SOPS_AGE_KEY_FILE=/var/lib/sops/age/keys.txt sops set --value-stdin \
         secrets/containers/keycloak.yaml '["keycloak-google-env"]'; unset id secret
   ```

   Paste the client ID, press Enter, paste the secret (not echoed), press Enter. Then commit and push nixos-secrets, run `nix flake update nix-secrets` in `/etc/nixos`, and run `bash scripts/ace-rebuild.sh`. The secret change restarts `keycloak-realm-sync`, which adds the button.
3. **Users:** each user's Keycloak **Email** must be their Google address (`docs/keycloak-users.md`, step 2).

This needs `homelab-config` to exist first (above), since the sync can't run without it.

Keycloak stays LAN/tailnet/VPN only. Google never connects to it: the browser carries the redirect, and Keycloak calls Google outbound.

To rotate the Google secret, create a new one in Google and repeat step 2.

## Troubleshooting

| Symptom | Check |
|---|---|
| Realm missing after start | `podman logs keycloak`: the import aborts on invalid JSON or an unresolved placeholder |
| `invalid_client` from SSSD | The secret in the realm differs from `sssd-keycloak-env`. Reset it in Clients → sssd → Credentials, or update sops to match |
| Account console says "Something went wrong" | The user has no `default-roles-homelab`. Imported users don't get it automatically. Fix it in Users → the user → Role mapping → Assign role → `default-roles-homelab` |
| Redirect loop or http:// URLs | `KC_HOSTNAME` must be `https://keycloak.prestonhager.com` and Caddy must send `X-Forwarded-Proto` (it does by default) |

```bash
podman logs keycloak --tail 50
curl -s http://127.0.0.1:9281/health/ready
```
