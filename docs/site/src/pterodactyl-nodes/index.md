# Pterodactyl Nodes

Game server workloads run on dedicated NixOS hosts running **Pterodactyl Wings** (Docker). The panel lives on **ace** at https://panel.prestonhager.com.

| Node | IP | Flake | Hardware | Status |
|------|-----|-------|----------|--------|
| **crux** | 192.168.5.6 | `#crux` | Dell OptiPlex 7050 | Online (`Gi2/0/25`); also the Coolify deploy server |
| **nova** | 192.168.5.7 | `#nova` | Dell OptiPlex 7050 (same module tree) | Physically disconnected; config kept as a template |
| **elara** | 192.168.5.8 | `#elara` | Dell OptiPlex (`hosts/elara/hardware.nix`) | Online (SSH, Wings active) |
| **zenith** | 192.168.5.9 | `#zenith` | Dell OptiPlex (no hardware config yet) | Planned / not connected |

All four share `hosts/pterodactyl-nodes/default.nix`; the flake also imports `hosts/<name>/default.nix` when it exists. `hosts/crux/` adds static networking, monitoring and the Coolify node module; `hosts/nova/` sets the static IP and hardware; `hosts/elara/` adds static networking, hardware and a disko layout; `hosts/zenith/` has DNS/hosts entries only and needs a hardware config before it can be installed.

## Common config

| Component | Notes |
|-----------|-------|
| Wings | `inputs.pterodactyl-wings` overlay binary (Wings 1.13.4 in the current lock), `wings.service` |
| Docker | Enabled with `liveRestore = true`, so game servers keep running when dockerd restarts on a rebuild (Wings requirement; ace uses Podman instead) |
| TLS certs | NFS symlink from ace Let's Encrypt (`link-letsencrypt.nix`); ace exports each active node's share read-only with `root_squash` (`nixos/nfs/default.nix`) |
| Container network | Game containers reach the internet only: no LAN, tailnet, link-local or ULA destinations and no services on the node itself (`homelab.security.containerEgress`, `nixos/security/container-egress.nix`). Published game ports still work. |
| SSH | Keys-only; only Nix-declared keys count (`~/.ssh/authorized_keys` is ignored); no TCP/agent/X11 forwarding; root@ace's automation key only from `192.168.5.5` (`nixos/security/ssh.nix`) |
| DNS | Clients use ace Technitium `192.168.5.5`; nodes resolve panel via `/etc/hosts` or Technitium |
| Monitoring | crux runs local Prometheus + blackbox probes (`nixos/monitoring/crux-*.nix`) |

## LAN DNS names (preferred)

| Hostname | LAN IP |
|----------|--------|
| `crux.lc1.nm.us.prestonhager.com` | **192.168.5.6** |
| `nova.lc1.nm.us.prestonhager.com` | **192.168.5.7** |
| `elara.lc1.nm.us.prestonhager.com` | **192.168.5.8** |
| `zenith.lc1.nm.us.prestonhager.com` | **192.168.5.9** (planned) |

Shorter aliases (`crux.prestonhager.com`, `nova.prestonhager.com`) also resolve on LAN via Technitium CNAMEs for hosts that are already in DNS.

Deploy an existing node:

```bash
sudo nixos-rebuild switch --flake /etc/nixos#crux   # or #elara (#nova once reattached)
```

Untrusted workload surface — log forwarding, fail2ban, and isolation playbooks for these nodes are in the [IDS & Security Monitoring Plan](../shared/security-ids-plan.md) (§8). Addressing and switch ports: [Network topology](../shared/network-topology.md).
