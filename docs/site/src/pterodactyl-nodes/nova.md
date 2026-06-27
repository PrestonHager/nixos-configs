# Nova

Pterodactyl Wings node at **192.168.5.7**.

| Field | Value |
|-------|-------|
| Hostname | `nova` |
| Flake | `nixos-rebuild switch --flake /etc/nixos#nova` |
| Module tree | Same as crux (`hosts/pterodactyl-nodes/default.nix`) |
| Hardware | Dell OptiPlex 7050 (`hardware/dell-optiplex-7050/`) |

Nova is defined in `flake.nix` via `nodes.nova = ./hosts/pterodactyl-nodes` with `networking.hostName = "nova"`. There is no separate `hosts/nova/default.nix` today — add one if nova needs different networking or monitoring from crux.

## LAN names

| Name | IP |
|------|-----|
| `nova.internal.prestonhager.com` | 192.168.5.7 |
| `nova.prestonhager.com` | CNAME → internal |
| `nova.lc1.nm.us.prestonhager.com` | CNAME → internal (legacy) |

NFS TLS domain: `nova.lc1.nm.us.prestonhager.com` (`nixos/nfs/default.nix`).

## Deploy

```bash
sudo nixos-rebuild switch --flake /etc/nixos#nova
```

## Verify

```bash
systemctl status wings docker
dig @192.168.5.5 nova.prestonhager.com +short   # expect 192.168.5.7
```
