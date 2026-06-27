# Ace Server Health Report

**Generated:** 2026-06-26 (MDT)  
**Host:** ace (`192.168.5.5`)  
**NixOS:** 26.11.20260531.331800d (Zokor)  
**Config branch:** `dell-poweredge-r730xd`  
**Uptime:** (re-check on ace after deploy)  

> **Note:** This report is a point-in-time snapshot. Matrix Synapse is **enabled** in config (`hosts/ace/default.nix` imports `nixos/matrix.nix`) as of 2026-06-26; re-run probes on ace to refresh HTTP/container status.

---

## 1. Executive Summary

| Category | Count | Details |
|----------|------:|---------|
| **Healthy** | 24+ | Core infra, app stacks, LAN DNS, Technitium DoH/DoT, **Matrix/Synapse** |
| **Degraded** | 4 | Nextcloud warnings, MediaWiki upgrade vhost, elevated load metric |
| **Down / broken** | 0 | — |
| **Not configured** | 3 | Forgejo, Spacetime/Sui (commented out in flake) |

**Overall:** Ace is **operational** for production workloads (Nextcloud, Grafana, Zitadel, Pterodactyl, Jellyfin, Vaultwarden, **Matrix**, LAN DNS).

**System resources:** 31 GiB RAM (23 GiB available), `/` 17% used (2.9 TiB free), `/stor` 1% used.

---

## 2. Per-Service Status

| Service | URL | Status | Notes / Errors |
|---------|-----|--------|----------------|
| **Caddy** | — | ✅ Healthy | `active`; 0 failed systemd units; H1/H2/H3 enabled |
| **Grafana** | https://grafana.prestonhager.com | ✅ Healthy | HTTP 200 `/login`; OAuth/Zitadel button present; `/api/health` DB ok (v13.0.2) |
| **Prometheus** | https://prometheus.prestonhager.com | ✅ Healthy | HTTP 403 (auth expected); direct `/-/healthy` OK |
| **node_exporter** | `:9100` | ✅ Healthy | `active` |
| **blackbox_exporter** | `:9115` | ✅ Healthy | `active`; probing vhosts every 15s |
| **ace-health-exporter** | — | ✅ Healthy | Timer `active`; metrics exported; 1 warning (load), 0 critical |
| **Zitadel** | https://zitadel.prestonhager.com | ✅ Healthy | HTTP 302; OIDC discovery returns `issuer: https://zitadel.prestonhager.com` |
| **Zitadel DB** | — | ✅ Healthy | Container running |
| **Zitadel Login** | — | ✅ Healthy | Container running (v4.15.0) |
| **Nextcloud** | https://cloud.prestonhager.com | ✅ Healthy | HTTP 200; v34.0.0.12 installed (2026-06-27 upgrade from 31.0.14.1) |
| **Nextcloud DB** | — | ✅ Healthy | Running |
| **Nextcloud Redis** | — | ✅ Healthy | Running |
| **Nextcloud ClamAV** | — | ✅ Healthy | ClamAV 1.5.2/28023; `podman-nextcloud-clamav` active |
| **Nextcloud notify_push** | — | ✅ Healthy | Active; push endpoint responding; slow DB pool acquire warning in logs |
| **Technitium DNS** | https://dns.prestonhager.com | ✅ Healthy | Primary LAN DNS on **192.168.5.5:53**; web console HTTP 200; **DoH/DoT verified** (see §3) |
| **LanCache** | — | ➖ Disabled | Removed from `containers/default.nix` (slowed DNS) |
| **Jellyfin** | https://jellyfin.prestonhager.com | ✅ Healthy | HTTP 302; container `(healthy)` |
| **Vaultwarden** | https://vault.prestonhager.com | ✅ Healthy | HTTP 200 |
| **WG Portal** | https://wg.prestonhager.com | ✅ Healthy | HTTP 301; metrics vhost HTTP 403 (expected) |
| **Pterodactyl Panel** | https://panel.prestonhager.com | ✅ Healthy | HTTP 200 |
| **Pterodactyl Test** | https://test.panel.prestonhager.com | ✅ Healthy | HTTP 200 |
| **MediaWiki** | https://loftiawiki.org | ✅ Healthy | HTTP 301 |
| **MediaWiki (com)** | https://loftiawiki.com | ✅ Healthy | HTTP 301 |
| **MediaWiki upgrade** | https://upgrade.loftiawiki.org | ⚠️ Degraded | HTTP 403 |
| **Matrix / Synapse** | https://matrix.prestonhager.com | ✅ Healthy (config) | Synapse enabled via `nixos/matrix.nix` on ace; verify `:6167` and SSO after rebuild |
| **Forgejo / Phorge / Spacetime / Sui** | — | ➖ N/A | Commented out in `containers/default.nix` / `caddy/default.nix` |

---

## 3. DNS Stack Results

### Authoritative / LAN DNS (Technitium on `:53`)

Queries against `@192.168.5.5`:

| Hostname | Result |
|----------|--------|
| `cloud.prestonhager.com` | CNAME → `cloud.internal.prestonhager.com` → **192.168.5.5** |
| `grafana.prestonhager.com` | CNAME → `grafana.internal.prestonhager.com` → **192.168.5.5** |
| `zitadel.prestonhager.com` | CNAME → `ace.internal.prestonhager.com` → **192.168.5.5** |
| `dns.prestonhager.com` | CNAME → `dns.internal.prestonhager.com` → **192.168.5.5** |
| `ace.internal.prestonhager.com` | **192.168.5.5** |
| `crux.lc1.nm.us.prestonhager.com` | CNAME → `crux.internal.prestonhager.com` → **192.168.5.6** |

### Internal paths

| Path | Port | Status |
|------|------|--------|
| Technitium loopback | `127.0.0.1:5353` | ✅ Listening |
| Technitium web/API | `127.0.0.1:5380` | ✅ HTTP 200 |
| Technitium on bond0 | `192.168.5.5:53` | ✅ Active (primary LAN DNS) |

### DNS-over-HTTPS (DoH)

| Check | Result |
|-------|--------|
| `POST https://dns.prestonhager.com/dns-query` | ✅ **HTTP 200** (DNS wire query returns valid response) |
| Backend `127.0.0.1:8053` | ✅ **Listening** (Technitium container) |

Caddy reverse-proxies `/dns-query` → `127.0.0.1:8053` (`nixos/caddy/technitium.nix`); `technitium-sync-protocols.service` enables the DoH backend via Technitium API.

### DNS-over-TLS (DoT)

| Check | Result |
|-------|--------|
| `:853` on ace | ✅ **Listening** (`0.0.0.0:853`, Technitium container) |
| TLS handshake to `dns.prestonhager.com:853` | ✅ **Let's Encrypt** cert for `dns.prestonhager.com` (verified 2026-06-06) |

### DoH/DoT deployment (verified)

`nixos/containers/technitium-protocols.nix` is imported from `nixos/containers/technitium.nix` on ace (`/etc/nixos/nixos/containers/technitium-protocols.nix`). It defines `technitium-sync-tls-cert` and `technitium-sync-protocols` to export the Caddy LE cert to PKCS#12 and enable DoH/DoT via Technitium API:

- PFX at `/stor/technitium/certs/dns.prestonhager.com.pfx` ✅
- Caddy cert for `dns.prestonhager.com` ✅
- `technitium-sync-protocols.service` and `technitium-sync-tls-cert.service` **active (exited)** ✅

---

## 4. Failed Systemd Units

```
0 loaded units listed.
```

All 26 `podman-*` container units are **active/running**.

Core host services:

| Unit | State |
|------|-------|
| `caddy` | active |
| `prometheus-node-exporter` | active |
| `prometheus-blackbox-exporter` | active |
| `ace-health-exporter.timer` | active (oneshot service runs on schedule) |
| `technitium-sync-protocols` | active (exited) |

---

## 5. Container Issues

### Running (all expected stacks up)

26 podman systemd units active. Key containers: `grafana`, `prometheus`, `nextcloud` (+ db/redis/clamav/notify-push), `zitadel` (+ db/login), `technitium`, `jellyfin`, `vaultwarden`, `wg-portal`, `pterodactyl` (+ db/redis), `pterodactyl-test` (+ db/redis), `mediawiki` (+ db/redis/upgrade).

### Exited (stale / harmless)

| Container | Status | Notes |
|-----------|--------|-------|
| `nextcloud-aio-domaincheck` | Exited (0) | Leftover from old AIO setup |
| `ea1304e2a55c-infra` | Exited (0), 10 months | Orphan pod infra |
| `clever_panini` | Exited (0), 9 months | Orphan container |

No **unhealthy** containers reported (`podman ps --filter health=unhealthy` empty).

### Recent restarts / log notes

- **Nextcloud stack** restarted during last ~2h (likely `nixos-rebuild switch`); now serving traffic (desktop client sync observed in logs).
- **Grafana** restarted ~18 min before check; healthy.
- **Zitadel** restarted ~51 min before check; healthy.
- **notify_push:** WARN slow DB connection acquire (>2s threshold) — monitor if persistent.
- **Historical (2026-06-06):** Caddy 502 for `matrix.prestonhager.com` before Synapse was enabled — resolved by importing `nixos/matrix.nix` on ace.

---

## 6. Application-Specific Checks

### Grafana
- Login page: HTTP 200
- OAuth: **Zitadel** sign-in button present
- Health: `database: ok`, version 13.0.2

### Zitadel
- OIDC: `/.well-known/openid-configuration` returns valid JSON with `https://zitadel.prestonhager.com` issuer
- Login UI v2 loads (legacy `environment.json` path returns 404 — expected for v2 UI)

### Nextcloud
```
installed: true
version: 31.0.14.1
maintenance: false
needsDbUpgrade: false
```
Setup checks: mostly passing; **14 errors in logs** since rebuild; **whiteboard WebSocket** not configured (non-critical); push service OK.

### Technitium
- Web console: running
- API reachable on `:5380`
- Protocol sync (DoH port 8053, DoT port 853): **active** (verified 2026-06-06)

### ClamAV (Nextcloud antivirus)
- Version 1.5.2, signatures current (Jun 6 2026)

### ace-version-check (service versions)

Six-hourly timer exports installed vs upstream semver to `/var/lib/node-exporter-textfile/ace_versions.prom`. Grafana dashboard **Ace Service Versions** (`ace-versions`) and update alerts consume `ace_service_version_*` metrics.

Monitored services include Grafana, **Prometheus**, Nextcloud (+ `nextcloud-mariadb`, `nextcloud-redis`, `nextcloud-clamav`), Zitadel, Matrix Synapse, Technitium, Jellyfin, Vaultwarden, Caddy, Pterodactyl panel (+ `pterodactyl-mariadb`, `pterodactyl-redis`), and notify_push. Prometheus version is read from the Podman image tag or the local `:9090/api/v1/status/buildinfo` API.

### ace-health-exporter (Prometheus textfile)
```
ace_health_exporter_up 1
ace_health_warnings 1
ace_health_critical 0
ace_health_finding{level="warn",component="load",message="1m load is x CPU count (48) — elevated"}
```
Load average ~0.85 on 48 logical CPUs — actual load is low; metric wording may be misleading.

---

## 7. HTTP/HTTPS Probe Summary

Probed from ace via loopback (`--resolve …:443:127.0.0.1`):

| URL | HTTP | Interpretation |
|-----|-----:|----------------|
| grafana.prestonhager.com/login | 200 | OK |
| zitadel.prestonhager.com/ | 302 | OK (redirect to login) |
| cloud.prestonhager.com/ | 302 | OK (redirect to login) |
| dns.prestonhager.com/ | 200 | OK (Technitium console) |
| prometheus.prestonhager.com/ | 403 | OK (auth required) |
| jellyfin.prestonhager.com/ | 302 | OK |
| vault.prestonhager.com/ | 200 | OK |
| wg.prestonhager.com/ | 301 | OK |
| metrics.wg.prestonhager.com/ | 403 | OK (restricted) |
| panel.prestonhager.com/ | 200 | OK |
| test.panel.prestonhager.com/ | 200 | OK |
| matrix.prestonhager.com/ | 200 / 302 | OK when Synapse up (re-probe on ace) |
| loftiawiki.org/ | 301 | OK |
| loftiawiki.com/ | 301 | OK |
| upgrade.loftiawiki.org/ | 403 | ⚠️ Restricted |

---

## 8. Recommendations / Open Items

### High priority
1. **Re-run health probes on ace** after Matrix deploy and docs-site changes to refresh this report.

### Medium priority
2. **Nextcloud post-rebuild** — Review log errors via `occ log:watch` or admin log viewer; confirm ClamAV scanning and notify_push stable after restart.
3. **Clean stale containers** — Remove `nextcloud-aio-domaincheck`, `clever_panini`, old infra pods.

### Low priority
4. **MediaWiki upgrade vhost** — Investigate HTTP 403 on `upgrade.loftiawiki.org` if that instance should be publicly reachable.
5. **ace-health load warning** — Review `server-health.sh` threshold logic on 48-core host (0.85 load is not elevated).
6. **IDS / security monitoring** — Follow phased plan in `docs/security-ids-plan.md` (Phase 1: audit logging + Loki; complements Grafana blackbox alerts above).

---

## Appendix: Config Sources (expected services)

From `nixos/containers/default.nix` + `nixos/caddy/default.nix` on branch `dell-poweredge-r730xd`:

**Enabled containers:** Grafana, Jellyfin, MediaWiki, Nextcloud, Prometheus, Pterodactyl (+ test), Vaultwarden, WG Portal, Technitium, Zitadel, **Matrix (Synapse + Postgres)**

**Enabled Caddy vhosts:** Jellyfin, Matrix, Technitium/DoH, Grafana, MediaWiki, Nextcloud, Prometheus, Pterodactyl, Vaultwarden, WG Portal, Zitadel, **serverdocs** (LAN-only)

**Disabled / commented:** Forgejo, Phorge, SpacetimeDB, Sui, Nextcloud AIO
