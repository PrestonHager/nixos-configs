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

Setup scripts (run on ace as root):

```bash
# Create role + grant prestonh
nix shell nixpkgs#nodejs_22 -c node scripts/zitadel-pterodactyl-test-admin-setup.js

# Refresh homelabGroups action (includes pterodactyl_test_admin in groups claim)
nix shell nixpkgs#nodejs_22 -c node scripts/zitadel-homelab-groups-action.js
```

Test panel SSO uses `ZitadelTestAdminSync` and checks `pterodactyl_test_admin` only — `pterodactyl_admin` does **not** grant admin on the test panel.

NixOS modules:

| File | Purpose |
|------|---------|
| `nixos/containers/pterodactyl-test-sso.nix` | Seed Zitadel provider, SocialiteProviders driver, test admin role sync (`pterodactyl_test_admin`) |
| `nixos/containers/pterodactyl-test.nix` | Proxy/session `.env` (`TRUSTED_PROXIES`, `SESSION_*`), Zitadel host-gateway on pod |

OAuth client ID/secret come from sops (`secrets/containers/pterodactyl-oauth.yaml`) — same credentials as production; only `ZITADEL_REDIRECT_URI` and `APP_URL` differ.

SSO redirect URL for testing:

**https://test.panel.prestonhager.com/extensions/sociallogin/redirect/zitadel**

Break-glass local login remains at `/auth/login`.

## CSRF / session behind Caddy

Laravel must trust Caddy as a reverse proxy. The test panel env file (`/var/lib/pterodactyl-test/pterodactyl.env`) sets:

| Variable | Value |
|----------|-------|
| `APP_URL` | `https://test.panel.prestonhager.com` |
| `TRUSTED_PROXIES` | `*` |
| `SESSION_DOMAIN` | `.prestonhager.com` |
| `SESSION_SECURE_COOKIE` | `true` |
| `SESSION_SAME_SITE` | `lax` |
| `SESSION_DRIVER` | `redis` |

Without `TRUSTED_PROXIES`, Laravel treats requests as HTTP and CSRF/session cookies fail behind HTTPS Caddy.

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
nix shell nixpkgs#nodejs_22 -c node scripts/zitadel-pterodactyl-test-admin-setup.js

# Sign in at https://test.panel.prestonhager.com/extensions/sociallogin/redirect/zitadel
# Admin menu should appear; production panel unchanged unless pterodactyl_admin is granted
```

Verify:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://test.panel.prestonhager.com/
grep -E 'TRUSTED_PROXIES|SESSION_' /var/lib/pterodactyl-test/pterodactyl.env
podman exec pterodactyl-test php /var/www/pterodactyl/artisan route:list | grep sociallogin
podman exec pterodactyl-test php /var/www/pterodactyl/artisan --version
runuser -u prestonh -- bash /home/prestonh/Projects/panel/blueprint.sh -info
```

Admin credentials (if fresh setup): `/var/lib/pterodactyl-test/admin-credentials`

## Related docs

- [pterodactyl-ace.md](./pterodactyl.md) — production panel
- [pterodactyl-extensions-user-guide.md](./pterodactyl-extensions-user-guide.md) — extension usage
- [dns-ace.md](../shared/dns.md) — Technitium DNS on ace
