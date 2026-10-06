# Nextcloud cloud migration (OneDrive, iCloud)

Migrate files and photos from cloud providers into [Nextcloud on ace](https://cloud.prestonhager.com) using **rclone** and **icloudpd**. Credentials live in **sops**, never in git.

## Layout

```
scripts/nextcloud-migrate/
├── migrate.py              # unified CLI (onedrive, icloud, config, status)
├── migrate.sh              # wrapper → migrate.py
├── default.nix               # nix package with rclone, icloudpd, podman
├── lib/                      # shared: config, logging, WebDAV, occ scan, rclone, state
├── onedrive/                 # OneDrive files + photos (rclone OAuth → WebDAV)
├── icloud/                   # iCloud Drive (rclone) + Photos (icloudpd → rclone)
├── rclone.conf.example
├── env.example
└── icloudpd.conf.example
```

## Quick start

```bash
# Local templates (~/.config/nextcloud-migrate/)
python3 scripts/nextcloud-migrate/migrate.py config init

# Preview migrations
python3 scripts/nextcloud-migrate/migrate.py onedrive files --dry-run
python3 scripts/nextcloud-migrate/migrate.py onedrive photos --dry-run
python3 scripts/nextcloud-migrate/migrate.py icloud files --dry-run
python3 scripts/nextcloud-migrate/migrate.py icloud photos --dry-run

# Status (paths + last job JSON)
python3 scripts/nextcloud-migrate/migrate.py status
```

On ace via Nix: `nix run .#nextcloud-migrate -- onedrive files --dry-run` (after wiring `default.nix` in flake).

## Prerequisites on ace

- `rclone`, `podman`, `python3` (and `icloudpd` for iCloud photos)
- Nextcloud running (`podman ps | grep nextcloud`)
- Nextcloud **app password** for the target user (Settings → Security)
- Env file: `/run/secrets/nextcloud-migrate-env` (sops) or `--env-file` / `~/.config/nextcloud-migrate/env`

WebDAV URL (from `nixos/containers/nextcloud.nix`):

`https://cloud.prestonhager.com/remote.php/dav/files/<user>/`

---

## OneDrive OAuth (workstation → ace)

OAuth requires a browser. Authorize on your workstation, copy the token to ace.

### 1. Authorize on workstation

```bash
rclone version

# Interactive (opens browser)
rclone config create onedrive-work onedrive

# Headless: prints token JSON to paste on ace
rclone authorize "onedrive"
```

Collect `access_token`, `refresh_token`, `expiry`, and after first list, `drive_id` (`rclone lsd onedrive-work:`).

### 2. rclone.conf on ace (not in git)

```bash
sudo install -d -m 0700 /run/nextcloud-migrate
sudo cp scripts/nextcloud-migrate/rclone.conf.example /run/nextcloud-migrate/rclone.conf
sudo chmod 0600 /run/nextcloud-migrate/rclone.conf
```

Edit `/run/nextcloud-migrate/rclone.conf`:

1. Paste OneDrive `token = {...}` and set `drive_id` / `drive_type = personal`.
2. Set Nextcloud WebDAV `url`, `user`, and obscured `pass`:

```bash
rclone obscure 'your-nextcloud-app-password'
```

Test:

```bash
export RCLONE_CONFIG=/run/nextcloud-migrate/rclone.conf
rclone lsd onedrive:
rclone lsd nextcloud:
```

### 3. sops env (nixos-secrets)

```yaml
nextcloud-migrate-env: |
  RCLONE_CONFIG=/run/nextcloud-migrate/rclone.conf
  NEXTCLOUD_USER=prestonhager
  NEXTCLOUD_URL=https://cloud.prestonhager.com
```

Store the OneDrive token in `rclone.conf` on ace only — never commit it.

---

## OneDrive usage

```bash
# Files (excludes Pictures/Photos by default → use photos subcommand for those)
python3 scripts/nextcloud-migrate/migrate.py onedrive files --dry-run
python3 scripts/nextcloud-migrate/migrate.py onedrive files --path Documents/Archive

# Camera roll / Pictures → Nextcloud Photos/
python3 scripts/nextcloud-migrate/migrate.py onedrive photos --dry-run
python3 scripts/nextcloud-migrate/migrate.py onedrive photos
```

### Photo path mapping (OneDrive → Nextcloud Photos)

| OneDrive source | Nextcloud destination |
|-----------------|----------------------|
| `Pictures/Camera Roll` | `Photos/Camera Roll` |
| `Pictures` (excl. Camera Roll) | `Photos` |
| `Photos` | `Photos` |
| `Camera Roll` | `Photos/Camera Roll` |

Override: `ONEDRIVE_PHOTO_MAPPINGS=source:dest,...` in env.

### Files defaults

- Destination: `OneDrive/` in Nextcloud Files
- Excludes: `Pictures/**`, `Photos/**`, `Camera Roll/**`

---

## iCloud usage

iCloud Drive uses rclone `[icloud]` remote (app-specific password on Linux). Photos use **icloudpd** download → rclone upload.

```bash
python3 scripts/nextcloud-migrate/migrate.py icloud files --dry-run
python3 scripts/nextcloud-migrate/migrate.py icloud files --since 2024-01-01
python3 scripts/nextcloud-migrate/migrate.py icloud photos --dry-run
python3 scripts/nextcloud-migrate/migrate.py icloud photos --album "Family Trip"
```

Env keys: `ICLOUD_APPLE_ID`, `ICLOUD_PASSWORD`, `ICLOUD_FILES_DEST`, `ICLOUD_PHOTOS_DEST`. See `env.example` and `icloudpd.conf.example`.

---

## Shared library

| Module | Purpose |
|--------|---------|
| `lib/config.py` | Load sops env, `--env-file`, or `~/.config/nextcloud-migrate/env` |
| `lib/log.py` | Timestamped logs, `[DRY-RUN]` prefix |
| `lib/nextcloud.py` | `webdav_url()`, `files_scan()` via `podman exec … occ files:scan` |
| `lib/rclone.py` | Run rclone with `RCLONE_CONFIG`, honor `--dry-run` |
| `lib/state.py` | Job state for `migrate.py status` |

After each migration, `occ files:scan` runs for the affected path (skipped in `--dry-run`).

## Troubleshooting

- **401 nextcloud remote**: Regenerate app password; WebDAV URL must end with `/files/<user>/`.
- **OneDrive token expired**: Re-run `rclone authorize "onedrive"` on workstation; update token in rclone.conf.
- **Photos missing in Nextcloud app**: Files must be under `Photos/`; run `occ files:scan <user> --path=<user>/files/Photos`.
- **iCloud 2FA on Linux**: Use an [app-specific password](https://support.apple.com/en-us/102654) in `ICLOUD_PASSWORD`.
