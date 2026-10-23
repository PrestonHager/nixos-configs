# Security audit (October 2026)

A read-only audit of the whole homelab ran on 2026-10-22, followed by fixes deployed the same day. This page records what was looked at, what changed, and what is still open. Details of how individual issues could be exploited are deliberately left out: this repository is public.

## Scope and method

| Area | How |
|---|---|
| nixos-configs repository | Full tree and all git history (secrets, Caddy exposure, firewalls, containers, SSH, users, sops handling, input age) |
| ace (live) | Listening sockets, nftables/iptables, Podman containers (capabilities, users, mounts, networks), SSH, file modes, auth logs, backups |
| crux, elara, mars (live) | Same, plus Docker/Wings/Coolify container isolation and egress tests from container network namespaces |
| Network edge | Astracap (operational `show` output), Astraquasar (full config), iDRACs (unauthenticated TLS/port checks), LAN host discovery, public DNS / certificate-transparency names, external HTTP checks |

No logins were attempted on anything that needed a password, and nothing was exploited.

## Results at a glance

| Severity | Found | Fixed in config (deployed) | Needs owner action | Planned / accepted |
|---|---|---|---|---|
| Critical | 2 | 1 | 1 (switch) | — |
| High | 16 | 9 | 5 | 2 |
| Medium | 23 | 15 | 3 | 5 |
| Low and info | ~40 | most | a few | rest |

Counts merge duplicates reported by more than one part of the audit.

## Fixed

### CI runners (`nixos/services/github-runner*`, `nixos/containers/animal-search.nix`)

- The animal-search deploy unit no longer trusts anything the CI runner can write. The runner gets only an inbox (`inbox/releases`, `inbox/deploy`) per environment; the root unit claims requests without following links, accepts only a 40-character hex SHA, copies the release into root-owned storage, and runs under a strict systemd sandbox. Live releases and MariaDB data are not visible to the runner. The group-5 `deploy.yml` contract is unchanged. See [GitHub Actions runners](github-runner.md) (and `docs/animal-search-ace.md` in the repository).
- All runners are on a dedicated Podman network (`ghrunner`, `10.250.250.0/24`) that can reach the internet only: private ranges, the tailnet and ace itself are dropped before any other rule sees the traffic. An assertion stops the bridge from ever being trusted.
- The persistent runner's registration is mounted read-only and copied into the container; the shared toolchain directory is an overlay for every runner; credential files are 0600 and work directories are wiped around each run; the GitHub token is no longer on command lines; `mountPodmanSocket` defaults to false.

### ace host and containers (`nixos/monitoring`, `nixos/containers`)

- `podman0` is no longer a trusted firewall interface. Containers and WireGuard clients reach only the host ports they need (DNS, HTTP(S), Caddy metrics, Loki, node and blackbox exporters).
- Redis/Valkey for MediaWiki, Nextcloud and the Pterodactyl panel require a password (generated on the host under `/var/lib/redis-auth`) and listen on loopback inside their pods.
- wg-portal no longer has `CAP_SYS_MODULE` (the `wireguard` module loads on the host) and `wg0.conf` is kept at 0600.
- `www-data` is no longer in the `podman` group.
- Exporters and Loki listen only where their consumers are; pushgateway and Jellyfin are no longer published on every address.
- The Zitadel login key is 0640 with a dedicated group; the Grafana image renderer runs without `CAP_SYS_ADMIN`; Technitium and MariaDB credentials are no longer passed on command lines; the `pterodactyl` system account is locked; dangling images are pruned weekly.

See [Monitoring](../ace/monitoring.md).

### Internet exposure (`nixos/caddy`, Coolify, Pterodactyl test panel)

- One shared LAN allowlist (`nixos/caddy/lib.nix`: loopback, `192.168.5.0/24`, the tailnet, WireGuard clients) guards every admin surface. Now LAN/tailnet/VPN-only: the Coolify dashboard, realtime socket, web terminal and API (only `/webhooks/*` stays public), the WireGuard portal, the Pterodactyl test panel, Vaultwarden `/admin`, Synapse's admin API, plus the existing Prometheus, DNS console, serverdocs and wg metrics.
- The test panel runs without debug output, with a host-only session cookie and exact trusted proxies, and no longer has the router key; its port-forward extension is always a dry run.
- coolify-edge routes only the root team's apps, refuses sensitive hostnames (ace's own vhosts and labels such as login, auth, vault, admin), does not forward databases unless explicitly enabled, caps forwarded ports, logs every change at warning level, rate-limits the on-demand TLS check, and runs sandboxed. Coolify registration is pinned off.
- HSTS, `nosniff` and Referrer-Policy on public vhosts; the update-approval links now need a POST from a confirmation page; Pterodactyl `TRUSTED_PROXIES` narrowed; no vhosts or certificates for disconnected Wings nodes.

See [Coolify](../ace/coolify.md) and [DNS](dns.md).

### Nodes, SSH and shared security modules (`nixos/security`, `hosts/*`, `nixos/nfs`)

- Game-server and Coolify app containers can reach the internet but not the LAN, the tailnet or their own host (`homelab.security.containerEgress`); blocked attempts are logged as `ctr-egress-drop`.
- mars accepts new connections to published container ports from private sources only when they are ace → :80 (`coolify-ingress`).
- SSH: forwarding is off on every host; on the nodes and mars only Nix-declared keys count; automation keys from ace are pinned to `from="192.168.5.5"`; a stale root key was removed from elara. elara (which had drifted to an old generation) was redeployed.
- fail2ban now matches OpenSSH 10's `sshd-session` and no longer ignores the whole LAN.
- node_exporter is reachable only from ace; NFS certificate shares are exported only to active nodes, with `root_squash`; AIDE excludes container data and re-baselines after rebuilds; auditd runs with bounded logs.

See [IDS test cases](security-ids-test-cases.md) (TC-1.6, TC-1.7, TC-2.6) and [mars](../poweredge/mars.md).

## Needs owner action

These need credentials or console access that automation does not have.

| Item | Severity | What to do |
|---|---|---|
| Astraquasar web UI | Critical | Disable `ip http server` / `ip http secure-server` after checking for signs of compromise; plan an IOS-XE upgrade (16.12.10a or later). |
| Astracap services reachable from the WAN | High | Disable the router's DNS server, add an inbound ACL and uRPF on the WAN interface, turn off CDP/proxy-ARP/redirects there. Needs `aaa authorization exec` so admin sessions land at privilege 15 (see [Astracap](network-astracap.md)). |
| iDRACs | High | Disable IPMI over LAN and the VNC server, disable SNMP where unused, raise the minimum TLS version, rotate the root passwords, update firmware. The mars iDRAC6 is end of life; keep its switch port shut when not in use. |
| Old secrets in git history | Medium | A Yubico OTP API key and an old user password hash were once committed. Rotate the Yubico credentials and confirm the user's password has changed since. |
| Switch management | Medium | Remove reversible (type 7) passwords, require keys for SSH, add NTP and syslog to ace. |
| Production panel cookie domain | Low | The live panel `.env` still scopes its session cookie to `.prestonhager.com`; make it host-only once the SSO cookie setup allows. |

## Planned

- **Network segmentation:** separate VLANs for management (router, switch, iDRACs), servers, game nodes, users/Wi‑Fi and IoT, with ACLs between them. Today everything shares VLAN 1, which limits how much any single control can contain.
- **Edge router replacement:** the Cisco 2911 and IOS 15.7 are past end of support.
- **Off-site, encrypted backups** for ace (restic currently writes to the same chassis) and disk encryption for `/stor`.
- **User namespaces** (`--userns=auto`) for rootful containers, starting with the runners.
- Dedicated, least-privilege router accounts for the Pterodactyl and Coolify NAT automation, and per-repository deploy keys instead of ace's GitHub account key.
- `pterodactyl-test-redis` authentication; secrets on command lines in the Pterodactyl panel bootstrap scripts.

## Accepted

- Coolify's own components (sentinel, proxy) need the Docker socket on mars; mars is dedicated to Coolify.
- The WireGuard portal container keeps `NET_ADMIN`.
- Jellyfin stays directly reachable on `192.168.5.5:8096` for TV and app clients on the LAN.
