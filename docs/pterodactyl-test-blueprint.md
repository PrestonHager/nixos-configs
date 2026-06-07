# Test panel Blueprint fork (test.panel.prestonhager.com)

Architecture and deployment notes for the **test** Pterodactyl panel using a forked Blueprint framework with DNS extension support. Production (`panel.prestonhager.com`) is configured separately and uses upstream Blueprint.

## Overview

| Component | Test panel | Production panel |
|-----------|------------|------------------|
| URL | https://test.panel.prestonhager.com | https://panel.prestonhager.com |
| Panel source | Stock [pterodactyl/panel](https://github.com/pterodactyl/panel) `release/v1.11.11` | Stock `release/v1.11.11` |
| Extension framework | **[PrestonHager/framework](https://github.com/PrestonHager/framework)** branch `feat/prestonhager-plugin-manager` | [BlueprintFramework/framework](https://github.com/BlueprintFramework/framework) |
| DNS | `dnsrecords` Blueprint extension | (not on test workstream scope) |
| SSO | Local admin login (no oauth2-proxy) | Blueprint Social Login + Zitadel |

The test panel previously ran the full panel fork (`PrestonHager/panel` branch `feat/plugin-manager`) with a native PHP plugin system. That approach is replaced by **stock panel + forked Blueprint + Blueprint extensions**.

## Fork URL

**https://github.com/PrestonHager/framework** (branch: `feat/prestonhager-plugin-manager`)

Tracked in this repo via flake input:

```nix
blueprint-framework = {
  url = "github:PrestonHager/framework/feat/prestonhager-plugin-manager";
  flake = false;
};
```

Runtime sync uses git clone to `/var/lib/pterodactyl-test/blueprint-framework` (see `nixos/containers/pterodactyl-test-blueprint.nix`).

### Blueprint install order (test panel)

Same pattern as production, then fork upgrade:

1. **Upstream** `BlueprintFramework/framework` `release.zip` — full framework tree for `blueprint.sh` first-time install
2. **`blueprint.sh`** first-time install (as root; panel owned by `prestonh`, ACL cleanup via `runuser -u prestonh`)
3. **`blueprint -upgrade remote PrestonHager/framework`** — fork framework
4. **Git archive overlay** — fork-specific PHP patches not covered by upgrade
5. **Build/install** `dnsrecords` extension from `plugins/pterodactyl-dns-blueprint/`

Do not bootstrap from the fork archive before step 3; partial fork files leave a broken `.blueprint` tree (missing `assets/`, `private/db/is_installed`, etc.).

## Features ported from panel fork

Source: `PrestonHager/panel` branch `feat/plugin-manager` (~113 commits, native plugin API v3.0).

| Panel fork feature | Blueprint / extension implementation |
|--------------------|--------------------------------------|
| `GitHubPluginInstaller` | `blueprint -install-github owner/repo [ref]` |
| Bulk plugin upgrade | `blueprint -upgrade-all` |
| Commit SHA / source tracking | `.blueprint/.../github_sources` registry |
| DNS plugin (`com.prestonhager.dns`) | `plugins/pterodactyl-dns-blueprint/` → Blueprint extension `dnsrecords` |
| Server install/delete DNS hooks | `OnServerInstalled` / `OnServerDeleting` listeners in extension |
| Plugin settings schema | Extension admin UI + `dnsrecords_settings` table |
| Cloudflare DNS backend | Ported in extension (Technitium backend: planned via `TECHNITIUM_API_URL` in `.blueprintrc`) |
| Panel git fork auto-update | Removed; test uses stock panel + `blueprint -upgrade remote PrestonHager/framework` |
| Subuser plugin permissions | Blueprint client API routes (extension-level auth) |
| Plugin theme overlay | Blueprint admin/dashboard wrappers |

### Not ported (by design)

- Entire native `PluginManager` PHP stack — replaced by Blueprint extension model
- `com.prestonhager.builder` plugin — install separately via `-install-github` when a Blueprint port exists
- oauth2-proxy header auth — production uses Blueprint Social Login instead

## NixOS modules

| File | Purpose |
|------|---------|
| `nixos/containers/pterodactyl-test.nix` | Test pod, env, Caddy bind mount |
| `nixos/containers/pterodactyl-test-stock-reset.nix` | Reset test checkout from panel fork → stock panel |
| `nixos/containers/pterodactyl-test-blueprint.nix` | Apply forked Blueprint + build/install `dnsrecords` |
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
runuser -u pterodactyl -- bash /home/prestonh/Projects/panel/blueprint.sh -info
```

Admin credentials (if fresh setup): `/var/lib/pterodactyl-test/admin-credentials`

## Fork diff from upstream Blueprint

See [PrestonHager/framework PRESTONHAGER.md](https://github.com/PrestonHager/framework/blob/feat/prestonhager-plugin-manager/PRESTONHAGER.md):

- `scripts/commands/extensions/install-github.sh` — GitHub URL extension install
- `scripts/commands/extensions/upgrade-all.sh` — bulk extension upgrade
- `.blueprintrc.prestonhager.example` — homelab defaults (Technitium URL, fork remote)
- CLI help/completion updates in `blueprint.sh` and `help.sh`

## Related docs

- [pterodactyl-ace.md](./pterodactyl-ace.md) — production panel (oauth2-proxy era; being migrated by separate workstream)
- [dns-ace.md](./dns-ace.md) — Technitium DNS on ace
