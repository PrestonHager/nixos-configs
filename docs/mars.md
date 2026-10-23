# Mars (PowerEdge R410)

Dell PowerEdge **R410** host. Paired with a dedicated iDRAC 6 OOB interface.

| Field | Value |
|-------|-------|
| Hostname | `mars` |
| Host OS IPv4 | **`192.168.5.15/24`** static on `eno1` (`eno2` unused) |
| iDRAC IPv4 | **`192.168.5.11/24`** — [mars iDRAC](mars-idrac.md) |
| Gateway / DNS | `192.168.5.1` / ace `192.168.5.5`, then `1.1.1.1` |
| Hardware | 2× Xeon E5620, 24 GB RAM, PERC 6/i (one 465 GB virtual disk), legacy BIOS only |
| OS | NixOS, flake `.#mars` (`hosts/mars/`) |
| Role | [Coolify](../ace/coolify.md) deploy and build server (Coolify server id 2) |
| WAN | HTTP(S) via ace's Caddy; ports Coolify apps publish are NATed to mars by `coolify-edge-nat` |

## Configuration

- `hosts/mars/default.nix`: static IP, GRUB (no UEFI on the R410, so the systemd-boot default from `nixos/default.nix` is forced off), Docker with `liveRestore` and a weekly prune, keys-only SSH, node security agents and log shipping to Loki on ace.
- `hosts/mars/disko.nix`: GPT on `wwn-0x6d4ae520a94a3800154129fa075a156a` with a 1 MiB BIOS boot partition, 8 GiB swap and ext4 `/`.
- `nixos/coolify-node.nix` with `homelab.coolifyNode = { address = "192.168.5.15"; lanInterface = "eno1"; }`: Coolify's `coolify@ace` key for root (only from ace, no forwarding), `git`/`curl`/`jq`, and the container firewall:
  - **Inbound** (`coolify-ingress` chain, jumped from `DOCKER-USER`): on `eno1`, new connections to published container ports from private, CGNAT/tailnet or link-local sources are dropped, except ace to port 80 (the Traefik proxy Caddy forwards to). Public sources (internet clients that `coolify-edge-nat` forwards through the router) reach whatever Coolify publishes.
  - **Outbound** (`homelab.security.containerEgress`): app containers reach the internet but not the LAN, the tailnet or mars itself. Exceptions: DNS to ace (Docker hands containers the host's resolvers), and HTTPS to ace from the default `docker0` bridge only, for `coolify-sentinel`'s metrics push to `coolify.prestonhager.com`. Traffic between Docker networks (Traefik to apps) is left to Docker.
- SSH: only Nix-declared keys count and forwarding is off (`nixos/security/ssh.nix`).
- sops decrypts with the host SSH key only (`sops.age.keyFile = null`). Mars's age key is a recipient of `secrets/users.yaml` and the home-manager secrets in nixos-secrets, nothing else.

## Deploying

From ace, with root@ace's own key (`nixos/ace-git-identity.nix`):

```bash
cd /etc/nixos && nixos-rebuild switch --flake .#mars --target-host root@192.168.5.15
```

## Coolify

mars is Coolify's only deploy server (crux was removed on 2026-10-20). Registered by hand ([Coolify](../ace/coolify.md)): server `mars`, private key `crux-deploy` (the `coolify@ace` key from `coolify-node.nix`; the name is historical), marked reachable/usable directly because Coolify rejects `ID=nixos`.

The Traefik proxy (`coolify-proxy`, `/data/coolify/proxy/docker-compose.yml`) serves HTTP on :80 only and trusts `X-Forwarded-*` from ace (`--entrypoints.http.forwardedHeaders.trustedIPs=192.168.5.5/32`, also in Coolify's saved proxy configuration so a proxy restart from the UI keeps it). TLS terminates on ace's Caddy, which sends `*.apps.prestonhager.com` and every hostname a Coolify app uses that ace does not serve itself to `192.168.5.15:80`. Ports apps publish are forwarded from the WAN by `coolify-edge-nat` on ace. See [Routing traffic to apps](../ace/coolify.md#routing-traffic-to-apps).

```bash
docker ps                                   # coolify-proxy, coolify-sentinel, apps
docker logs coolify-proxy --tail 50
iptables -S DOCKER-USER                     # jumps to coolify-ingress and homelab-docker-user
iptables -S coolify-ingress                 # ace -> :80 RETURN, then private-source DROPs
iptables -S homelab-ctr-egress              # private-destination drops for app containers
journalctl -k --grep ctr-egress-drop        # containers that tried to reach the LAN
```

From a LAN client other than ace, `curl -m 5 http://192.168.5.15/` must time out; through ace's Caddy, app domains still load.

## Install notes (2026-10-20)

Installed with nixos-anywhere from ace. The live ISO on iDRAC virtual media hit intermittent read errors (`setsid`, the ext4 module, `unshare`), so kexec was not usable and GRUB was installed by chrooting into the installed system. For a reinstall, put the ISO on USB or boot it with `copytoram`.
