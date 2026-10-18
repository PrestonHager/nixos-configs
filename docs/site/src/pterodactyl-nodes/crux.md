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

- `hosts/pterodactyl-nodes/` — Wings 1.13.4, Docker (`liveRestore = true`), MariaDB (local), NFS LE certs
- `nixos/monitoring/crux-probes.nix` — blackbox HTTP/TCP probes
- `nixos/monitoring/crux-prometheus.nix` — local Prometheus scraping ace + crux
- `nixos/monitoring/promtail.nix` — logs to Loki on ace
- `nixos/coolify-node.nix` — Coolify deploy server (see below)

## Coolify deploy server

crux runs the apps that [Coolify on ace](../ace/coolify.md) deploys. Coolify connects as root over SSH with its own key (`coolify@ace`) and runs its Traefik proxy (`coolify-proxy`) on **:80** only, since Wings owns :443. TLS for `*.apps.prestonhager.com` terminates on ace's Caddy, which forwards plain HTTP to crux:80. A `DOCKER-USER` iptables rule drops :80 connections to crux from anything but ace (`192.168.5.5`). Details: [Crux ports & NAT](crux-ports.md#coolify-proxy-on-80-ace-only).

Docker's `liveRestore` keeps game servers and Coolify apps running when dockerd restarts during a rebuild.

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
docker logs coolify-proxy --tail 50         # Coolify proxy
iptables -S DOCKER-USER                     # expect the :80 drop rule
dig @192.168.5.5 crux.lc1.nm.us.prestonhager.com +short   # expect 192.168.5.6
```
