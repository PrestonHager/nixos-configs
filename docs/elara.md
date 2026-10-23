# Elara

**Pterodactyl Wings** node (Dell OptiPlex) at **192.168.5.8**.

| Field | Value |
|-------|-------|
| Hostname | `elara` |
| Flake | `nixos-rebuild switch --flake /etc/nixos#elara` |
| Module tree | `hosts/pterodactyl-nodes/default.nix` + `hosts/elara/` (`default.nix`, `hardware.nix`, `disko.nix`) |
| IPv4 | **`192.168.5.8/24`** static (`eno1`) |
| Gateway | `192.168.5.1` |
| DNS | `192.168.5.5` (ace Technitium), `1.1.1.1` |
| Hardware | Dell OptiPlex |
| Role | Pterodactyl Wings node |
| Switch port | *not yet labelled* |
| WAN | None (same pattern as crux — LAN only + outbound PAT) |
| Preferred TLS / Wings domain | `elara.lc1.nm.us.prestonhager.com` |

## Status (Oct 2026)

**Online.** elara answers SSH from ace as root with root@ace's automation key; root's keys are declared only in `hosts/pterodactyl-nodes/default.nix` (the bootstrap-era `root@ph-nixos` RSA key was removed, and `~/.ssh/authorized_keys` files are ignored). Checked read-only on 2026-10-18: `wings` is `active` and the host runs NixOS 26.11. The deployed Wings binary was 1.12.3, older than the 1.13.4 the flake currently pins, so elara has not been rebuilt from the current tree yet.

`disko.nix` is kept in git for a future `nixos-anywhere` install; `disko.enableConfig = false`, so a switch never formats disks.

Grafana probes `192.168.5.8:22` (SSH, `service_tier = non-essential`, `nixos/monitoring/prometheus-config.nix`).

## Verify

```bash
ssh root@192.168.5.8 'systemctl is-active wings docker; nixos-version'
dig @192.168.5.5 elara.lc1.nm.us.prestonhager.com +short   # expect 192.168.5.8
```

## Related

- [Network topology](../shared/network-topology.md)
- Other Wings nodes: [crux](crux.md) (`192.168.5.6`), [nova](nova.md) (`192.168.5.7`, disconnected)
