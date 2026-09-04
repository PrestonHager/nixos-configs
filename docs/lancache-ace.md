# LanCache on ace (deprecated)

> **Status:** Disabled as of 2026-06. Technitium serves primary LAN DNS on **192.168.5.5:53**. LanCache was removed because it slowed DNS resolution for the whole network.
>
> See **`docs/dns-ace.md`** for the current DNS stack.

## Previous architecture

When enabled, `nixos/containers/lancache.nix` ran a Podman pod (monolithic + lancache-dns) that:

- Answered **192.168.5.5:53** for LAN clients
- Hijacked game CDN hostnames for local caching
- Forwarded other queries to Technitium via a podman-bridge socat relay (`10.88.0.1:53` → `127.0.0.1:5353`)

## Storage (retained on disk)

- `CACHE_ROOT`: `/stor/lancache/cache` (1.4T `/stor` volume)
- `CACHE_DISK_SIZE`: 1000g cap

## Re-enabling (not recommended)

1. Uncomment `./lancache.nix` in `nixos/containers/default.nix`
2. Revert Technitium to loopback-only DNS binding in `technitium.nix` (remove `192.168.5.5:53` publish; restore upstream relay services)
3. `nixos-rebuild switch --flake /etc/nixos#ace`
