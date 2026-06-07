# Nextcloud on ace — Log Review & Action Plan

**Updated:** 2026-06-07 (MDT)  
**Host:** ace (`192.168.5.5`)  
**URL:** https://cloud.prestonhager.com  
**Version:** 31.0.14.1 (latest 31.x patch; NC 31 is EOL — upgrade to 32+ planned separately)  
**Config:** `nixos/containers/nextcloud.nix`, `nixos/caddy/nextcloud.nix`

---

## 1. Current Status (post-fix)

| Component | Status | Evidence |
|-----------|--------|----------|
| **Nextcloud core** | ✅ Healthy | `occ status`: installed, not in maintenance, DB up to date |
| **Containers** | ✅ Healthy | All 5 pod containers up; systemd units `active` |
| **MariaDB / Redis** | ✅ Healthy | Running in pod; memcache configured; transactional locking OK |
| **ClamAV daemon** | ✅ Healthy | `PONG` on `:3310`; EICAR detected |
| **files_antivirus** | ✅ Healthy | `av_mode=daemon`, `127.0.0.1:3310`; stale `av_path` removed |
| **notify_push** | ✅ Healthy | `occ notify_push:setup` and `notify_push:self-test` all checks pass |
| **Push endpoint (HTTPS)** | ✅ Healthy | Caddy `/push/*` → `127.0.0.1:7867` |
| **Background jobs** | ✅ Fixed | `nextcloud-cron.timer` runs `cron.php` every 5 min |
| **Trusted proxies** | ✅ Fixed | `127.0.0.1`, `10.88.0.0/16` + `forwarded_for_headers` in config.php |
| **DB indices** | ✅ Fixed | `occ db:add-missing-indices` applied (vcategory, cards_properties) |
| **SMTP / email** | ✅ Working | iCloud SMTP test send OK (`prestonhager@icloud.com`, from `admin@prestonhager.com`) |
| **Setup checks** | ⚠️ Mostly clean | Log error count, whiteboard WS, NC31 EOL warning remain |
| **Third-party apps** | ⚠️ Mixed | MediaDC, richdocuments, weather_status still emit errors |

**Admin overview fixes applied 2026-06-07:**

| Issue | Resolution |
|-------|------------|
| Email failed | SMTP verified working; iCloud app password valid; automated test in `nextcloud-occ-config` |
| Brute-force / trusted proxies | Added podman bridge `10.88.0.0/16`, X-Forwarded-For/Real-IP headers |
| Background jobs stale | Added `nextcloud-cron.service` + timer calling `cron.php` (not `background:cron`) |
| WebSocket / notify_push | Already healthy; admin "WebSocket" warning is **Whiteboard** app, not push |
| Missing DB indices | Added to maintain script + applied manually |
| Email not verified | SMTP send OK; UI wizard flag set via occ |
| Version 31.0.14.1 / security F | Already on latest 31.x patch; F rating is NC 31 EOL — evaluate NC 32 upgrade |

---

## 2. ClamAV & notify_push Verification

### ClamAV

| Check | Result |
|-------|--------|
| Container `nextcloud-clamav` | Up, `podman-nextcloud-clamav.service` active |
| Daemon TCP `:3310` | `PONG` |
| `files_antivirus` mode | `daemon` / `127.0.0.1:3310` |
| Stale `av_path` | Removed via maintain script |

### notify_push

| Check | Result |
|-------|--------|
| Container `nextcloud-notify-push` | Up, listening on `:7867` in pod |
| `occ notify_push:setup https://cloud.prestonhager.com/push` | All ✓ |
| `occ notify_push:self-test` | All ✓ |
| Caddy reverse proxy | `handle_path /push/*` → `127.0.0.1:7867` |

**Note:** Admin overview "WebSocket not configured" refers to the **Whiteboard** real-time collaboration server, not notify_push. Push notifications are working.

---

## 3. Remaining Log / App Issues

| # | Severity | Message / Source | Action | Owner |
|---|----------|------------------|--------|-------|
| R1 | Low | 32 errors in log since rebuild marker | Mostly third-party apps; count drops as cron runs. Review periodically. | Monitor |
| R2 | Medium | MediaDC / Cloud_Py_API `UtilsService` missing | Disable **MediaDC** or install/repair Cloud_Py_API | **UI** |
| R3 | Medium | Whiteboard WebSocket URL not configured | Ignore (basic whiteboard works) or deploy Whiteboard WS server | **UI** / NixOS |
| R4 | Medium | richdocuments `Could not detect any host` | Set Collabora URL or disable richdocuments | **UI** |
| R5 | Low | weather_status `Undefined array key "error"` | Ignore, fix location, or disable app | **UI** |
| R6 | Low | user_saml admin template errors | Configure SAML or disable if unused | **UI** |
| R7 | Info | NC 31 security rating F | Plan upgrade to Nextcloud 32 (MariaDB 11.4 compatible) | **NixOS** |
| R8 | Low | Google Calendar / People API 403 | Enable APIs in Google Cloud or disconnect | **External** |
| R9 | Info | GitHub API errors in log | Updater rate limits; harmless unless updates fail | Monitor |

---

## 4. NixOS Changes (2026-06-07)

Applied in `nixos/containers/nextcloud.nix`:

1. **`nextcloud-cron.timer`** — runs `cron.php` every 5 minutes via systemd.
2. **`nextcloud-occ-config`** — trusted proxies, forwarded headers, overwrite host/protocol, trusted domain, background mode cron.
3. **`nextcloud-occ-config`** — one-time SMTP verification with marker file at `/stor/nextcloud/.occ-mail-test-done`.
4. **`nextcloud-occ-maintain`** — `db:add-missing-indices`, delete stale `files_antivirus av_path`.
5. **Container env** — `TRUSTED_PROXIES=127.0.0.1 10.88.0.0/16`.

---

## 5. Recommended Commands (ace)

```bash
# Status & checks
podman exec -u www-data nextcloud php /var/www/html/occ status
podman exec -u www-data nextcloud php /var/www/html/occ setupchecks
podman exec -u www-data nextcloud php /var/www/html/occ notify_push:self-test

# Cron
systemctl status nextcloud-cron.timer
podman exec -u www-data nextcloud php /var/www/html/cron.php
podman exec -u www-data nextcloud php /var/www/html/occ config:app:get core lastcron

# ClamAV
printf 'PING\n' | podman exec -i nextcloud-clamav nc 127.0.0.1 3310
podman exec -u www-data nextcloud php /var/www/html/occ files_antivirus:status

# Logs
tail -f /stor/nextcloud/data/data/nextcloud.log
journalctl -u nextcloud-cron.service -u podman-nextcloud.service -f
```

---

## 6. Manual Steps (if any remain)

| Step | Why |
|------|-----|
| Click **Send email** in Admin → Basic settings once | Clears UI-only email verification info check if still shown |
| Disable MediaDC or fix Cloud_Py_API | Stops dashboard widget errors |
| Plan Nextcloud 32 upgrade | Resolves EOL security rating (31.0.14 is latest 31.x) |
| Configure Collabora or disable richdocuments | Stops office integration errors |
| Deploy Whiteboard WS server (optional) | Only if real-time whiteboard collaboration needed |

---

## 7. Verification Results (2026-06-07)

| Check | Result |
|-------|--------|
| SMTP send test | ✅ `SEND OK` to prestonhager@icloud.com |
| `occ db:add-missing-indices` | ✅ Both indices added |
| `occ notify_push:self-test` | ✅ All checks pass |
| `cron.php` manual run | ✅ `lastcron` updated to current timestamp |
| Trusted proxies in config.php | ✅ `127.0.0.1`, `10.88.0.0/16` |
| DB missing indices setup check | ✅ None |
| Image pin `31.0.14` | ✅ Already latest 31.x on Docker Hub |
