# Nextcloud on ace — Log Review & Action Plan

**Generated:** 2026-06-06 (MDT)  
**Host:** ace (`192.168.5.5`)  
**URL:** https://cloud.prestonhager.com  
**Version:** 31.0.14.1  
**Config:** `nixos/containers/nextcloud.nix`, `nixos/caddy/nextcloud.nix`

---

## 1. Current Status

| Component | Status | Evidence |
|-----------|--------|----------|
| **Nextcloud core** | ✅ Healthy | `occ status`: installed, not in maintenance, DB up to date |
| **Containers** | ✅ Healthy | All 5 pod containers up ~30 min (post-rebuild); systemd units `active` |
| **MariaDB / Redis** | ✅ Healthy | Running in pod; memcache configured; transactional locking OK |
| **ClamAV daemon** | ✅ Healthy | `PONG` on `:3310`; EICAR detected; signatures 1.5.2/28023 |
| **files_antivirus** | ✅ Healthy (now) | `av_mode=daemon`, `av_host=127.0.0.1`, `av_port=3310`; 203 unscanned files queued |
| **notify_push** | ✅ Healthy | `occ notify_push:setup` and `notify_push:self-test` all checks pass |
| **Push endpoint (HTTPS)** | ✅ Healthy | Caddy `/push/*` → `127.0.0.1:7867`; setup tests return 200 |
| **Desktop sync** | ✅ Healthy | mirall client PROPFIND/204 observed in Apache logs |
| **Setup checks** | ⚠️ Degraded | 14 errors since rebuild marker; whiteboard WS missing; 2 DB index warnings |
| **SMTP / email** | ❌ Broken | All mail test attempts fail (TransportException) |
| **Third-party apps** | ⚠️ Mixed | MediaDC, user_saml, richdocuments, weather_status emit errors |

**Log summary** (`/stor/nextcloud/data/data/nextcloud.log`, 628 lines total):

| Level | Count |
|-------|------:|
| DEBUG | 437 |
| INFO | 139 |
| WARN | 11 |
| ERROR | 41 |

Since rebuild marker (`2026-06-06T06:38:43`): **14 errors** (matches Admin → Overview). After container restart + `nextcloud-occ-maintain` (`07:05`): **1 error** (SMTP test only). Antivirus upload failures were **pre-restart only**.

---

## 2. ClamAV & notify_push Verification

### ClamAV

| Check | Result |
|-------|--------|
| Container `nextcloud-clamav` | Up, `podman-nextcloud-clamav.service` active |
| Daemon TCP `:3310` | `PONG` |
| `clamdscan /etc/hosts` | OK |
| EICAR test string | `Eicar-Signature FOUND` |
| `occ files_antivirus:status` | 203 unscanned files, 0 scheduled re-scan |
| `files_antivirus` mode | `daemon` / `127.0.0.1:3310` |

**Note:** At `06:38:43` (before maintain/restart), uploads failed because ClamAV was not yet reachable and `av_path` still pointed at `/usr/bin/clamscan` (missing in the Nextcloud container). `nextcloud-occ-maintain` set daemon mode at `07:05`; no antivirus errors since.

**Container log quirk:** `LibClamAV Error: cl_statdbdir(): Can't open directory /var/lib/clamav` during self-check — database volume is mounted at `/var/lib/clamav` but clamd uses a different internal path. Self-check still reports **Database status OK**. Harmless; monitor only.

### notify_push

| Check | Result |
|-------|--------|
| Container `nextcloud-notify-push` | Up, listening on `:7867` in pod |
| `occ notify_push:setup https://cloud.prestonhager.com/push` | All ✓ (redis, DB, trusted proxy, version match) |
| `occ notify_push:self-test` | All ✓ |
| Caddy reverse proxy | `handle_path /push/*` → `127.0.0.1:7867` |
| Startup WARN | One-time slow DB pool acquire (2.56s > 2.0s threshold) at container start |

**WebSocket self-test:** `curl` HTTP/2 upgrade to `wss://cloud.prestonhager.com/push/ws` is inconclusive (HTTP/2 rejects `Connection: Upgrade`). Official `occ` tests confirm end-to-end push path. Real-time push from desktop client is working (notify_push UID requests in Apache logs).

---

## 3. Log Findings by Category

### Infra (NixOS / container / proxy)

| # | Severity | Message / Source | Cause | Action | Owner |
|---|----------|------------------|-------|--------|-------|
| I1 | Low | Apache `AH00558`: Could not reliably determine ServerName | Default Apache config in official image | Optional: add `ServerName cloud.prestonhager.com` via mounted Apache conf in `nextcloud.nix` | NixOS |
| I2 | Low | ClamAV `cl_statdbdir(): Can't open directory /var/lib/clamav` | ClamAV image path vs volume mount mismatch on self-check | Monitor; no action unless signatures stop updating | NixOS (optional) |
| I3 | Info | notify_push slow DB pool acquire at startup | Cold MariaDB / first connection after restart | Monitor if recurring under load | NixOS (optional: DB tuning) |
| I4 | **Resolved** | `No connection to anti virus` / `clamscan not found` at 06:38 | ClamAV not ready + wrong `av_mode` before `nextcloud-occ-maintain` | Already fixed by maintain script; verify uploads scan | Verify only |
| I5 | Info | `nextcloud-aio-domaincheck` exited container | Leftover from old AIO setup | `podman rm nextcloud-aio-domaincheck` | NixOS / ops |

### App configuration (Admin UI / occ)

| # | Severity | Message / Source | Cause | Action | Owner |
|---|----------|------------------|-------|--------|-------|
| A1 | **High** | SMTP test failed (`TransportException` / `UnexpectedResponseException`) | iCloud SMTP (`smtp.mail.me.com`) rejecting connection or bad app-specific password | Admin → Basic settings → Email server: verify host/port/TLS, regenerate [iCloud app-specific password](https://appleid.apple.com), run “Send email” test. Update sops `SMTP_PASSWORD` in `nextcloud-environment` if rotated, then redeploy | **UI + sops** |
| A2 | Medium | `Could not load lazy dashboard widget: MediaDC\RecentTasksWidget` (15×) | MediaDC depends on Cloud_Py_API; `UtilsService` class missing | Disable **MediaDC** until Cloud_Py_API is installed/fixed, or install/repair Cloud_Py_API | **UI** |
| A3 | Medium | `Could not resolve Cloud_Py_API\Service\UtilsService` | Cloud_Py_API broken or partially installed | Same as A2: disable MediaDC or reinstall Cloud_Py_API | **UI** |
| A4 | Medium | Whiteboard setup check ✗ — WebSocket URL not configured | Real-time whiteboard needs separate WS server | Either ignore (basic whiteboard works) or deploy Nextcloud Whiteboard server and set URL in app settings | **UI** (+ NixOS if self-hosting WS) |
| A5 | Medium | `Could not detect any host` (richdocuments) | Collabora/ONLYOFFICE WOPI URL not configured | Admin → Office → set Collabora Online URL, or disable richdocuments if unused | **UI** |
| A6 | Low | `Undefined array key` in user_saml admin template | SAML app opened before IdP metadata configured | Configure SAML in Admin → SSO & SAML, or disable app if unused | **UI** |
| A7 | Low | Missing optional DB indices (`vcategory`, `cards_properties`) | Normal post-upgrade maintenance | Run `occ db:add-missing-indices` (via SSH or add to maintain script) | **occ** / NixOS |
| A8 | Low | Email test setup check ℹ — not verified | Consequence of A1 | Fixed when SMTP works | **UI** |
| A9 | Low | Google Calendar / People API 403 | APIs disabled in Google Cloud project | Enable APIs in Google Cloud Console or disconnect Google integration | **External** |
| A10 | Low | `av_path` still `/usr/bin/clamscan` while mode is `daemon` | Stale setting from earlier executable mode | `occ config:app:delete files_antivirus av_path` to avoid fallback confusion | **occ** |

### Harmless / expected

| # | Severity | Message / Source | Cause | Action |
|---|----------|------------------|-------|--------|
| H1 | Info | Login failed (admin, nextcloud-admin) | Failed login attempts during setup | None — brute-force throttle active |
| H2 | Info | `Renewing session token failed` (1×) | Stale browser session after rebuild | None — user re-login |
| H3 | Info | GitHub API client/server error (4×) | Updater or app store rate limit / network | None unless updates fail |
| H4 | Info | weather_status `Undefined array key "error"` | App bug when location API returns unexpected payload | Ignore, fix location, or disable weather_status |
| H5 | Info | Apache `AH01797: client denied … /data/.ncdata` | Nextcloud Server Crawler probing protected path | Expected security behavior |
| H6 | Info | 404 on `terms_of_service`, `end_to_end_encryption` | Apps not installed; client probes anyway | None |
| H7 | Info | `Table oc_audioplayer_playlist_tracks has no primary key` | Legacy audioplayer schema | Update/disable audioplayer app |
| H8 | Info | External bot/scanner 404s in Apache access log | Internet background noise | None |
| H9 | Info | `Failed addUser: User already exists` | One-time duplicate user creation attempt | None |

---

## 4. Priority Order

| Priority | Item | Type | Effort |
|----------|------|------|--------|
| **P1** | Fix SMTP (A1) — blocks email notifications, password reset mail, admin alerts | UI + sops | 15 min |
| **P2** | Confirm ClamAV scanning on upload (I4 verify) — upload a test file, check `occ files_antivirus:status` | Verify | 5 min |
| **P3** | Clean stale `av_path` (A10) | occ | 1 min |
| **P4** | Disable or fix MediaDC / Cloud_Py_API (A2, A3) — noisy dashboard errors | UI | 5 min |
| **P5** | Run `occ db:add-missing-indices` (A7) | occ / NixOS | 5 min |
| **P6** | Configure Collabora URL or disable richdocuments (A5) | UI | 10 min |
| **P7** | Whiteboard WebSocket (A4) — only if real-time collaboration needed | UI / NixOS | Variable |
| **P8** | SAML admin errors (A6) — if SSO planned | UI | Variable |
| **P9** | Remove stale AIO container (I5) | ops | 1 min |
| **P10** | Optional Apache ServerName (I1) | NixOS | Low |

---

## 5. Recommended Commands (ace)

```bash
# Status & checks
podman exec -u www-data nextcloud php /var/www/html/occ status
podman exec -u www-data nextcloud php /var/www/html/occ setupchecks
podman exec -u www-data nextcloud php /var/www/html/occ notify_push:self-test

# ClamAV
printf 'PING\n' | podman exec -i nextcloud-clamav nc 127.0.0.1 3310
podman exec -u www-data nextcloud php /var/www/html/occ files_antivirus:status

# Maintenance
podman exec -u www-data nextcloud php /var/www/html/occ db:add-missing-indices
podman exec -u www-data nextcloud php /var/www/html/occ config:app:delete files_antivirus av_path

# Logs
tail -f /stor/nextcloud/data/data/nextcloud.log
podman logs -f nextcloud-notify-push
journalctl -u podman-nextcloud.service -u nextcloud-occ-maintain.service -f
```

---

## 6. NixOS Changes (not urgent)

No critical NixOS bugs found. Optional follow-ups for a future PR:

1. **Apache ServerName** — mount a small conf snippet to silence `AH00558`.
2. **`nextcloud-occ-maintain`** — add `occ config:app:delete files_antivirus av_path` after setting daemon mode (prevents stale executable path).
3. **`nextcloud-occ-maintain`** — add `occ db:add-missing-indices` on upgrade.
4. **Whiteboard** — only if deploying a Whiteboard WebSocket container (new service + Caddy route).

Current `nextcloud.nix` maintain script correctly waits for ClamAV `:3310`, sets daemon mode, and runs `notify_push:setup` — this resolved the pre-restart antivirus failures.

---

## 7. UI vs NixOS Summary

| Fix in Admin UI / occ | Fix in NixOS / ops |
|------------------------|-------------------|
| SMTP credentials & test (A1) | Optional Apache ServerName (I1) |
| Disable/fix MediaDC, Cloud_Py_API (A2–A3) | Add `av_path` delete to maintain script (A10) |
| Collabora / richdocuments URL (A5) | Add `db:add-missing-indices` to maintain (A7) |
| Whiteboard WebSocket URL (A4) | Whiteboard WS container (if desired) |
| SAML IdP configuration (A6) | Remove `nextcloud-aio-domaincheck` (I5) |
| Google API enablement (A9) | |
| `occ db:add-missing-indices` (A7) | |
| `occ config:app:delete files_antivirus av_path` (A10) | |
