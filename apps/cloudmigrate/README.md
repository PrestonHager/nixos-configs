# Cloud Migrate (Nextcloud app)

Nextcloud web extension for one-time migration from **Microsoft OneDrive** and (Phase 2) **Apple iCloud** into each user's `files/Migrated/` tree.

- **App ID:** `cloudmigrate`
- **Path in repo:** `apps/cloudmigrate/`
- **Deployed to:** `/var/www/html/custom_apps/cloudmigrate` on ace

## Features (Phase 1)

- Admin settings: Azure Application (client) ID, optional client secret, tenant (`common`)
- Per-user OneDrive OAuth (Microsoft Graph) — refresh tokens encrypted in Nextcloud app config
- UI: connect, pick root folder, dry-run, start migration, progress
- Background queued job copies files via Graph API into `Migrated/OneDrive/Files/` (configurable subpath)
- `occ cloudmigrate:run <id>` for manual job execution

## Microsoft Azure app registration

1. Open [Azure Portal → App registrations](https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade)
2. **New registration**
   - Name: `Nextcloud Cloud Migrate` (any label)
   - Supported account types: *Accounts in any organizational directory and personal Microsoft accounts*
   - Redirect URI: **Web** → `https://cloud.prestonhager.com/index.php/apps/cloudmigrate/oauth/onedrive`
3. **Certificates & secrets** — create a client secret if using a confidential client (optional for public/mobile flow)
4. **API permissions** → Microsoft Graph → Delegated:
   - `Files.Read`
   - `User.Read`
   - `offline_access`
5. Copy **Application (client) ID** into Nextcloud **Settings → Administration → Cloud Migrate**

### Redirect URI (exact)

```
https://cloud.prestonhager.com/index.php/apps/cloudmigrate/oauth/onedrive
```

## Enable on ace

After Nix deploy symlinks the app into `custom_apps`:

```bash
podman exec -u www-data nextcloud php /var/www/html/occ app:enable cloudmigrate
podman exec -u www-data nextcloud php /var/www/html/occ maintenance:repair
```

## iCloud (Phase 2 — limitations)

Apple does **not** provide a public OAuth web flow for iCloud Drive comparable to Microsoft Graph.

| Approach | Status |
|----------|--------|
| CloudKit / Sign in with Apple | Not suitable for bulk Drive file export in a browser app |
| App-specific password | Scaffolded in UI; stored encrypted per user; server-side rclone/icloudpd job **not yet implemented** |
| iCloud Photos (`icloudpd`) | Requires server background job; cannot run in browser — deferred |

See `docs/nextcloud-cloud-migrate-app.md` for the full user guide.

## Coexistence with CLI

The operator CLI in `scripts/nextcloud-migrate/` remains available for bulk/server-side runs with sops-managed `rclone.conf`. This app uses per-user OAuth in the Nextcloud database instead.

## Security

- No OAuth secrets in git or sops (admin client ID/secret in Nextcloud system app config; user tokens encrypted with `ICrypto`)
- Copy-only semantics — no delete/sync on source clouds
