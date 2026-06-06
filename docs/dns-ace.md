# DNS on ace (LanCache + Technitium)

Implementation: `nixos/containers/lancache.nix`, `nixos/containers/technitium.nix`, `nixos/containers/technitium-zones.nix`, Caddy `nixos/caddy/technitium.nix`.

## Query path

```mermaid
flowchart LR
  Client["LAN client DHCP DNS"]
  LC["LanCache DNS 192.168.5.5:53"]
  Tech["Technitium 127.0.0.1:5353"]
  CF["Cloudflare 1.1.1.1 / 1.0.0.1"]
  Client --> LC
  LC -->|"cache miss / non-CDN"| Relay["socat 10.88.0.1:53"]
  Relay --> Tech
  Tech --> CF
```

1. **Clients** use DHCP DNS **192.168.5.5** (ace).
2. **LanCache DNS** answers hijacked game CDN names and forwards everything else upstream.
3. **Upstream** is **10.88.0.1:53** on the podman bridge — a host **socat** relay to **Technitium** on **127.0.0.1:5353** (not published on bond0).
4. **Technitium** serves **Primary** zones for `internal.prestonhager.com` and `prestonhager.com`, then recurses other names via forwarders **1.1.1.1** and **1.0.0.1**.

Ace itself keeps resolver **192.168.5.2** in `hosts/ace/default.nix` so the server does not loop through LanCache.

## Ports

| Service | Bind | Notes |
|---------|------|-------|
| LanCache DNS | `192.168.5.5:53` udp/tcp | House / game LAN DNS |
| Technitium DNS | `127.0.0.1:5353` udp/tcp | Upstream for LanCache only |
| Technitium UI | `127.0.0.1:5380` tcp | Caddy → `dns.prestonhager.com` |
| Podman relay | `10.88.0.1:53` udp/tcp | Not routed from LAN; pod → Technitium |

## Storage

- LanCache: `/stor/lancache`
- Technitium config/logs: `/stor/technitium`, `/stor/technitium/logs`
- Zone sync hashes: `/stor/technitium/.internal-prestonhager-com-zone.sha256`, `/stor/technitium/.prestonhager-com-zone.sha256`

## Zones (Nix → Technitium API)

Authoritative records live in `nixos/containers/technitium-zones.nix` (`internalHosts`, `prestonhagerHosts`). `technitium-sync-zones.service` logs into the Technitium HTTP API and imports generated zone files (idempotent; re-runs when a zone file hash changes).

Technitium is configured with `DNS_SERVER_DOMAIN=internal.prestonhager.com` so the server does not default to `ip1.lc1.nm.us.prestonhager.com`-style automatic names. Do not recreate `lc1.nm.us` zones in Technitium.

### Zone: `internal.prestonhager.com`

| Host | Type | Target / IP |
|------|------|-------------|
| ace | A | 192.168.5.5 |
| crux | A | 192.168.5.6 |
| nova | A | 192.168.5.7 |
| grafana | A | 192.168.5.5 |
| cloud | A | 192.168.5.5 |
| dns | A | 192.168.5.5 |

### Zone: `prestonhager.com` (LAN only)

This zone overrides public Cloudflare answers for LAN clients using ace as DNS. The apex is not defined here (no `@` A/AAAA); only listed subdomains are authoritative on Technitium.

| Name | Type | Target |
|------|------|--------|
| ace | CNAME | ace.internal.prestonhager.com |
| crux | CNAME | crux.internal.prestonhager.com |
| nova | CNAME | nova.internal.prestonhager.com |
| grafana | CNAME | grafana.internal.prestonhager.com |
| cloud | CNAME | cloud.internal.prestonhager.com |
| dns | CNAME | dns.internal.prestonhager.com |
| panel, test.panel, testpanel, prometheus, jellyfin, vault, wg, metrics.wg, zitadel, portunus, git, matrix, spacetime, test.sui, faucet.test.sui, indexer.test.sui | CNAME | ace.internal.prestonhager.com |

### Legacy `lc1.nm.us.prestonhager.com` → new names

Public DNS discovery (Cloudflare authoritative for `prestonhager.com`):

| Query | Result (public) |
|-------|-----------------|
| `prestonhager.com` NS | ivy.ns.cloudflare.com, felipe.ns.cloudflare.com |
| `prestonhager.com` A | 185.199.108–111.153 (GitHub Pages) |
| `crux.lc1.nm.us.prestonhager.com` A | 192.168.5.6 |
| `nova.lc1.nm.us.prestonhager.com` A | 192.168.5.7 |
| `ip1.lc1.nm.us.prestonhager.com` A | 73.26.67.25 |
| Other `*.lc1.nm.us.prestonhager.com` service names | No public A records observed |

LAN mapping (use these instead of `*.lc1.nm.us.prestonhager.com` when DHCP DNS is 192.168.5.5):

| Old / Wings / TLS pattern | Preferred LAN name | Resolves via |
|---------------------------|-------------------|--------------|
| `crux.lc1.nm.us.prestonhager.com` | `crux.prestonhager.com` | → crux.internal → 192.168.5.6 |
| `nova.lc1.nm.us.prestonhager.com` | `nova.prestonhager.com` | → nova.internal → 192.168.5.7 |
| `ip1.lc1.nm.us.prestonhager.com` (WAN) | `ace.prestonhager.com` | → ace.internal → 192.168.5.5 |
| Ace Caddy vhosts (`grafana.prestonhager.com`, etc.) | same short name under `prestonhager.com` | CNAME → ace.internal or matching `*.internal` |

Wings and public TLS may still reference `*.lc1.nm.us.prestonhager.com` in Cloudflare and `/etc/hosts` on nodes until migrated.

## Cloudflare DNS

Add a **proxied** record (same pattern as other ace Caddy apps):

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| A | `dns` | `192.168.5.5` | Proxied (orange cloud) |

Public `prestonhager.com` records stay in Cloudflare; the Technitium zone is for split-horizon LAN resolution only.

## Local hosts (ace)

`nixos/local-service-hosts.nix` includes **`dns.prestonhager.com`** → `127.0.0.1` and internal names on LAN IPs. Apply with your usual `nixos-rebuild switch` on ace.

## DHCP (house / game LAN)

Set **primary DNS** to **192.168.5.5** on the router or DHCP scope.

## Technitium first run

1. Deploy config and `nixos-rebuild switch --flake /etc/nixos#ace`.
2. Confirm `systemctl status technitium-sync-zones` is **active (exited)**.
3. Open **https://dns.prestonhager.com** and sign in as **`admin`** (password in sops).
4. Confirm forwarders **1.1.1.1 / 1.0.0.1** under Settings if you use a pre-existing data dir.

## Verify

```bash
# From a DHCP client using 192.168.5.5 as DNS
dig @192.168.5.5 ace.internal.prestonhager.com +short
dig @192.168.5.5 crux.prestonhager.com +short
dig @192.168.5.5 grafana.prestonhager.com +short

# On ace — Technitium directly
dig @127.0.0.1 -p 5353 crux.internal.prestonhager.com +short
dig @127.0.0.1 -p 5353 crux.prestonhager.com +short

# Relay from podman bridge
dig @10.88.0.1 ace.internal.prestonhager.com +short
```

### Add a host later

1. **Preferred:** Edit `internalHosts` and/or `prestonhagerHosts` in `technitium-zones.nix`, bump the zone serial, run `nixos-rebuild switch --flake /etc/nixos#ace`. Delete the matching `/stor/technitium/.*-zone.sha256` file to force re-import without a serial bump.
2. **Ad hoc:** Technitium UI → Zones → edit record. UI changes may be overwritten on the next sync unless Nix is updated too.

### Reverse DNS (optional)

PTR for `192.168.5.0/24` is not managed in Nix today.

## Related

See also `docs/lancache-ace.md` for cache storage and HTTP ports.