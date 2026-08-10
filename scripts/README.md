# Bootstrap scripts

## `bootstrap-minimal.sh`

Installs a **tiny stage0 NixOS** from a NixOS installer image so the machine
comes up on the LAN (DHCP on any ethernet NIC) with SSH root access. Use that
as the target for [nixos-anywhere](https://github.com/nix-community/nixos-anywhere)
to lay down the real host configuration (which will wipe the disk again).

### From the NixOS installer

```sh
curl -fsSL https://raw.githubusercontent.com/PrestonHager/nixos-configs/main/scripts/bootstrap-minimal.sh | sudo bash
```

Non-interactive (recommended):

```sh
curl -fsSL https://raw.githubusercontent.com/PrestonHager/nixos-configs/main/scripts/bootstrap-minimal.sh \
  | sudo bash -s -- -y -d /dev/nvme0n1 -k 'ssh-ed25519 AAAA... your-key'
```

From a LAN HTTP share:

```sh
curl -fsSL http://<lan-host>/bootstrap-minimal.sh \
  | sudo bash -s -- -y -d /dev/sda -f /path/to/authorized_keys
```

### After reboot

```sh
nix run github:nix-community/nixos-anywhere -- \
  --flake /path/to/nixos-configs#<host> \
  --target-host root@<dhcp-ip>
```

### What it configures

- GPT disk: EFI (or BIOS boot) + ext4 root, optional swap (`--swap 2G`)
- `systemd-networkd` DHCP matching `Type = "ether"` (any ethernet adapter)
- OpenSSH with root login (authorized keys and/or password)
- Minimal packages only (`vim`, `curl`, `git`, `iproute2`)
