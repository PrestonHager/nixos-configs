# Nova

Pterodactyl Wings node at **192.168.5.7**.

**Status (Oct 2026): physically disconnected.** The flake target is kept as a template so nova can be reattached without new config; the IP stays reserved.

| Field | Value |
|-------|-------|
| Hostname | `nova` |
| Flake | `nixos-rebuild switch --flake /etc/nixos#nova` |
| Module tree | `hosts/pterodactyl-nodes/default.nix` + `hosts/nova/default.nix` |
| Hardware | Dell OptiPlex 7050 (`hardware/dell-optiplex-7050/`) |
| Preferred TLS / Wings domain | `nova.lc1.nm.us.prestonhager.com` |

Nova is defined in `flake.nix` via `nodes.nova = ./hosts/pterodactyl-nodes` with `networking.hostName = "nova"`. `hosts/nova/default.nix` sets the static IP (`192.168.5.7` on `enp0s31f6`), its `/etc/hosts` entry, the OptiPlex 7050 hardware config and promtail.

## LAN names

| Name | IP |
|------|-----|
| `nova.lc1.nm.us.prestonhager.com` | **192.168.5.7** (preferred) |
| `nova.internal.prestonhager.com` | 192.168.5.7 |
| `nova.prestonhager.com` | CNAME → internal |

NFS TLS domain: `nova.lc1.nm.us.prestonhager.com` (`nixos/nfs/default.nix`).

## Deploy (once reattached)

```bash
sudo nixos-rebuild switch --flake /etc/nixos#nova
```

## Verify

```bash
systemctl status wings docker
dig @192.168.5.5 nova.lc1.nm.us.prestonhager.com +short   # expect 192.168.5.7
```

## Related

- [Network topology](../shared/network-topology.md)
- [Crux](crux.md) (same module tree)
