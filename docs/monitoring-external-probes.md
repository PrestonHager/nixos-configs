# Internal and external HTTP monitoring for Ace

Options for monitoring Ace services from **inside the LAN** (split-horizon DNS, Technitium) and from **outside** (public Internet).

Related: `docs/monitoring-ace.md`, `docs/dns-ace.md`.

## Architecture (implemented)

```mermaid
flowchart LR
  subgraph crux["crux 192.168.5.6"]
    BB[blackbox_exporter :9115]
    EXT[ace-external-probe-push timer]
  end
  subgraph ace["ace 192.168.5.5"]
    PG[Pushgateway :9091]
    PROM[Prometheus :9090]
    BBlocal[blackbox_exporter :9115 local]
  end
  BB -->|"HTTPS via Technitium DNS"| ace
  PROM -->|"scrape /probe"| BB
  EXT -->|"curl public URLs"| WAN[Internet]
  EXT -->|"POST metrics"| PG
  PROM -->|"scrape pushgateway-external"| PG
  PROM -->|"scrape local blackbox"| BBlocal
```

## Probe locations (labels)

| Label | Meaning | Source |
|-------|---------|--------|
| `local` | Ace host loopback / `/etc/hosts` path | `blackbox-http`, `blackbox-tcp` on ace |
| `lan` | LAN client path from crux via Technitium DNS | `blackbox-http-lan`, `blackbox-dns-lan` scraping crux `:9115` |
| `external` | Public DNS + WAN path | Pushgateway ← `scripts/ace-external-probe-push.sh` on crux |

Additional labels: `probe_source=crux` on LAN and external probes.

DNS split-horizon health on ace: `ace_dns_probe_success` from `lan-dns-prober` (`dig @192.168.5.5`).

---

## Part 1 — LAN: blackbox on crux

**crux** (`192.168.5.6`) runs `prometheus-blackbox-exporter` on `:9115` with Technitium DNS (`192.168.5.5`).

### HTTP targets (via LAN DNS)

- `https://grafana.prestonhager.com/`
- `https://cloud.prestonhager.com/`
- `https://zitadel.prestonhager.com/`
- `https://dns.prestonhager.com/`
- `https://matrix.prestonhager.com/_matrix/client/versions`
- `http://192.168.5.5/` (loopback health, `http_local` module)

### DNS target

- `dig @192.168.5.5 grafana.prestonhager.com` → `192.168.5.5` (blackbox `dns_lan_grafana_prestonhager_com` module)

### NixOS files

| File | Host |
|------|------|
| `nixos/monitoring/crux-probes.nix` | crux — blackbox + external probe timer |
| `nixos/monitoring/crux-blackbox-config.nix` | crux blackbox modules |
| `hosts/crux/default.nix` | imports crux-probes, nameserver `192.168.5.5` |
| `nixos/monitoring/prometheus-config.nix` | ace — scrape jobs `blackbox-http-lan`, `blackbox-dns-lan` |

### Firewall

- **crux**: TCP `9115` from `192.168.5.5` (ace Prometheus)
- **ace**: TCP `9091` from `192.168.5.6` (crux push script)

---

## Part 2 — WAN: Pushgateway + external probe on crux

**ace** runs Pushgateway (`prom/pushgateway`) on host port **9091** (not exposed via Caddy).

**crux** runs `ace-external-probe-push` systemd timer every **5 minutes**:

- Resolves targets via public DNS (`1.1.1.1`)
- Curls HTTPS endpoints reachable from the Internet
- Pushes `probe_success`, `probe_duration_seconds`, `probe_http_status_code` to Pushgateway
- Labels: `probe_location=external`, `probe_source=crux`

### NixOS / scripts

| File | Role |
|------|------|
| `nixos/containers/pushgateway.nix` | ace Pushgateway container |
| `scripts/ace-external-probe-push.sh` | probe + push logic |
| `nixos/monitoring/crux-probes.nix` | crux timer + service |

Prometheus scrape job: **`pushgateway-external`** (`honor_labels: true`).

---

## Grafana

**Ace Service Uptime** (`ace-uptime.json`): template variable `probe_location` with values `local`, `lan`, `external`.

- LAN row: crux blackbox metrics
- External row: pushgateway metrics
- DNS row: `ace_dns_probe_success` (ace-side Technitium split-horizon check)

Dashboard URLs (on ace Grafana):

- `/d/ace-uptime` — combined uptime
- `/d/ace-http-probes` — local blackbox HTTP detail
- `/d/ace-tcp-probes` — local TCP probes

---

## Deploy

### ace

```bash
git pull
sudo nixos-rebuild switch --flake /etc/nixos#ace
```

### crux

```bash
git pull
sudo nixos-rebuild switch --flake /etc/nixos#crux
```

Verify:

```bash
# On crux
curl -sS http://127.0.0.1:9115/metrics | head
systemctl status ace-external-probe-push.timer

# On ace
curl -sS 'http://127.0.0.1:9090/api/v1/query?query=probe_success{probe_location="lan"}' | jq .
```
