# Test panel Blueprint (test.panel.prestonhager.com)

Architecture and deployment notes for the **test** Pterodactyl panel using upstream Blueprint with DNS and Social Login extension support. Production (`panel.prestonhager.com`) uses the same upstream Blueprint pattern plus Port Forward.

## Overview

| Component | Test panel | Production panel |
|-----------|------------|------------------|
| URL | https://test.panel.prestonhager.com | https://panel.prestonhager.com |
| Panel source | Stock [pterodactyl/panel](https://github.com/pterodactyl/panel) `release/v1.11.11` | Stock `release/v1.11.11` |
| Extension framework | [BlueprintFramework/framework](https://github.com/BlueprintFramework/framework) | Same |
| DNS | `dnsrecords` Blueprint extension | `dnsrecords` + Port Forward |
| SSO | Blueprint Social Login + Zitadel (same Home Lab OIDC app) | Same |

The test panel uses **stock panel + upstream Blueprint + Blueprint extensions** (same model as production, minus Port Forward).

## Upstream Blueprint

**https://github.com/BlueprintFramework/framework**

Runtime install downloads `release.zip` from the latest GitHub release (see `nixos/containers/pterodactyl-test-blueprint.nix`). The flake input pins a rev for reference:

```nix
blueprint-framework = {
  url = "github:BlueprintFramework/framework";
  flake = false;
};
```

### Blueprint install order (test panel)

Same pattern as production (`nixos/containers/pterodactyl-blueprint.nix`):

1. Download **`release.zip`** from [BlueprintFramework/framework releases](https://github.com/BlueprintFramework/framework/releases/latest/download/release.zip)
2. Run **`blueprint.sh`** first-time install (panel owned by `prestonh`, ACL cleanup via `runuser -u prestonh`)
3. **Install** `sociallogin` from the upstream `.blueprint` release
4. **Install** `dnsrecords` via `blueprint -install '[developer-build]'` from `plugins/pterodactyl-dns-blueprint/`

Do not pre-move `panel/blueprint` into `.blueprint/blueprint` before step 2 — `blueprint.sh` must perform that relocation itself.

## Zitadel SSO on test panel

The test panel shares the **Home Lab** Zitadel OIDC application with production. Redirect URIs include:

- `https://panel.prestonhager.com/extensions/sociallogin/callback`
- `https://test.panel.prestonhager.com/extensions/sociallogin/callback`

### Admin roles (test vs production)

| Zitadel project role | Panel | Effect |
|----------------------|-------|--------|
| `pterodactyl_admin` | Production only | `root_admin=1` on `panel.prestonhager.com` |
| `pterodactyl_test_admin` | Test only | `root_admin=1` on `test.panel.prestonhager.com` |

Both roles live in the **Home Lab** Zitadel project (`376196450586990901`). The unified `homelabGroups` complement action emits both into the OIDC `groups` claim when granted; each panel maps only its own role.

The setup scripts were removed in commit `572c200`; no Nix unit creates the role or the action. Recover them on ace (as root) when needed:

```bash
cd /etc/nixos
git show 572c200^:scripts/zitadel-pterodactyl-test-admin-setup.js > /tmp/zitadel-pterodactyl-test-admin-setup.js
git show 572c200^:scripts/zitadel-homelab-groups-action.js > /tmp/zitadel-homelab-groups-action.js

# Create role + grant prestonh
nix shell nixpkgs#nodejs_22 -c node /tmp/zitadel-pterodactyl-test-admin-setup.js

# Refresh homelabGroups action (includes pterodactyl_test_admin in groups claim)
nix shell nixpkgs#nodejs_22 -c node /tmp/zitadel-homelab-groups-action.js
```

Test panel SSO uses `ZitadelTestAdminSync` and checks `pterodactyl_test_admin` only — `pterodactyl_admin` does **not** grant admin on the test panel.

NixOS modules:

| File | Purpose |
|------|---------|
| `nixos/containers/pterodactyl-test-sso.nix` | Seed Zitadel provider, SocialiteProviders driver, test admin role sync (`pterodactyl_test_admin`) |
| `nixos/containers/pterodactyl-test.nix` | Proxy/session/debug `.env` (`TRUSTED_PROXIES`, `SESSION_*`, `APP_DEBUG`, `LOG_LEVEL`), extension secrets without the router key, Zitadel host-gateway on pod |

OAuth client ID/secret come from sops (`secrets/containers/pterodactyl-oauth.yaml`) — same credentials as production; only `ZITADEL_REDIRECT_URI` and `APP_URL` differ.

SSO redirect URL for testing:

**https://test.panel.prestonhager.com/extensions/sociallogin/redirect/zitadel**

Break-glass local login remains at `/auth/login`.

## Access

The test panel runs a work-in-progress checkout, so it is **not on the internet**: `nixos/caddy/pterodactyl.nix` wraps the vhost in the shared `lanOnly` guard (`nixos/caddy/lib.nix`), which allows ace itself, `192.168.5.0/24`, the Tailscale tailnet and WireGuard VPN clients and returns 403 to everyone else. From off-site, connect to the tailnet or the VPN first.

## CSRF / session behind Caddy

Caddy talks FastCGI to php-fpm and passes the client address as `REMOTE_ADDR` and `HTTPS=on`, so Laravel sees HTTPS without trusting forwarded headers from clients. `pterodactyl-test-env.service` enforces these values in the env file (`/var/lib/pterodactyl-test/pterodactyl.env`) on every boot, including for an env file created by an older configuration, and `pterodactyl-test-sso-configure` writes the same values:

| Variable | Value |
|----------|-------|
| `APP_URL` | `https://test.panel.prestonhager.com` |
| `APP_DEBUG` | `false` |
| `LOG_LEVEL` | `info` |
| `TRUSTED_PROXIES` | `127.0.0.1,::1,10.88.0.1` (local callers only) |
| `SESSION_DOMAIN` | `test.panel.prestonhager.com` (host-only) |
| `SESSION_COOKIE` | `pterodactyl_test_session` (distinct from production) |
| `SESSION_SECURE_COOKIE` | `true` |
| `SESSION_SAME_SITE` | `lax` |
| `SESSION_DRIVER` | `redis` |

`pterodactyl-test-laravel-env-refresh` re-runs `artisan config:clear` whenever these enforced values change.

## Extension secrets

The test panel does not get the production secrets directory. `pterodactyl-test-extensions-env.service` builds `/var/lib/pterodactyl-test/secrets` from `/pterodactyl/secrets` **without the router SSH key** (and without `PORTFORWARD_SSH_KEY_FILE`), and the container mounts that at `/pterodactyl/secrets`. The Port Forward extension's settings on the test panel are always written with `dry_run = true` (`pterodactyl-test-blueprint-extensions-configure.nix`), so the test panel can never change NAT on the router. The Technitium and Cloudflare DNS tokens are still provided for the DNS extension.

## Features on test panel

| Feature | Implementation |
|---------|----------------|
| DNS plugin (`com.prestonhager.dns`) | `plugins/pterodactyl-dns-blueprint/` → Blueprint extension `dnsrecords` |
| Zitadel SSO | Blueprint `sociallogin` + `pterodactyl-test-sso-configure.service` |
| Server install/delete DNS hooks | `OnServerInstalled` / `OnServerDeleting` listeners in extension |
| Plugin settings schema | Extension admin UI + `dnsrecords_settings` table |
| Cloudflare DNS backend | Ported in extension (Technitium backend: planned via `TECHNITIUM_API_URL` in `.blueprintrc`) |

### Not on test panel

- Port Forward extension (production only)
- PrestonHager panel fork (`feat/plugin-manager`) — removed

## NixOS modules

| File | Purpose |
|------|---------|
| `nixos/containers/pterodactyl-test.nix` | Test pod, env, Caddy bind mount, Zitadel host-gateway |
| `nixos/containers/pterodactyl-test-stock-reset.nix` | Reset test checkout to stock panel |
| `nixos/containers/pterodactyl-test-blueprint.nix` | Install upstream Blueprint + `sociallogin` + `dnsrecords` |
| `nixos/containers/pterodactyl-test-sso.nix` | Configure Zitadel OIDC provider on test panel |
| `plugins/pterodactyl-dns-blueprint/` | DNS Records Blueprint extension source |

### Service order (test panel)

```
pterodactyl-test-env
  → pterodactyl-test-panel-perms
  → pod-pterodactyl-test
  → podman-pterodactyl-test
  → pterodactyl-test-laravel-env-refresh
  → pterodactyl-test-stock-reset
  → pterodactyl-test-blueprint-install
  → pterodactyl-test-sso-configure
  → pterodactyl-test-setup
  → pterodactyl-test-public-mount
```

## Deploy (test only)

On ace:

```bash
cd /etc/nixos
# sync nixos-configs (git pull or copy)
nixos-rebuild switch --flake /etc/nixos#ace

# Re-run Blueprint/SSO if marker blocked sociallogin install:
systemctl restart pterodactyl-test-blueprint-install.service
systemctl restart pterodactyl-test-sso-configure.service

# Watch first-time migration
journalctl -u pterodactyl-test-stock-reset -u pterodactyl-test-blueprint-install -u pterodactyl-test-sso-configure -f
```

Verify SSO admin (after Zitadel role grant + sign out/in):

```bash
# prestonh should have pterodactyl_test_admin in Zitadel Authorizations
# (console → Projects → Home Lab → Authorizations, or the recovered script above)
nix shell nixpkgs#nodejs_22 -c node /tmp/zitadel-pterodactyl-test-admin-setup.js

# Sign in at https://test.panel.prestonhager.com/extensions/sociallogin/redirect/zitadel
# Admin menu should appear; production panel unchanged unless pterodactyl_admin is granted
```

Verify:

```bash
# 200 from the LAN/tailnet, 403 from anywhere else
curl -sS -o /dev/null -w '%{http_code}\n' https://test.panel.prestonhager.com/
grep -E 'TRUSTED_PROXIES|SESSION_|APP_DEBUG|LOG_LEVEL' /var/lib/pterodactyl-test/pterodactyl.env
podman exec pterodactyl-test ls /pterodactyl/secrets   # no pterodactyl-router-ssh-key
podman exec pterodactyl-test php /var/www/pterodactyl/artisan route:list | grep sociallogin
podman exec pterodactyl-test php /var/www/pterodactyl/artisan --version
runuser -u prestonh -- bash /home/prestonh/Projects/panel/blueprint.sh -info
```

Admin credentials (if fresh setup): `/var/lib/pterodactyl-test/admin-credentials`

## Related docs

- [pterodactyl-ace.md](./pterodactyl.md) — production panel
- [pterodactyl-extensions-user-guide.md](./pterodactyl-extensions-user-guide.md) — extension usage
- [dns-ace.md](../shared/dns.md) — Technitium DNS on ace
