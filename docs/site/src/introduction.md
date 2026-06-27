# Server Docs

Homelab documentation for the [nixos-configs](https://github.com/PrestonHager/nixos-configs) flake (`dell-poweredge-r730xd` branch).

## Hosts

| Host | IP | Flake target | Role |
|------|-----|--------------|------|
| **ace** | 192.168.5.5 | `#ace` | Main server — Caddy, Podman stacks, DNS, monitoring |
| **crux** | 192.168.5.6 | `#crux` | Pterodactyl Wings node |
| **nova** | 192.168.5.7 | `#nova` | Pterodactyl Wings node |
| **ph-nixos** | DHCP | `#ph-nixos` | Laptop/desktop (GNOME) |

## Network

| Device | IP | SSH alias |
|--------|-----|-----------|
| Astracap (Cisco router) | 192.168.5.1 | `ssh astracap` |
| Technitium DNS | 192.168.5.5 | — |
| Astraquasar (Cisco switch) | 192.168.5.3 | `ssh astraquasar` |

## Accessing this site

| Where | URL / command |
|-------|----------------|
| **LAN** | https://serverdocs.prestonhager.com (RFC1918 only; served by Caddy on ace) |
| **Local build** | `nix build .#docs` then open `result/index.html`, or `nix develop -c mdbook serve docs/site` |

Source markdown lives in `docs/*.md`; the site wraps those files via mdBook includes so content is not duplicated.
