# Hydrodactyl on ace

The game-server panel at https://panel.prestonhager.com (and the test panel at https://test.panel.prestonhager.com) runs **[Hydrodactyl](https://github.com/BlueprintFramework/hydrodactyl)**, a fork of the Pterodactyl panel. Production moved from Pterodactyl + Blueprint on 2026-10-26; see `docs/hydrodactyl-migration-plan.md` in the repo for what changed and why. The game servers themselves run on the [Wings nodes](../pterodactyl-nodes/index.md) (stock Wings 1.13.4, which Hydrodactyl drives unchanged).

Many identifiers still say `pterodactyl` because they predate the move and renaming them would mean migrating data: container and unit names (`pterodactyl`, `pterodactyl-db`, `pterodactyl-redis`, `podman-pterodactyl.service`), the data paths (`/pterodactyl/html`, `/pterodactyl-test/html`), the PHP namespace (`Pterodactyl\`), sops keys (`pterodactyl-env`, `pterodactyl-oauth-env`) and the Zitadel role keys (`pterodactyl_admin`).

## Service

| Field | Value |
|---|---|
| URL | https://panel.prestonhager.com (test: https://test.panel.prestonhager.com) |
| Version | Hydrodactyl **6.4.2** (Laravel 13, PHP 8.4, React 19), built by Nix from the release tarball |
| Addons | Native Hydrodactyl addons in `plugins/hydrodactyl`: Zitadel SSO, DNS records, router port forwarding, Minecraft tools |
| Auth | Zitadel OIDC (SSO addon); break-glass local login at `/auth/login` |
| Containers | `pterodactyl` (panel, image `localhost/hydrodactyl-runtime:v6.4.2`), `pterodactyl-db` (MariaDB 12.3), `pterodactyl-redis` (Valkey 9.1), in one pod |
| Test panel | Same image; `pterodactyl-test`, `pterodactyl-test-db` (MariaDB 11.4), `pterodactyl-test-redis`; its own `APP_KEY`, so it can never decrypt production node tokens |

## Implementation

| File | What it does |
|---|---|
| `nixos/containers/hydrodactyl-panel.nix` | Builds the panel: release tarball (pinned version + hash), the addons, Composer `vendor/` and the Vite frontend. Nothing is fetched at runtime |
| `nixos/containers/hydrodactyl-docker.nix` | The runtime image. On start it syncs code into `/var/www/pterodactyl` (keeping `.env`, `storage/`, `bootstrap/cache`), runs migrations and caches, then php-fpm, the queue worker and the scheduler |
| `nixos/containers/hydrodactyl.nix` | The flavor switch (`homelab.panel.{prod,test}.flavor = "hydrodactyl"` in `hosts/ace`), `hydrodactyl[-test]-env` (enforces `.env` keys) and `hydrodactyl[-test]-configure` (Zitadel provider from sops, egg loader features) |
| `nixos/containers/pterodactyl.nix`, `pterodactyl-test.nix` | The pod, MariaDB, Valkey (password from `pterodactyl-redis-auth`), Caddy site and secrets, shared by both flavors |
| `nixos/containers/hydrodactyl-test-node.nix` | A throwaway Wings node for the test panel |

## SSO (Zitadel)

- The SSO addon does the OIDC code flow (PKCE, state, nonce) against the **Pterodactyl** app in Zitadel's **Home Lab** project (`376196450586990901`). The Zitadel app keeps its old name.
- Login page: **Sign in with Zitadel**, which starts at `/extensions/sociallogin/redirect/zitadel`. The callback is `/extensions/sociallogin/callback` (kept from the Blueprint era, so the Zitadel app's redirect URIs did not change).
- Client ID and secret come from sops `pterodactyl-oauth-env`; `hydrodactyl-configure` writes them into the panel's provider settings.
- **Admin rights:** on each login the addon sets `root_admin` from the `groups` claim. Users whose groups include `pterodactyl_admin` (Zitadel project role of the same name, mapped by the `homelabGroups` action, `scripts/zitadel-homelab-groups-action.js`) are admins; others are not. A token with no groups claim leaves `root_admin` unchanged.
- Linking a Zitadel identity to an existing account by email requires `email_verified`. Users manage links under Account → Linked Accounts.

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
# The panel reaches Zitadel through host-gateway, not 127.0.0.1:
podman exec pterodactyl curl -sf --max-time 10 https://zitadel.prestonhager.com/.well-known/openid-configuration | head -c 80
```

See also [Hydrodactyl addons: user guide](./pterodactyl-extensions-user-guide.md), [DNS records](./pterodactyl-plugin-dns-records.md), [Port forward](./pterodactyl-plugin-port-forward.md), [Zitadel](./zitadel.md), [Wings nodes](../pterodactyl-nodes/index.md) and [Network topology](../shared/network-topology.md).
