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
| Apple iCloud Drive | Scaffold only (app-specific password UI) | `files/Migrated/iCloud/Drive/` (planned) |
| Apple iCloud Photos | Not in browser — planned background job | `files/Migrated/iCloud/Photos/` (planned) |

Tokens and passwords are stored **per user** in the Nextcloud app database (encrypted). Nothing is committed to git or sops.

---

## 2. Register a Microsoft Azure application

1. Sign in to the [Azure Portal](https://portal.azure.com/) with a Microsoft account that can create app registrations (personal MSA is fine for OneDrive personal).
2. Go to **Microsoft Entra ID** → **App registrations** → **New registration**.  
   Direct link: [App registrations blade](https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade)
3. Configure:
   - **Name:** `Nextcloud Cloud Migrate` (any descriptive name)
   - **Supported account types:** *Accounts in any organizational directory and personal Microsoft accounts*
   - **Redirect URI:** Platform **Web**, URL:
     ```
     https://cloud.prestonhager.com/index.php/apps/cloudmigrate/oauth/onedrive
     ```
4. After creation, copy the **Application (client) ID**.
5. (Optional) **Certificates & secrets** → **New client secret** — required only if you register a confidential client. Public clients can omit the secret.
6. **API permissions** → **Add a permission** → **Microsoft Graph** → **Delegated permissions**:
   - `Files.Read` (read user files)
   - `User.Read` (sign-in)
   - `offline_access` (refresh token)
7. Click **Grant admin consent** if your tenant requires it (personal accounts usually do not).

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

## 6. iCloud (Phase 2 scaffold)

The iCloud section shows:

- Honest limitation: no public Drive OAuth for web apps.
- Optional **app-specific password** form — credentials saved encrypted; **no copy job yet**.
- Badge: Drive via server-side rclone and Photos via icloudpd — coming in Phase 2.

**Security note:** App-specific passwords can be revoked anytime at appleid.apple.com. Prefer this over storing your primary Apple ID password.

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
| Redirect URI mismatch | Azure redirect must match exactly (see §2) |
| Token errors after months | Disconnect and reconnect OneDrive |
| Job stuck queued | `occ background:cron` or wait for systemd timer |
| Files not in Files app | Migration writes via Nextcloud storage API (indexed automatically) |

---

## References

- [Nextcloud Cloud Migration Plan](./nextcloud-cloud-migration-plan.md) — overall strategy
- [App README](../apps/cloudmigrate/README.md) — developer notes
- [Microsoft Graph files API](https://learn.microsoft.com/en-us/graph/api/resources/onedrive)
