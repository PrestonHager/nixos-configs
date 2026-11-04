# Hydrodactyl on ace

The game-server panel at https://panel.prestonhager.com (and the test panel at https://test.panel.prestonhager.com) runs **[Hydrodactyl](https://github.com/BlueprintFramework/hydrodactyl)**, a fork of the Pterodactyl panel. Production moved from Pterodactyl + Blueprint on 2026-10-26; see `docs/hydrodactyl-migration-plan.md` in the repo for what changed and why. The game servers themselves run on the [Wings nodes](../pterodactyl-nodes/index.md) (stock Wings 1.13.4, which Hydrodactyl drives unchanged).

Many identifiers still say `pterodactyl` because they predate the move and renaming them would mean migrating data: container and unit names (`pterodactyl`, `pterodactyl-db`, `pterodactyl-redis`, `podman-pterodactyl.service`), the data paths (`/pterodactyl/html`, `/pterodactyl-test/html`), the PHP namespace (`Pterodactyl\`), sops keys (`pterodactyl-env`, `pterodactyl-oauth-env`) and the admin group names (`pterodactyl_admin`, `pterodactyl_test_admin`, Keycloak groups named after the old Zitadel roles).

## Service

| Field | Value |
|---|---|
| URL | https://panel.prestonhager.com (test: https://test.panel.prestonhager.com) |
| Version | Hydrodactyl **6.4.2** (Laravel 13, PHP 8.4, React 19), built by Nix from the release tarball |
| Addons | Native Hydrodactyl addons in `plugins/hydrodactyl`: Keycloak SSO, DNS records, router port forwarding, Minecraft tools |
| Auth | Keycloak OIDC (realm `homelab`, SSO addon); break-glass local login at `/auth/login` |
| Containers | `pterodactyl` (panel, image `localhost/hydrodactyl-runtime:v6.4.2`), `pterodactyl-db` (MariaDB 12.3), `pterodactyl-redis` (Valkey 9.1), in one pod |
| Test panel | Same image; `pterodactyl-test`, `pterodactyl-test-db` (MariaDB 11.4), `pterodactyl-test-redis`; its own `APP_KEY`, so it can never decrypt production node tokens |

## Implementation

| File | What it does |
|---|---|
| `nixos/containers/hydrodactyl-panel.nix` | Builds the panel: release tarball (pinned version + hash), the addons, Composer `vendor/` and the Vite frontend. Nothing is fetched at runtime |
| `nixos/containers/hydrodactyl-docker.nix` | The runtime image. On start it syncs code into `/var/www/pterodactyl` (keeping `.env`, `storage/`, `bootstrap/cache`), runs migrations and caches, then php-fpm, the queue worker and the scheduler |
| `nixos/containers/hydrodactyl.nix` | The flavor switch (`homelab.panel.{prod,test}.flavor = "hydrodactyl"` in `hosts/ace`), `hydrodactyl[-test]-env` (enforces `.env` keys) and `hydrodactyl[-test]-configure` (Keycloak provider row, SSO link migration, egg loader features) and the `pterodactyl` Keycloak client |
| `nixos/containers/pterodactyl.nix`, `pterodactyl-test.nix` | The pod, MariaDB, Valkey (password from `pterodactyl-redis-auth`), Caddy site and secrets, shared by both flavors |
| `nixos/containers/hydrodactyl-test-node.nix` | A throwaway Wings node for the test panel |

## SSO (Keycloak)

- The SSO addon (`plugins/hydrodactyl/app/Addons/Sso`, `OidcClient`) does the OIDC code flow (PKCE, state, nonce) against the Keycloak realm `homelab` (issuer `https://keycloak.prestonhager.com/realms/homelab`, endpoints from its discovery document). Both panels use the confidential client **`pterodactyl`**, declared in `hydrodactyl.nix` (`homelab.keycloak.clients.pterodactyl`) and applied by `keycloak-realm-sync`.
- Redirect URIs: `https://panel.prestonhager.com/extensions/sociallogin/callback`, `https://test.panel.prestonhager.com/extensions/sociallogin/callback`, and `https://panel.prestonhager.com/oauth2/callback` for the oauth2-proxy in `pterodactyl-oauth.nix` (not imported at the moment).
- Login page: **Sign in with Keycloak**, which starts at `/extensions/sociallogin/redirect/keycloak`. The callback path is unchanged from the Blueprint era.
- Secret: `PTERODACTYL_OIDC_CLIENT_SECRET` in sops `pterodactyl-oauth-env` (the value the Zitadel app had; Keycloak is set to it). The client ID `pterodactyl` is in Nix. `hydrodactyl[-test]-configure` writes both into the panel's provider row (`social_providers`, short name `keycloak`).
- `.env` keys (enforced by `hydrodactyl[-test]-env`): `SSO_ISSUER`, `SSO_ADMIN_GROUP` (`pterodactyl_admin` on production, `pterodactyl_test_admin` on the test panel). Old `ZITADEL_*` keys are removed.
- **Admin rights:** on each login the addon sets `root_admin` from the flat `groups` claim (the client's `groups` scope). Members of the panel's admin group are admins; others are not. A token with no groups claim leaves `root_admin` unchanged. Group membership is managed in the Keycloak admin console (docs/keycloak-users.md).
- **Accounts:** panel users are linked to an identity in `social_connections` (`auth_id` = the OIDC `sub`, the Keycloak user id). Links are matched by sub, so a username difference (panel `prestonhager`, Keycloak `prestonh`) does not matter. An unknown sub links to the panel user with the same email only when Keycloak says the email is verified; otherwise a new account is created (`sociallogin::allow_register`).
- **Move from Zitadel (2026-11):** `hydrodactyl[-test]-configure` renamed the `zitadel` provider row to `keycloak` (same id, so links stay attached) and replaced Zitadel subs (all digits) with Keycloak user ids from `ssoLinks` in `hydrodactyl.nix`:

  | Panel user | Email | Zitadel sub (before) | Keycloak user / sub (after) |
  |---|---|---|---|
  | prestonhager (id 1) | preston@hagerfamily.com | 376197075085302069 | prestonh / 99d63cf6-7775-44d9-b9c9-6be589bea2ae |
  | dylanjdl (id 2) | dylan@hagerfamily.com | (no link) | dylanh: links by verified email on first login |

  The other panel users have local logins only. No panel account exists for admin@prestonhager.com.
- The panel containers reach Keycloak at `https://keycloak.prestonhager.com` (192.168.5.5 through Caddy) for the token and userinfo calls.
- Regression test: `bash tests/sso/run.sh pterodactyl` (`tests/sso/pterodactyl.test.sh`). It logs in on both panels as `sso-regression`, checks admin with and without the groups, checks the migrated links, and deletes the panel users it created.
- oauth2-proxy (`pterodactyl-oauth.nix` with `oauth = true` in `nixos/caddy/pterodactyl.nix`) is not deployed. `bash tests/sso/run.sh pterodactyl-oauth2-proxy` builds it from the repo, runs it as a transient unit on 127.0.0.1:4180, and checks the whole login: start, Keycloak, callback, then `/oauth2/auth` returning the email, username and groups that `HeaderAuthentication.php` reads. The email header comes from the `email` claim; before the move it carried the username (`--user-id-claim` is the old name of `--oidc-email-claim`), so header auth would not have matched existing users by email.
- The Blueprint-era modules (`pterodactyl-sso.nix`, `pterodactyl-test-sso.nix`, listeners `KeycloakAdminSync.php` / `KeycloakTestAdminSync.php`, `seed-sso-provider.php`) are switched to the socialiteproviders Keycloak driver too, but they only run with the `pterodactyl` flavor, which neither panel uses.

## Upgrading

Hydrodactyl is **not** auto-updated: the update tooling can only rewrite version strings, and the release tarball is pinned by hash. The *Ace manual update available* alert mails when a newer release in the same series is out.

1. Take a backup (`systemctl start restic-backups-local`); Hydrodactyl's migrations are one-way.
2. In `nixos/containers/hydrodactyl-panel.nix`, set `version` and the `upstream` hash (`nix store prefetch-file https://github.com/BlueprintFramework/hydrodactyl/releases/download/v<version>/panel.tar.gz`).
3. Rebuild, then check the test panel first (log in, a server console, the DNS and port-forward tabs).
4. Check production: `podman exec pterodactyl php /var/www/pterodactyl/artisan --version`, the login page, an SSO login.

## Verification

```bash
systemctl is-active podman-pterodactyl hydrodactyl-env hydrodactyl-configure
curl -sS -o /dev/null -w '%{http_code}\n' https://panel.prestonhager.com/auth/login
podman exec pterodactyl php /var/www/pterodactyl/artisan --version
# The panel reaches Keycloak (expect the issuer URL):
podman exec pterodactyl php -r 'echo json_decode(file_get_contents("https://keycloak.prestonhager.com/realms/homelab/.well-known/openid-configuration"))->issuer, "\n";'
bash tests/sso/run.sh pterodactyl
```

See also [Hydrodactyl addons: user guide](./pterodactyl-extensions-user-guide.md), [DNS records](./pterodactyl-plugin-dns-records.md), [Port forward](./pterodactyl-plugin-port-forward.md), [Keycloak](./keycloak-ace.md), [Wings nodes](../pterodactyl-nodes/index.md) and [Network topology](../shared/network-topology.md).
