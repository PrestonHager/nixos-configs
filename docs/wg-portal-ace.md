# wg-portal on ace

Implementation: `nixos/containers/wg-portal.nix` (container, config rendering, Keycloak client), `nixos/containers/wg-portal-scripts.nix`, Caddy `nixos/caddy/wg-portal.nix`. The web UI is at `https://wg.prestonhager.com` (LAN/tailnet/VPN only), and WireGuard listens on UDP 51825.

## Config

The config comes from sops (`wg-portal-config`, `secrets/containers/wg-portal-config.yaml`) and is rendered to `/run/wg-portal/config.yaml` with `yq` before every start (`podman-wg-portal` preStart):

- The web session and CSRF secrets are generated on ace (`/var/lib/wg-portal-secrets`) so `ace-secret-rotate` can roll them (`docs/secret-rotation.md`).
- The OIDC provider is replaced by the Keycloak one built in Nix (below).

## Login (OIDC via Keycloak)

| Setting | Value |
|---------|-------|
| Provider id | `keycloak` (callback `/api/v0/auth/login/keycloak/callback`) |
| Issuer | `https://keycloak.prestonhager.com/realms/homelab` |
| Client | `wg-portal` (`homelab.keycloak.clients.wg-portal`), PKCE S256 |
| Scopes | `openid email profile groups` |
| Account key | `preferred_username` (the Keycloak username) |
| Admin | Keycloak group `wg-admin` (`admin_group_regex: ^wg-admin$` on the `groups` claim) |

`useKeycloak` at the top of the module switches between Keycloak and the old Zitadel provider.

**Client secret.** The secret is the one the Zitadel provider had. It is still stored in the sops YAML under the provider entry with `id: zitadel`. The rendered config copies it into the Keycloak entry. `wg-portal-keycloak-env` also extracts it into `/run/wg-portal-keycloak/client.env` (`WG_PORTAL_OIDC_CLIENT_SECRET`, root 0600), because `keycloak-realm-sync` needs a `KEY=VALUE` file to set the Keycloak client to the same value.

**Existing accounts.** wg-portal finds the account by its identifier (`preferred_username`). If that account has no authentication for the provider yet, wg-portal adds one, so `prestonh` and `dylanh` keep their accounts, peers and settings. On each login, admin is set from `wg-admin`. Someone who is a wg-portal admin today without `wg-admin` in Keycloak loses admin at their next login.

**Regression test:** `bash tests/sso/run.sh wg-portal`. It checks that `keycloak` is the only provider, that a login as a `wg-admin` member is admin and is linked to `oauth/keycloak`, that a second login without the group is the same account and not admin, and that real accounts are unchanged. The test account stays in wg-portal as a non-admin; it can log in only through the `sso-regression` Keycloak user, which is disabled between runs.
