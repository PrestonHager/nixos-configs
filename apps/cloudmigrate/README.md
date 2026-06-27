# Cloud Migrate (Nextcloud app)

Nextcloud web extension for one-time migration from **Microsoft OneDrive** and (Phase 2) **Apple iCloud** into each user's `files/Migrated/` tree.

- **App ID:** `cloudmigrate`
- **Path in repo:** `apps/cloudmigrate/`
- **Deployed to:** `/var/www/html/custom_apps/cloudmigrate` on ace

## Features

### OneDrive (Phase 1)

- Admin settings: Azure Application (client) ID, optional client secret, tenant (`common`)
- Per-user OneDrive OAuth (Microsoft Graph) — refresh tokens encrypted in Nextcloud app config
- UI: connect, browse folders, dry-run, start migration, progress
- Background queued job copies files via Graph API into `Migrated/OneDrive/` (configurable path)
- `occ cloudmigrate:run <id>` for manual job execution

### iCloud Drive (Phase 2)

- **Auth:** App-specific password per user (password encrypted via `ICrypto`; Apple ID stored in app config)
- **Engine:** Server-side **rclone** `icloud` remote with ephemeral per-job config (no credentials on disk)
- UI: connect, pick root folder or enter path, configurable destination (default `Migrated/iCloud`), dry-run, shared migration status
- Requires **rclone** in the Nextcloud container (bind-mounted on ace via `nextcloud.nix`)
- **Not yet:** iCloud Photos (`icloudpd` background job)

## Microsoft Azure app registration

1. Open [Azure Portal → App registrations](https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade)
2. **New registration**
   - Name: `Hager Cloud` or `Nextcloud Cloud Migrate` (any label)
   - Supported account types: *Accounts in any organizational directory and personal Microsoft accounts*
   - Redirect URI: **Web** → `https://cloud.prestonhager.com/apps/cloudmigrate/oauth/onedrive`
3. **Authentication** → add alternate if needed: `https://cloud.prestonhager.com/index.php/apps/cloudmigrate/oauth/onedrive`
4. **Certificates & secrets** — create a client secret if using a confidential client (optional for public/mobile flow)
5. **API permissions** → Microsoft Graph → Delegated:
   - `Files.Read`
   - `User.Read`
   - `offline_access`
6. Copy **Application (client) ID** into Nextcloud **Settings → Administration → Cloud Migrate**

### Redirect URI (exact)

Primary (ace — pretty URLs):

```
https://cloud.prestonhager.com/apps/cloudmigrate/oauth/onedrive
```

Alternate (register in Azure if Connect still fails):

```
https://cloud.prestonhager.com/index.php/apps/cloudmigrate/oauth/onedrive
```

No `/callback` suffix. Confirm the live value in admin settings.

## Enable on ace

After Nix deploy symlinks the app into `custom_apps`:

```bash
podman exec -u www-data nextcloud php /var/www/html/occ app:enable cloudmigrate
podman exec -u www-data nextcloud php /var/www/html/occ maintenance:repair
```

## iCloud (Phase 2)

Apple does **not** provide a public OAuth web flow for iCloud Drive comparable to Microsoft Graph.

| Approach | Status |
|----------|--------|
| CloudKit / Sign in with Apple | Not suitable for bulk Drive file export in a browser app |
| App-specific password | **Implemented** — encrypted per user; server-side rclone copy job |
| iCloud Photos (`icloudpd`) | Requires server background job — **not yet implemented** |

### Admin (ace)

- Deploy includes rclone bind-mounted at `/usr/local/bin/rclone` in the Nextcloud container
- Optional **rclone binary path** override in **Settings → Administration → Cloud Migrate**
- No Apple or iCloud secrets in admin settings — users enter app-specific passwords in the app UI

### User flow

1. Generate an [app-specific password](https://appleid.apple.com) for iCloud
2. **Cloud Migrate → Apple iCloud → Connect iCloud**
3. Select **All iCloud Drive files** or a folder, set destination (default `Migrated/iCloud`), dry-run optional
4. Progress appears under **Migration status** (same queue as OneDrive)

See `docs/nextcloud-cloud-migrate-app.md` for the full user guide.

## Coexistence with CLI

The operator CLI in `scripts/nextcloud-migrate/` remains available for bulk/server-side runs with sops-managed `rclone.conf`. This app uses per-user OAuth in the Nextcloud database instead.

## Security

- No OAuth secrets in git or sops (admin client ID/secret in Nextcloud system app config; user tokens encrypted with `ICrypto`)
- Copy-only semantics — no delete/sync on source clouds
