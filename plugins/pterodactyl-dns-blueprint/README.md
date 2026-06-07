# DNS Records — Blueprint extension

Blueprint-compatible port of [PrestonHager/Pterodactyl-DNS-Plugin](https://github.com/PrestonHager/Pterodactyl-DNS-Plugin) for stock Pterodactyl + [Blueprint](https://blueprint.zip).

## Location

| Item | Path |
|------|------|
| Source (this repo) | `plugins/pterodactyl-dns-blueprint/` |
| Blueprint identifier | `dnsrecords` |
| Legacy plugin id (data migration) | `com.prestonhager.dns` |
| Upstream DNS logic | https://github.com/PrestonHager/Pterodactyl-DNS-Plugin |

## Features

- Cloudflare DNS CRUD (A, AAAA, CNAME, MX, TXT, SRV)
- SRV profiles (Minecraft Java/Bedrock, Factorio, custom games)
- Auto-provision A + SRV on server install
- Cleanup on server delete
- **Admin-only** DNS tab on `/admin/servers/view/{id}` (no client `/server/{uuid}/dns` route)
- Vanity hostnames, custom domain verification, nameserver delegation

## Requirements

- Pterodactyl Panel **1.11.x** (tested target: Blueprint `beta-2025-09`)
- [Blueprint](https://blueprint.zip) installed and enabled
- Outbound HTTPS to `api.cloudflare.com`
- Cloudflare API token with **Zone.DNS Edit** and **Zone.Zone Read**

## Install via Blueprint

1. Copy or symlink this directory into your panel, or build a release zip from it.
2. On the panel host (inside the Pterodactyl root, e.g. `/var/www/pterodactyl` or `/pterodactyl/html`):

   ```bash
   # Option A: install from git checkout on the server
   cp -a /path/to/nixos-configs/plugins/pterodactyl-dns-blueprint ./dnsrecords.blueprint

   # Option B: zip and upload in Admin → Extensions
   cd plugins/pterodactyl-dns-blueprint && zip -r ../dnsrecords.blueprint.zip .
   ```

3. Admin → **Extensions** → install **DNS Records** (`dnsrecords`).
4. Blueprint runs migrations (`dnsrecords_settings`, `dnsrecords_data`).
5. Open **Admin → Extensions → DNS Records** and configure Cloudflare token, zone ID, base domain, and SRV profiles.
6. Open **Admin → Servers → View server** — use the **DNS** tab.

### Rebuild after source changes

With Blueprint developer mode enabled:

```bash
cd /var/www/pterodactyl   # or your panel path
blueprint -build
php artisan migrate --force
php artisan optimize:clear
```

## Development workflow

1. Edit files under `plugins/pterodactyl-dns-blueprint/` in this repo.
2. Copy/sync to the panel `.blueprint/extensions/dnsrecords/` dev tree or rebuild from checkout.
3. Run `blueprint -build` on the panel.
4. Test on **test.panel** first (production deploy is handled separately).

### Layout

```
conf.yml                 # Blueprint manifest
admin/                   # Extension settings UI + admin server tab wrapper
app/                     # PHP (symlinked into panel by Blueprint)
routes/                  # application, client, web routers
database/migrations/     # settings + per-server state tables
public/dns-admin.js      # Admin server DNS tab UI
settings.schema.json     # Field reference (from legacy settings.json)
```

### API routes (admin UI)

Session-authenticated web routes (used by the admin DNS tab):

```
/extensions/dnsrecords/admin/servers/{serverId}/records
/extensions/dnsrecords/admin/servers/{serverId}/srv-profiles
/extensions/dnsrecords/admin/servers/{serverId}/subdomain
...
```

Application API (optional automation):

```
/api/application/extensions/dnsrecords/servers/{server}/records
```

## Migration from DNS-Plugin

See [MIGRATION.md](./MIGRATION.md).

## License

MIT (same as upstream DNS plugin).
