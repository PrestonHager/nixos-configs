# Zenith

Planned **Pterodactyl Wings** node (Dell OptiPlex) at **192.168.5.9**.

| Field | Value |
|-------|-------|
| Hostname | `zenith` |
| Flake | `#zenith` (defined; not deployable yet) |
| Module tree | `hosts/pterodactyl-nodes/default.nix` + `hosts/zenith/default.nix` |
| IPv4 | **`192.168.5.9/24`** reserved (the host config still uses DHCP) |
| Gateway | `192.168.5.1` |
| Hardware | Dell OptiPlex — **no hardware config in the repo yet** |
| Role | Pterodactyl Wings node |
| Switch port | *unassigned* — label when cabled |
| WAN | None (same pattern as crux — LAN only + outbound PAT) |
| Preferred TLS / Wings domain (planned) | `zenith.lc1.nm.us.prestonhager.com` |

## Status (Oct 2026)

**Planned, not connected.** The flake target exists (`nodes.zenith` in `flake.nix`, `hosts/zenith/default.nix`), but there is no hardware configuration yet, and SSH to `192.168.5.9` does not answer (no route to host from ace, 2026-10-18). Add `hardware.nix` (and disko layout) the way [elara](elara.md) does before the first install.

## Related

- [Network topology](../shared/network-topology.md)
- Other Wings nodes: [crux](crux.md) (`192.168.5.6`), [elara](elara.md) (`192.168.5.8`), [nova](nova.md) (`192.168.5.7`, disconnected)
