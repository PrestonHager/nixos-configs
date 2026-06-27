# Pterodactyl Nodes

Game server workloads run on dedicated NixOS hosts running **Pterodactyl Wings** (Docker). The panel lives on **ace** at https://panel.prestonhager.com.

| Node | IP | Flake | Hardware |
|------|-----|-------|----------|
| **crux** | 192.168.5.6 | `#crux` | Dell OptiPlex 7050 |
| **nova** | 192.168.5.7 | `#nova` | Dell OptiPlex 7050 (same module tree) |

Both nodes share `hosts/pterodactyl-nodes/default.nix` with host-specific overrides in `hosts/crux/default.nix` (nova uses flake `mapAttrs` hostname only).

## Common config

| Component | Notes |
|-----------|-------|
| Wings | `inputs.pterodactyl-wings` overlay binary, `wings.service` |
| Docker | Enabled (Wings requirement; ace uses Podman instead) |
| TLS certs | NFS symlink from ace Let's Encrypt (`link-letsencrypt.nix`) |
| DNS | Clients use ace Technitium `192.168.5.5`; nodes resolve panel via `/etc/hosts` or Technitium |
| Monitoring | crux runs local Prometheus + blackbox probes (`nixos/monitoring/crux-*.nix`) |

## LAN DNS names (preferred)

| Hostname | LAN IP |
|----------|--------|
| `crux.lc1.nm.us.prestonhager.com` | **192.168.5.6** |
| `nova.lc1.nm.us.prestonhager.com` | **192.168.5.7** |

Shorter aliases (`crux.prestonhager.com`, `nova.prestonhager.com`) also resolve on LAN via Technitium CNAMEs.

Deploy a node:

```bash
sudo nixos-rebuild switch --flake /etc/nixos#crux   # or #nova
```

Untrusted workload surface — log forwarding, fail2ban, and isolation playbooks for these nodes are in `docs/security-ids-plan.md` (§8).
