# Ace

Main homelab server on a Dell PowerEdge R730xd at **192.168.5.5**.

| Field | Value |
|-------|-------|
| Hostname | `ace` |
| Flake | `nixos-rebuild switch --flake /etc/nixos#ace` |
| Gateway | 192.168.5.1 (Astracap) |
| Resolver | 192.168.5.5, 1.1.1.1 |
| Bond | `eno1` + `eno2` → `bond0` (802.3ad LACP) |
| iDRAC | **`192.168.5.10`** — see [iDRAC](idrac.md) |

## Stack

Ace runs **Caddy** on `:80`/`:443` for `*.prestonhager.com`, **Technitium DNS** on `:53`, and Podman containers (Grafana, Prometheus, Nextcloud, Zitadel, Pterodactyl, Jellyfin, Vaultwarden, Matrix/Synapse, MediaWiki, WG Portal, and more). LanCache is disabled.

Config entry points:

| Path | Purpose |
|------|---------|
| `hosts/ace/default.nix` | Host networking, imports Matrix |
| `nixos/headless/` | Caddy, containers, monitoring |
| `nixos/local-service-hosts.nix` | Loopback `/etc/hosts` for on-box Caddy vhosts |

## Related LAN names

| Name | Resolves to |
|------|-------------|
| `ace.prestonhager.com` | 192.168.5.5 (via Technitium CNAME) |
| `ace.internal.prestonhager.com` | 192.168.5.5 |

See child pages for per-service runbooks. Shared DNS, SSH, monitoring, and the [IDS deployment plan](../shared/security-ids-plan.md) are under **Shared**.
