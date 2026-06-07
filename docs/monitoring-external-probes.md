# Internal and external HTTP monitoring for Ace

Options for monitoring Ace services from **inside the LAN** (split-horizon DNS, LanCache) and from **outside** (public Internet). Implemented approach is at the bottom.

Related: `docs/monitoring-ace.md`, `docs/dns-ace.md`.

## Probe locations (implemented labels)

| Label | Meaning | Source |
|-------|---------|--------|
| `local` | Ace host loopback / `/etc/hosts` path | `blackbox-http`, `blackbox-tcp` on ace |
| `internal` | LAN client path via `192.168.5.5` + vhost `Host` header | `blackbox-http-lan` on ace |
| `external` | Public DNS + WAN IP checks | Pushgateway ← `scripts/external-probe-push.sh` |

DNS split-horizon health: `ace_dns_probe_success` from `lan-dns-prober` (`dig @192.168.5.5`).

---

## Part A — LAN options

### 1. Blackbox exporter on crux (recommended long-term)

Run `prometheus-blackbox-exporter` on **crux** (`192.168.5.6`). Crux uses LanCache DNS (`192.168.5.5`) like any LAN client. Prometheus on ace scrapes `192.168.5.6:9115` with relabel `probe_location=internal`.

| | |
|---|---|
| **Cost** | Free |
| **Interval** | 15s (configurable) |
| **Integration** | Medium — NixOS module on crux or manual install + firewall |
| **Metrics** | Full blackbox set: `probe_success`, `probe_duration_seconds`, `probe_http_status_code`, TLS, phases |

**Pros:** True LAN client perspective (DNS + routing). **Cons:** Requires crux deploy; crux flake host is minimal today (`hosts/crux/default.nix`).

### 2. Second blackbox job on ace via LAN IP + Host headers (implemented)

Ace blackbox probes `https://192.168.5.5/` with per-vhost modules (`Host` + TLS SNI). Job: `blackbox-http-lan`, label `probe_location=internal`.

| | |
|---|---|
| **Cost** | Free |
| **Interval** | 15s |
| **Integration** | Low — config-only on ace |
| **Metrics** | Full blackbox HTTP metrics |

**Pros:** No extra host; fast to ship. **Cons:** Probes originate on ace, not a remote LAN client; does not validate DHCP DNS on client subnets.

### 3. Grafana Agent / Alloy on crux → remote_write ace

Run Grafana Agent on crux with blackbox integration and `remote_write` to ace Prometheus (or Mimir).

| | |
|---|---|
| **Cost** | Free |
| **Interval** | 15–60s |
| **Integration** | High — agent install, remote_write URL, auth |
| **Metrics** | Blackbox + optional node metrics |

**Pros:** Scales to nova/other nodes. **Cons:** More moving parts than option 1.

---

## Part B — WAN / external options

### 1. UptimeRobot free tier + Pushgateway or Grafana Infinity

[UptimeRobot](https://uptimerobot.com/) free: 50 monitors, **5-minute** interval, email/Slack alerts.

| | |
|---|---|
| **Cost** | Free |
| **Interval** | 5 min |
| **Integration** | Low for alerts; medium for Grafana (Infinity datasource or manual Pushgateway webhook) |
| **Metrics** | Uptime %, response time, status code (API); not native Prometheus unless bridged |

**Pros:** Real external vantage points. **Cons:** 5 min granularity; Prometheus integration needs extra glue (see manual setup below).

### 2. Self-hosted blackbox on free VPS → Pushgateway

Oracle Cloud Always Free or Fly.io VM runs blackbox + cron push to ace Pushgateway (`9091`).

| | |
|---|---|
| **Cost** | Free tier |
| **Interval** | 1–5 min |
| **Integration** | Medium |
| **Metrics** | Full Prometheus blackbox metrics |

**Pros:** Full metrics, your control. **Cons:** VPS upkeep, secure Pushgateway exposure.

### 3. Cloudflare synthetic monitoring

Cloudflare **does not** offer a free standalone synthetic/uptime product comparable to UptimeRobot on all plans. Health Checks are paid (Notifications + health checks on Enterprise/advanced). **Not applicable** for a zero-cost setup unless you already pay for a plan that includes it.

| | |
|---|---|
| **Cost** | Paid for meaningful HTTP synthetics |
| **Interval** | 60s+ (paid) |
| **Integration** | Webhook → Pushgateway possible |
| **Metrics** | Limited vs Prometheus |

### 4. HetrixTools free external checks

HetrixTools free tier: external uptime from multiple locations, ~**1 hour** interval on free.

| | |
|---|---|
| **Cost** | Free |
| **Interval** | ~60 min (free) |
| **Integration** | Dashboard-only or webhook |
| **Metrics** | Uptime/latency in Hetrix UI |

**Pros:** Multi-region. **Cons:** Slow on free tier; no native Prometheus.

---

## Comparison summary

| Option | Cost | Interval | Effort | Prometheus-native |
|--------|------|----------|--------|-------------------|
| Crux blackbox | Free | 15s | Medium | Yes |
| Ace LAN IP + Host (implemented) | Free | 15s | Low | Yes |
| Grafana Agent remote_write | Free | 15s | High | Yes |
| UptimeRobot | Free | 5 min | Low | Via bridge |
| VPS blackbox + Pushgateway | Free | 1–5 min | Medium | Yes |
| Cloudflare synthetics | Paid | — | — | Partial |
| HetrixTools | Free | ~60 min | Low | No |

---

## Part C — What we implemented

### LAN (`probe_location=internal`)

- **`blackbox-http-lan`** scrape job in `nixos/monitoring/prometheus-config.nix`
- Per-vhost blackbox modules in `nixos/monitoring/blackbox-config.nix` (TLS SNI + `Host` → `https://192.168.5.5/`)
- **`lan-dns-prober`** timer: `dig @192.168.5.5` for key hostnames → `ace_dns_probe_success` textfile metrics

### WAN (`probe_location=external`)

- **Pushgateway** container (`nixos/containers/pushgateway.nix`, port **9091**)
- **`scripts/external-probe-push.sh`** — curl public URLs, optional WAN IP + SNI probes, push `probe_*` metrics
- **`ace-external-probe-push`** systemd timer on ace (every 5 min, uses public resolver `1.1.1.1`)

### Grafana

- **Ace Service Uptime** dashboard: `probe_location` template variable, LAN/External/DNS summary panels

### Existing jobs

- `blackbox-http` / `blackbox-tcp` labeled `probe_location=local` (unchanged behavior, new label)

---

## Manual setup (optional)

### UptimeRobot (extra external checks)

1. Create free account at [uptimerobot.com](https://uptimerobot.com).
2. Add **HTTPS** monitors for publicly reachable endpoints, e.g.:
   - `https://dns.prestonhager.com/`
   - Any grey-cloud / port-forwarded service on `73.26.67.25`
3. Configure alert contacts (email, Slack, webhook).
4. For Grafana: use UptimeRobot dashboard, or add **Infinity** datasource pointing at UptimeRobot API (paid API on some tiers) — optional.

Most ace vhosts are **LAN-only** (Technitium split-horizon); only Cloudflare-proxied or port-forwarded names are meaningful for true external monitors.

### Run external probes from crux (stronger WAN perspective)

Ace’s timer uses ace’s outbound path. For a true off-box check from another LAN host with Internet:

```bash
# On crux (192.168.5.6), every 5 min via cron
PUSHGATEWAY_URL=http://192.168.5.5:9091 \
EXTERNAL_PROBE_TARGETS="https://dns.prestonhager.com/" \
WAN_SNI_HOSTS="dns.prestonhager.com" \
/path/to/nixos-configs/scripts/external-probe-push.sh
```

### Deploy crux blackbox (future upgrade)

Add to `hosts/crux/default.nix`:

```nix
services.prometheus.exporters.blackbox.enable = true;
```

Open `9115` from ace (`192.168.5.5`) only; add Prometheus job scraping `192.168.5.6:9115` with `probe_location=internal` and retire overlapping LAN IP modules if desired.

---

## Deploy on ace

```bash
git pull
sudo nixos-rebuild switch --flake /etc/nixos#ace
systemctl status lan-dns-prober.timer ace-external-probe-push.timer
curl -s http://127.0.0.1:9091/metrics | head
```

Verify in Prometheus:

```promql
probe_success{probe_location="internal"}
probe_success{probe_location="external"}
ace_dns_probe_success
```

---

## Security notes

- Pushgateway accepts any push on LAN; keep **9091** off WAN (default: host port, no Caddy exposure).
- Do not expose Pushgateway through Cloudflare without authentication.
- External script metrics use grouping key `job=external-probe`, `probe_location=external`.
