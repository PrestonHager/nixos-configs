# Migration: DNS-Plugin → Blueprint `dnsrecords`

This document covers moving from the custom **Plugin Manager** extension (`com.prestonhager.dns`) on the PrestonHager panel fork to the Blueprint extension in this directory.

## What changed

| Topic | Old (Plugin Manager) | New (Blueprint) |
|-------|----------------------|-----------------|
| Panel | PrestonHager/panel `feat/plugin-manager` | Stock Pterodactyl + Blueprint |
| Plugin id | `com.prestonhager.dns` | Blueprint identifier `dnsrecords` |
| Install | Admin → Plugins → Install from Git | Admin → Extensions → install Blueprint package |
| Settings | Admin → Plugins → DNS Records → Settings | Admin → Extensions → DNS Records |
| Admin DNS UI | Admin server view tab (patched panel) | Admin server view **DNS** tab via `admin/wrapper.blade.php` |
| Client DNS tab | `/server/{uuid}/dns` (optional) | **Removed** — admin-only by design |
| HTTP API prefix | `/api/plugins/com.prestonhager.dns/...` | `/extensions/dnsrecords/admin/servers/{id}/...` |
| Plugin config storage | `plugins.config` (encrypted JSON) | `dnsrecords_settings` table |
| Per-server state | `plugin_data` table | `dnsrecords_data` table |
| Lifecycle hooks | `plugin.json` hooks | Laravel `Installed` / `Deleting` events |

## Pre-migration checklist

1. Export Cloudflare-related settings from the old plugin (token, zone ID, base domain, `srv_profiles` JSON).
2. Note which servers have active DNS state (hostname labels, SRV profiles, tracked records).
3. Plan a maintenance window — disable the old plugin before enabling the Blueprint extension to avoid duplicate auto-provision jobs.

## Install steps

1. Deploy stock panel + Blueprint (see workstream 1 / production panel docs).
2. **Disable and uninstall** `com.prestonhager.dns` from the old plugin manager (if still present).
3. Install this Blueprint extension (`dnsrecords`).
4. Re-enter settings under **Admin → Extensions → DNS Records**.
5. Verify the **DNS** tab on an admin server page.

## Data migration (optional)

If you need to preserve per-server DNS state from the old `plugin_data` rows:

```sql
-- Example: copy dns_state blobs from legacy plugin_data into dnsrecords_data
INSERT INTO dnsrecords_data (scope, subject_id, `key`, value, created_at, updated_at)
SELECT 'server', subject_id, `key`, value, created_at, updated_at
FROM plugin_data
WHERE plugin_id = 'com.prestonhager.dns'
  AND subject_type = 'server'
  AND `key` IN ('dns_state', 'plugin_settings')
ON DUPLICATE KEY UPDATE value = VALUES(value), updated_at = VALUES(updated_at);
```

Migrate encrypted admin config manually (Blueprint stores settings in `dnsrecords_settings`; Cloudflare token must be re-entered in the extension admin UI unless you write a one-off import script).

## Configuration mapping

Legacy JSON keys map 1:1 to Blueprint settings keys:

- `cloudflare_api_token`
- `zone_id`
- `base_domain`
- `auto_provision_enabled`
- `default_ttl`
- `srv_profiles`
- `primary_domains`
- `subdomain_generation`, `client_subdomain_policy`, etc.

See `settings.schema.json` for the full list.

## Rollback

1. Disable/remove Blueprint extension `dnsrecords`.
2. Re-enable the legacy plugin on the forked panel (test environment only).
3. Restore `plugin_data` from backup if you migrated rows.

## Verification

- [ ] Extension admin page saves Cloudflare settings without error
- [ ] Admin server **DNS** tab loads records and SRV profiles
- [ ] New server install creates auto-provision records (when enabled)
- [ ] Server delete removes tracked Cloudflare records
- [ ] Client route `/server/{uuid}/dns` returns 404 (expected for admin-only mode)

## Related repos

- Legacy plugin: https://github.com/PrestonHager/Pterodactyl-DNS-Plugin
- Panel fork (deprecated for prod): https://github.com/PrestonHager/panel (`feat/plugin-manager`)
