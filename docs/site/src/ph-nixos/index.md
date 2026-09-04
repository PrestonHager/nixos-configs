# ph-nixos

Personal laptop/desktop NixOS configuration (MSI Summit E16 Flip).

| Field | Value |
|-------|-------|
| Hostname | `ph-nixos` |
| Flake | `nixos-rebuild switch --flake /etc/nixos#ph-nixos` |
| Desktop | GNOME (`nixos/gnome/`) |
| User | `prestonh` via home-manager |

## Imports

`hosts/ph-nixos/default.nix` pulls in the shared `nixos/` base, GNOME desktop stack, YubiKey support, and `users/prestonh` home-manager config (Neovim, Bitwarden CLI, SSH aliases for Astracap/Astraquasar, etc.).

Unlike ace and the Pterodactyl nodes, **ph-nixos does not run homelab services** — it is a client machine that uses LAN DNS (192.168.5.5), Vaultwarden SSH keys, and SSH to ace/crux/nova.

## Rebuild

```bash
sudo nixos-rebuild switch --flake /etc/nixos#ph-nixos
```

See **Shared → Network & SSH / Bitwarden** for Cisco device access and `bw ssh-agent` workflow.
