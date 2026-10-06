# Crux

Pterodactyl Wings node at **192.168.5.6**.

| Field | Value |
|-------|-------|
| Hostname | `crux` |
| Flake | `nixos-rebuild switch --flake /etc/nixos#crux` |
| Gateway | 192.168.5.1 |
| DNS | 192.168.5.5 (ace Technitium), 1.1.1.1 |
| Interface | `enp0s31f6` static |
| Preferred TLS / Wings domain | `crux.lc1.nm.us.prestonhager.com` |

## Host-specific config

`hosts/crux/default.nix` sets static IP and `/etc/hosts` entries for ace panel and internal names. Imports:

- `hosts/pterodactyl-nodes/` — Wings, Docker, MariaDB (local), NFS LE certs
- `nixos/monitoring/crux-probes.nix` — blackbox HTTP/TCP probes
- `nixos/monitoring/crux-prometheus.nix` — local Prometheus scraping ace + crux

## SSH

```bash
ssh root@192.168.5.6
# or from LAN: ssh root@crux.lc1.nm.us.prestonhager.com
```

## NFS / TLS

Wings reads Let's Encrypt certificates from ace via NFS mount (`hosts/pterodactyl-nodes/nfs.nix`). TLS domain: **`crux.lc1.nm.us.prestonhager.com`** (`nixos/nfs/default.nix`, `nixos/caddy/pterodactyl.nix`).

## Ports and monitoring

Open ports, Astracap NAT, and Grafana probes: [Crux ports & NAT](crux-ports.md). LAN map: [Network topology](../shared/network-topology.md).

Dashboards: [Crux Service Uptime](https://grafana.prestonhager.com/d/crux-uptime), [Network Topology & Ports](https://grafana.prestonhager.com/d/network-topology).

## Verify Wings

```bash
systemctl status wings docker
journalctl -u wings -n 50
dig @192.168.5.5 crux.lc1.nm.us.prestonhager.com +short   # expect 192.168.5.6
```
