# Cloud Migrate — Nextcloud Web App User Guide

**App ID:** `cloudmigrate`  
**Instance:** https://cloud.prestonhager.com  
**Updated:** 2026-06-27

This guide covers the **web UI** migration path. The operator CLI in `scripts/nextcloud-migrate/` remains available for bulk server-side copies with sops-managed credentials.

---

## 1. Overview

| Source | Phase 1 (web app) | Destination on Nextcloud |
|--------|-------------------|---------------------------|
| Microsoft OneDrive | OAuth + Graph API copy job | `files/Migrated/OneDrive/Files/` (or `Pictures/`) |
| Apple iCloud Drive | App-specific password + rclone copy job | `files/Migrated/iCloud/` (configurable) |
| Apple iCloud Photos | Not in browser — planned background job | `files/Migrated/iCloud/Photos/` (planned) |

Tokens and passwords are stored **per user** in the Nextcloud app database (encrypted). Nothing is committed to git or sops.

---

## 2. Register a Microsoft Azure application

1. Sign in to the [Azure Portal](https://portal.azure.com/) with a Microsoft account that can create app registrations (personal MSA is fine for OneDrive personal).
2. Go to **Microsoft Entra ID** → **App registrations** → **New registration**.  
   Direct link: [App registrations blade](https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade)
3. Configure:
   - **Name:** `Hager Cloud` or `Nextcloud Cloud Migrate` (any descriptive name)
   - **Supported account types:** *Accounts in any organizational directory and personal Microsoft accounts*
   - **Redirect URI:** Platform **Web** — see exact URIs below
4. After creation, open **Authentication** → **Web** → **Redirect URIs** and add **both** of these (ace uses pretty URLs; Azure requires an exact match):

   **Primary (required on ace):**
   ```
   https://cloud.prestonhager.com/apps/cloudmigrate/oauth/onedrive
   ```

   **Alternate (add if Connect still fails):**
   ```
   https://cloud.prestonhager.com/index.php/apps/cloudmigrate/oauth/onedrive
   ```

   There is no `/callback` suffix — the same route handles the OAuth return.

   The admin settings page (**Settings → Administration → Cloud Migrate**) shows the live redirect URI this instance sends to Microsoft. Copy that value if your hostname differs.

5. Copy the **Application (client) ID**.
6. (Optional) **Certificates & secrets** → **New client secret** — required only if you register a confidential client. Public clients can omit the secret.
7. **API permissions** → **Add a permission** → **Microsoft Graph** → **Delegated permissions**:
   - `Files.Read` (read user files)
   - `User.Read` (sign-in)
   - `offline_access` (refresh token)
8. Click **Grant admin consent** if your tenant requires it (personal accounts usually do not).

### Redirect URI mismatch (`invalid_request`)

Azure must list the **exact** URL the app sends (no trailing slash, no `/callback` suffix). On ace the primary URI is the pretty-URL form without `index.php`. Confirm the live value in **Settings → Administration → Cloud Migrate** (read-only field). If Connect still fails after adding the primary URI, register the alternate `index.php` variant from step 4 as well.

### Publisher domain verification

Azure may require verifying ownership of `prestonhager.com` before branding or certain app settings.

1. In the app registration → **Branding & properties** → **Publisher domain** → **Verify and save domain**.
2. Microsoft expects this file at the site root (served by Caddy, not Nextcloud):

   ```
   https://cloud.prestonhager.com/.well-known/microsoft-identity-association.json
   ```

3. File content (application ID must match your registration):

   ```json
   {
     "associatedApplications": [
       {
         "applicationId": "2431460d-9e91-44f4-be4d-2fddc0f00f55"
       }
     ]
   }
   ```

4. Source in this repo: `static/nextcloud/.well-known/microsoft-identity-association.json`, deployed via `nixos/caddy/nextcloud.nix`.
5. After deploy, verify:

   ```bash
   curl -s https://cloud.prestonhager.com/.well-known/microsoft-identity-association.json
   ```

6. Return to Azure and complete domain verification.

### Apple developer (iCloud — Phase 2 reference)

Apple does **not** expose iCloud Drive through a standard OAuth flow like Microsoft Graph.

- [Apple Developer Account](https://developer.apple.com/account/) — CloudKit containers apply to app data in iCloud, not bulk export of a user's Drive/Photos library via a third-party web app.
- **Sign in with Apple** authenticates the user but does not grant file-read scopes for Drive.
- **Practical fallback:** user-generated [app-specific password](https://appleid.apple.com) (stored encrypted in this Nextcloud app) for server-side `rclone` / `icloudpd` jobs — UI scaffolded; copy jobs not yet implemented.

---

## 3. Configure Nextcloud (administrator)

1. Log in as an administrator.
2. Open **Settings** → **Administration** → **Cloud Migrate**.
3. Enter:
   - **Application (client) ID** from Azure
   - **Client secret** (if created)
   - **Tenant:** `common` (personal + work/school accounts)
4. Save.

No restart required. Users can connect immediately.

---

## 4. Connect OneDrive (user)

1. Open the **Cloud Migrate** app from the Nextcloud app menu.
2. Click **Connect OneDrive**.
3. Sign in with Microsoft and consent to read files.
4. You are returned to Cloud Migrate with a success message.

Refresh tokens are encrypted and tied to your Nextcloud user only.

---

## 5. Run a migration

1. In **Cloud Migrate**, choose a **source folder** from your OneDrive root.
2. Set **destination** subpath (default `Files` → `Migrated/OneDrive/Files/`).
3. Enable **Dry run** to count files without copying.
4. Click **Start migration**.

Progress appears under **Migration status**. Large libraries run in a background job (Nextcloud cron every 5 minutes on ace, or trigger cron manually).

### Manual job (operator)

```bash
podman exec -u www-data nextcloud php /var/www/html/occ cloudmigrate:run <migration-id>
```

---

## 6. iCloud Drive migration

Apple does not expose iCloud Drive through OAuth like Microsoft Graph. This app uses an **app-specific password** (revocable at [appleid.apple.com](https://appleid.apple.com)) stored encrypted per user.

1. Open **Cloud Migrate → Apple iCloud**
2. Enter Apple ID and app-specific password → **Connect iCloud**
3. Choose **All iCloud Drive files** or a top-level folder, or type a source path (e.g. `Documents/Archive`)
4. Set **destination path** (default `Migrated/iCloud`)
5. Enable **Dry run** to count files without copying
6. Click **Start migration**

Jobs use the same **Migration status** panel and background queue as OneDrive. The server runs `rclone copy` with a temporary config; credentials are never written to git or sops.

**Administrator:** ace deploy bind-mounts rclone at `/usr/local/bin/rclone`. After NixOS deploy, recreate the Nextcloud container if rclone was added for the first time.

**Security:** Revoke the app-specific password anytime at appleid.apple.com. Never use your primary Apple ID password.

### iCloud Photos (not yet)

Bulk photo library export requires **icloudpd** on the server — planned as a separate background job.

---

## 7. Deploy / enable on ace

The app is symlinked from the Nix store into `/stor/nextcloud/data/custom_apps/cloudmigrate` by `nixos/containers/nextcloud-cloud-migrate.nix`. Deploy enables it via:

```bash
occ app:install cloudmigrate   # first time
occ app:enable cloudmigrate
```

---

## 8. Troubleshooting

| Symptom | Check |
|---------|--------|
| Connect button missing | Admin has not set Azure Client ID |
| Redirect URI mismatch | Azure redirect must match exactly (see **Redirect URI** under §2) |
| Token errors after months | Disconnect and reconnect OneDrive |
| Job stuck queued | `occ background:cron` or wait for systemd timer |
| Files not in Files app | Migration writes via Nextcloud storage API (indexed automatically) |

---

## References

- [Nextcloud Cloud Migration Plan](./nextcloud-cloud-migration-plan.md) — overall strategy
- [App README](../apps/cloudmigrate/README.md) — developer notes
- [Microsoft Graph files API](https://learn.microsoft.com/en-us/graph/api/resources/onedrive)
