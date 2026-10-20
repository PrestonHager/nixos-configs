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
| WAN | None — LAN / outbound PAT only |

## Configuration

- `hosts/mars/default.nix`: static IP, GRUB (no UEFI on the R410, so the systemd-boot default from `nixos/default.nix` is forced off), Docker with `liveRestore` and a weekly prune, keys-only SSH, node security agents and log shipping to Loki on ace.
- `hosts/mars/disko.nix`: GPT on `wwn-0x6d4ae520a94a3800154129fa075a156a` with a 1 MiB BIOS boot partition, 8 GiB swap and ext4 `/`.
- `nixos/coolify-node.nix` with `homelab.coolifyNode.address = "192.168.5.15"`: Coolify's `coolify@ace` key for root, `git`/`curl`/`jq`, and a `DOCKER-USER` rule that drops port 80 from anything but ace.
- sops decrypts with the host SSH key only (`sops.age.keyFile = null`). Mars's age key is a recipient of `secrets/users.yaml` and the home-manager secrets in nixos-secrets, nothing else.

## Deploying

From ace, with root@ace's own key (`nixos/ace-git-identity.nix`):

```bash
cd /etc/nixos && nixos-rebuild switch --flake .#mars --target-host root@192.168.5.15
```

## Coolify

Registered like crux (`docs/coolify-ace.md`): server `mars`, private key `crux-deploy` (the `coolify@ace` key both nodes authorize), marked reachable/usable directly because Coolify rejects `ID=nixos`. The Traefik proxy uses crux's saved configuration: HTTP on :80 only, TLS on ace's Caddy.

Apps deployed to mars are reachable from ace on `192.168.5.15:80`. ace's Caddy still sends every `*.apps.prestonhager.com` request to crux, so a public hostname for a mars app needs its own entry in `nixos/caddy/coolify.nix`.

## Install notes (2026-10-20)

Installed with nixos-anywhere from ace. The live ISO on iDRAC virtual media hit intermittent read errors (`setsid`, the ext4 module, `unshare`), so kexec was not usable and GRUB was installed by chrooting into the installed system. For a reinstall, put the ISO on USB or boot it with `copytoram`.
