# Server Docs

Homelab documentation for the [nixos-configs](https://github.com/PrestonHager/nixos-configs) flake (`dell-poweredge-r730xd` branch).

## Hosts

| Host | IP | Flake target | Accessible from | Role |
|------|-----|--------------|-----------------|------|
| **ace** | 192.168.5.5 | `#ace` | LAN + WAN `:80`/`:443` | Main server — Caddy, Podman stacks, DNS, monitoring ([overview](ace/index.md)) |
| **ace iDRAC** | 192.168.5.10 | — | LAN OOB only | OOB management ([iDRAC](ace/idrac.md)) |
| **mars iDRAC** | 192.168.5.11 | — | LAN OOB only (`Gi2/0/48`) | PowerEdge R410 iDRAC 6 ([mars iDRAC](poweredge/mars-idrac.md)) — **online** |
| **mars** | 192.168.5.15 | — | Reserved / not connected | PowerEdge R410 host ([mars](poweredge/mars.md)) |
| **sally iDRAC** | 192.168.5.12 | — | Reserved / not connected | PowerEdge R320 OOB ([sally iDRAC](poweredge/sally-idrac.md)) |
| **sally** | 192.168.5.16 | — | Reserved / not connected | PowerEdge R320 host ([sally](poweredge/sally.md)) |
| **crux** | 192.168.5.6 | `#crux` | LAN only (`Gi2/0/25`) | Pterodactyl Wings node ([crux](pterodactyl-nodes/crux.md)) |
| **nova** | 192.168.5.7 | `#nova` | Reserved / offline | Pterodactyl Wings node ([nova](pterodactyl-nodes/nova.md)) |
| **elara** | 192.168.5.8 | — | Reserved / not connected | OptiPlex Wings node ([elara](pterodactyl-nodes/elara.md)) |
| **zenith** | 192.168.5.9 | — | Reserved / not connected | OptiPlex Wings node ([zenith](pterodactyl-nodes/zenith.md)) |
| **ph-nixos** | DHCP | `#ph-nixos` | LAN | Laptop/desktop (GNOME) ([ph-nixos](ph-nixos/index.md)) |

Full map (IPs, switch ports, WAN vs LAN): [Network topology](shared/network-topology.md).

## Network

| Device | IP | SSH alias | Accessible from |
|--------|-----|-----------|-----------------|
| Astracap (Cisco router) | 192.168.5.1 | `ssh astracap` | LAN management only |
| Technitium DNS | 192.168.5.5 | — | LAN (`:53`); recursion for clients |
| Astraquasar (Cisco switch) | 192.168.5.3 | `ssh astraquasar` | LAN management only |

Planned intrusion detection and response across these hosts and devices: [IDS & Security Monitoring Plan](shared/security-ids-plan.md).

## Accessing this site

| Where | URL / command |
|-------|----------------|
| **LAN** | https://serverdocs.prestonhager.com (RFC1918 only; served by Caddy on ace) |
| **Local build** | `nix build .#docs` then open `result/index.html`, or `nix develop -c mdbook serve docs/site` |

Source markdown lives in `docs/*.md`; the site wraps those files via mdBook includes so content is not duplicated.
