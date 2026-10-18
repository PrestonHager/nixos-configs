# Crux ports and Astracap forwards

Inventory from live host (`ss` / firewall) and Astracap NAT (Jul 2026), updated from the Nix config in Oct 2026 for the Coolify proxy. Secrets omitted.

## Crux service inventory

| Service | Role | Listen | Firewall | Notes |
|---------|------|--------|----------|-------|
| Wings 1.13.4 | Pterodactyl daemon API / TLS | `0.0.0.0:443` | LAN open | Domain `crux.lc1.nm.us.prestonhager.com`; version from the `pterodactyl-wings` flake input |
| Coolify proxy (Traefik, `coolify-proxy`) | HTTP for `*.apps.prestonhager.com` | `*:80` (docker-proxy) | **ace only** — `DOCKER-USER` rule | TLS terminates on ace's Caddy, which forwards plain HTTP here. See below |
| Wings SFTP | File transfer (panel file manager) | `*:2022` | LAN open | Not Samba; Samba secret exists but service not enabled |
| SSH | Management | `0.0.0.0:22` | LAN open | |
| Docker game servers | Per-allocation TCP/UDP | Dynamic (e.g. docker-proxy) | **Not** in Nix `allowedTCPPorts` unless allocation + NAT | Ephemeral; do not hardcode in Prometheus |
| Prometheus | Local metrics | `*:9090` | **ace only** (`192.168.5.5`) | Grafana datasource `prometheus-crux` |
| Blackbox exporter | Probe agent | `*:9115` | **ace only** | Scraped by ace Prometheus for LAN HTTP/DNS |
| Node exporter | Host metrics | `*:9100` | Closed to LAN | Not ace-reachable today |
| MariaDB | Wings local DB | `127.0.0.1:3306` | localhost | Cannot probe from ace |
| Alloy | Logs → Loki | `127.0.0.1:12345` | localhost | Cannot probe from ace |
| rpcbind | NFS client helper | `*:111` | Not in allow list | Used for NFS LE certs from ace |

Nix firewall allow list (`hosts/pterodactyl-nodes/default.nix`): **TCP 22, 443, 2022**.

### Coolify proxy on :80 (ace only)

crux is also the deploy server for [Coolify on ace](../ace/coolify.md) (`nixos/coolify-node.nix`, imported by `hosts/crux/default.nix`):

- **Deploy role:** Coolify on ace connects as `root` over SSH with its own key (`coolify@ace`, in root's `authorized_keys`; the private half is the `crux-deploy` key in Coolify's database). `git`, `curl` and `jq` are installed for Coolify's server validation. Docker and Compose come from `virtualisation.docker` in `hosts/pterodactyl-nodes`, so Coolify's own Docker installer is never used.
- **Port 80:** Coolify's Traefik proxy publishes :80 only; Wings owns :443. Docker-published ports are DNATed and go through `FORWARD`, so `nixos-fw` (INPUT) never sees them and :80 is not in `allowedTCPPorts`. Instead `networking.firewall.extraCommands` inserts a `DOCKER-USER` rule that drops TCP connections to `192.168.5.6:80` from anything but ace (`192.168.5.5`):

  ```text
  -p tcp -m conntrack --ctorigdst 192.168.5.6 --ctorigdstport 80 --ctdir ORIGINAL ! -s 192.168.5.5 -j DROP
  ```

  `--ctorigdst` limits the rule to connections addressed to crux itself. The first version (2026-10-18) lacked it and also dropped containers' outbound plain-HTTP requests; the firewall script deletes that old rule on start.
- **Docker `liveRestore = true`:** game servers and Coolify apps keep running when dockerd restarts during a rebuild.

## Astracap WAN port forwards

| WAN | Inside | Status |
|-----|--------|--------|
| TCP 80 | `192.168.5.5:80` (ace) | Active (static NAT) |
| TCP 443 | `192.168.5.5:443` (ace) | Active (static NAT) |
| → crux `192.168.5.6` | — | **None** (no static NAT to crux) |
| → nova `192.168.5.7` | — | **None** |
| Other | PAT overload on Gi0/0 | Outbound only |

Optional game NAT is managed by the Pterodactyl **portforward** extension when enabled; not present in current NAT translations for crux.

## Prometheus probes (from ace)

| Job | Target | Meaning |
|-----|--------|---------|
| `blackbox-http-crux` | `https://crux.lc1.nm.us.prestonhager.com/` | Wings API (HTTP 401 = healthy) |
| `blackbox-tcp-crux` | `.6:443`, `:2022`, `:22`, `:9115`, `:9090` | Wings / SFTP / SSH / monitoring |
| `blackbox-tcp-lan-hosts` | ace/nova `:443`, Astracap/Astraquasar `:22` | Topology dashboard |
| essential TCP probe | crux `:80` | Coolify proxy; Coolify and Network Topology dashboards |

## Cannot probe from ace

- MariaDB, Alloy (loopback)
- node_exporter `:9100` (firewalled)
- Dynamic Docker game ports (allocation-specific; often not opened in Nix firewall until forwarded)
- WAN ports to crux (none configured)

## Dashboards

| Dashboard | UID | URL path |
|-----------|-----|----------|
| Crux Service Uptime | `crux-uptime` | `/d/crux-uptime` |
| Network Topology & Ports | `network-topology` | `/d/network-topology` |

## Related docs

- [Network topology](../shared/network-topology.md)
- [Astracap router](../shared/network-astracap.md)
- [Pterodactyl port forward](../ace/pterodactyl-plugin-port-forward.md)
- [Coolify on ace](../ace/coolify.md)
