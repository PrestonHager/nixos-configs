# Crux

Pterodactyl Wings node at **192.168.5.6**.

| Field | Value |
|-------|-------|
| Hostname | `crux` |
| Flake | `nixos-rebuild switch --flake /etc/nixos#crux` |
| Gateway | 192.168.5.1 |
| DNS | 192.168.5.5 (ace LanCache), 1.1.1.1 |
| Interface | `enp0s31f6` static |

## Host-specific config

`hosts/crux/default.nix` sets static IP and `/etc/hosts` entries for ace panel and internal names. Imports:

- `hosts/pterodactyl-nodes/` — Wings, Docker, MariaDB (local), NFS LE certs
- `nixos/monitoring/crux-probes.nix` — blackbox HTTP/TCP probes
- `nixos/monitoring/crux-prometheus.nix` — local Prometheus scraping ace + crux

## SSH

```bash
ssh root@192.168.5.6
# or from LAN: ssh root@crux.prestonhager.com
```

## NFS / TLS

Wings reads Let's Encrypt certificates from ace via NFS mount (`hosts/pterodactyl-nodes/nfs.nix`). Domain pattern may still reference `crux.lc1.nm.us.prestonhager.com` in Cloudflare until fully migrated to `crux.prestonhager.com`.

## Verify Wings

```bash
systemctl status wings docker
journalctl -u wings -n 50
```
