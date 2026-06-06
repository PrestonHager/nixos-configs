# LanCache on ace

Implementation: `nixos/containers/lancache.nix` (monolithic + lancache-dns pod). Upstream DNS: **Technitium** via `nixos/containers/technitium.nix`. Full chain: **`docs/dns-ace.md`**.

## Storage

- `CACHE_ROOT`: `/stor/lancache/cache` (1.4T `/stor` volume)
- `CACHE_DISK_SIZE`: 1000g cap

## IPs and ports

| Service | Bind | Notes |
|---------|------|-------|
| Caddy | `192.168.5.5:80/443` | Unchanged for `*.prestonhager.com` |
| lancache-dns | `192.168.5.5:53` udp/tcp | **House / game LAN DNS** (DHCP → 192.168.5.5) |
| LanCache HTTP/HTTPS (pod) | host `8084` → cache `:80`, `8443` → `:443` | CDN clients use DNS to reach cache IP |
| Technitium (upstream) | `127.0.0.1:5353` | LanCache `UPSTREAM_DNS=10.88.0.1` (relay) |

`LANCACHE_IP` / `DNS_BIND_IP`: **192.168.5.5** (bond0).

## DHCP / DNS setup

Point house or gaming clients at **192.168.5.5** as DNS. Ace host resolver stays **192.168.5.2** (see `hosts/ace/default.nix`).

## Cloudflare

Proxied **A** for **`dns.prestonhager.com`** → `192.168.5.5` (Technitium UI via Caddy). Other app hostnames unchanged.

## Local hosts (Caddy apps on ace)

See `nixos/local-service-hosts.nix` — includes **`dns.prestonhager.com`**, `cloud.prestonhager.com`, `zitadel.prestonhager.com`, etc.

Do not add CDN hostnames to hosts; clients resolve those via lancache-dns.
