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

- **Auth:** Apple ID + **regular Apple ID password** + one-time **2FA** (rclone `iclouddrive` trust token, ~30 days)
- **Engine:** Server-side **rclone** `iclouddrive` remote; trust token + cookies encrypted in Nextcloud app config
- UI: save credentials → **Start sign-in** → enter 2FA code → browse folders, dry-run, migrate
- Requires **rclone** v1.74+ in the Nextcloud container (static binary bind-mounted on ace via `nextcloud.nix`)
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
| rclone `iclouddrive` (Apple ID + 2FA trust token) | **Implemented** — web UI + `occ cloudmigrate:icloud-auth` |
| App-specific password | **Not supported** by rclone 1.74 iclouddrive |
| iCloud Photos (`icloudpd`) | Requires server background job — **not yet implemented** |

### First-time iCloud sign-in (user)

1. Open **Cloud Migrate → Apple iCloud**
2. Enter **Apple ID** and your **regular Apple ID password** (not an app-specific password)
3. Click **Save credentials**, then **Start sign-in**
4. Approve the sign-in on a trusted Apple device, or type `sms` in the 2FA field for a text message
5. Enter the 6-digit code → **Submit code**
6. When status shows signed in, pick a source folder and run a dry run or migration

Trust tokens expire after ~30 days. Repeat steps 3–5 if folder listing or migration fails with a trust-token error.

### First-time iCloud sign-in (server console)

If the web 2FA step fails, run on ace as the Nextcloud user:

```bash
podman exec -u www-data nextcloud php /var/www/html/occ cloudmigrate:icloud-auth YOUR_UID
```

Replace `YOUR_UID` with your Nextcloud username. Enter the 2FA code when prompted.

### Admin (ace)

- Deploy includes static rclone at `/usr/local/bin/rclone` in the Nextcloud container
- Optional **rclone binary path** override in **Settings → Administration → Cloud Migrate**
- No Apple secrets in admin settings — users store credentials encrypted in the app

See `docs/nextcloud-cloud-migrate-app.md` for the full user guide.

## Coexistence with CLI

The operator CLI in `scripts/nextcloud-migrate/` remains available for bulk/server-side runs with sops-managed `rclone.conf`. This app uses per-user OAuth in the Nextcloud database instead.

## Security

- No OAuth secrets in git or sops (admin client ID/secret in Nextcloud system app config; user tokens encrypted with `ICrypto`)
- Copy-only semantics — no delete/sync on source clouds
