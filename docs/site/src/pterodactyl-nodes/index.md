# Pterodactyl Nodes

Game server workloads run on dedicated NixOS hosts running **Pterodactyl Wings** (Docker). The panel lives on **ace** at https://panel.prestonhager.com.

| Node | IP | Flake | Hardware | Status |
|------|-----|-------|----------|--------|
| **crux** | 192.168.5.6 | `#crux` | Dell OptiPlex 7050 | Online (`Gi2/0/25`) |
| **nova** | 192.168.5.7 | `#nova` | Dell OptiPlex 7050 (same module tree) | Offline / reserved |
| **elara** | 192.168.5.8 | — | Dell OptiPlex | Reserved / not connected |
| **zenith** | 192.168.5.9 | — | Dell OptiPlex | Reserved / not connected |

crux and nova share `hosts/pterodactyl-nodes/default.nix` with host-specific overrides in `hosts/crux/default.nix` (nova uses flake `mapAttrs` hostname only). elara and zenith are planned additions (IPs reserved; flake targets TBD).

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
| `elara.lc1.nm.us.prestonhager.com` | **192.168.5.8** (planned) |
| `zenith.lc1.nm.us.prestonhager.com` | **192.168.5.9** (planned) |

Shorter aliases (`crux.prestonhager.com`, `nova.prestonhager.com`) also resolve on LAN via Technitium CNAMEs for hosts that are already in DNS.

Deploy an existing node:

```bash
sudo nixos-rebuild switch --flake /etc/nixos#crux   # or #nova
```

Untrusted workload surface — log forwarding, fail2ban, and isolation playbooks for these nodes are in the [IDS & Security Monitoring Plan](../shared/security-ids-plan.md) (§8). Addressing and switch ports: [Network topology](../shared/network-topology.md).
