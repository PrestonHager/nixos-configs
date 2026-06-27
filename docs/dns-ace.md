# DNS on ace (Technitium)

Implementation: `nixos/containers/technitium.nix`, `nixos/containers/technitium-zones.nix`, `nixos/containers/technitium-sso.nix`, Caddy `nixos/caddy/technitium.nix`.

LanCache (`nixos/containers/lancache.nix`) is **disabled** — it was slowing DNS resolution. Technitium is the primary LAN DNS server.

Physical path: [Network topology](network-topology.md) (Astracap DHCP hands clients DNS **192.168.5.5**).

## Query path

```mermaid
flowchart LR
  Client["LAN client DHCP DNS"]
  Tech["Technitium 192.168.5.5:53"]
  CF["Cloudflare 1.1.1.1 / 1.0.0.1"]
  Client --> Tech
  Tech --> CF
```

1. **Clients** use DHCP DNS **192.168.5.5** (ace / Technitium).
2. **Technitium** serves **Primary** zones for `internal.prestonhager.com` and `prestonhager.com`, then recurses other names via forwarders **1.1.1.1** and **1.0.0.1**.

Ace itself uses resolver **192.168.5.5** in `hosts/ace/default.nix` (Technitium on bond0).

## Ports

| Service | Bind | Notes |
|---------|------|-------|
| Technitium DNS | `192.168.5.5:53` udp/tcp | **Primary house / game LAN DNS** |
| Technitium DNS (loopback) | `127.0.0.1:5353` udp/tcp | Local diagnostics / `dig @127.0.0.1 -p 5353` |
| Technitium UI | `127.0.0.1:5380` tcp | Caddy → `dns.prestonhager.com` |
| Technitium DoH backend | `127.0.0.1:8053` tcp | DNS-over-HTTP; Caddy terminates TLS |
| Technitium DoT | `:853` tcp | Native TLS (PFX from Caddy LE cert) |
| Caddy DoH / HTTP/3 | `:443` tcp + udp | `https://dns.prestonhager.com/dns-query` |

Plain DNS on **192.168.5.5:53** (Technitium). Encrypted DNS is additive.

## Encrypted DNS (DoH, DoT, HTTP/3)

### Architecture

| Protocol | Termination | Backend | Client URL |
|----------|-------------|---------|------------|
| **DoH** | Caddy (Let's Encrypt via existing ace TLS) | Technitium DNS-over-HTTP on `127.0.0.1:8053` | `https://dns.prestonhager.com/dns-query` |
| **HTTP/3** | Caddy (`protocols h1 h2 h3`, UDP/443) | Same DoH path | Same URL (HTTP/3 when client supports QUIC) |
| **DoT** | Technitium native TLS | Technitium DNS TCP `:853` | `dns.prestonhager.com:853` |

Caddy handles DoH so TLS renewal stays centralized and HTTP/3 works without Technitium binding port 443. DoT uses Technitium's built-in listener; the LE certificate is exported from Caddy's on-disk cert store to PKCS#12 (`technitium-sync-tls-cert.service`) and applied via the Technitium API (`technitium-sync-protocols.service`).

Implementation: `nixos/caddy/technitium.nix`, `nixos/containers/technitium.nix`, `nixos/containers/technitium-protocols.nix`.

### Client configuration

| Client type | Setting |
|-------------|---------|
| DoH (browser, Android Private DNS, iOS profile) | `https://dns.prestonhager.com/dns-query` |
| DoT (Android, router, `systemd-resolved`) | `dns.prestonhager.com` port **853** |
| Plain DNS | `192.168.5.5` |

Recursion remains **AllowOnlyForPrivateNetworks** — LAN and RFC1918 clients get answers; public IPs may receive `REFUSED` unless you widen recursion in Technitium settings.

### Cloudflare DNS records

| Type | Name | Content | Proxy | Purpose |
|------|------|---------|-------|---------|
| CNAME | `dns` | `ip1.lc1.nm.us.prestonhager.com` | **DNS only (grey)** | DoH + web UI via Caddy :443 on ace WAN |

Do **not** orange-cloud names to `192.168.5.5` — Cloudflare cannot reach private LAN IPs and may return empty responses. LAN clients resolve via Technitium split-horizon to ace directly.

**DoT on port 853 does not traverse Cloudflare's HTTP proxy.** For encrypted DNS from the public Internet over DoT, use WAN IP / NAT to ace `:853`, or connect over LAN/VPN.

### Deploy encrypted DNS

After `nixos-rebuild switch --flake /etc/nixos#ace`:

```bash
systemctl status technitium-sync-tls-cert technitium-sync-protocols caddy
ss -tlnp | grep -E '8053|853|443'
```

## Storage

- Technitium config/logs: `/stor/technitium`, `/stor/technitium/logs`
- Zone sync hashes: `/stor/technitium/.internal-prestonhager-com-zone.sha256`, `/stor/technitium/.prestonhager-com-zone.sha256`
- LanCache data (unused): `/stor/lancache` — retained on disk; container disabled

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
| ai, panel, test.panel, prometheus, jellyfin, vault, wg, metrics.wg, zitadel, git, matrix, spacetime, test.sui, faucet.test.sui, indexer.test.sui, factorio, game, lancache, mc, vpn, serverdocs | CNAME | ace.internal.prestonhager.com |
| crux.lc1.nm.us | CNAME | crux.internal.prestonhager.com |
| nova.lc1.nm.us | CNAME | nova.internal.prestonhager.com |

External Cloudflare CNAMEs (blog, github.io sites, dontgetgot, ACM validation, etc.) and apex **MX/TXT/SRV** records are copied into the Technitium zone unchanged so LAN clients still resolve them without NXDOMAIN from the partial primary zone.

### Cloudflare `ip1.lc1` → LAN mapping

Public Cloudflare CNAMEs that target `ip1.lc1.nm.us.prestonhager.com` (73.26.67.25) are overridden on LAN as follows:

| Public name | LAN target |
|-------------|------------|
| cloud, dns, grafana | matching `*.internal.prestonhager.com` A → 192.168.5.5 |
| ace, ai, factorio, faucet.test.sui, game, indexer.test.sui, jellyfin, lancache, matrix, mc, metrics.wg, panel, prometheus, spacetime, test.panel, test.sui, vault, vpn, wg, zitadel, serverdocs | ace.internal.prestonhager.com → 192.168.5.5 |
| crux.lc1.nm.us | crux.internal.prestonhager.com → 192.168.5.6 |
| nova.lc1.nm.us | nova.internal.prestonhager.com → 192.168.5.7 |

### `lc1.nm.us.prestonhager.com` names (preferred for Wings / nodes)

These are the **preferred** hostnames for Pterodactyl Wings nodes and TLS — not being migrated away.

| Hostname | LAN (`@192.168.5.5`) | Public Internet |
|----------|----------------------|-----------------|
| `crux.lc1.nm.us.prestonhager.com` | **192.168.5.6** | **192.168.5.6** (Cloudflare A) |
| `nova.lc1.nm.us.prestonhager.com` | **192.168.5.7** | **192.168.5.7** (Cloudflare A) |
| `ip1.lc1.nm.us.prestonhager.com` | ace.internal → 192.168.5.5 | **73.26.67.25** (WAN / NAT to ace) |

Shorter aliases also resolve on LAN when DHCP DNS is 192.168.5.5:

| Name | Resolves via |
|------|--------------|
| `crux.prestonhager.com` | → crux.internal → 192.168.5.6 |
| `nova.prestonhager.com` | → nova.internal → 192.168.5.7 |
| `ace.prestonhager.com` | → ace.internal → 192.168.5.5 |
| Ace Caddy vhosts (`grafana.prestonhager.com`, etc.) | CNAME → ace.internal or matching `*.internal` |

Wings NFS TLS and Caddy certificates use `crux.lc1.nm.us.prestonhager.com` / `nova.lc1.nm.us.prestonhager.com` (`nixos/nfs/default.nix`, `nixos/caddy/pterodactyl.nix`).

## Cloudflare DNS (public Internet)

Public `prestonhager.com` records stay in Cloudflare; the Technitium zone is for split-horizon LAN resolution only.

### Ace Caddy apps (grafana, vault, cloud, panel, …)

Use **DNS only** (grey cloud). Do **not** orange-cloud these names to a private LAN IP — Cloudflare cannot reach `192.168.5.5` and may return **HTTP 200 with an empty body** (`Content-Length: 0`, `Server: cloudflare`) while LAN clients work fine.

Working pattern (same as grafana):

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| CNAME | `vault` (and other ace apps) | `ip1.lc1.nm.us.prestonhager.com` | DNS only (grey) |

`ip1.lc1.nm.us.prestonhager.com` A → `73.26.67.25` (Cisco WAN / NAT → ace `:443`).

After changing proxy status, purge Cloudflare cache for the hostname. Verify from outside LAN:

```bash
curl -sS -D - -o /dev/null -w 'bytes=%{size_download}\n' https://vault.prestonhager.com/
# expect bytes in the tens of thousands, not 0
```

### Technitium DoH (`dns.prestonhager.com`)

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| CNAME | `dns` | `ip1.lc1.nm.us.prestonhager.com` | DNS only (grey) |

DoT on port 853 does not traverse Cloudflare's HTTP proxy; use WAN NAT or LAN/VPN (see above).

## Local hosts (ace)

`nixos/local-service-hosts.nix` includes **`dns.prestonhager.com`** → `127.0.0.1` and internal names on LAN IPs. Apply with your usual `nixos-rebuild switch` on ace.

## DHCP (house / game LAN)

Set **primary DNS** to **192.168.5.5** on the router or DHCP scope.

## Technitium first run

1. Deploy config and `nixos-rebuild switch --flake /etc/nixos#ace`.
2. Open https://dns.prestonhager.com (or `http://127.0.0.1:5380` on ace).
3. Default admin password is in `/stor/technitium/secrets/admin-password` (created on first boot).
4. `technitium-sync-zones.service` imports Nix-defined zones automatically.

## Verification

```bash
# LAN DNS (primary)
dig @192.168.5.5 crux.lc1.nm.us.prestonhager.com +short    # 192.168.5.6
dig @192.168.5.5 nova.lc1.nm.us.prestonhager.com +short   # 192.168.5.7
dig @192.168.5.5 cloud.prestonhager.com +short            # 192.168.5.5

# Loopback (diagnostics)
dig @127.0.0.1 -p 5353 crux.lc1.nm.us.prestonhager.com +short

# DoH (POST with wire-format DNS message — preferred by Technitium)
curl -sS -H 'Content-Type: application/dns-message' \
  --data-binary @<(printf '\x00\x00\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x04dns\x0bprestonhager\x03com\x00\x00\x01\x00\x01') \
  https://dns.prestonhager.com/dns-query | xxd | head
```

## Adding or changing LAN records

1. **Preferred:** Edit `internalHosts` and/or `prestonhagerHosts` in `technitium-zones.nix`, bump the zone serial, run `nixos-rebuild switch --flake /etc/nixos#ace`. Delete the matching `/stor/technitium/.*-zone.sha256` file to force re-import without a serial bump.
2. **Ad hoc:** Technitium web UI at https://dns.prestonhager.com (changes not in Nix will be overwritten on next zone sync unless excluded).

## Deprecated: LanCache

LanCache game CDN caching is disabled in `nixos/containers/default.nix`. See `docs/lancache-ace.md` for the previous architecture if re-enabling.
