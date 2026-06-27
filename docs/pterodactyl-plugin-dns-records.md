# Pterodactyl Blueprint — DNS Records (Implementation)

**Status:** Implemented (v1.4.0)  
**Branch:** `dell-poweredge-r730xd`  
**Panel:** https://panel.prestonhager.com  
**Plan:** [pterodactyl-plugin-dns-records-plan.md](./pterodactyl-plugin-dns-records-plan.md)

---

## What was built

| Component | Path | Notes |
|-----------|------|-------|
| Blueprint extension | `plugins/pterodactyl-dns-blueprint/` | Identifier `dnsrecords` |
| Cloudflare provider | `.../Providers/CloudflareProvider.php` | Existing client refactored |
| Technitium provider | `.../Technitium/Client.php`, `TechnitiumProvider.php` | HTTP API `127.0.0.1:5380` via `host.containers.internal` |
| Provider router | `.../Providers/ProviderManager.php` | Modes: `cloudflare`, `technitium`, `both` |
| Audit log | `dnsrecords_audit_log` table | Redacted secrets |
| Allocation hook | `UpdateSrvOnAllocationJob` | Re-provisions SRV when primary allocation changes |
| Nix install | `nixos/containers/pterodactyl-blueprint.nix` | Installs on ace production panel |
| Secrets env | `nixos/containers/pterodactyl-extensions.nix` | `TECHNITIUM_API_TOKEN_FILE`, no keys in git |

### Event hooks

- `Server\Installed` → `ProvisionSrvProfilesJob`
- `Server\Deleting` → `DeleteDnsRecordsJob`
- `Server\Updated` (allocation_id changed) → `UpdateSrvOnAllocationJob`

### Admin UI

- **Admin → Extensions → DNS Records** — provider mode, Cloudflare + Technitium credentials, dry-run, SRV profiles
- **Admin → Servers → View → DNS tab** — per-server records and SRV provisioning

See **[Usage guide](./pterodactyl-extensions-user-guide.md)** for step-by-step instructions (prerequisites, server workflow, troubleshooting).

---

## Deploy

On ace after pulling this branch:

```bash
sudo nixos-rebuild switch --flake /etc/nixos#ace
sudo systemctl restart pterodactyl-blueprint-install.service
sudo podman exec pterodactyl php /var/www/pterodactyl/artisan migrate --force
```

Configure credentials in the extension admin UI or via sops-mounted env files (see Secrets below).

---

## Secrets (not in git)

| Secret | Source | Env var |
|--------|--------|---------|
| Cloudflare API token | sops `cloudflare.yaml` → `acme-env` (same as Caddy DNS-01) or admin UI | `CLOUDFLARE_API_TOKEN_FILE` |
| Technitium API token | sops `pterodactyl-technitium-api-token` or admin UI | `TECHNITIUM_API_TOKEN_FILE` |

Create Technitium API token in https://dns.prestonhager.com (dedicated API user recommended).

---

## Test case TC-DNS-1 — Technitium SRV on LAN

### Setup

1. Extension installed on production panel; provider mode `technitium` or `both`
2. Technitium token configured; default zone `prestonhager.com`
3. Test server on crux with Minecraft Java SRV profile (auto-provision enabled)
4. Dry-run **disabled**

### Execution

1. Install or re-provision a test server from admin → Servers → DNS tab → Provision selected
2. From ace or LAN client: `dig @192.168.5.5 _minecraft._tcp.<hostname>.prestonhager.com SRV +short`

### Expected deliverables

- SRV record in Technitium zone for the server hostname
- `dnsrecords_audit_log` entry with action `create`, provider `technitium`
- Per-server DNS tab shows record with provider badge

### Interpretation

| Result | Meaning |
|--------|---------|
| SRV resolves on LAN | Technitium backend working |
| NXDOMAIN | Check zone name, token permissions, infra reserved labels |
| Audit shows `dry_run` | Disable dry-run in extension settings |
| Panel cannot reach Technitium | Verify `host.containers.internal:5380` from panel pod |

### Troubleshooting

```bash
# Panel pod → Technitium
sudo podman exec pterodactyl wget -qO- http://host.containers.internal:5380/api/sso/status

# Audit log
sudo podman exec pterodactyl php artisan tinker --execute="DB::table('dnsrecords_audit_log')->orderByDesc('id')->limit(5)->get();"
```

---

## Test case TC-DNS-2 — Dual provider (both)

Same as TC-DNS-1 with provider mode `both`. Verify Cloudflare dashboard **and** `dig @192.168.5.5` both return the SRV record.

---

## Known limitations

- Manual CRUD via admin DNS tab remains Cloudflare-centric; auto-provision uses ProviderManager for both backends
- Technitium records in Nix-managed infra labels (`ace`, `crux`, `panel`, …) are blocked
- Nix `technitium-zones.nix` sync may overwrite extension records in shared zones on rebuild — prefer game-specific subdomains

---

## References

- [dns-ace.md](./dns-ace.md)
- [pterodactyl-test-blueprint.md](./pterodactyl-test-blueprint.md)
- [pterodactyl-plugin-port-forward.md](./pterodactyl-plugin-port-forward.md)
