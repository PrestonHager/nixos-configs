# LanCache on ace

Implementation: `nixos/containers/lancache.nix` (monolithic + lancache-dns + sniproxy pod).

## Storage

- `CACHE_ROOT`: `/stor/lancache/cache` (1.4T `/stor` volume)
- `CACHE_DISK_SIZE`: 1000g cap

## IPs and ports

| Service | Bind | Notes |
|---------|------|-------|
| Caddy | `192.168.5.5:80/443` | Unchanged for `*.prestonhager.com` |
| lancache-dns | `192.168.5.5:53` udp/tcp | For **game LAN clients only** (not house DNS at 192.168.5.2) |
| LanCache HTTP/HTTPS (pod) | host `8084` → cache `:80`, `8443` → `:443` | Published on ace; CDN clients use DNS to reach cache IP |

`LANCACHE_IP` / `DNS_BIND_IP`: **192.168.5.5** (bond0). sniproxy in the pod handles HTTPS passthrough for non-cache SNI where needed.

## DHCP / DNS setup

Point gaming clients (or a VLAN) at **192.168.5.5** as DNS. Ace resolver stays **192.168.5.2**.

## Cloudflare

No changes for LanCache. Keep proxied A/AAAA for app hostnames (`cloud`, `zitadel`, `grafana`, etc.).

## Local hosts (Caddy apps on ace)

See `nixos/local-service-hosts.nix` — loopback or `192.168.5.5` for:

- `cloud.prestonhager.com`, `zitadel.prestonhager.com`, `grafana.prestonhager.com`, `prometheus.prestonhager.com`, `jellyfin.prestonhager.com`, `vault.prestonhager.com`, `wg.prestonhager.com`, `panel.prestonhager.com`, `test.panel.prestonhager.com`, `matrix.prestonhager.com`, wiki hosts, etc.

Do not add CDN hostnames to hosts; use lancache-dns for those clients.
