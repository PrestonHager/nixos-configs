# Test panel Blueprint (test.panel.prestonhager.com)

Architecture and deployment notes for the **test** Pterodactyl panel using upstream Blueprint with DNS extension support. Production (`panel.prestonhager.com`) uses the same upstream Blueprint pattern.

## Overview

| Component | Test panel | Production panel |
|-----------|------------|------------------|
| URL | https://test.panel.prestonhager.com | https://panel.prestonhager.com |
| Panel source | Stock [pterodactyl/panel](https://github.com/pterodactyl/panel) `release/v1.11.11` | Stock `release/v1.11.11` |
| Extension framework | [BlueprintFramework/framework](https://github.com/BlueprintFramework/framework) | Same |
| DNS | `dnsrecords` Blueprint extension | `dnsrecords` + Social Login |
| SSO | Local admin login (no Zitadel) | Blueprint Social Login + Zitadel |

The test panel uses **stock panel + upstream Blueprint + Blueprint extensions** (same model as production).

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
3. **Install** `dnsrecords` via `blueprint -install '[developer-build]'` from `plugins/pterodactyl-dns-blueprint/`

Do not pre-move `panel/blueprint` into `.blueprint/blueprint` before step 2 — `blueprint.sh` must perform that relocation itself.

## Features on test panel

| Feature | Implementation |
|---------|----------------|
| DNS plugin (`com.prestonhager.dns`) | `plugins/pterodactyl-dns-blueprint/` → Blueprint extension `dnsrecords` |
| Server install/delete DNS hooks | `OnServerInstalled` / `OnServerDeleting` listeners in extension |
| Plugin settings schema | Extension admin UI + `dnsrecords_settings` table |
| Cloudflare DNS backend | Ported in extension (Technitium backend: planned via `TECHNITIUM_API_URL` in `.blueprintrc`) |

### Not on test panel

- Blueprint Social Login / Zitadel SSO (production only)
- PrestonHager panel fork (`feat/plugin-manager`) — removed

## NixOS modules

| File | Purpose |
|------|---------|
| `nixos/containers/pterodactyl-test.nix` | Test pod, env, Caddy bind mount |
| `nixos/containers/pterodactyl-test-stock-reset.nix` | Reset test checkout to stock panel |
| `nixos/containers/pterodactyl-test-blueprint.nix` | Install upstream Blueprint + `dnsrecords` |
| `plugins/pterodactyl-dns-blueprint/` | DNS Records Blueprint extension source |

### Service order (test panel)

```
pterodactyl-test-env
  → pterodactyl-test-panel-perms
  → podman-pterodactyl-test
  → pterodactyl-test-stock-reset
  → pterodactyl-test-blueprint-install
  → pterodactyl-test-setup
  → pterodactyl-test-public-mount
```

## Deploy (test only)

On ace:

```bash
cd /etc/nixos
# sync nixos-configs (git pull or copy)
nixos-rebuild switch --flake /etc/nixos#ace

# Watch first-time migration
journalctl -u pterodactyl-test-stock-reset -u pterodactyl-test-blueprint-install -f
```

Verify:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://test.panel.prestonhager.com/
podman exec pterodactyl-test php /var/www/pterodactyl/artisan --version
runuser -u prestonh -- bash /home/prestonh/Projects/panel/blueprint.sh -info
```

Admin credentials (if fresh setup): `/var/lib/pterodactyl-test/admin-credentials`

## Related docs

- [pterodactyl-ace.md](./pterodactyl-ace.md) — production panel
- [dns-ace.md](./dns-ace.md) — Technitium DNS on ace
